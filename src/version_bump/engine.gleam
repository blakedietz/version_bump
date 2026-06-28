//// The release pipeline orchestrator.
////
//// `run` wires the leaf modules (git, branches, commit_parser), the plugin
//// registry, and the hook runners into semantic-release's lifecycle:
////
////   1. resolve the current branch and build the shared `Context`
////   2. resolve each configured plugin against the registry
////   3. verify_conditions
////   4. find the last release from the git tags
////   5. read & parse the commits since that release
////   6. analyze_commits -> a release type (or stop: "no release")
////   7. compute the next version and build the `NextRelease`
////   8. verify_release
////   9. generate_notes -> attach to the next release
////   10. (dry-run) report and stop
////   11. prepare, then create & push the git tag
////   12. publish -> collect the produced releases
////   13. success
////
//// Any error after `verify_conditions` triggers the plugins' `fail` hooks
//// before the error is returned to the caller.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import version_bump/branch
import version_bump/commit_parser
import version_bump/config.{type Config}
import version_bump/context.{type Context, Context}
import version_bump/error.{type ReleaseError, ConfigError}
import version_bump/git
import version_bump/logging
import version_bump/registry
import version_bump/release.{type LastRelease, type Release, NextRelease}
import version_bump/runner.{type ResolvedPlugin}
import version_bump/semver.{type ReleaseType}
import version_bump/task.{type Task}

/// The outcome of a pipeline run.
///
/// `released` is `False` when nothing was published — either no commits
/// warranted a release, or the run was a dry-run. `version`/`notes` carry the
/// computed next release details when one was determined (even in a dry-run, so
/// callers can preview them); `releases` holds the artifacts published by the
/// `publish` hooks.
pub type Summary {
  Summary(
    released: Bool,
    version: Option(String),
    notes: Option(String),
    releases: List(Release),
  )
}

/// The default remote releases are pushed to.
const remote = "origin"

/// Run the full release pipeline for the project rooted at `cwd`.
///
/// Returns a `Task` because the `publish` stage is asynchronous: on Erlang the
/// task is synchronous; on JavaScript it is a promise. Callers run it with
/// `task.run`.
pub fn run(
  config: Config,
  cwd: String,
  env: Dict(String, String),
) -> Task(Result(Summary, ReleaseError)) {
  // Steps 1 & 2 happen before any plugin runs, so their failures are returned
  // directly without invoking `fail` hooks.
  case build_context(config, cwd, env) {
    Error(err) -> task.resolve(Error(err))
    Ok(ctx0) ->
      case resolve_plugins(config, ctx0) {
        Error(err) -> task.resolve(Error(err))
        // Everything from verify_conditions onward runs `fail` hooks on error.
        Ok(plugins) -> run_pipeline(config, ctx0, plugins)
      }
  }
}

// --- Setup (pre-plugin) -----------------------------------------------------

/// Resolve branches against the repository and build the initial context.
fn build_context(
  config: Config,
  cwd: String,
  env: Dict(String, String),
) -> Result(Context, ReleaseError) {
  use git_branches <- result.try(git.list_branches(cwd))
  use current <- result.try(git.current_branch(cwd))
  use #(branch, all_branches) <- result.try(branch.resolve(
    config,
    git_branches,
    current,
  ))
  logging.info("Running on branch '" <> branch.name <> "'")
  Ok(context.new(
    cwd: cwd,
    env: env,
    config: config,
    branch: branch,
    branches: all_branches,
  ))
}

/// Zip each configured `PluginSpec` with its registry `Plugin`, failing with a
/// `ConfigError` for any spec whose name is not a known built-in plugin.
fn resolve_plugins(
  config: Config,
  _ctx: Context,
) -> Result(List(ResolvedPlugin), ReleaseError) {
  let known = registry.default()
  list.try_map(config.plugins, fn(spec) {
    case dict.get(known, spec.name) {
      Ok(plugin) -> Ok(#(spec, plugin))
      Error(_) -> Error(ConfigError("Unknown plugin '" <> spec.name <> "'"))
    }
  })
}

// --- Pipeline (post-verify_conditions runs `fail` on error) -----------------

/// Drive the verify -> analyze -> prepare -> publish -> success pipeline. On
/// any error from `verify_conditions` onward, the plugins' `fail` hooks run
/// before the error is propagated. Asynchronous (publish), hence a `Task`.
fn run_pipeline(
  config: Config,
  context: Context,
  plugins: List(ResolvedPlugin),
) -> Task(Result(Summary, ReleaseError)) {
  use result <- task.map(pipeline(config, context, plugins))
  case result {
    Ok(summary) -> Ok(summary)
    Error(err) -> {
      logging.error(error.to_string(err))
      // Run fail hooks for effect; their own failure must not mask the original.
      let _ = runner.run_fail(plugins, context)
      Error(err)
    }
  }
}

/// The synchronous decision of whether (and what) to release. Either the run is
/// complete (`Halt`, e.g. no release or a dry-run) or it is ready to perform the
/// asynchronous publish tail (`Ready`).
type SyncOutcome {
  Halt(summary: Summary)
  Ready(context: Context, version: String, git_tag: String, notes: String)
}

/// The pipeline body. The synchronous stages (3-10) run in `sync_pipeline`;
/// only the publish tail is asynchronous, so it is lifted into a `Task` here.
fn pipeline(
  config: Config,
  context: Context,
  plugins: List(ResolvedPlugin),
) -> Task(Result(Summary, ReleaseError)) {
  case sync_pipeline(config, context, plugins) {
    Error(err) -> task.resolve(Error(err))
    Ok(Halt(summary)) -> task.resolve(Ok(summary))
    Ok(Ready(context, version, git_tag, notes)) ->
      finalize_release(context, plugins, version, git_tag, notes)
  }
}

/// The fully synchronous part of the pipeline: verify_conditions, find the last
/// release, read & analyze commits, compute the next version, verify_release,
/// generate notes, and apply the dry-run short-circuit.
fn sync_pipeline(
  config: Config,
  context: Context,
  plugins: List(ResolvedPlugin),
) -> Result(SyncOutcome, ReleaseError) {
  // 3) verify_conditions
  logging.info("Verifying conditions")
  use _ <- result.try(runner.run_verify_conditions(plugins, context))

  // 4) last release from the tags
  use last_release <- result.try(resolve_last_release(config, context))
  let context = Context(..context, last_release: last_release)
  log_last_release(last_release)

  // 5) commits since the last release
  use context <- result.try(load_commits(context, last_release))

  // 6) analyze commits
  logging.info("Analyzing commits")
  use release_type <- result.try(runner.run_analyze_commits(plugins, context))

  case release_type {
    None -> {
      logging.info(
        "There are no relevant changes, so no new version is released",
      )
      Ok(
        Halt(Summary(released: False, version: None, notes: None, releases: [])),
      )
    }
    Some(rtype) -> sync_continue(config, context, plugins, last_release, rtype)
  }
}

/// Synchronous continuation once a release is warranted: compute the version,
/// verify the release, generate notes, then decide between a dry-run halt and a
/// ready-to-publish outcome.
fn sync_continue(
  config: Config,
  context: Context,
  plugins: List(ResolvedPlugin),
  last_release: Option(LastRelease),
  rtype: ReleaseType,
) -> Result(SyncOutcome, ReleaseError) {
  // 7) next version & NextRelease
  use version <- result.try(branch.next_version(
    last_release,
    rtype,
    context.branch,
    config.versioning_mode,
  ))
  use head <- result.try(git.head_sha(context.cwd))
  let git_tag = render_tag(config.tag_format, version)
  let next =
    NextRelease(
      version: version,
      type_: rtype,
      git_tag: git_tag,
      git_head: head,
      channel: context.branch.channel,
      notes: "",
    )
  let context = Context(..context, next_release: Some(next))
  logging.info(
    "The next release version is "
    <> version
    <> " ("
    <> semver.release_type_to_string(rtype)
    <> ")",
  )

  // 8) verify_release
  logging.info("Verifying release")
  use _ <- result.try(runner.run_verify_release(plugins, context))

  // 9) generate notes
  logging.info("Generating release notes")
  use notes <- result.try(runner.run_generate_notes(plugins, context))
  let next = NextRelease(..next, notes: notes)
  let context = Context(..context, next_release: Some(next))

  // 10) dry-run short-circuit
  case config.dry_run {
    True -> {
      logging.warn("Dry-run: skipping prepare, tag, publish and success")
      logging.info("Release note for version " <> version <> ":")
      logging.info(notes)
      Ok(
        Halt(
          Summary(
            released: False,
            version: Some(version),
            notes: Some(notes),
            releases: [],
          ),
        ),
      )
    }
    False ->
      Ok(Ready(
        context: context,
        version: version,
        git_tag: git_tag,
        notes: notes,
      ))
  }
}

/// The asynchronous effecting tail: prepare & tag (synchronous), then publish
/// (asynchronous) and success.
fn finalize_release(
  context: Context,
  plugins: List(ResolvedPlugin),
  version: String,
  git_tag: String,
  notes: String,
) -> Task(Result(Summary, ReleaseError)) {
  // 11) prepare, then create & push the tag (all synchronous)
  case prepare_and_tag(context, plugins, version, git_tag) {
    Error(err) -> task.resolve(Error(err))
    Ok(Nil) -> {
      // 12) publish (asynchronous)
      logging.info("Publishing release")
      use published <- task.map(runner.run_publish(plugins, context))
      case published {
        Error(err) -> Error(err)
        Ok(releases) -> {
          let context = Context(..context, releases: releases)
          // 13) success
          logging.info("Running success hooks")
          case runner.run_success(plugins, context) {
            Error(err) -> Error(err)
            Ok(Nil) -> {
              logging.success("Published release " <> version)
              Ok(Summary(
                released: True,
                version: Some(version),
                notes: Some(notes),
                releases: releases,
              ))
            }
          }
        }
      }
    }
  }
}

/// Run `prepare`, then create and push the git tag. All synchronous.
fn prepare_and_tag(
  context: Context,
  plugins: List(ResolvedPlugin),
  version: String,
  git_tag: String,
) -> Result(Nil, ReleaseError) {
  logging.info("Preparing release")
  use _ <- result.try(runner.run_prepare(plugins, context))

  logging.info("Creating git tag " <> git_tag)
  use _ <- result.try(git.create_tag(context.cwd, git_tag, version))

  // Push the branch first (so a release commit made by the `git` plugin lands on
  // it), then the tag — which now points at that commit. With no `git` plugin
  // configured the branch push is a harmless no-op (HEAD is unchanged).
  use _ <- result.try(git.push(
    context.cwd,
    remote,
    "HEAD:" <> context.branch.name,
  ))
  git.push(context.cwd, remote, git_tag)
}

// --- helpers ----------------------------------------------------------------

/// Read the repository's tags and pick the last release for the current branch.
fn resolve_last_release(
  config: Config,
  context: Context,
) -> Result(Option(LastRelease), ReleaseError) {
  use tags <- result.map(git.get_tags(context.cwd))
  branch.last_release(tags, context.branch, config.tag_format)
}

/// Load the commits since the last release into the context, parsing each into
/// a `ConventionalCommit`.
fn load_commits(
  context: Context,
  last_release: Option(LastRelease),
) -> Result(Context, ReleaseError) {
  let from = case last_release {
    Some(release) ->
      case string.trim(release.git_head) {
        "" -> option_from_tag(release)
        head -> Some(head)
      }
    None -> None
  }
  use commits <- result.map(git.log_since(context.cwd, from))
  let parsed = list.map(commits, commit_parser.parse)
  logging.info("Found " <> int.to_string(list.length(parsed)) <> " commit(s)")
  Context(..context, commits: parsed)
}

/// The git_head to range from, defaulting to the tag when no SHA was recorded.
fn option_from_tag(release: LastRelease) -> Option(String) {
  case string.trim(release.git_tag) {
    "" -> None
    tag -> Some(tag)
  }
}

/// Render a tag from a `tag_format` by substituting the version placeholder.
fn render_tag(tag_format: String, version: String) -> String {
  string.replace(tag_format, "${version}", version)
}

/// Log the discovered last release, or note that this is the first one.
fn log_last_release(last_release: Option(LastRelease)) -> Nil {
  case last_release {
    Some(release) -> logging.info("Found previous release " <> release.version)
    None -> logging.info("No previous release found")
  }
}

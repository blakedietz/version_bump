//// The GitHub publish plugin.
////
//// Mirrors `@semantic-release/github`'s core responsibility: authenticate with
//// a GitHub token, resolve the target repository, and create a GitHub Release
//// for the version semantic-release just determined.
////
//// Hooks implemented:
////   - verify_conditions: a `GITHUB_TOKEN`/`GH_TOKEN` and a resolvable
////     repository URL must be present, otherwise the pipeline aborts.
////   - publish:           create the GitHub release and return it.
////   - success:           log that the release was published.
////
//// Effectful work (HTTP, environment access) is kept in the hook bodies; the
//// pure decision logic lives in helpers (`resolve_token`, `is_prerelease`,
//// `verify`) so it can be unit-tested without a network or live environment.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/string

import envoy

import version_bump/config.{type Config}
import version_bump/context.{type Context}
import version_bump/error.{type ReleaseError, PluginError}
import version_bump/github_api
import version_bump/logging
import version_bump/plugin.{type Plugin, Plugin}
import version_bump/release.{type NextRelease, type Release}
import version_bump/task.{type Task}

const name = "github"

/// The plugin record, wiring up the GitHub hooks.
pub fn plugin() -> Plugin {
  Plugin(
    ..plugin.new(name),
    verify_conditions: Some(do_verify_conditions),
    publish: Some(do_publish),
    success: Some(do_success),
  )
}

// --- verify_conditions -----------------------------------------------------

/// Ensure a GitHub token and a resolvable repository are available before the
/// pipeline does any work.
fn do_verify_conditions(
  _spec: config.PluginSpec,
  context: Context,
) -> Result(Nil, ReleaseError) {
  // A dry run never creates a GitHub release, so a token is not required to
  // preview the next release — matching @semantic-release/github's behaviour.
  case context.dry_run {
    True -> Ok(Nil)
    False -> {
      let token = resolve_token(context.env)
      verify(token, context.config)
    }
  }
}

/// PURE verification: given a resolved token (if any) and the config, decide
/// whether the GitHub plugin can run. Separated out so it can be tested without
/// touching the process environment.
pub fn verify(
  token: Option(String),
  config: Config,
) -> Result(Nil, ReleaseError) {
  case token {
    None ->
      Error(PluginError(
        name,
        "No GitHub token found. Set the GITHUB_TOKEN or GH_TOKEN environment "
          <> "variable.",
      ))
    Some(_) ->
      case resolve_repo_url(config) {
        None ->
          Error(PluginError(
            name,
            "No repository URL configured. Set `repositoryUrl` so the GitHub "
              <> "release can be created.",
          ))
        Some(url) ->
          case github_api.parse_repo_url(url) {
            Ok(_) -> Ok(Nil)
            Error(_) ->
              Error(PluginError(
                name,
                "Could not parse a GitHub owner/repo from repository URL: "
                  <> url,
              ))
          }
      }
  }
}

// --- publish ---------------------------------------------------------------

/// Create a GitHub release for the upcoming version and return it.
///
/// The synchronous pre-flight (token, repo URL, next release, owner/repo) is
/// gathered first; only the HTTP create-release call is asynchronous.
fn do_publish(
  _spec: config.PluginSpec,
  context: Context,
) -> Task(Result(Option(Release), ReleaseError)) {
  case gather_publish_inputs(context) {
    Error(err) -> task.resolve(Error(err))
    Ok(#(token, owner, repo, next_release)) -> {
      let prerelease = is_prerelease(next_release)
      let head = next_release.git_head

      github_api.create_release(
        token,
        owner,
        repo,
        next_release.git_tag,
        next_release.version,
        next_release.notes,
        prerelease,
        head,
      )
      |> task.map(fn(result) {
        case result {
          Ok(release) -> Ok(Some(release))
          Error(err) -> Error(adapt_error(err))
        }
      })
    }
  }
}

/// Collect the synchronous inputs `do_publish` needs, short-circuiting with a
/// `PluginError` if any are missing or unparseable.
fn gather_publish_inputs(
  context: Context,
) -> Result(#(String, String, String, NextRelease), ReleaseError) {
  use token <- with_token(context.env)
  use url <- with_repo_url(context.config)
  use next_release <- with_next_release(context)
  use #(owner, repo) <- with_parsed_repo(url)
  Ok(#(token, owner, repo, next_release))
}

// --- success ---------------------------------------------------------------

/// Log that the GitHub release was published. MVP: a single log line.
fn do_success(
  _spec: config.PluginSpec,
  context: Context,
) -> Result(Nil, ReleaseError) {
  let message = case context.next_release {
    Some(next_release) -> "Published GitHub release " <> next_release.git_tag
    None -> "Published GitHub release"
  }
  logging.success(message)
  Ok(Nil)
}

// --- pure helpers ----------------------------------------------------------

/// Whether the upcoming release is a prerelease (i.e. its channel-tied version
/// carries a prerelease identifier such as `-beta.1`).
pub fn is_prerelease(next_release: NextRelease) -> Bool {
  string.contains(next_release.version, "-")
}

/// Resolve a GitHub token from the supplied environment, preferring
/// `GITHUB_TOKEN` over `GH_TOKEN`, falling back to the live process environment
/// when neither key is present in the passed-in dictionary.
fn resolve_token(env: Dict(String, String)) -> Option(String) {
  case env_lookup(env, "GITHUB_TOKEN") {
    Some(token) -> Some(token)
    None ->
      case env_lookup(env, "GH_TOKEN") {
        Some(token) -> Some(token)
        None ->
          case envoy_lookup("GITHUB_TOKEN") {
            Some(token) -> Some(token)
            None -> envoy_lookup("GH_TOKEN")
          }
      }
  }
}

/// The configured repository URL, treating an empty/whitespace value as absent.
fn resolve_repo_url(config: Config) -> Option(String) {
  case config.repository_url {
    Some(url) ->
      case string.trim(url) {
        "" -> None
        trimmed -> Some(trimmed)
      }
    None -> None
  }
}

/// Look up a key in the passed-in environment, treating empty/whitespace-only
/// values as absent.
fn env_lookup(env: Dict(String, String), key: String) -> Option(String) {
  case dict.get(env, key) {
    Ok(value) -> non_empty(value)
    Error(_) -> None
  }
}

/// Look up a key in the live process environment via `envoy`.
fn envoy_lookup(key: String) -> Option(String) {
  case envoy.get(key) {
    Ok(value) -> non_empty(value)
    Error(_) -> None
  }
}

fn non_empty(value: String) -> Option(String) {
  case string.trim(value) {
    "" -> None
    trimmed -> Some(trimmed)
  }
}

/// Map a transport-level error onto the plugin's namespace so failures are
/// attributed to the GitHub plugin in aggregate reporting.
fn adapt_error(err: ReleaseError) -> ReleaseError {
  PluginError(name, error.to_string(err))
}

// --- `use`-friendly guard helpers ------------------------------------------
// Each returns the required value or short-circuits with a PluginError, keeping
// `do_publish` a flat sequence of `use` bindings.

fn with_token(
  env: Dict(String, String),
  next: fn(String) -> Result(a, ReleaseError),
) -> Result(a, ReleaseError) {
  case resolve_token(env) {
    Some(token) -> next(token)
    None ->
      Error(PluginError(
        name,
        "No GitHub token found. Set the GITHUB_TOKEN or GH_TOKEN environment "
          <> "variable.",
      ))
  }
}

fn with_repo_url(
  config: Config,
  next: fn(String) -> Result(a, ReleaseError),
) -> Result(a, ReleaseError) {
  case resolve_repo_url(config) {
    Some(url) -> next(url)
    None -> Error(PluginError(name, "No repository URL configured."))
  }
}

fn with_next_release(
  context: Context,
  next: fn(NextRelease) -> Result(a, ReleaseError),
) -> Result(a, ReleaseError) {
  case context.next_release {
    Some(next_release) -> next(next_release)
    None -> Error(PluginError(name, "No next release to publish to GitHub."))
  }
}

fn with_parsed_repo(
  url: String,
  next: fn(#(String, String)) -> Result(a, ReleaseError),
) -> Result(a, ReleaseError) {
  case github_api.parse_repo_url(url) {
    Ok(owner_repo) -> next(owner_repo)
    Error(err) -> Error(adapt_error(err))
  }
}

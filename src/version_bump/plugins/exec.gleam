//// The `exec` plugin — semantic-release's escape hatch.
////
//// Instead of implementing a hook in Gleam, the user supplies a shell command
//// for any lifecycle step via `PluginSpec.options`. Each option key maps to one
//// hook; when present, that hook runs the command through `sh -c` in the
//// project's `cwd`:
////
////   - `verifyConditionsCmd` -> verify_conditions
////   - `analyzeCommitsCmd`   -> analyze_commits
////   - `verifyReleaseCmd`    -> verify_release
////   - `generateNotesCmd`    -> generate_notes
////   - `prepareCmd`          -> prepare
////   - `publishCmd`          -> publish
////   - `successCmd`          -> success
////   - `failCmd`             -> fail
////
//// Hook semantics:
////   - analyze_commits: the trimmed stdout is parsed into a `ReleaseType`
////     ("major"/"minor"/"patch" -> `Some(..)`, empty / anything else -> `None`).
////   - generate_notes:  the trimmed stdout becomes the release notes.
////   - publish:         currently signals "not handled" (`None`) on success,
////     since the command produces no structured `Release`.
////   - everything else: a non-zero exit aborts the pipeline with a `PluginError`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import shellout
import version_bump/config.{type PluginSpec}
import version_bump/context.{type Context}
import version_bump/error.{type ReleaseError, PluginError}
import version_bump/plugin.{type Plugin}
import version_bump/release.{type Release}
import version_bump/semver.{type ReleaseType, Major, Minor, Patch}
import version_bump/task.{type Task}

/// The plugin's registered name.
const name = "exec"

/// Build the `exec` plugin, wiring every hook to the command runner. Each hook
/// looks up its corresponding option key at call time; if the key is absent the
/// hook is a no-op (it returns the neutral value for that step), so a single
/// plugin record can serve any subset of configured commands.
pub fn plugin() -> Plugin {
  plugin.Plugin(
    ..plugin.new(name),
    verify_conditions: Some(verify_conditions),
    analyze_commits: Some(analyze_commits),
    verify_release: Some(verify_release),
    generate_notes: Some(generate_notes),
    prepare: Some(prepare),
    publish: Some(publish),
    success: Some(success),
    fail: Some(fail),
  )
}

// --- Hooks -----------------------------------------------------------------

/// Run `verifyConditionsCmd` for effect; absent key is a no-op.
fn verify_conditions(
  spec: PluginSpec,
  context: Context,
) -> Result(Nil, ReleaseError) {
  run_for_effect(spec, context, "verifyConditionsCmd")
}

/// Run `analyzeCommitsCmd` and parse its stdout into a `ReleaseType`. With no
/// command configured the plugin contributes no opinion (`None`).
fn analyze_commits(
  spec: PluginSpec,
  context: Context,
) -> Result(Option(ReleaseType), ReleaseError) {
  case command_for(spec, "analyzeCommitsCmd") {
    None -> Ok(None)
    Some(cmd) -> {
      use stdout <- result.map(run(cmd, context.cwd))
      parse_release_type(stdout)
    }
  }
}

/// Run `verifyReleaseCmd` for effect; absent key is a no-op.
fn verify_release(
  spec: PluginSpec,
  context: Context,
) -> Result(Nil, ReleaseError) {
  run_for_effect(spec, context, "verifyReleaseCmd")
}

/// Run `generateNotesCmd`; its trimmed stdout is the notes. With no command the
/// plugin contributes no notes (the empty string).
fn generate_notes(
  spec: PluginSpec,
  context: Context,
) -> Result(String, ReleaseError) {
  case command_for(spec, "generateNotesCmd") {
    None -> Ok("")
    Some(cmd) -> {
      use stdout <- result.map(run(cmd, context.cwd))
      string.trim(stdout)
    }
  }
}

/// Run `prepareCmd` for effect; absent key is a no-op.
fn prepare(spec: PluginSpec, context: Context) -> Result(Nil, ReleaseError) {
  run_for_effect(spec, context, "prepareCmd")
}

/// Run `publishCmd` for effect. The command yields no structured `Release`, so
/// a successful run reports "not handled" (`None`); the engine still treats the
/// step as having run.
fn publish(
  spec: PluginSpec,
  context: Context,
) -> Task(Result(Option(Release), ReleaseError)) {
  task.resolve(case command_for(spec, "publishCmd") {
    None -> Ok(None)
    Some(cmd) -> {
      use _ <- result.map(run(cmd, context.cwd))
      None
    }
  })
}

/// Run `successCmd` for effect; absent key is a no-op.
fn success(spec: PluginSpec, context: Context) -> Result(Nil, ReleaseError) {
  run_for_effect(spec, context, "successCmd")
}

/// Run `failCmd` for effect; absent key is a no-op.
fn fail(spec: PluginSpec, context: Context) -> Result(Nil, ReleaseError) {
  run_for_effect(spec, context, "failCmd")
}

// --- Pure helpers ----------------------------------------------------------

/// Parse the trimmed stdout of an `analyzeCommitsCmd` into a `ReleaseType`.
///
/// PURE. Matches semantic-release/exec semantics: the command prints the bump
/// type on stdout. `"major"`/`"minor"`/`"patch"` (case-insensitive, surrounding
/// whitespace ignored) map to `Some(..)`; empty output or any other value means
/// "no release" (`None`).
pub fn parse_release_type(stdout: String) -> Option(ReleaseType) {
  case string.lowercase(string.trim(stdout)) {
    "major" -> Some(Major)
    "minor" -> Some(Minor)
    "patch" -> Some(Patch)
    _ -> None
  }
}

/// Look up the command string for an option key, treating a present-but-blank
/// value the same as an absent key (`None`).
fn command_for(spec: PluginSpec, key: String) -> Option(String) {
  case get_option(spec.options, key) {
    Some(cmd) ->
      case string.trim(cmd) {
        "" -> None
        _ -> Some(cmd)
      }
    None -> None
  }
}

/// `Some(value)` when `key` is present in the options dict, else `None`.
fn get_option(options: Dict(String, String), key: String) -> Option(String) {
  case dict.get(options, key) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

// --- Effectful helpers -----------------------------------------------------

/// Run the command for the given option key only for its exit status; a
/// non-zero exit becomes a `PluginError`. A missing key is a successful no-op.
fn run_for_effect(
  spec: PluginSpec,
  context: Context,
  key: String,
) -> Result(Nil, ReleaseError) {
  case command_for(spec, key) {
    None -> Ok(Nil)
    Some(cmd) -> {
      use _ <- result.map(run(cmd, context.cwd))
      Nil
    }
  }
}

/// Execute `cmd` through `sh -c` in `cwd`, returning captured stdout (with
/// stderr folded in by shellout's default) or a `PluginError` carrying the exit
/// code and output on failure.
fn run(cmd: String, cwd: String) -> Result(String, ReleaseError) {
  shellout.command(run: "sh", with: ["-c", cmd], in: cwd, opt: [])
  |> result.map_error(fn(failure) {
    let #(code, message) = failure
    PluginError(
      name,
      "command `"
        <> cmd
        <> "` failed (exit "
        <> int.to_string(code)
        <> "): "
        <> string.trim(message),
    )
  })
}

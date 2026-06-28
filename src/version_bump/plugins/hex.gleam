//// The Hex / Gleam publish plugin (plugin name "hex").
////
//// The Gleam analogue of `@semantic-release/npm`. It publishes the package to
//// the Hex package repository with `gleam publish`. Two things differ from npm:
//// the version lives in `gleam.toml` (not `package.json`), and Hex has no
//// dist-tag / channel concept, so `add_channel` is intentionally NOT implemented
//// (a prerelease is published as an ordinary semver prerelease and Hex surfaces
//// it as such).
////
////   - verify_conditions: a `gleam.toml` exists in `context.cwd` carrying the
////     `description` and `licences` fields that `gleam publish` requires, and a
////     `HEXPM_API_KEY` is available (skipped on a dry run, since a dry run never
////     publishes — matching the npm/github plugins here).
////   - prepare: rewrite the top-level `version` field of `gleam.toml`.
////   - publish: run `gleam publish --yes` and report the hex.pm release URL.
////
//// `set_version` and `package_name` are PURE string functions, exported so the
//// version rewrite and URL construction can be unit-tested without any IO.

import envoy
import gleam/dict
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/regexp.{type Regexp, Match, Options}
import gleam/result
import gleam/string
import shellout
import simplifile

import version_bump/config.{type PluginSpec}
import version_bump/context.{type Context}
import version_bump/error.{type ReleaseError, PluginError}
import version_bump/plugin.{type Plugin}
import version_bump/release.{type NextRelease, type Release, Release}
import version_bump/task.{type Task}

/// The plugin's own name; used in `PluginError`s and the produced `Release`.
const plugin_name = "hex"

/// Build the Hex plugin: implements `verify_conditions`, `prepare`, and
/// `publish`. There is deliberately no `add_channel` — Hex has no dist-tags.
pub fn plugin() -> Plugin {
  plugin.Plugin(
    ..plugin.new(plugin_name),
    verify_conditions: Some(verify_conditions),
    prepare: Some(prepare),
    publish: Some(publish),
  )
}

// --- verify_conditions ------------------------------------------------------

/// Ensure `gleam.toml` exists with the metadata `gleam publish` requires, and
/// that a Hex API key is available (except on a dry run).
fn verify_conditions(
  _spec: PluginSpec,
  context: Context,
) -> Result(Nil, ReleaseError) {
  use contents <- result.try(read_gleam_toml(context.cwd))
  use _ <- result.try(ensure_publishable_metadata(contents))
  case context.dry_run {
    True -> Ok(Nil)
    False -> ensure_api_key(context)
  }
}

/// Read `gleam.toml`, mapping a missing/unreadable file to a clear error.
fn read_gleam_toml(cwd: String) -> Result(String, ReleaseError) {
  let path = gleam_toml_path(cwd)
  case simplifile.read(path) {
    Ok(contents) -> Ok(contents)
    Error(_) ->
      Error(PluginError(plugin_name, "no gleam.toml found at " <> path))
  }
}

/// `gleam publish` refuses to publish a package without `description` and
/// `licences`, so verify they are present (and uncommented) up front rather than
/// failing after the version has already been bumped and tagged.
fn ensure_publishable_metadata(contents: String) -> Result(Nil, ReleaseError) {
  use _ <- result.try(require_field(contents, "description"))
  require_field(contents, "licences")
}

fn require_field(contents: String, field: String) -> Result(Nil, ReleaseError) {
  case field_present(contents, field) {
    True -> Ok(Nil)
    False ->
      Error(PluginError(
        plugin_name,
        "gleam.toml is missing the `"
          <> field
          <> "` field, which `gleam publish` requires to publish to Hex",
      ))
  }
}

/// True when `field` appears as an uncommented top-level key. A leading `#`
/// (comment) prevents a match, so the commented placeholders in a freshly
/// scaffolded `gleam.toml` are correctly treated as absent.
fn field_present(contents: String, field: String) -> Bool {
  case compile_ml("^[ \t]*" <> field <> "[ \t]*=") {
    Ok(re) ->
      case regexp.scan(with: re, content: contents) {
        [] -> False
        _ -> True
      }
    Error(_) -> False
  }
}

/// Verify that a `HEXPM_API_KEY` is available, checking the context environment
/// first and falling back to the live process environment.
fn ensure_api_key(context: Context) -> Result(Nil, ReleaseError) {
  case api_key(context) {
    Some(_) -> Ok(Nil)
    None ->
      Error(PluginError(
        plugin_name,
        "HEXPM_API_KEY is not set (run `gleam hex authenticate` to create a key, "
          <> "then expose it as HEXPM_API_KEY in CI)",
      ))
  }
}

/// Resolve the Hex API key from `context.env`, falling back to the live process
/// environment. Empty/whitespace-only values are treated as absent.
fn api_key(context: Context) -> Option(String) {
  let from_ctx = case dict.get(context.env, "HEXPM_API_KEY") {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
  let key = case from_ctx {
    Some(value) -> Some(value)
    None ->
      case envoy.get("HEXPM_API_KEY") {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
  }
  case key {
    Some(value) ->
      case string.trim(value) {
        "" -> None
        trimmed -> Some(trimmed)
      }
    None -> None
  }
}

// --- prepare ----------------------------------------------------------------

/// Rewrite `gleam.toml`'s `version` to the next release version, in place.
fn prepare(_spec: PluginSpec, context: Context) -> Result(Nil, ReleaseError) {
  use next <- result.try(require_next_release(context))
  let path = gleam_toml_path(context.cwd)
  use contents <- result.try(read_file(path))
  use updated <- result.try(set_version(contents, next.version))
  write_file(path, updated)
}

// --- publish ----------------------------------------------------------------

/// Run `gleam publish --yes` in `context.cwd` and report the resulting release. The
/// `HEXPM_API_KEY` in the environment is inherited by the subprocess.
fn publish(
  _spec: PluginSpec,
  context: Context,
) -> Task(Result(Option(Release), ReleaseError)) {
  task.resolve({
    use next <- result.try(require_next_release(context))
    use _ <- result.try(run_gleam_publish(context.cwd))
    Ok(
      Some(Release(
        name: plugin_name,
        url: release_url(context.cwd, next.version),
        version: next.version,
        git_tag: next.git_tag,
        channel: next.channel,
        plugin_name: plugin_name,
      )),
    )
  })
}

/// Run `gleam publish` and confirm from its output that the package was actually
/// published — never trusting the exit code alone.
fn run_gleam_publish(cwd: String) -> Result(Nil, ReleaseError) {
  // `gleam publish` guards releases below 1.0.0 behind a prompt that requires
  // typing the exact phrase below, and `--yes` does NOT auto-accept it. In CI
  // (no TTY, stdin at EOF) that prompt reads "" and the publish silently aborts
  // — yet still exits 0. So pipe the phrase into stdin via a shell: 0.x releases
  // then publish non-interactively, `--yes` still covers the ordinary y/N
  // confirmation, and for >= 1.0.0 the piped line is simply never read. (Assumes
  // a POSIX `sh`, true on the Linux/macOS runners where releases run.)
  let publish =
    "echo 'I am not using semantic versioning' | gleam publish --yes"
  case shellout.command(run: "sh", with: ["-c", publish], in: cwd, opt: []) {
    // gleam publish can exit 0 WITHOUT publishing (it abandons that 0.x prompt
    // on EOF) — that false success is exactly what once let a non-publish sail
    // through as green. So confirm the success line is present; the captured
    // output is surfaced verbatim on failure for debugging.
    Ok(output) ->
      case published_ok(output) {
        True -> Ok(Nil)
        False ->
          Error(PluginError(
            plugin_name,
            "`gleam publish` exited 0 but did not report a successful publish "
              <> "(no \"Published package\" in its output) — it likely aborted a "
              <> "prompt. Output:\n"
              <> string.trim(output),
          ))
      }
    Error(#(code, message)) ->
      Error(PluginError(
        plugin_name,
        "`gleam publish` failed (exit "
          <> int.to_string(code)
          <> "): "
          <> string.trim(message),
      ))
  }
}

/// True when `gleam publish` output confirms a successful publish. gleam prints
/// "Published package and documentation" on success; the lowercase "published"
/// in its <1.0.0 warning does not contain this marker, so an aborted publish is
/// correctly treated as a failure. Exposed for testing.
pub fn published_ok(output: String) -> Bool {
  string.contains(output, "Published package")
}

/// Best-effort hex.pm URL for the published release; `None` if the package name
/// cannot be read (publishing already succeeded, so this is not fatal).
fn release_url(cwd: String, version: String) -> Option(String) {
  case read_file(gleam_toml_path(cwd)) {
    Ok(contents) ->
      case package_name(contents) {
        Ok(name) -> Some("https://hex.pm/packages/" <> name <> "/" <> version)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

// --- pure helpers (exported for testing) ------------------------------------

/// Replace the top-level `version = "..."` value in a `gleam.toml` document with
/// `version`, leaving the rest of the file intact. PURE.
pub fn set_version(
  gleam_toml: String,
  version: String,
) -> Result(String, ReleaseError) {
  case compile_ml("(^[ \t]*version[ \t]*=[ \t]*\")([^\"]*)\"") {
    Error(message) -> Error(PluginError(plugin_name, message))
    Ok(re) ->
      case regexp.scan(with: re, content: gleam_toml) {
        [Match(content: matched, submatches: [Some(prefix), _old]), ..] -> {
          let replacement = prefix <> version <> "\""
          Ok(replace_first(gleam_toml, matched, replacement))
        }
        _ ->
          Error(PluginError(
            plugin_name,
            "no top-level `version` field found in gleam.toml",
          ))
      }
  }
}

/// Read the package `name` from a `gleam.toml` document. PURE.
pub fn package_name(gleam_toml: String) -> Result(String, ReleaseError) {
  case compile_ml("^[ \t]*name[ \t]*=[ \t]*\"([^\"]*)\"") {
    Error(message) -> Error(PluginError(plugin_name, message))
    Ok(re) ->
      case regexp.scan(with: re, content: gleam_toml) {
        [Match(content: _, submatches: [Some(name)]), ..] -> Ok(name)
        _ ->
          Error(PluginError(plugin_name, "no `name` field found in gleam.toml"))
      }
  }
}

// --- shared helpers ---------------------------------------------------------

/// Compile a multi-line regexp so `^` anchors to each line start.
fn compile_ml(pattern: String) -> Result(Regexp, String) {
  regexp.compile(
    pattern,
    with: Options(case_insensitive: False, multi_line: True),
  )
  |> result.map_error(fn(err) { "invalid regexp: " <> err.error })
}

/// Replace only the first occurrence of `needle` in `haystack`.
fn replace_first(
  haystack: String,
  needle: String,
  replacement: String,
) -> String {
  case string.split_once(haystack, needle) {
    Ok(#(before, after)) -> before <> replacement <> after
    Error(_) -> haystack
  }
}

/// The path to `gleam.toml` within the working directory.
fn gleam_toml_path(cwd: String) -> String {
  case string.ends_with(cwd, "/") {
    True -> cwd <> "gleam.toml"
    False -> cwd <> "/gleam.toml"
  }
}

/// Read a file, mapping any failure to a `PluginError`.
fn read_file(path: String) -> Result(String, ReleaseError) {
  simplifile.read(path)
  |> result.map_error(fn(err) {
    PluginError(
      plugin_name,
      "could not read " <> path <> ": " <> simplifile.describe_error(err),
    )
  })
}

/// Write a file, mapping any failure to a `PluginError`.
fn write_file(path: String, contents: String) -> Result(Nil, ReleaseError) {
  simplifile.write(to: path, contents: contents)
  |> result.map_error(fn(err) {
    PluginError(
      plugin_name,
      "could not write " <> path <> ": " <> simplifile.describe_error(err),
    )
  })
}

/// Extract the next release from the context, failing when the pipeline has not
/// determined one (handled rather than asserted).
fn require_next_release(context: Context) -> Result(NextRelease, ReleaseError) {
  case context.next_release {
    Some(next) -> Ok(next)
    None -> Error(PluginError(plugin_name, "no next release determined"))
  }
}

//// The npm publish plugin (plugin name "npm").
////
//// Mirrors `@semantic-release/npm`. It manages a `package.json` and the npm
//// registry across three hooks:
////
////   - verify_conditions: there must be a `package.json` in `context.cwd` and an
////     `NPM_TOKEN` available (checked in `context.env`, then the process env).
////   - prepare: rewrite the `"version"` field of `package.json` to the next
////     release version, preserving the rest of the file verbatim.
////   - publish: run `npm publish` in `context.cwd`, returning a `Release`.
////
//// The only PURE function is `set_version`, which performs the `package.json`
//// version rewrite as a string transformation so it can be unit-tested without
//// any IO. It is exported for that reason.

import envoy
import gleam/dict
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/regexp.{type Regexp, Match}
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
const plugin_name = "npm"

/// Build the npm plugin: implements `verify_conditions`, `prepare`, and
/// `publish`.
pub fn plugin() -> Plugin {
  plugin.Plugin(
    ..plugin.new(plugin_name),
    verify_conditions: Some(verify_conditions),
    prepare: Some(prepare),
    publish: Some(publish),
  )
}

// --- verify_conditions ------------------------------------------------------

/// Ensure a `package.json` exists in `context.cwd` and an npm auth token is present.
fn verify_conditions(
  _spec: PluginSpec,
  context: Context,
) -> Result(Nil, ReleaseError) {
  use _ <- result.try(ensure_package_json_exists(context.cwd))
  // A dry run never publishes, so npm credentials are not required to preview
  // the next release — matching @semantic-release/npm's dry-run behaviour.
  case context.dry_run {
    True -> Ok(Nil)
    False -> ensure_npm_token(context)
  }
}

/// Verify that `package.json` is present in the working directory.
fn ensure_package_json_exists(cwd: String) -> Result(Nil, ReleaseError) {
  let path = package_json_path(cwd)
  case simplifile.is_file(path) {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) ->
      Error(PluginError(plugin_name, "no package.json found at " <> path))
  }
}

/// Verify that an `NPM_TOKEN` is available, checking the context environment
/// first and falling back to the live process environment.
fn ensure_npm_token(context: Context) -> Result(Nil, ReleaseError) {
  case npm_token(context) {
    Some(_) -> Ok(Nil)
    None ->
      Error(PluginError(
        plugin_name,
        "NPM_TOKEN environment variable is not set",
      ))
  }
}

/// Resolve the npm auth token from `context.env`, falling back to the live process
/// environment. Empty/whitespace-only values are treated as absent.
fn npm_token(context: Context) -> Option(String) {
  let from_ctx = case dict.get(context.env, "NPM_TOKEN") {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
  let token = case from_ctx {
    Some(value) -> Some(value)
    None ->
      case envoy.get("NPM_TOKEN") {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
  }
  case token {
    Some(value) ->
      case string.trim(value) {
        "" -> None
        trimmed -> Some(trimmed)
      }
    None -> None
  }
}

// --- prepare ----------------------------------------------------------------

/// Rewrite `package.json`'s `version` to the next release version and write it
/// back to disk.
fn prepare(_spec: PluginSpec, context: Context) -> Result(Nil, ReleaseError) {
  use next <- result.try(require_next_release(context))
  let path = package_json_path(context.cwd)
  use contents <- result.try(read_file(path))
  use updated <- result.try(set_version(contents, next.version))
  write_file(path, updated)
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

/// Replace the top-level `"version"` field in a `package.json` document with
/// `version`, leaving the rest of the document byte-for-byte intact.
///
/// PURE: a string transformation, no IO. Returns a `PluginError` when no
/// `"version"` field is present so callers can surface a clear message rather
/// than silently producing a package.json without a version.
///
/// The match targets the first `"version": "..."` pair, which in a well-formed
/// `package.json` is the top-level package version. Only the quoted value is
/// rewritten; surrounding whitespace and formatting are preserved.
pub fn set_version(
  package_json: String,
  version: String,
) -> Result(String, ReleaseError) {
  case version_regexp() {
    Error(message) -> Error(PluginError(plugin_name, message))
    Ok(re) ->
      case regexp.scan(with: re, content: package_json) {
        [Match(content: matched, submatches: [Some(prefix), _old]), ..] -> {
          let replacement = prefix <> escape_json_string(version) <> "\""
          Ok(replace_first(package_json, matched, replacement))
        }
        _ ->
          Error(PluginError(
            plugin_name,
            "no \"version\" field found in package.json",
          ))
      }
  }
}

/// Compile the regexp matching a JSON `"version": "<value>"` pair.
///
/// Submatch 1 captures everything up to and including the opening quote of the
/// value (the key, colon, whitespace, and opening `"`); submatch 2 captures the
/// existing value. Rebuilding `prefix <> new_value <> "\""` preserves the
/// original key spacing while swapping only the value.
fn version_regexp() -> Result(Regexp, String) {
  let pattern = "(\"version\"\\s*:\\s*\")((?:\\\\.|[^\"\\\\])*)\""
  regexp.from_string(pattern)
  |> result.map_error(fn(err) { "invalid version regexp: " <> err.error })
}

/// Replace only the first occurrence of `needle` in `haystack` with
/// `replacement`. Used so that rewriting the top-level `version` never also
/// rewrites an identical `"version": "x"` pair nested deeper in the document.
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

/// Escape a string for safe inclusion inside a JSON string literal. A semantic
/// version contains only `[0-9A-Za-z.+-]`, so in practice nothing needs
/// escaping, but this keeps `set_version` correct for arbitrary input.
fn escape_json_string(value: String) -> String {
  value
  |> string.replace(each: "\\", with: "\\\\")
  |> string.replace(each: "\"", with: "\\\"")
}

// --- publish ----------------------------------------------------------------

/// Run `npm publish` in `context.cwd` and report the resulting release. `npm publish`
/// is synchronous (a subprocess), so the result is wrapped in an already-resolved
/// task to satisfy the asynchronous `publish` contract.
fn publish(
  _spec: PluginSpec,
  context: Context,
) -> Task(Result(Option(Release), ReleaseError)) {
  task.resolve({
    use next <- result.try(require_next_release(context))
    use _ <- result.try(run_npm_publish(context.cwd))
    Ok(
      Some(Release(
        name: plugin_name,
        url: None,
        version: next.version,
        git_tag: next.git_tag,
        channel: next.channel,
        plugin_name: plugin_name,
      )),
    )
  })
}

/// Shell out to `npm publish`, mapping a non-zero exit to a `PluginError`.
fn run_npm_publish(cwd: String) -> Result(Nil, ReleaseError) {
  case shellout.command(run: "npm", with: ["publish"], in: cwd, opt: []) {
    Ok(_) -> Ok(Nil)
    Error(#(code, message)) ->
      Error(PluginError(
        plugin_name,
        "`npm publish` failed (exit "
          <> int.to_string(code)
          <> "): "
          <> string.trim(message),
      ))
  }
}

// --- shared helpers ---------------------------------------------------------

/// The path to `package.json` within the working directory.
fn package_json_path(cwd: String) -> String {
  case string.ends_with(cwd, "/") {
    True -> cwd <> "package.json"
    False -> cwd <> "/package.json"
  }
}

/// Extract the next release from the context, failing when the pipeline has not
/// determined one (which should never happen by the time `prepare`/`publish`
/// run, but is handled rather than asserted).
fn require_next_release(context: Context) -> Result(NextRelease, ReleaseError) {
  case context.next_release {
    Some(next) -> Ok(next)
    None -> Error(PluginError(plugin_name, "no next release determined"))
  }
}

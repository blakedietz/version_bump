//// Unit tests for the npm plugin's PURE `set_version` helper.

import gleeunit
import gleeunit/should

import version_bump/error
import version_bump/plugins/npm

pub fn main() {
  gleeunit.main()
}

/// A standard pretty-printed package.json gets its version replaced while the
/// rest of the document (keys, ordering, indentation) is preserved.
pub fn set_version_basic_test() {
  let input =
    "{\n  \"name\": \"my-pkg\",\n  \"version\": \"1.2.3\",\n  \"main\": \"index.js\"\n}\n"
  let expected =
    "{\n  \"name\": \"my-pkg\",\n  \"version\": \"2.0.0\",\n  \"main\": \"index.js\"\n}\n"
  npm.set_version(input, "2.0.0")
  |> should.equal(Ok(expected))
}

/// A prerelease/version-with-build value is fully replaced (the whole old value
/// is swapped, not partially matched).
pub fn set_version_prerelease_test() {
  let input = "{\"version\": \"1.0.0-beta.1\"}"
  npm.set_version(input, "1.0.0-beta.2")
  |> should.equal(Ok("{\"version\": \"1.0.0-beta.2\"}"))
}

/// Compact (no-space) JSON is handled: `"version":"x"`.
pub fn set_version_no_space_test() {
  let input = "{\"name\":\"x\",\"version\":\"0.1.0\"}"
  npm.set_version(input, "0.1.1")
  |> should.equal(Ok("{\"name\":\"x\",\"version\":\"0.1.1\"}"))
}

/// Extra whitespace around the colon is preserved verbatim.
pub fn set_version_extra_whitespace_test() {
  let input = "{ \"version\"  :   \"1.0.0\" }"
  npm.set_version(input, "1.1.0")
  |> should.equal(Ok("{ \"version\"  :   \"1.1.0\" }"))
}

/// A document with no `version` field is an error, not a silent no-op.
pub fn set_version_missing_field_test() {
  let input = "{\"name\": \"my-pkg\"}"
  npm.set_version(input, "1.0.0")
  |> is_plugin_error
  |> should.be_true
}

/// True when the result is a `PluginError` from the npm plugin.
fn is_plugin_error(result: Result(String, error.ReleaseError)) -> Bool {
  case result {
    Error(error.PluginError("npm", _)) -> True
    _ -> False
  }
}

/// Only the first/top-level `version` is rewritten; a later `version` inside a
/// nested object (e.g. a dependency entry) is left untouched.
pub fn set_version_only_first_test() {
  let input = "{\"version\": \"1.0.0\", \"engines\": {\"version\": \"1.0.0\"}}"
  npm.set_version(input, "2.0.0")
  |> should.equal(Ok(
    "{\"version\": \"2.0.0\", \"engines\": {\"version\": \"1.0.0\"}}",
  ))
}

/// The replacement value is JSON-escaped so a value containing a quote or
/// backslash cannot break out of the string literal. (Not a real semver, but
/// guards `set_version`'s correctness for arbitrary input.)
pub fn set_version_escapes_value_test() {
  let input = "{\"version\": \"1.0.0\"}"
  npm.set_version(input, "a\"b\\c")
  |> should.equal(Ok("{\"version\": \"a\\\"b\\\\c\"}"))
}

//// Unit tests for the Hex plugin's PURE helpers (`set_version`, `package_name`)
//// and its registration.

import gleam/string
import gleeunit
import gleeunit/should

import version_bump/error
import version_bump/plugins/hex

pub fn main() {
  gleeunit.main()
}

/// A representative gleam.toml with a top-level version plus a `[dependencies]`
/// table whose entries must never be mistaken for the package version.
const sample = "name = \"my_pkg\"\nversion = \"1.2.3\"\ndescription = \"A thing\"\nlicences = [\"Apache-2.0\"]\n\n[dependencies]\ngleam_stdlib = \">= 0.34.0 and < 2.0.0\"\n"

/// The top-level `version` is rewritten; spacing and surrounding lines are kept.
pub fn set_version_basic_test() {
  let input = "name = \"p\"\nversion = \"1.0.0\"\n"
  let expected = "name = \"p\"\nversion = \"1.1.0\"\n"
  hex.set_version(input, "1.1.0")
  |> should.equal(Ok(expected))
}

/// Compact (no-space) assignment is handled: `version="x"`.
pub fn set_version_no_space_test() {
  hex.set_version("version=\"0.1.0\"", "0.1.1")
  |> should.equal(Ok("version=\"0.1.1\""))
}

/// In a full gleam.toml the version is bumped while dependency version *ranges*
/// (which also contain digits and quotes) are left untouched.
pub fn set_version_leaves_dependencies_test() {
  case hex.set_version(sample, "2.0.0") {
    Ok(out) -> {
      string.contains(out, "version = \"2.0.0\"") |> should.be_true
      string.contains(out, "gleam_stdlib = \">= 0.34.0 and < 2.0.0\"")
      |> should.be_true
      string.contains(out, "1.2.3") |> should.be_false
    }
    Error(_) -> should.fail()
  }
}

/// A document with no top-level `version` is an error, not a silent no-op.
pub fn set_version_missing_field_test() {
  hex.set_version("name = \"p\"\n", "1.0.0")
  |> is_plugin_error
  |> should.be_true
}

/// The package name is read from the `name` field.
pub fn package_name_test() {
  hex.package_name(sample)
  |> should.equal(Ok("my_pkg"))
}

/// Missing `name` is reported as an error.
pub fn package_name_missing_test() {
  hex.package_name("version = \"1.0.0\"\n")
  |> is_name_error
  |> should.be_true
}

/// The plugin registers under the expected short name.
pub fn plugin_name_test() {
  hex.plugin().name
  |> should.equal("hex")
}

fn is_plugin_error(result: Result(String, error.ReleaseError)) -> Bool {
  case result {
    Error(error.PluginError("hex", _)) -> True
    _ -> False
  }
}

fn is_name_error(result: Result(String, error.ReleaseError)) -> Bool {
  case result {
    Error(error.PluginError("hex", _)) -> True
    _ -> False
  }
}

// --- published_ok (publish verification) -----------------------------------

/// The success line gleam prints means the package really went out.
pub fn published_ok_accepts_success_marker_test() {
  hex.published_ok(
    " Publishing version_bump v0.1.2\n Publishing documentation\n  Published package and documentation\n",
  )
  |> should.equal(True)
}

/// The <1.0.0 warning contains the lowercase word "published" but NOT the
/// "Published package" success line, so an aborted 0.x publish (which still
/// exits 0) must be treated as a failure — this is the false-success guard.
pub fn published_ok_rejects_0x_abort_test() {
  hex.published_ok(
    "If your package is not ready to be used in production it should not\nbe published.\n\nType 'I am not using semantic versioning' to continue: \n",
  )
  |> should.equal(False)
}

pub fn published_ok_rejects_empty_test() {
  hex.published_ok("")
  |> should.equal(False)
}

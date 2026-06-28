import gleam/option.{None, Some}
import gleeunit/should
import version_bump/plugins/exec
import version_bump/semver.{Major, Minor, Patch}

pub fn parse_release_type_major_test() {
  exec.parse_release_type("major")
  |> should.equal(Some(Major))
}

pub fn parse_release_type_minor_test() {
  exec.parse_release_type("minor")
  |> should.equal(Some(Minor))
}

pub fn parse_release_type_patch_test() {
  exec.parse_release_type("patch")
  |> should.equal(Some(Patch))
}

pub fn parse_release_type_empty_is_none_test() {
  exec.parse_release_type("")
  |> should.equal(None)
}

pub fn parse_release_type_whitespace_is_none_test() {
  exec.parse_release_type("   \n  ")
  |> should.equal(None)
}

pub fn parse_release_type_trims_surrounding_whitespace_test() {
  exec.parse_release_type("  minor\n")
  |> should.equal(Some(Minor))
}

pub fn parse_release_type_is_case_insensitive_test() {
  exec.parse_release_type("MAJOR")
  |> should.equal(Some(Major))
  exec.parse_release_type("Patch")
  |> should.equal(Some(Patch))
}

pub fn parse_release_type_unknown_is_none_test() {
  exec.parse_release_type("none")
  |> should.equal(None)
  exec.parse_release_type("release")
  |> should.equal(None)
}

pub fn parse_release_type_multiline_uses_full_trimmed_value_test() {
  // A command that prints extra lines is not a clean bump keyword -> None.
  exec.parse_release_type("minor\nextra output")
  |> should.equal(None)
}

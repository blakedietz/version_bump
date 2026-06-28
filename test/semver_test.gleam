import gleam/option.{None, Some}
import gleam/order
import gleeunit/should
import version_bump/semver.{
  InitialDevelopment, Major, Minor, Patch, Stable, Version,
}

// --- parsing valid ---------------------------------------------------------

pub fn parse_basic_test() {
  semver.parse("1.2.3")
  |> should.equal(Ok(Version(1, 2, 3, [], [])))
}

pub fn parse_leading_v_test() {
  semver.parse("v1.2.3")
  |> should.equal(Ok(Version(1, 2, 3, [], [])))
}

pub fn parse_zeros_test() {
  semver.parse("0.0.0")
  |> should.equal(Ok(Version(0, 0, 0, [], [])))
}

pub fn parse_prerelease_test() {
  semver.parse("1.0.0-beta.1")
  |> should.equal(Ok(Version(1, 0, 0, ["beta", "1"], [])))
}

pub fn parse_build_test() {
  semver.parse("1.0.0+build.5")
  |> should.equal(Ok(Version(1, 0, 0, [], ["build", "5"])))
}

pub fn parse_prerelease_and_build_test() {
  semver.parse("1.2.3-alpha.1+exp.sha.5114f85")
  |> should.equal(
    Ok(Version(1, 2, 3, ["alpha", "1"], ["exp", "sha", "5114f85"])),
  )
}

pub fn parse_trims_whitespace_test() {
  semver.parse("  1.2.3  ")
  |> should.equal(Ok(Version(1, 2, 3, [], [])))
}

pub fn parse_build_with_leading_zero_ok_test() {
  // Build metadata permits leading zeros.
  semver.parse("1.0.0+001")
  |> should.equal(Ok(Version(1, 0, 0, [], ["001"])))
}

// --- parsing invalid -------------------------------------------------------

pub fn parse_empty_test() {
  semver.parse("")
  |> should.be_error
}

pub fn parse_too_few_parts_test() {
  semver.parse("1.2")
  |> should.be_error
}

pub fn parse_too_many_parts_test() {
  semver.parse("1.2.3.4")
  |> should.be_error
}

pub fn parse_non_numeric_core_test() {
  semver.parse("1.x.3")
  |> should.be_error
}

pub fn parse_leading_zero_core_test() {
  semver.parse("01.2.3")
  |> should.be_error
}

pub fn parse_negative_test() {
  semver.parse("1.-2.3")
  |> should.be_error
}

pub fn parse_empty_prerelease_test() {
  semver.parse("1.2.3-")
  |> should.be_error
}

pub fn parse_numeric_prerelease_leading_zero_test() {
  semver.parse("1.2.3-01")
  |> should.be_error
}

pub fn parse_invalid_prerelease_char_test() {
  semver.parse("1.2.3-beta_1")
  |> should.be_error
}

// --- round trip ------------------------------------------------------------

pub fn to_string_basic_test() {
  semver.to_string(Version(1, 2, 3, [], []))
  |> should.equal("1.2.3")
}

pub fn to_string_prerelease_test() {
  semver.to_string(Version(1, 0, 0, ["beta", "1"], []))
  |> should.equal("1.0.0-beta.1")
}

pub fn to_string_full_test() {
  semver.to_string(Version(1, 2, 3, ["alpha", "1"], ["exp", "sha"]))
  |> should.equal("1.2.3-alpha.1+exp.sha")
}

pub fn round_trip_test() {
  let s = "2.3.4-rc.2+build.99"
  case semver.parse(s) {
    Ok(v) -> semver.to_string(v) |> should.equal(s)
    Error(_) -> should.fail()
  }
}

// --- precedence ------------------------------------------------------------

pub fn compare_equal_test() {
  semver.compare(Version(1, 2, 3, [], []), Version(1, 2, 3, [], []))
  |> should.equal(order.Eq)
}

pub fn compare_build_ignored_test() {
  // Build metadata does not affect precedence.
  semver.compare(Version(1, 0, 0, [], ["a"]), Version(1, 0, 0, [], ["b"]))
  |> should.equal(order.Eq)
}

pub fn compare_major_test() {
  semver.compare(Version(2, 0, 0, [], []), Version(1, 9, 9, [], []))
  |> should.equal(order.Gt)
}

pub fn compare_minor_test() {
  semver.compare(Version(1, 1, 0, [], []), Version(1, 2, 0, [], []))
  |> should.equal(order.Lt)
}

pub fn compare_patch_test() {
  semver.compare(Version(1, 0, 5, [], []), Version(1, 0, 2, [], []))
  |> should.equal(order.Gt)
}

pub fn compare_prerelease_lower_than_release_test() {
  // 1.0.0-alpha < 1.0.0
  semver.compare(Version(1, 0, 0, ["alpha"], []), Version(1, 0, 0, [], []))
  |> should.equal(order.Lt)
}

pub fn compare_release_higher_than_prerelease_test() {
  semver.compare(Version(1, 0, 0, [], []), Version(1, 0, 0, ["alpha"], []))
  |> should.equal(order.Gt)
}

pub fn compare_alpha_vs_alpha_1_test() {
  // 1.0.0-alpha < 1.0.0-alpha.1 (more fields wins when prefix equal)
  semver.compare(
    Version(1, 0, 0, ["alpha"], []),
    Version(1, 0, 0, ["alpha", "1"], []),
  )
  |> should.equal(order.Lt)
}

pub fn compare_numeric_below_alphanumeric_test() {
  // numeric identifiers always have lower precedence than alphanumeric
  semver.compare(
    Version(1, 0, 0, ["alpha", "1"], []),
    Version(1, 0, 0, ["alpha", "beta"], []),
  )
  |> should.equal(order.Lt)
}

pub fn compare_numeric_identifiers_test() {
  semver.compare(
    Version(1, 0, 0, ["alpha", "1"], []),
    Version(1, 0, 0, ["alpha", "10"], []),
  )
  |> should.equal(order.Lt)
}

pub fn compare_alpha_vs_beta_test() {
  // 1.0.0-alpha.1 < 1.0.0-beta
  semver.compare(
    Version(1, 0, 0, ["alpha", "1"], []),
    Version(1, 0, 0, ["beta"], []),
  )
  |> should.equal(order.Lt)
}

/// Full chain from the SemVer 2.0.0 spec:
/// 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta
///   < 1.0.0-beta.2 < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0
pub fn spec_precedence_chain_test() {
  let chain = [
    Version(1, 0, 0, ["alpha"], []),
    Version(1, 0, 0, ["alpha", "1"], []),
    Version(1, 0, 0, ["alpha", "beta"], []),
    Version(1, 0, 0, ["beta"], []),
    Version(1, 0, 0, ["beta", "2"], []),
    Version(1, 0, 0, ["beta", "11"], []),
    Version(1, 0, 0, ["rc", "1"], []),
    Version(1, 0, 0, [], []),
  ]
  check_strictly_increasing(chain)
}

fn check_strictly_increasing(versions) {
  case versions {
    [] -> Nil
    [_] -> Nil
    [a, b, ..rest] -> {
      semver.compare(a, b) |> should.equal(order.Lt)
      check_strictly_increasing([b, ..rest])
    }
  }
}

// --- bump ------------------------------------------------------------------

pub fn bump_patch_test() {
  semver.bump(Version(1, 2, 3, [], []), Patch)
  |> should.equal(Version(1, 2, 4, [], []))
}

pub fn bump_minor_resets_patch_test() {
  semver.bump(Version(1, 2, 3, [], []), Minor)
  |> should.equal(Version(1, 3, 0, [], []))
}

pub fn bump_major_resets_minor_patch_test() {
  semver.bump(Version(1, 2, 3, [], []), Major)
  |> should.equal(Version(2, 0, 0, [], []))
}

// --- effective_release_type (0.x) ----------------------------------------

pub fn initial_dev_downshifts_breaking_to_minor_test() {
  semver.effective_release_type(
    Version(0, 3, 1, [], []),
    Major,
    InitialDevelopment,
  )
  |> should.equal(Minor)
}

pub fn initial_dev_leaves_minor_and_patch_test() {
  semver.effective_release_type(
    Version(0, 3, 1, [], []),
    Minor,
    InitialDevelopment,
  )
  |> should.equal(Minor)
  semver.effective_release_type(
    Version(0, 3, 1, [], []),
    Patch,
    InitialDevelopment,
  )
  |> should.equal(Patch)
}

pub fn initial_dev_no_effect_when_major_at_least_1_test() {
  semver.effective_release_type(
    Version(1, 0, 0, [], []),
    Major,
    InitialDevelopment,
  )
  |> should.equal(Major)
}

pub fn initial_dev_no_effect_when_disabled_test() {
  semver.effective_release_type(Version(0, 1, 0, [], []), Major, Stable)
  |> should.equal(Major)
}

pub fn bump_clears_prerelease_and_build_test() {
  semver.bump(Version(1, 2, 3, ["beta", "1"], ["b"]), Patch)
  |> should.equal(Version(1, 2, 4, [], []))
}

pub fn bump_with_prerelease_minor_test() {
  semver.bump_with_prerelease(Version(1, 1, 0, [], []), Minor, "beta")
  |> should.equal(Version(1, 2, 0, ["beta", "1"], []))
}

pub fn bump_with_prerelease_major_test() {
  semver.bump_with_prerelease(Version(1, 2, 3, [], []), Major, "alpha")
  |> should.equal(Version(2, 0, 0, ["alpha", "1"], []))
}

pub fn bump_with_prerelease_renders_test() {
  semver.bump_with_prerelease(Version(1, 1, 0, [], []), Minor, "beta")
  |> semver.to_string
  |> should.equal("1.2.0-beta.1")
}

// --- max -------------------------------------------------------------------

pub fn max_empty_test() {
  semver.max([])
  |> should.equal(None)
}

pub fn max_single_test() {
  semver.max([Version(1, 0, 0, [], [])])
  |> should.equal(Some(Version(1, 0, 0, [], [])))
}

pub fn max_multiple_test() {
  semver.max([
    Version(1, 0, 0, [], []),
    Version(2, 3, 1, [], []),
    Version(2, 3, 0, [], []),
    Version(0, 9, 9, [], []),
  ])
  |> should.equal(Some(Version(2, 3, 1, [], [])))
}

pub fn max_prefers_release_over_prerelease_test() {
  semver.max([
    Version(1, 0, 0, ["rc", "1"], []),
    Version(1, 0, 0, [], []),
  ])
  |> should.equal(Some(Version(1, 0, 0, [], [])))
}

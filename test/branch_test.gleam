import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import version_bump/branch.{
  type Branch, Branch, MaintenanceBranch, PrereleaseBranch, ReleaseBranch,
}
import version_bump/config.{type BranchConfig, type Config, BranchConfig, Config}
import version_bump/release.{LastRelease}
import version_bump/semver.{InitialDevelopment, Major, Minor, Patch, Stable}

/// A config with the conventional default branch set but a custom tag format
/// kept simple for readability.
fn cfg(branches: List(BranchConfig)) -> Config {
  Config(
    repository_url: None,
    tag_format: "v${version}",
    branches: branches,
    plugins: [],
    dry_run: False,
    ci: True,
    versioning_mode: Stable,
  )
}

fn default_branch_configs() -> List(BranchConfig) {
  [
    BranchConfig("main", None, None, None),
    BranchConfig("1.x", None, None, None),
    BranchConfig("next", Some("next"), None, None),
    BranchConfig("beta", None, Some("beta"), None),
    BranchConfig("alpha", None, Some("alpha"), None),
  ]
}

/// Find a resolved branch by name in the resolved list.
fn find(branches: List(Branch), name: String) -> Branch {
  case list.find(branches, fn(b) { b.name == name }) {
    Ok(b) -> b
    Error(_) -> missing_branch(name)
  }
}

// gleeunit lacks a "fail with message"; build a sentinel so a missing branch
// surfaces as an obviously-wrong value in the failing assertion rather than a
// crash inside the test helper.
fn missing_branch(name: String) -> Branch {
  Branch(
    name: "<missing:" <> name <> ">",
    type_: ReleaseBranch,
    channel: None,
    prerelease: None,
    range: None,
    main: False,
  )
}

// --- resolve / classification ----------------------------------------------

pub fn classify_main_is_release_branch_test() {
  let assert Ok(#(current, _)) =
    branch.resolve(
      cfg(default_branch_configs()),
      ["main", "1.x", "next", "beta", "alpha"],
      "main",
    )
  current.type_
  |> should.equal(ReleaseBranch)
  current.main
  |> should.equal(True)
  current.prerelease
  |> should.equal(None)
}

pub fn classify_next_is_release_branch_with_channel_test() {
  let assert Ok(#(_, all)) =
    branch.resolve(cfg(default_branch_configs()), ["main", "next"], "main")
  let next = find(all, "next")
  next.type_
  |> should.equal(ReleaseBranch)
  next.channel
  |> should.equal(Some("next"))
  // `next` is not the first plain release branch, so it is not "main".
  next.main
  |> should.equal(False)
}

pub fn classify_maintenance_branch_test() {
  let assert Ok(#(_, all)) =
    branch.resolve(cfg(default_branch_configs()), ["main", "1.x"], "main")
  let maint = find(all, "1.x")
  maint.type_
  |> should.equal(MaintenanceBranch)
  maint.prerelease
  |> should.equal(None)
  maint.range
  |> should.equal(Some(">=1.0.0 <2.0.0"))
}

pub fn classify_maintenance_major_minor_test() {
  let assert Ok(#(_, all)) =
    branch.resolve(
      cfg([
        BranchConfig("main", None, None, None),
        BranchConfig("1.2.x", None, None, None),
      ]),
      ["main", "1.2.x"],
      "main",
    )
  let maint = find(all, "1.2.x")
  maint.type_
  |> should.equal(MaintenanceBranch)
  maint.range
  |> should.equal(Some(">=1.2.0 <1.3.0"))
}

pub fn classify_beta_is_prerelease_branch_test() {
  let assert Ok(#(current, _)) =
    branch.resolve(cfg(default_branch_configs()), ["main", "beta"], "beta")
  current.type_
  |> should.equal(PrereleaseBranch)
  current.prerelease
  |> should.equal(Some("beta"))
  current.channel
  |> should.equal(Some("beta"))
  current.main
  |> should.equal(False)
}

pub fn resolve_drops_branches_absent_from_git_test() {
  // Only `main` exists in git; the others are configured but not present.
  let assert Ok(#(_, all)) =
    branch.resolve(cfg(default_branch_configs()), ["main"], "main")
  list.length(all)
  |> should.equal(1)
}

pub fn resolve_unknown_current_branch_errors_test() {
  branch.resolve(cfg(default_branch_configs()), ["main"], "feature-x")
  |> should.be_error
}

// --- last_release -----------------------------------------------------------

pub fn last_release_picks_highest_stable_test() {
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  let tags = ["v1.0.0", "v1.2.0", "v1.1.5", "not-a-tag", "v0.9.0"]
  let assert Some(lr) = branch.last_release(tags, branch, "v${version}")
  lr.version
  |> should.equal("1.2.0")
  lr.git_tag
  |> should.equal("v1.2.0")
}

pub fn last_release_ignores_prereleases_on_release_branch_test() {
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  // The highest tag is a prerelease and must be skipped on a release branch.
  let tags = ["v1.0.0", "v2.0.0-beta.1"]
  let assert Some(lr) = branch.last_release(tags, branch, "v${version}")
  lr.version
  |> should.equal("1.0.0")
}

pub fn last_release_prerelease_branch_matches_id_test() {
  let branch =
    Branch("beta", PrereleaseBranch, Some("beta"), Some("beta"), None, False)
  let tags = ["v1.0.0", "v2.0.0-alpha.3", "v2.0.0-beta.1", "v2.0.0-beta.2"]
  let assert Some(lr) = branch.last_release(tags, branch, "v${version}")
  lr.version
  |> should.equal("2.0.0-beta.2")
}

pub fn last_release_maintenance_branch_within_range_test() {
  let branch =
    Branch(
      "1.x",
      MaintenanceBranch,
      Some("1.x"),
      None,
      Some(">=1.0.0 <2.0.0"),
      False,
    )
  let tags = ["v1.0.0", "v1.4.2", "v2.0.0", "v0.9.0"]
  let assert Some(lr) = branch.last_release(tags, branch, "v${version}")
  // 2.0.0 is out of range; 1.4.2 is the highest in-range stable version.
  lr.version
  |> should.equal("1.4.2")
}

pub fn last_release_none_when_no_match_test() {
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  branch.last_release(["release-1", "snapshot"], branch, "v${version}")
  |> should.equal(None)
}

// --- next_version -----------------------------------------------------------

pub fn next_version_first_release_test() {
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  branch.next_version(None, Minor, branch, Stable)
  |> should.equal(Ok("1.0.0"))
}

pub fn next_version_first_release_prerelease_branch_test() {
  let branch =
    Branch("beta", PrereleaseBranch, Some("beta"), Some("beta"), None, False)
  branch.next_version(None, Major, branch, Stable)
  |> should.equal(Ok("1.0.0-beta.1"))
}

pub fn next_version_bumps_minor_test() {
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  let last = Some(LastRelease("1.2.3", "v1.2.3", "abc", [None]))
  branch.next_version(last, Minor, branch, Stable)
  |> should.equal(Ok("1.3.0"))
}

pub fn next_version_bumps_patch_test() {
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  let last = Some(LastRelease("1.2.3", "v1.2.3", "abc", [None]))
  branch.next_version(last, Patch, branch, Stable)
  |> should.equal(Ok("1.2.4"))
}

pub fn next_version_prerelease_branch_bump_test() {
  let branch =
    Branch("beta", PrereleaseBranch, Some("beta"), Some("beta"), None, False)
  let last = Some(LastRelease("1.1.0", "v1.1.0", "abc", [Some("beta")]))
  branch.next_version(last, Minor, branch, Stable)
  |> should.equal(Ok("1.2.0-beta.1"))
}

// --- next_version: initial-development (0.x) mode ---------------------------

pub fn next_version_initial_dev_first_release_is_0_1_0_test() {
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  branch.next_version(None, Major, branch, InitialDevelopment)
  |> should.equal(Ok("0.1.0"))
}

pub fn next_version_initial_dev_breaking_stays_in_0x_test() {
  // A breaking change while major is 0 bumps the MINOR, not to 1.0.0.
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  let last = Some(LastRelease("0.3.1", "v0.3.1", "abc", [None]))
  branch.next_version(last, Major, branch, InitialDevelopment)
  |> should.equal(Ok("0.4.0"))
}

pub fn next_version_initial_dev_feat_and_fix_unchanged_test() {
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  let last = Some(LastRelease("0.3.1", "v0.3.1", "abc", [None]))
  branch.next_version(last, Minor, branch, InitialDevelopment)
  |> should.equal(Ok("0.4.0"))
  branch.next_version(last, Patch, branch, InitialDevelopment)
  |> should.equal(Ok("0.3.2"))
}

pub fn next_version_initial_dev_no_effect_once_stable_test() {
  // Once major >= 1, the flag is moot: a breaking change is a major bump.
  let branch = Branch("main", ReleaseBranch, None, None, None, True)
  let last = Some(LastRelease("1.2.3", "v1.2.3", "abc", [None]))
  branch.next_version(last, Major, branch, InitialDevelopment)
  |> should.equal(Ok("2.0.0"))
}

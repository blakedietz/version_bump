import gleam/option.{type Option, None, Some}
import gleeunit/should
import version_bump/commit_parser.{
  type ConventionalCommit, Commit, ConventionalCommit,
}
import version_bump/plugins/commit_analyzer
import version_bump/semver.{Major, Minor, Patch}

/// Build a minimal conventional commit for testing classification.
fn cc(type_: Option(String), breaking: Bool) -> ConventionalCommit {
  ConventionalCommit(
    commit: Commit(
      hash: "deadbeef",
      short_hash: "dead",
      subject: "subject",
      body: "",
      author_name: "Tester",
      author_email: "test@example.com",
      committer_date: "2026-06-21",
    ),
    type_: type_,
    scope: None,
    subject: "subject",
    breaking: breaking,
    notes: [],
    references: [],
    merge: False,
    revert: False,
  )
}

pub fn empty_commits_test() {
  commit_analyzer.analyze([])
  |> should.equal(None)
}

pub fn no_releasable_commits_test() {
  commit_analyzer.analyze([
    cc(Some("docs"), False),
    cc(Some("chore"), False),
    cc(Some("style"), False),
    cc(None, False),
  ])
  |> should.equal(None)
}

pub fn fix_is_patch_test() {
  commit_analyzer.analyze([cc(Some("fix"), False)])
  |> should.equal(Some(Patch))
}

pub fn perf_is_patch_test() {
  commit_analyzer.analyze([cc(Some("perf"), False)])
  |> should.equal(Some(Patch))
}

pub fn feat_is_minor_test() {
  commit_analyzer.analyze([cc(Some("feat"), False)])
  |> should.equal(Some(Minor))
}

pub fn breaking_is_major_test() {
  commit_analyzer.analyze([cc(Some("fix"), True)])
  |> should.equal(Some(Major))
}

pub fn breaking_on_nonreleasable_type_is_major_test() {
  commit_analyzer.analyze([cc(Some("chore"), True)])
  |> should.equal(Some(Major))
}

pub fn highest_wins_feat_over_fix_test() {
  commit_analyzer.analyze([
    cc(Some("fix"), False),
    cc(Some("docs"), False),
    cc(Some("feat"), False),
    cc(Some("perf"), False),
  ])
  |> should.equal(Some(Minor))
}

pub fn highest_wins_breaking_over_feat_test() {
  commit_analyzer.analyze([
    cc(Some("fix"), False),
    cc(Some("feat"), False),
    cc(Some("feat"), True),
  ])
  |> should.equal(Some(Major))
}

pub fn order_does_not_matter_test() {
  commit_analyzer.analyze([
    cc(Some("feat"), True),
    cc(Some("feat"), False),
    cc(Some("fix"), False),
  ])
  |> should.equal(Some(Major))
}

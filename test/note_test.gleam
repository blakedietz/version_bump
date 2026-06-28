import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import version_bump/commit_parser.{
  type Commit, type CommitNote, type ConventionalCommit, Commit, CommitNote,
  ConventionalCommit,
}
import version_bump/note

/// Build a bare Commit with the given short hash and subject.
fn commit(short_hash: String, subject: String) -> Commit {
  Commit(
    hash: "deadbeefcafebabe",
    short_hash: short_hash,
    subject: subject,
    body: "",
    author_name: "Test Author",
    author_email: "test@example.com",
    committer_date: "2026-06-21",
  )
}

/// Build a ConventionalCommit with sensible defaults.
fn cc(
  type_: option.Option(String),
  scope: option.Option(String),
  subject: String,
  short_hash: String,
  breaking: Bool,
  notes: List(CommitNote),
) -> ConventionalCommit {
  ConventionalCommit(
    commit: commit(short_hash, subject),
    type_: type_,
    scope: scope,
    subject: subject,
    breaking: breaking,
    notes: notes,
    references: [],
    merge: False,
    revert: False,
  )
}

pub fn version_heading_test() {
  let out = note.generate([], "1.2.3", None)
  out
  |> string.contains("## 1.2.3")
  |> should.equal(True)
}

pub fn empty_commits_only_heading_test() {
  let out = note.generate([], "1.0.0", None)
  out
  |> should.equal("## 1.0.0")
}

pub fn features_section_test() {
  let commits = [
    cc(Some("feat"), Some("api"), "add new endpoint", "abc1234", False, []),
  ]
  let out = note.generate(commits, "2.0.0", None)
  out
  |> string.contains("### Features")
  |> should.equal(True)
  out
  |> string.contains("* **api:** add new endpoint (abc1234)")
  |> should.equal(True)
}

pub fn fix_section_test() {
  let commits = [
    cc(Some("fix"), Some("parser"), "handle empty input", "def5678", False, []),
  ]
  let out = note.generate(commits, "1.0.1", None)
  out
  |> string.contains("### Bug Fixes")
  |> should.equal(True)
  out
  |> string.contains("* **parser:** handle empty input (def5678)")
  |> should.equal(True)
}

pub fn perf_section_test() {
  let commits = [
    cc(Some("perf"), None, "cache lookups", "feed001", False, []),
  ]
  let out = note.generate(commits, "1.1.0", None)
  out
  |> string.contains("### Performance")
  |> should.equal(True)
  // No scope -> no bold prefix
  out
  |> string.contains("* cache lookups (feed001)")
  |> should.equal(True)
}

pub fn breaking_changes_section_test() {
  let commits = [
    cc(Some("feat"), Some("core"), "drop legacy api", "bbbb111", True, [
      CommitNote("BREAKING CHANGE", "The legacy API has been removed."),
    ]),
  ]
  let out = note.generate(commits, "3.0.0", None)
  out
  |> string.contains("### BREAKING CHANGES")
  |> should.equal(True)
  out
  |> string.contains("* **core:** The legacy API has been removed.")
  |> should.equal(True)
}

pub fn breaking_without_note_falls_back_to_subject_test() {
  let commits = [
    cc(Some("feat"), None, "rewrite everything", "cccc222", True, []),
  ]
  let out = note.generate(commits, "4.0.0", None)
  out
  |> string.contains("### BREAKING CHANGES")
  |> should.equal(True)
  out
  |> string.contains("* rewrite everything")
  |> should.equal(True)
}

pub fn omits_empty_sections_test() {
  let commits = [
    cc(Some("feat"), None, "only a feature", "aaaa000", False, []),
  ]
  let out = note.generate(commits, "1.0.0", None)
  out
  |> string.contains("### Features")
  |> should.equal(True)
  // No fix/perf/breaking commits -> those headings absent.
  out
  |> string.contains("### Bug Fixes")
  |> should.equal(False)
  out
  |> string.contains("### Performance")
  |> should.equal(False)
  out
  |> string.contains("### BREAKING CHANGES")
  |> should.equal(False)
}

pub fn multiple_sections_order_test() {
  let commits = [
    cc(Some("fix"), None, "a fix", "f1", False, []),
    cc(Some("feat"), None, "a feature", "f2", False, []),
  ]
  let out = note.generate(commits, "1.0.0", None)
  // Features should appear before Bug Fixes regardless of commit order.
  let feat_idx = index_of(out, "### Features")
  let fix_idx = index_of(out, "### Bug Fixes")
  { feat_idx < fix_idx }
  |> should.equal(True)
}

/// Tiny helper: byte index of `needle` in `haystack`, or a large sentinel.
fn index_of(haystack: String, needle: String) -> Int {
  case string.split_once(haystack, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(_) -> 1_000_000
  }
}

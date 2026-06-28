import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import version_bump/commit_parser.{Commit, CommitNote}

/// Build a `Commit` from a header (subject) and body, filling the rest with
/// stable placeholder metadata so tests focus on parsing.
fn commit(subject: String, body: String) -> commit_parser.Commit {
  Commit(
    hash: "0123456789abcdef0123456789abcdef01234567",
    short_hash: "0123456",
    subject: subject,
    body: body,
    author_name: "Ada Lovelace",
    author_email: "ada@example.com",
    committer_date: "2026-06-21T00:00:00Z",
  )
}

pub fn feat_test() {
  let parsed = commit_parser.parse(commit("feat: add a shiny new thing", ""))

  parsed.type_ |> should.equal(Some("feat"))
  parsed.scope |> should.equal(None)
  parsed.subject |> should.equal("add a shiny new thing")
  parsed.breaking |> should.equal(False)
  parsed.notes |> should.equal([])
  parsed.merge |> should.equal(False)
  parsed.revert |> should.equal(False)
}

pub fn fix_test() {
  let parsed = commit_parser.parse(commit("fix: correct a typo", ""))

  parsed.type_ |> should.equal(Some("fix"))
  parsed.scope |> should.equal(None)
  parsed.subject |> should.equal("correct a typo")
  parsed.breaking |> should.equal(False)
}

pub fn feat_with_scope_test() {
  let parsed = commit_parser.parse(commit("feat(parser): support arrays", ""))

  parsed.type_ |> should.equal(Some("feat"))
  parsed.scope |> should.equal(Some("parser"))
  parsed.subject |> should.equal("support arrays")
  parsed.breaking |> should.equal(False)
}

pub fn breaking_bang_with_scope_test() {
  let parsed =
    commit_parser.parse(commit("feat(api)!: drop legacy endpoints", ""))

  parsed.type_ |> should.equal(Some("feat"))
  parsed.scope |> should.equal(Some("api"))
  parsed.subject |> should.equal("drop legacy endpoints")
  parsed.breaking |> should.equal(True)
}

pub fn breaking_bang_no_scope_test() {
  let parsed = commit_parser.parse(commit("feat!: overhaul config", ""))

  parsed.type_ |> should.equal(Some("feat"))
  parsed.scope |> should.equal(None)
  parsed.subject |> should.equal("overhaul config")
  parsed.breaking |> should.equal(True)
}

pub fn breaking_change_footer_test() {
  let body =
    "Some description of the change.\n\nBREAKING CHANGE: the config format changed entirely."
  let parsed = commit_parser.parse(commit("feat: new config loader", body))

  parsed.type_ |> should.equal(Some("feat"))
  parsed.breaking |> should.equal(True)
  parsed.notes
  |> should.equal([
    CommitNote(
      title: "BREAKING CHANGE",
      text: "the config format changed entirely.",
    ),
  ])
}

pub fn breaking_change_hyphen_footer_test() {
  let body = "BREAKING-CHANGE: removed the deprecated flag"
  let parsed = commit_parser.parse(commit("refactor: cleanup", body))

  parsed.breaking |> should.equal(True)
  parsed.notes
  |> should.equal([
    CommitNote(title: "BREAKING CHANGE", text: "removed the deprecated flag"),
  ])
}

pub fn plain_commit_test() {
  let parsed = commit_parser.parse(commit("just some words here", ""))

  parsed.type_ |> should.equal(None)
  parsed.scope |> should.equal(None)
  parsed.subject |> should.equal("just some words here")
  parsed.breaking |> should.equal(False)
  parsed.notes |> should.equal([])
  parsed.references |> should.equal([])
}

pub fn revert_test() {
  let body = "This reverts commit 0123456789abcdef0123456789abcdef01234567."
  let parsed =
    commit_parser.parse(commit("Revert \"feat: add a shiny new thing\"", body))

  parsed.revert |> should.equal(True)
}

pub fn merge_test() {
  let parsed =
    commit_parser.parse(commit("Merge pull request #42 from feature/login", ""))

  parsed.merge |> should.equal(True)
}

pub fn references_test() {
  let parsed =
    commit_parser.parse(commit("fix: resolve crash", "fixes #123 and #456"))

  parsed.references |> should.equal(["#123", "#456"])
}

pub fn references_in_header_test() {
  let parsed = commit_parser.parse(commit("fix: resolve crash (#789)", ""))

  parsed.references |> should.equal(["#789"])
}

pub fn references_deduped_test() {
  let parsed =
    commit_parser.parse(commit("fix: thing #1", "closes #1 and also #2"))

  parsed.references |> should.equal(["#1", "#2"])
}

pub fn no_references_test() {
  let parsed = commit_parser.parse(commit("feat: nothing to reference", ""))

  parsed.references |> should.equal([])
}

pub fn breaking_change_takes_priority_over_no_bang_test() {
  // Header has no `!` but the body declares a breaking change.
  let body = "BREAKING CHANGE: signature changed"
  let parsed = commit_parser.parse(commit("fix: small change", body))

  parsed.breaking |> should.equal(True)
  list.length(parsed.notes) |> should.equal(1)
}

pub fn commit_preserved_test() {
  let original = commit("feat: keep me", "")
  let parsed = commit_parser.parse(original)

  parsed.commit |> should.equal(original)
}

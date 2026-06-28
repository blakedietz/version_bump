import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import version_bump/branch.{type Branch, Branch, ReleaseBranch}
import version_bump/commit_parser.{
  type ConventionalCommit, Commit, ConventionalCommit,
}
import version_bump/config
import version_bump/context
import version_bump/plugins/release_notes
import version_bump/release.{NextRelease}
import version_bump/semver.{Minor}

/// A resolved main release branch.
fn main_branch() -> Branch {
  Branch(
    name: "main",
    type_: ReleaseBranch,
    channel: None,
    prerelease: None,
    range: None,
    main: True,
  )
}

/// A bare conventional commit of the given type with a subject.
fn feat(subject: String, short_hash: String) -> ConventionalCommit {
  ConventionalCommit(
    commit: Commit(
      hash: "deadbeefcafebabe",
      short_hash: short_hash,
      subject: subject,
      body: "",
      author_name: "Test Author",
      author_email: "test@example.com",
      committer_date: "2026-06-21",
    ),
    type_: Some("feat"),
    scope: None,
    subject: subject,
    breaking: False,
    notes: [],
    references: [],
    merge: False,
    revert: False,
  )
}

/// A context with the given commits and an optional pending release version.
fn ctx_with(
  commits: List(ConventionalCommit),
  version: option.Option(String),
) -> context.Context {
  let base =
    context.new(
      cwd: "/tmp/project",
      env: dict.new(),
      config: config.default(),
      branch: main_branch(),
      branches: [main_branch()],
    )
  let next = case version {
    Some(v) ->
      Some(NextRelease(
        version: v,
        type_: Minor,
        git_tag: "v" <> v,
        git_head: "deadbeef",
        channel: None,
        notes: "",
      ))
    None -> None
  }
  context.Context(..base, commits: commits, next_release: next)
}

pub fn plugin_name_test() {
  release_notes.plugin().name
  |> should.equal("release-notes-generator")
}

pub fn generate_notes_hook_is_set_test() {
  release_notes.plugin().generate_notes
  |> option.is_some
  |> should.equal(True)
}

pub fn notes_contain_version_heading_test() {
  let context = ctx_with([feat("add a thing", "abc1234")], Some("1.2.0"))
  let out = release_notes.notes_for(context)
  out
  |> string.contains("## 1.2.0")
  |> should.equal(True)
}

pub fn notes_contain_features_section_test() {
  let context = ctx_with([feat("add a thing", "abc1234")], Some("1.2.0"))
  let out = release_notes.notes_for(context)
  out
  |> string.contains("### Features")
  |> should.equal(True)
  out
  |> string.contains("* add a thing (abc1234)")
  |> should.equal(True)
}

pub fn no_next_release_returns_empty_test() {
  let context = ctx_with([feat("add a thing", "abc1234")], None)
  release_notes.notes_for(context)
  |> should.equal("")
}

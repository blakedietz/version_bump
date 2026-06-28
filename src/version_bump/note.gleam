//// Generate Markdown release notes from parsed conventional commits.
////
//// Commits are grouped into sections by type (Features, Bug Fixes,
//// Performance) plus a dedicated "BREAKING CHANGES" section that lists the
//// breaking-change note text for any breaking commit. Empty sections are
//// omitted. All functions here are PURE — given the same input they always
//// produce the same Markdown string.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import version_bump/commit_parser.{type CommitNote, type ConventionalCommit}

/// Generate the full Markdown release notes for the given commits and version.
///
/// `repo_url` is currently accepted for future link generation; the output is
/// stable regardless of whether it is provided. Sections that have no matching
/// commits are omitted entirely.
pub fn generate(
  commits: List(ConventionalCommit),
  version: String,
  repo_url: Option(String),
) -> String {
  let _ = repo_url

  let sections =
    [
      section("### Features", filter_type(commits, "feat")),
      section("### Bug Fixes", filter_type(commits, "fix")),
      section("### Performance", filter_type(commits, "perf")),
      breaking_section(commits),
    ]
    |> list.filter_map(fn(s) { s })

  let heading = "## " <> version

  case sections {
    [] -> heading
    _ -> heading <> "\n\n" <> string.join(sections, "\n\n")
  }
}

/// Keep only commits whose conventional type matches `type_name`.
fn filter_type(
  commits: List(ConventionalCommit),
  type_name: String,
) -> List(ConventionalCommit) {
  list.filter(commits, fn(c) {
    case c.type_ {
      Some(t) -> t == type_name
      None -> False
    }
  })
}

/// Build a non-breaking section (Features / Bug Fixes / Performance). Returns
/// `Error(Nil)` when there are no commits so the caller can omit it.
fn section(
  heading: String,
  commits: List(ConventionalCommit),
) -> Result(String, Nil) {
  case commits {
    [] -> Error(Nil)
    _ -> {
      let lines = list.map(commits, commit_line)
      Ok(heading <> "\n\n" <> string.join(lines, "\n"))
    }
  }
}

/// Render a single commit as a Markdown bullet:
///   `* **scope:** subject (shorthash)`
/// When there is no scope the `**scope:**` prefix is omitted:
///   `* subject (shorthash)`
fn commit_line(c: ConventionalCommit) -> String {
  let scope_prefix = case c.scope {
    Some(s) -> "**" <> s <> ":** "
    None -> ""
  }
  let short = c.commit.short_hash
  let hash_suffix = case short {
    "" -> ""
    _ -> " (" <> short <> ")"
  }
  "* " <> scope_prefix <> c.subject <> hash_suffix
}

/// Build the BREAKING CHANGES section from any breaking commits. The breaking
/// note text is preferred; if a breaking commit has no `BREAKING CHANGE` note,
/// its subject is used as a fallback. Returns `Error(Nil)` when none break.
fn breaking_section(commits: List(ConventionalCommit)) -> Result(String, Nil) {
  let breaking = list.filter(commits, fn(c) { c.breaking })
  case breaking {
    [] -> Error(Nil)
    _ -> {
      let lines = list.map(breaking, breaking_line)
      Ok("### BREAKING CHANGES\n\n" <> string.join(lines, "\n"))
    }
  }
}

/// Render a single breaking-change bullet using the note text when present.
fn breaking_line(c: ConventionalCommit) -> String {
  let text = breaking_text(c.notes)
  let body = case text {
    "" -> c.subject
    _ -> text
  }
  let scope_prefix = case c.scope {
    Some(s) -> "**" <> s <> ":** "
    None -> ""
  }
  "* " <> scope_prefix <> body
}

/// Extract the text of the first `BREAKING CHANGE`/`BREAKING CHANGES` note,
/// or "" when there is no such note.
fn breaking_text(notes: List(CommitNote)) -> String {
  let found =
    list.find(notes, fn(n) {
      let title = string.uppercase(n.title)
      title == "BREAKING CHANGE" || title == "BREAKING CHANGES"
    })
  case found {
    Ok(note) -> note.text
    Error(_) -> ""
  }
}

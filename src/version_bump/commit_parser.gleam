//// Parse a raw foundation `Commit` into a `ConventionalCommit` following the
//// Conventional Commits / Angular preset.
////
//// The parser is intentionally PURE: it derives everything it needs from the
//// commit's `subject` (the header line) and `body`. It never touches git or the
//// network. Regular expressions follow the shapes used by
//// `conventional-changelog-angular` and `@semantic-release/commit-analyzer`.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp.{type Regexp, Match}
import gleam/string

/// A raw git commit as read from `git log`.
pub type Commit {
  Commit(
    hash: String,
    short_hash: String,
    subject: String,
    body: String,
    author_name: String,
    author_email: String,
    committer_date: String,
  )
}

/// A note extracted from a commit body, e.g. a `BREAKING CHANGE:` footer.
pub type CommitNote {
  CommitNote(title: String, text: String)
}

/// A commit parsed under a conventional-commits preset.
pub type ConventionalCommit {
  ConventionalCommit(
    commit: Commit,
    type_: Option(String),
    scope: Option(String),
    subject: String,
    breaking: Bool,
    notes: List(CommitNote),
    references: List(String),
    merge: Bool,
    revert: Bool,
  )
}

/// Parse a `Commit` into a `ConventionalCommit`.
///
/// The header (`commit.subject`) is matched against `type(scope)!: subject`.
/// When it doesn't match, `type_` and `scope` are `None` and the raw subject is
/// kept verbatim. Breaking changes are detected from a trailing `!` in the
/// header and from `BREAKING CHANGE:` / `BREAKING-CHANGE:` footers in the body,
/// either of which produces a `CommitNote`. References such as `#123` or
/// `fixes #123` are collected, and merge / revert commits are flagged.
pub fn parse(commit: Commit) -> ConventionalCommit {
  let header = commit.subject
  let body = commit.body

  let is_merge = is_merge_header(header)
  let revert = parse_revert(header, body)

  let #(type_, scope, header_breaking, subject) = parse_header(header)

  let notes = breaking_notes(body)
  let breaking = header_breaking || !list.is_empty(notes)

  let references = parse_references(header <> "\n" <> body)

  ConventionalCommit(
    commit: commit,
    type_: type_,
    scope: scope,
    subject: subject,
    breaking: breaking,
    notes: notes,
    references: references,
    merge: is_merge,
    revert: revert,
  )
}

// --- Header parsing ---------------------------------------------------------

/// Parse the header line into `#(type, scope, breaking, subject)`.
///
/// Matches `type(scope)!: subject` where `(scope)` and the trailing `!` are
/// optional. A leading/trailing whitespace-tolerant pattern is used so headers
/// like `feat: thing` and `fix(parser)!: thing` both parse. If the header has
/// no recognizable type prefix, returns `#(None, None, False, raw_header)`.
fn parse_header(
  header: String,
) -> #(Option(String), Option(String), Bool, String) {
  case regexp.scan(with: header_regexp(), content: string.trim(header)) {
    [Match(_, submatches), ..] -> {
      let type_ = submatch_nonempty(submatches, 0)
      let scope = submatch_nonempty(submatches, 1)
      let breaking = submatch_nonempty(submatches, 2) == Some("!")
      let subject = case submatch_nonempty(submatches, 3) {
        Some(s) -> s
        None -> string.trim(header)
      }
      #(type_, scope, breaking, subject)
    }
    [] -> #(None, None, False, string.trim(header))
  }
}

/// `type(scope)!: subject`
///   group 1: type
///   group 2: scope (without parens)
///   group 3: optional `!`
///   group 4: subject
fn header_regexp() -> Regexp {
  build_regexp("^(\\w+)(?:\\(([^()]*)\\))?(!)?:\\s*(.*)$")
}

// --- Merge / revert detection ----------------------------------------------

/// A merge commit header begins with `Merge ` (case-insensitive), e.g.
/// `Merge pull request #1 from ...` or `Merge branch 'x' into 'y'`.
fn is_merge_header(header: String) -> Bool {
  regexp.check(with: merge_regexp(), content: string.trim(header))
}

fn merge_regexp() -> Regexp {
  build_regexp_ci("^merge\\b")
}

/// A revert commit is `Revert "<original subject>"` with a body containing
/// `This reverts commit <hash>.`. We treat either the header form or the body
/// marker as sufficient to flag the commit as a revert (Angular preset relies
/// primarily on the header, but the body marker is a strong fallback).
fn parse_revert(header: String, body: String) -> Bool {
  regexp.check(with: revert_header_regexp(), content: string.trim(header))
  || regexp.check(with: reverts_body_regexp(), content: body)
}

fn revert_header_regexp() -> Regexp {
  build_regexp_ci("^revert:?\\s+\"?.+\"?")
}

fn reverts_body_regexp() -> Regexp {
  build_regexp_ci("this reverts commit\\s+[0-9a-f]+")
}

// --- BREAKING CHANGE notes --------------------------------------------------

/// Extract `BREAKING CHANGE:` / `BREAKING-CHANGE:` notes from the body.
///
/// Everything from the marker to the next blank line (or end of body) is the
/// note text. Multiple markers each produce a separate `CommitNote` whose title
/// is normalized to `BREAKING CHANGE`.
fn breaking_notes(body: String) -> List(CommitNote) {
  regexp.scan(with: breaking_regexp(), content: body)
  |> list.filter_map(fn(match) {
    case submatch_nonempty(match.submatches, 0) {
      // Trim so the captured text is identical across targets regardless of how
      // each engine's `$` treats a trailing newline.
      Some(text) ->
        Ok(CommitNote(title: "BREAKING CHANGE", text: string.trim(text)))
      None -> Error(Nil)
    }
  })
}

/// Matches a `BREAKING CHANGE` or `BREAKING-CHANGE` footer (optionally followed
/// by `:` and/or whitespace) and captures the text up to the next blank line or
/// end of input. `[\s\S]` (rather than `.` with a dot-all flag) spans newlines so
/// multi-line notes are captured — and, unlike the inline `(?s)` flag, it
/// compiles on BOTH the Erlang and JavaScript targets (JS `RegExp` rejects a
/// leading `(?s)`). The `(?=\n\n|$)` lookahead stops at the next paragraph break.
/// Built WITHOUT the multi-line flag so the trailing `$` anchors at the real end
/// of the body rather than at every line end (which would truncate notes).
fn breaking_regexp() -> Regexp {
  build_regexp_ci_singleline(
    "breaking[ -]change(?:s)?:?\\s*([\\s\\S]+?)(?=\\n[ \\t]*\\n|$)",
  )
}

// --- References -------------------------------------------------------------

/// Collect issue references such as `#123` and `fixes #45` from the full commit
/// text. Each captured number is returned prefixed with `#`, de-duplicated in
/// first-seen order.
fn parse_references(text: String) -> List(String) {
  regexp.scan(with: reference_regexp(), content: text)
  |> list.filter_map(fn(match) {
    case submatch_nonempty(match.submatches, 0) {
      Some(num) -> Ok("#" <> num)
      None -> Error(Nil)
    }
  })
  |> dedupe
}

/// Matches `#<digits>` optionally preceded by an owner/repo prefix
/// (`owner/repo#123`). Only the issue number is captured.
fn reference_regexp() -> Regexp {
  build_regexp("(?:[\\w.-]+\\/[\\w.-]+)?#(\\d+)")
}

// --- Helpers ----------------------------------------------------------------

/// Safe regexp construction. On a (developer error) compile failure we fall back
/// to a regexp that never matches, so callers stay total without `let assert`.
fn build_regexp(pattern: String) -> Regexp {
  case regexp.from_string(pattern) {
    Ok(re) -> re
    Error(_) -> never_match()
  }
}

fn build_regexp_ci(pattern: String) -> Regexp {
  let options = regexp.Options(case_insensitive: True, multi_line: True)
  case regexp.compile(pattern, with: options) {
    Ok(re) -> re
    Error(_) -> never_match()
  }
}

/// Case-insensitive but single-line: `$` anchors at end-of-string, not at every
/// line end. Used for footers whose text may span multiple lines.
fn build_regexp_ci_singleline(pattern: String) -> Regexp {
  let options = regexp.Options(case_insensitive: True, multi_line: False)
  case regexp.compile(pattern, with: options) {
    Ok(re) -> re
    Error(_) -> never_match()
  }
}

/// A regexp that matches nothing — used only as an unreachable fallback for the
/// statically-known patterns above. `(?!)` is a negative lookahead on the empty
/// string, which can never succeed. If even that fails to compile (it won't on
/// the Erlang target) we degrade to the empty pattern, which always compiles.
fn never_match() -> Regexp {
  case regexp.from_string("(?!)") {
    Ok(re) -> re
    Error(_) ->
      case regexp.from_string("") {
        Ok(re) -> re
        // The empty pattern always compiles on the BEAM; reuse the never-match
        // result rather than risk an unbounded loop.
        Error(_) -> never_match()
      }
  }
}

/// Read the nth submatch (0-indexed) and return it only when it is `Some` and
/// non-empty after trimming.
fn submatch_nonempty(
  submatches: List(Option(String)),
  index: Int,
) -> Option(String) {
  case nth(submatches, index) {
    Some(Some(s)) -> {
      let trimmed = string.trim(s)
      case trimmed {
        "" -> None
        _ -> Some(trimmed)
      }
    }
    _ -> None
  }
}

fn nth(items: List(a), index: Int) -> Option(a) {
  case items, index {
    [], _ -> None
    [first, ..], 0 -> Some(first)
    [_, ..rest], n if n > 0 -> nth(rest, n - 1)
    _, _ -> None
  }
}

/// De-duplicate a list keeping first-seen order.
fn dedupe(items: List(String)) -> List(String) {
  items
  |> list.fold([], fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> [item, ..acc]
    }
  })
  |> list.reverse
}

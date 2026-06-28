//// Tests for the PURE `git.parse_log` function. These build the raw `git log`
//// output by hand using the same unit (`\u{1f}`) and record (`\u{1e}`)
//// separators the production pretty format emits — no live git repo needed.

import gleam/list
import gleeunit
import gleeunit/should
import version_bump/commit_parser.{Commit}
import version_bump/git

pub fn main() {
  gleeunit.main()
}

const us = "\u{1f}"

const rs = "\u{1e}"

/// Build one record's worth of raw log text for the given fields.
fn record(
  hash hash: String,
  short short: String,
  subject subject: String,
  body body: String,
  name name: String,
  email email: String,
  date date: String,
) -> String {
  hash
  <> us
  <> short
  <> us
  <> subject
  <> us
  <> body
  <> us
  <> name
  <> us
  <> email
  <> us
  <> date
  <> rs
}

pub fn parse_log_multiple_commits_test() {
  let raw =
    record(
      hash: "aaaa1111bbbb2222cccc3333dddd4444eeee5555",
      short: "aaaa111",
      subject: "feat: add login",
      body: "Implements the login flow.",
      name: "Ada Lovelace",
      email: "ada@example.com",
      date: "2026-06-21T10:00:00+00:00",
    )
    <> record(
      hash: "ffff6666gggg7777hhhh8888iiii9999jjjj0000",
      short: "ffff666",
      subject: "fix: handle empty input",
      body: "BREAKING CHANGE: input is now validated.",
      name: "Alan Turing",
      email: "alan@example.com",
      date: "2026-06-20T09:30:00+00:00",
    )
    <> record(
      hash: "1111kkkk2222llll3333mmmm4444nnnn5555oooo",
      short: "1111kkk",
      subject: "docs: tidy readme",
      body: "",
      name: "Grace Hopper",
      email: "grace@example.com",
      date: "2026-06-19T08:15:00+00:00",
    )

  let commits = git.parse_log(raw)

  commits
  |> list.length
  |> should.equal(3)

  commits
  |> should.equal([
    Commit(
      hash: "aaaa1111bbbb2222cccc3333dddd4444eeee5555",
      short_hash: "aaaa111",
      subject: "feat: add login",
      body: "Implements the login flow.",
      author_name: "Ada Lovelace",
      author_email: "ada@example.com",
      committer_date: "2026-06-21T10:00:00+00:00",
    ),
    Commit(
      hash: "ffff6666gggg7777hhhh8888iiii9999jjjj0000",
      short_hash: "ffff666",
      subject: "fix: handle empty input",
      body: "BREAKING CHANGE: input is now validated.",
      author_name: "Alan Turing",
      author_email: "alan@example.com",
      committer_date: "2026-06-20T09:30:00+00:00",
    ),
    Commit(
      hash: "1111kkkk2222llll3333mmmm4444nnnn5555oooo",
      short_hash: "1111kkk",
      subject: "docs: tidy readme",
      body: "",
      author_name: "Grace Hopper",
      author_email: "grace@example.com",
      committer_date: "2026-06-19T08:15:00+00:00",
    ),
  ])
}

pub fn parse_log_empty_string_test() {
  git.parse_log("")
  |> should.equal([])
}

pub fn parse_log_trailing_record_separator_is_dropped_test() {
  // A single real commit followed by the trailing record separator (which git
  // always emits) must yield exactly one commit, not an extra blank one.
  let raw =
    record(
      hash: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
      short: "deadbee",
      subject: "chore: bump deps",
      body: "",
      name: "Dev",
      email: "dev@example.com",
      date: "2026-06-21T12:00:00+00:00",
    )

  git.parse_log(raw)
  |> list.length
  |> should.equal(1)
}

pub fn parse_log_skips_malformed_records_test() {
  // A record with too few fields is silently dropped; the well-formed one
  // around it survives.
  let good =
    record(
      hash: "0000111122223333444455556666777788889999",
      short: "0000111",
      subject: "feat: ok",
      body: "",
      name: "Someone",
      email: "someone@example.com",
      date: "2026-06-21T00:00:00+00:00",
    )
  let malformed = "only" <> us <> "two" <> rs

  git.parse_log(malformed <> good)
  |> list.length
  |> should.equal(1)
}

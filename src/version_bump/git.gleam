//// Git access by shelling out to the `git` executable via `shellout`.
////
//// `parse_log` is the only PURE function here — it decodes a custom
//// `--pretty` format that delimits fields with the ASCII unit separator
//// (`\u{1f}`) and records with the ASCII record separator (`\u{1e}`). Those
//// control characters never appear in normal commit text, so the parse is
//// unambiguous without any quoting/escaping.

import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import shellout
import version_bump/commit_parser.{type Commit, Commit}
import version_bump/error.{type ReleaseError, GitError}

/// ASCII unit separator — delimits the fields within a single commit record.
const unit_sep = "\u{1f}"

/// ASCII record separator — delimits one commit from the next.
const record_sep = "\u{1e}"

/// The `--pretty` format string handed to `git log`. The field order here MUST
/// match the destructuring in `parse_log`.
///
/// Fields, in order: full hash, abbreviated hash, subject, body, author name,
/// author email, committer date (strict ISO-8601). Each record ends with the
/// record separator so trailing newlines inside a body never confuse the split.
const pretty_format = "%H\u{1f}%h\u{1f}%s\u{1f}%b\u{1f}%an\u{1f}%ae\u{1f}%cI\u{1e}"

/// Parse the raw output of `git log --pretty=<pretty_format>` into commits.
///
/// PURE: no IO. Splits on the record separator, then each record on the unit
/// separator. Records with the wrong number of fields (including the empty
/// trailing record produced by the final record separator) are skipped.
pub fn parse_log(raw: String) -> List(Commit) {
  raw
  |> string.split(record_sep)
  |> list.filter_map(parse_record)
}

/// Parse a single commit record. Returns `Error(Nil)` for blank/short records
/// so `filter_map` can drop them cleanly.
fn parse_record(record: String) -> Result(Commit, Nil) {
  case string.trim(record) {
    "" -> Error(Nil)
    _ ->
      case string.split(record, unit_sep) {
        [hash, short_hash, subject, body, author_name, author_email, date] ->
          Ok(Commit(
            hash: string.trim(hash),
            short_hash: string.trim(short_hash),
            subject: subject,
            body: string.trim(body),
            author_name: author_name,
            author_email: author_email,
            committer_date: string.trim(date),
          ))
        _ -> Error(Nil)
      }
  }
}

/// Run `git log [from..HEAD]` with our pretty format and parse the result.
///
/// When `from` is `None` the entire history reachable from `HEAD` is returned;
/// otherwise only commits in the `from..HEAD` range (i.e. reachable from HEAD
/// but not from `from`).
pub fn log_since(
  cwd: String,
  from: Option(String),
) -> Result(List(Commit), ReleaseError) {
  let range = case from {
    option.Some(ref) -> ref <> "..HEAD"
    option.None -> "HEAD"
  }
  use raw <- result.map(run(cwd, ["log", "--pretty=" <> pretty_format, range]))
  parse_log(raw)
}

/// List all tags in the repository.
pub fn get_tags(cwd: String) -> Result(List(String), ReleaseError) {
  use raw <- result.map(run(cwd, ["tag"]))
  nonempty_lines(raw)
}

/// The name of the currently checked-out branch.
pub fn current_branch(cwd: String) -> Result(String, ReleaseError) {
  use raw <- result.map(run(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]))
  string.trim(raw)
}

/// The full SHA of `HEAD`.
pub fn head_sha(cwd: String) -> Result(String, ReleaseError) {
  use raw <- result.map(run(cwd, ["rev-parse", "HEAD"]))
  string.trim(raw)
}

/// List local and remote-tracking branch names, with the leading `origin/`
/// (or any other remote prefix is preserved as-is) and decorations stripped.
pub fn list_branches(cwd: String) -> Result(List(String), ReleaseError) {
  use raw <- result.map(
    run(cwd, [
      "branch",
      "--all",
      "--format=%(refname:short)",
    ]),
  )
  raw
  |> nonempty_lines
  // Drop the symbolic `origin/HEAD -> origin/main` style entries.
  |> list.filter(fn(name) { !string.contains(name, " -> ") })
}

/// Create an annotated tag at `HEAD`. The committer identity is set per-command
/// (an annotated tag records a tagger, which git refuses to invent) so this works
/// on a bare CI runner with no `user.name`/`user.email` configured — matching how
/// the `git` plugin's commit sets its identity.
pub fn create_tag(
  cwd: String,
  tag: String,
  message: String,
) -> Result(Nil, ReleaseError) {
  use _ <- result.map(
    run(cwd, [
      "-c",
      "user.name=version_bump",
      "-c",
      "user.email=version_bump@users.noreply.github.com",
      "tag",
      "-a",
      tag,
      "-m",
      message,
    ]),
  )
  Nil
}

/// Push a single ref to a remote. `ref` may be a tag name, a branch name, or a
/// `<src>:<dst>` refspec such as `HEAD:main`.
pub fn push(
  cwd: String,
  remote: String,
  ref: String,
) -> Result(Nil, ReleaseError) {
  use _ <- result.map(run(cwd, ["push", remote, ref]))
  Nil
}

/// Stage the given paths (`git add -- <paths>`).
pub fn stage(cwd: String, paths: List(String)) -> Result(Nil, ReleaseError) {
  use _ <- result.map(run(cwd, list.append(["add", "--"], paths)))
  Nil
}

/// Commit the staged changes with `message`, attributing the commit to the given
/// identity (set per-command so a release works even when git's `user.name`/
/// `user.email` aren't configured, e.g. on a fresh CI runner). When nothing is
/// staged this is a successful no-op, so a release with no file changes to commit
/// doesn't fail.
pub fn commit(
  cwd: String,
  message: String,
  committer_name: String,
  committer_email: String,
) -> Result(Nil, ReleaseError) {
  case has_staged_changes(cwd) {
    False -> Ok(Nil)
    True -> {
      use _ <- result.map(
        run(cwd, [
          "-c",
          "user.name=" <> committer_name,
          "-c",
          "user.email=" <> committer_email,
          "commit",
          "-m",
          message,
        ]),
      )
      Nil
    }
  }
}

/// True when there are staged changes. `git diff --staged --quiet` exits 0 when
/// the index matches HEAD (nothing staged) and non-zero when it differs.
fn has_staged_changes(cwd: String) -> Bool {
  case
    shellout.command(
      run: "git",
      with: ["diff", "--staged", "--quiet"],
      in: cwd,
      opt: [],
    )
  {
    Ok(_) -> False
    Error(_) -> True
  }
}

/// Resolve the fetch URL configured for a remote.
pub fn get_remote_url(
  cwd: String,
  remote: String,
) -> Result(String, ReleaseError) {
  use raw <- result.map(run(cwd, ["remote", "get-url", remote]))
  string.trim(raw)
}

/// Run a `git` subcommand in `cwd`, mapping the failure tuple to a `GitError`.
fn run(cwd: String, args: List(String)) -> Result(String, ReleaseError) {
  shellout.command(run: "git", with: args, in: cwd, opt: [])
  |> result.map_error(fn(failure) {
    let #(code, message) = failure
    GitError(
      "`git "
      <> string.join(args, " ")
      <> "` failed (exit "
      <> int.to_string(code)
      <> "): "
      <> string.trim(message),
    )
  })
}

/// Split text into lines, dropping any that are empty after trimming.
fn nonempty_lines(raw: String) -> List(String) {
  raw
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" })
}

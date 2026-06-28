//// Minimal GitHub REST client used by the GitHub publish plugin.
////
//// Pure request-building and URL-parsing helpers are separated from the
//// effectful `create_release`, which actually performs the HTTP call. This
//// keeps the parsing/serialisation logic unit-testable without a network.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/string

import version_bump/error.{type ReleaseError, NetworkError}
import version_bump/release.{type Release, Release}
import version_bump/task.{type Task}

const api_host = "api.github.com"

const user_agent = "version_bump"

/// Serialise the JSON body for a create-release request.
///
/// PURE: the `POST` payload for `api.github.com/repos/{owner}/{repo}/releases`.
pub fn build_release_payload(
  tag: String,
  name: String,
  body: String,
  prerelease: Bool,
  target: String,
) -> String {
  json.object([
    #("tag_name", json.string(tag)),
    #("name", json.string(name)),
    #("body", json.string(body)),
    #("prerelease", json.bool(prerelease)),
    #("target_commitish", json.string(target)),
  ])
  |> json.to_string
}

/// Create a GitHub release and return the resulting `Release`, asynchronously.
///
/// The HTTP send is cross-target via `send`: on Erlang it uses `httpc`
/// synchronously; on JavaScript it uses `fetch` (a real promise). Both yield a
/// `Task(#(status, body))`, which is mapped here into a `Release` (parsing
/// `html_url`), a non-2xx `NetworkError`, or a transport `NetworkError`
/// (signalled as status `0`).
pub fn create_release(
  token: String,
  owner: String,
  repo: String,
  tag: String,
  name: String,
  body: String,
  prerelease: Bool,
  target: String,
) -> Task(Result(Release, ReleaseError)) {
  let url =
    "https://" <> api_host <> "/repos/" <> owner <> "/" <> repo <> "/releases"
  let payload = build_release_payload(tag, name, body, prerelease, target)

  use outcome <- task.map(send(url, token, payload))
  let #(status, resp_body) = outcome
  case status {
    0 -> Error(NetworkError("Failed to reach the GitHub API: " <> resp_body))
    s if s >= 200 && s < 300 ->
      Ok(Release(
        name: name,
        url: parse_html_url(resp_body),
        version: tag,
        git_tag: tag,
        channel: None,
        plugin_name: "github",
      ))
    s ->
      Error(NetworkError(
        "GitHub API responded with status "
        <> int.to_string(s)
        <> ": "
        <> resp_body,
      ))
  }
}

/// Perform the POST and yield `#(status_code, body)`. A status of `0` signals a
/// transport-level failure, with the message in the body slot.
///
/// This function has a Gleam body (the Erlang/`httpc` implementation, also used
/// by any target without an external) and a JavaScript `@external` that uses
/// `fetch`. That is how one call site stays target-agnostic while the actual I/O
/// is synchronous on the BEAM and promise-based on Node.
@external(javascript, "./gh_http_ffi.mjs", "post")
fn send(url: String, token: String, body: String) -> Task(#(Int, String)) {
  case build_erlang_request(url, token, body) {
    Error(message) -> task.resolve(#(0, message))
    Ok(req) ->
      case httpc.send(req) {
        Ok(resp) -> task.resolve(#(resp.status, resp.body))
        Error(err) -> task.resolve(#(0, http_error_to_string(err)))
      }
  }
}

/// Build the `httpc` request from primitives (Erlang target only).
fn build_erlang_request(
  url: String,
  token: String,
  body: String,
) -> Result(request.Request(String), String) {
  case request.to(url) {
    Ok(req) ->
      Ok(
        req
        |> request.set_method(http.Post)
        |> request.set_body(body)
        |> request.set_header("authorization", "Bearer " <> token)
        |> request.set_header("accept", "application/vnd.github+json")
        |> request.set_header("content-type", "application/json")
        |> request.set_header("x-github-api-version", "2022-11-28")
        |> request.set_header("user-agent", user_agent),
      )
    Error(_) -> Error("invalid GitHub API URL: " <> url)
  }
}

/// Extract `(owner, repo)` from an HTTPS or `git@` GitHub remote URL.
///
/// PURE. Handles the common forms:
///   - `https://github.com/owner/repo.git`
///   - `https://github.com/owner/repo`
///   - `git@github.com:owner/repo.git`
///   - `ssh://git@github.com/owner/repo.git`
/// The trailing `.git` and any trailing slash are stripped.
pub fn parse_repo_url(url: String) -> Result(#(String, String), ReleaseError) {
  let trimmed = string.trim(url)

  // Strip a known scheme/prefix to reach the "host<sep>owner/repo" remainder.
  let without_prefix = case trimmed {
    "git+" <> rest -> rest
    other -> other
  }

  let remainder = case without_prefix {
    "https://" <> rest -> strip_userinfo(rest)
    "http://" <> rest -> strip_userinfo(rest)
    "ssh://" <> rest -> strip_userinfo(rest)
    "git://" <> rest -> strip_userinfo(rest)
    "git@" <> rest -> rest
    other -> other
  }

  // After the host there is either `/` (https/ssh) or `:` (scp-like git@).
  let path = case string.split_once(remainder, ":") {
    Ok(#(_host, after)) -> after
    Error(_) ->
      case string.split_once(remainder, "/") {
        Ok(#(_host, after)) -> after
        Error(_) -> remainder
      }
  }

  let path = drop_leading_slash(path)
  let path = strip_git_suffix(path)
  let path = drop_trailing_slash(path)

  case string.split_once(path, "/") {
    Ok(#(owner, repo)) ->
      case owner, repo {
        "", _ | _, "" ->
          Error(NetworkError("Could not parse owner/repo from URL: " <> url))
        _, _ -> {
          // `repo` may still contain a path tail (e.g. extra segments); keep
          // only the first segment as the repository name.
          let repo = first_segment(repo)
          case repo {
            "" ->
              Error(NetworkError("Could not parse owner/repo from URL: " <> url))
            _ -> Ok(#(owner, repo))
          }
        }
      }
    Error(_) ->
      Error(NetworkError("Could not parse owner/repo from URL: " <> url))
  }
}

// --- internal helpers -------------------------------------------------------

/// Strip an optional `user@` prefix from a host portion (e.g. `git@github.com`).
fn strip_userinfo(rest: String) -> String {
  case string.split_once(rest, "@") {
    // Only treat as userinfo when the `@` appears before any `/` (host part).
    Ok(#(before, after)) ->
      case string.contains(before, "/") {
        True -> rest
        False -> after
      }
    Error(_) -> rest
  }
}

fn drop_leading_slash(s: String) -> String {
  case s {
    "/" <> rest -> drop_leading_slash(rest)
    _ -> s
  }
}

fn drop_trailing_slash(s: String) -> String {
  case string.ends_with(s, "/") {
    True -> drop_trailing_slash(string.drop_end(s, 1))
    False -> s
  }
}

fn strip_git_suffix(s: String) -> String {
  case string.ends_with(s, ".git") {
    True -> string.drop_end(s, 4)
    False -> s
  }
}

fn first_segment(s: String) -> String {
  case string.split_once(s, "/") {
    Ok(#(head, _)) -> head
    Error(_) -> s
  }
}

/// Parse the `html_url` field out of a GitHub release JSON response, if present.
fn parse_html_url(body: String) -> option.Option(String) {
  let decoder = {
    use url <- decode.field("html_url", decode.string)
    decode.success(url)
  }
  case json.parse(body, decoder) {
    Ok(url) -> Some(url)
    Error(_) -> None
  }
}

fn http_error_to_string(err: httpc.HttpError) -> String {
  case err {
    httpc.InvalidUtf8Response -> "GitHub API returned a non-UTF-8 response"
    httpc.ResponseTimeout -> "GitHub API request timed out"
    httpc.FailedToConnect(_, _) -> "Failed to connect to the GitHub API"
  }
}

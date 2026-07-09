//// Minimal Forgejo REST client used by the Forgejo publish plugin.
////
//// Forgejo (the software Codeberg runs) exposes a Gitea-compatible REST API
//// whose create-release endpoint mirrors GitHub's almost field-for-field. The
//// key differences from `github_api`: the base URL is instance-dependent
//// (Forgejo is self-hostable), and authentication uses the `token` scheme.
////
//// Pure request-building helpers are separated from the effectful
//// `create_release`, which actually performs the HTTP call. This keeps the
//// parsing/serialisation logic unit-testable without a network.

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

const user_agent = "version_bump"

/// Serialise the JSON body for a create-release request.
///
/// PURE: the `POST` payload for `{base}/api/v1/repos/{owner}/{repo}/releases`.
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

/// Build the create-release endpoint URL from the instance base URL.
///
/// PURE. `base_url` is the root of the Forgejo instance (e.g.
/// `https://codeberg.org` or `https://git.example.com:3000`); trailing slashes
/// are tolerated.
pub fn release_endpoint(
  base_url: String,
  owner: String,
  repo: String,
) -> String {
  drop_trailing_slash(string.trim(base_url))
  <> "/api/v1/repos/"
  <> owner
  <> "/"
  <> repo
  <> "/releases"
}

/// Create a Forgejo release and return the resulting `Release`, asynchronously.
///
/// The HTTP send is cross-target via `send`: on Erlang it uses `httpc`
/// synchronously; on JavaScript it uses `fetch` (a real promise). Both yield a
/// `Task(#(status, body))`, which is mapped here into a `Release` (parsing
/// `html_url`), a non-2xx `NetworkError`, or a transport `NetworkError`
/// (signalled as status `0`).
pub fn create_release(
  base_url: String,
  token: String,
  owner: String,
  repo: String,
  tag: String,
  name: String,
  body: String,
  prerelease: Bool,
  target: String,
) -> Task(Result(Release, ReleaseError)) {
  let url = release_endpoint(base_url, owner, repo)
  let payload = build_release_payload(tag, name, body, prerelease, target)

  use outcome <- task.map(send(url, token, payload))
  let #(status, resp_body) = outcome
  case status {
    0 -> Error(NetworkError("Failed to reach the Forgejo API: " <> resp_body))
    s if s >= 200 && s < 300 ->
      Ok(Release(
        name: name,
        url: parse_html_url(resp_body),
        version: tag,
        git_tag: tag,
        channel: None,
        plugin_name: "forgejo",
      ))
    s ->
      Error(NetworkError(
        "Forgejo API responded with status "
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
@external(javascript, "./forgejo_http_ffi.mjs", "post")
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
        |> request.set_header("authorization", "token " <> token)
        |> request.set_header("accept", "application/json")
        |> request.set_header("content-type", "application/json")
        |> request.set_header("user-agent", user_agent),
      )
    Error(_) -> Error("invalid Forgejo API URL: " <> url)
  }
}

// --- internal helpers -------------------------------------------------------

fn drop_trailing_slash(s: String) -> String {
  case string.ends_with(s, "/") {
    True -> drop_trailing_slash(string.drop_end(s, 1))
    False -> s
  }
}

/// Parse the `html_url` field out of a Forgejo release JSON response, if
/// present.
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
    httpc.InvalidUtf8Response -> "Forgejo API returned a non-UTF-8 response"
    httpc.ResponseTimeout -> "Forgejo API request timed out"
    httpc.FailedToConnect(_, _) -> "Failed to connect to the Forgejo API"
  }
}

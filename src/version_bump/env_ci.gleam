//// CI environment detection from environment variables. This is a small, pure
//// reimplementation of the parts of the `env-ci` package that the release
//// pipeline relies on: figuring out whether we're running in CI, which provider,
//// the branch and commit under test, and whether the build is for a pull/merge
//// request.
////
//// Everything here is a pure function of an environment dictionary so it can be
//// unit-tested without touching the real process environment. Callers wire up
//// the live environment (e.g. via `envoy`) and pass it in.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/string

/// The result of inspecting the environment for CI metadata.
pub type CiEnv {
  CiEnv(
    /// Whether we appear to be running inside a CI service at all.
    is_ci: Bool,
    /// A short identifier for the detected provider (e.g. "github", "gitlab",
    /// "generic", or "" when nothing CI-like was found).
    provider: String,
    /// The branch being built, if it could be determined.
    branch: Option(String),
    /// The commit SHA being built, if it could be determined.
    commit: Option(String),
    /// Whether this build corresponds to a pull/merge request.
    is_pr: Bool,
  )
}

/// Detect the CI environment from the given environment variables.
///
/// Providers are checked from most-specific to least-specific so that a generic
/// `CI=true` only wins when no known provider matched. Returns a `CiEnv` with
/// `is_ci: False` and an empty provider when nothing CI-like is present.
pub fn detect(env: Dict(String, String)) -> CiEnv {
  case detect_github(env) {
    Some(result) -> result
    None ->
      case detect_gitlab(env) {
        Some(result) -> result
        None ->
          case detect_generic(env) {
            Some(result) -> result
            None ->
              CiEnv(
                is_ci: False,
                provider: "",
                branch: None,
                commit: None,
                is_pr: False,
              )
          }
      }
  }
}

/// GitHub Actions: identified by `GITHUB_ACTIONS=true`.
///
/// On a pull-request build the source branch lives in `GITHUB_HEAD_REF`; on a
/// push build the branch is in `GITHUB_REF_NAME` (falling back to stripping the
/// `refs/heads/` prefix off `GITHUB_REF`). The commit is `GITHUB_SHA`, and a PR
/// build is signalled by `GITHUB_EVENT_NAME` being `pull_request` or
/// `pull_request_target`.
fn detect_github(env: Dict(String, String)) -> Option(CiEnv) {
  case is_truthy(get(env, "GITHUB_ACTIONS")) {
    False -> None
    True -> {
      let event = get(env, "GITHUB_EVENT_NAME")
      let is_pr = case event {
        Some("pull_request") -> True
        Some("pull_request_target") -> True
        _ -> False
      }
      let branch = case is_pr {
        True -> first_present([get(env, "GITHUB_HEAD_REF")])
        False ->
          first_present([
            get(env, "GITHUB_REF_NAME"),
            strip_ref(get(env, "GITHUB_REF")),
          ])
      }
      Some(CiEnv(
        is_ci: True,
        provider: "github",
        branch: branch,
        commit: get(env, "GITHUB_SHA"),
        is_pr: is_pr,
      ))
    }
  }
}

/// GitLab CI: identified by `GITLAB_CI=true`.
///
/// A merge-request pipeline is detected via `CI_MERGE_REQUEST_ID` /
/// `CI_MERGE_REQUEST_IID`, in which case the source branch is
/// `CI_MERGE_REQUEST_SOURCE_BRANCH_NAME`; otherwise the branch is
/// `CI_COMMIT_REF_NAME`. The commit is `CI_COMMIT_SHA`.
fn detect_gitlab(env: Dict(String, String)) -> Option(CiEnv) {
  case is_truthy(get(env, "GITLAB_CI")) {
    False -> None
    True -> {
      let is_pr =
        is_present(get(env, "CI_MERGE_REQUEST_ID"))
        || is_present(get(env, "CI_MERGE_REQUEST_IID"))
      let branch = case is_pr {
        True ->
          first_present([
            get(env, "CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"),
            get(env, "CI_COMMIT_REF_NAME"),
          ])
        False -> get(env, "CI_COMMIT_REF_NAME")
      }
      Some(CiEnv(
        is_ci: True,
        provider: "gitlab",
        branch: branch,
        commit: get(env, "CI_COMMIT_SHA"),
        is_pr: is_pr,
      ))
    }
  }
}

/// Generic fallback for any CI service that only sets `CI=true`. No branch or
/// commit information is assumed, and it is never treated as a PR build.
fn detect_generic(env: Dict(String, String)) -> Option(CiEnv) {
  case is_truthy(get(env, "CI")) {
    False -> None
    True ->
      Some(CiEnv(
        is_ci: True,
        provider: "generic",
        branch: None,
        commit: None,
        is_pr: False,
      ))
  }
}

/// Look up a key, treating empty/whitespace-only values as absent.
fn get(env: Dict(String, String), key: String) -> Option(String) {
  case dict.get(env, key) {
    Ok(value) ->
      case string.trim(value) {
        "" -> None
        trimmed -> Some(trimmed)
      }
    Error(_) -> None
  }
}

/// Whether an optional value carries a non-empty string.
fn is_present(value: Option(String)) -> Bool {
  case value {
    Some(_) -> True
    None -> False
  }
}

/// Whether an optional value is a "truthy" flag. CI providers conventionally set
/// these to "true" or "1", but any present non-empty value counts as enabled.
fn is_truthy(value: Option(String)) -> Bool {
  case value {
    Some(v) ->
      case string.lowercase(v) {
        "false" -> False
        "0" -> False
        "no" -> False
        "off" -> False
        _ -> True
      }
    None -> False
  }
}

/// Return the first present value from a list of candidates.
fn first_present(candidates: List(Option(String))) -> Option(String) {
  case candidates {
    [] -> None
    [Some(value), ..] -> Some(value)
    [None, ..rest] -> first_present(rest)
  }
}

/// Strip a leading `refs/heads/` prefix from a git ref, leaving other refs and
/// plain branch names untouched.
fn strip_ref(value: Option(String)) -> Option(String) {
  case value {
    Some(ref) ->
      case string.starts_with(ref, "refs/heads/") {
        True -> Some(string.replace(ref, "refs/heads/", ""))
        False -> Some(ref)
      }
    None -> None
  }
}

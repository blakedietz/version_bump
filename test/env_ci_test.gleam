import gleam/dict
import gleam/option.{None, Some}
import gleeunit/should
import version_bump/env_ci

/// No CI-like environment variables at all -> not CI.
pub fn no_ci_test() {
  let env = dict.from_list([#("HOME", "/home/me"), #("PATH", "/usr/bin")])
  let result = env_ci.detect(env)
  result
  |> should.equal(env_ci.CiEnv(
    is_ci: False,
    provider: "",
    branch: None,
    commit: None,
    is_pr: False,
  ))
}

/// CI=false should not be treated as a CI environment.
pub fn ci_false_test() {
  let env = dict.from_list([#("CI", "false")])
  env_ci.detect(env).is_ci
  |> should.equal(False)
}

/// Generic CI fallback: only CI=true is set.
pub fn generic_ci_test() {
  let env = dict.from_list([#("CI", "true")])
  let result = env_ci.detect(env)
  result.is_ci
  |> should.equal(True)
  result.provider
  |> should.equal("generic")
  result.branch
  |> should.equal(None)
  result.commit
  |> should.equal(None)
  result.is_pr
  |> should.equal(False)
}

/// GitHub Actions on a push to a branch.
pub fn github_push_test() {
  let env =
    dict.from_list([
      #("CI", "true"),
      #("GITHUB_ACTIONS", "true"),
      #("GITHUB_EVENT_NAME", "push"),
      #("GITHUB_REF_NAME", "main"),
      #("GITHUB_REF", "refs/heads/main"),
      #("GITHUB_SHA", "abc123"),
    ])
  let result = env_ci.detect(env)
  result
  |> should.equal(env_ci.CiEnv(
    is_ci: True,
    provider: "github",
    branch: Some("main"),
    commit: Some("abc123"),
    is_pr: False,
  ))
}

/// GitHub Actions push when only GITHUB_REF is set (strip refs/heads/ prefix).
pub fn github_push_ref_fallback_test() {
  let env =
    dict.from_list([
      #("GITHUB_ACTIONS", "true"),
      #("GITHUB_EVENT_NAME", "push"),
      #("GITHUB_REF", "refs/heads/release/2.0"),
      #("GITHUB_SHA", "deadbeef"),
    ])
  let result = env_ci.detect(env)
  result.provider
  |> should.equal("github")
  result.branch
  |> should.equal(Some("release/2.0"))
  result.is_pr
  |> should.equal(False)
}

/// GitHub Actions on a pull_request build uses the head ref and flags is_pr.
pub fn github_pull_request_test() {
  let env =
    dict.from_list([
      #("GITHUB_ACTIONS", "true"),
      #("GITHUB_EVENT_NAME", "pull_request"),
      #("GITHUB_HEAD_REF", "feature/new-thing"),
      #("GITHUB_REF_NAME", "42/merge"),
      #("GITHUB_SHA", "f00ba7"),
    ])
  let result = env_ci.detect(env)
  result
  |> should.equal(env_ci.CiEnv(
    is_ci: True,
    provider: "github",
    branch: Some("feature/new-thing"),
    commit: Some("f00ba7"),
    is_pr: True,
  ))
}

/// pull_request_target is also treated as a PR build.
pub fn github_pull_request_target_test() {
  let env =
    dict.from_list([
      #("GITHUB_ACTIONS", "true"),
      #("GITHUB_EVENT_NAME", "pull_request_target"),
      #("GITHUB_HEAD_REF", "fix/bug"),
      #("GITHUB_SHA", "cafe01"),
    ])
  let result = env_ci.detect(env)
  result.is_pr
  |> should.equal(True)
  result.branch
  |> should.equal(Some("fix/bug"))
}

/// GitLab CI on a regular branch pipeline.
pub fn gitlab_branch_test() {
  let env =
    dict.from_list([
      #("CI", "true"),
      #("GITLAB_CI", "true"),
      #("CI_COMMIT_REF_NAME", "main"),
      #("CI_COMMIT_SHA", "0123456789"),
    ])
  let result = env_ci.detect(env)
  result
  |> should.equal(env_ci.CiEnv(
    is_ci: True,
    provider: "gitlab",
    branch: Some("main"),
    commit: Some("0123456789"),
    is_pr: False,
  ))
}

/// GitLab CI on a merge-request pipeline uses the MR source branch and is_pr.
pub fn gitlab_merge_request_test() {
  let env =
    dict.from_list([
      #("GITLAB_CI", "true"),
      #("CI_MERGE_REQUEST_IID", "17"),
      #("CI_MERGE_REQUEST_SOURCE_BRANCH_NAME", "feature/login"),
      #("CI_COMMIT_REF_NAME", "feature/login"),
      #("CI_COMMIT_SHA", "abcdef"),
    ])
  let result = env_ci.detect(env)
  result
  |> should.equal(env_ci.CiEnv(
    is_ci: True,
    provider: "gitlab",
    branch: Some("feature/login"),
    commit: Some("abcdef"),
    is_pr: True,
  ))
}

/// Known providers take precedence over the generic CI=true fallback.
pub fn provider_precedence_over_generic_test() {
  let env =
    dict.from_list([
      #("CI", "true"),
      #("GITLAB_CI", "true"),
      #("CI_COMMIT_REF_NAME", "develop"),
    ])
  env_ci.detect(env).provider
  |> should.equal("gitlab")
}

/// Empty / whitespace-only values are treated as absent.
pub fn empty_values_treated_as_absent_test() {
  let env =
    dict.from_list([
      #("GITHUB_ACTIONS", "true"),
      #("GITHUB_EVENT_NAME", "push"),
      #("GITHUB_REF_NAME", "   "),
      #("GITHUB_SHA", ""),
    ])
  let result = env_ci.detect(env)
  result.branch
  |> should.equal(None)
  result.commit
  |> should.equal(None)
}

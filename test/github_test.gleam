import gleam/option.{None, Some}
import gleeunit/should

import version_bump/config
import version_bump/release.{type NextRelease, NextRelease}
import version_bump/semver.{Minor}

import version_bump/plugins/github

pub fn plugin_name_test() {
  github.plugin().name
  |> should.equal("github")
}

pub fn plugin_implements_verify_conditions_test() {
  case github.plugin().verify_conditions {
    Some(_) -> should.be_true(True)
    None -> should.fail()
  }
}

pub fn plugin_implements_publish_test() {
  case github.plugin().publish {
    Some(_) -> should.be_true(True)
    None -> should.fail()
  }
}

pub fn plugin_implements_success_test() {
  case github.plugin().success {
    Some(_) -> should.be_true(True)
    None -> should.fail()
  }
}

/// No token at all -> fails regardless of config.
pub fn verify_fails_without_token_test() {
  github.verify(None, config.default())
  |> should.be_error
}

/// Token present but no repository URL configured -> fails.
pub fn verify_fails_without_repo_url_test() {
  let cfg = config.Config(..config.default(), repository_url: None)
  github.verify(Some("ghp_token"), cfg)
  |> should.be_error
}

/// Token present but the repository URL is unparseable -> fails.
pub fn verify_fails_with_unparseable_repo_url_test() {
  let cfg =
    config.Config(..config.default(), repository_url: Some("not-a-valid-url"))
  github.verify(Some("ghp_token"), cfg)
  |> should.be_error
}

/// Token present and a valid GitHub URL configured -> succeeds.
pub fn verify_succeeds_with_token_and_repo_url_test() {
  let cfg =
    config.Config(
      ..config.default(),
      repository_url: Some("https://github.com/octocat/hello-world.git"),
    )
  github.verify(Some("ghp_token"), cfg)
  |> should.equal(Ok(Nil))
}

/// An empty/whitespace repository URL is treated as absent -> fails.
pub fn verify_fails_with_blank_repo_url_test() {
  let cfg = config.Config(..config.default(), repository_url: Some("   "))
  github.verify(Some("ghp_token"), cfg)
  |> should.be_error
}

fn next_release(version: String) -> NextRelease {
  NextRelease(
    version: version,
    type_: Minor,
    git_tag: "v" <> version,
    git_head: "abc123",
    channel: None,
    notes: "notes",
  )
}

pub fn is_prerelease_true_for_prerelease_version_test() {
  github.is_prerelease(next_release("1.2.0-beta.1"))
  |> should.be_true
}

pub fn is_prerelease_false_for_stable_version_test() {
  github.is_prerelease(next_release("1.2.0"))
  |> should.be_false
}

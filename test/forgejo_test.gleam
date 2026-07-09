import gleam/option.{None, Some}
import gleeunit/should

import version_bump/config
import version_bump/release.{type NextRelease, NextRelease}
import version_bump/semver.{Minor}

import version_bump/plugins/forgejo

pub fn plugin_name_test() {
  forgejo.plugin().name
  |> should.equal("forgejo")
}

pub fn plugin_implements_verify_conditions_test() {
  case forgejo.plugin().verify_conditions {
    Some(_) -> should.be_true(True)
    None -> should.fail()
  }
}

pub fn plugin_implements_publish_test() {
  case forgejo.plugin().publish {
    Some(_) -> should.be_true(True)
    None -> should.fail()
  }
}

pub fn plugin_implements_success_test() {
  case forgejo.plugin().success {
    Some(_) -> should.be_true(True)
    None -> should.fail()
  }
}

/// No token at all -> fails regardless of config.
pub fn verify_fails_without_token_test() {
  forgejo.verify(None, config.default())
  |> should.be_error
}

/// Token present but no repository URL configured -> fails.
pub fn verify_fails_without_repo_url_test() {
  let cfg = config.Config(..config.default(), repository_url: None)
  forgejo.verify(Some("fj_token"), cfg)
  |> should.be_error
}

/// Token present but the repository URL is unparseable -> fails.
pub fn verify_fails_with_unparseable_repo_url_test() {
  let cfg =
    config.Config(..config.default(), repository_url: Some("not-a-valid-url"))
  forgejo.verify(Some("fj_token"), cfg)
  |> should.be_error
}

/// Token present and a valid Codeberg URL configured -> succeeds.
pub fn verify_succeeds_with_token_and_repo_url_test() {
  let cfg =
    config.Config(
      ..config.default(),
      repository_url: Some("https://codeberg.org/owner/repo.git"),
    )
  forgejo.verify(Some("fj_token"), cfg)
  |> should.equal(Ok(Nil))
}

/// An empty/whitespace repository URL is treated as absent -> fails.
pub fn verify_fails_with_blank_repo_url_test() {
  let cfg = config.Config(..config.default(), repository_url: Some("   "))
  forgejo.verify(Some("fj_token"), cfg)
  |> should.be_error
}

/// Without an override the API base is https:// plus the repo URL's host.
pub fn resolve_api_base_derives_from_host_test() {
  forgejo.resolve_api_base(None, "codeberg.org")
  |> should.equal("https://codeberg.org")
}

/// An explicit instance URL (plugin option or env var) wins over the host.
pub fn resolve_api_base_explicit_override_wins_test() {
  forgejo.resolve_api_base(Some("https://git.example.com:3000"), "codeberg.org")
  |> should.equal("https://git.example.com:3000")
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
  forgejo.is_prerelease(next_release("1.2.0-beta.1"))
  |> should.be_true
}

pub fn is_prerelease_false_for_stable_version_test() {
  forgejo.is_prerelease(next_release("1.2.0"))
  |> should.be_false
}

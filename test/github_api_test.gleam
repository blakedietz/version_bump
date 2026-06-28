import gleam/string
import gleeunit/should
import version_bump/github_api

fn sample_payload() -> String {
  github_api.build_release_payload(
    "v1.2.3",
    "v1.2.3",
    "Release notes here",
    False,
    "main",
  )
}

pub fn payload_is_json_with_tag_test() {
  let body = sample_payload()
  should.be_true(string.contains(body, "\"tag_name\""))
  should.be_true(string.contains(body, "v1.2.3"))
}

pub fn payload_includes_name_test() {
  should.be_true(string.contains(sample_payload(), "\"name\""))
}

pub fn payload_includes_release_notes_test() {
  should.be_true(string.contains(sample_payload(), "Release notes here"))
}

pub fn payload_includes_prerelease_flag_test() {
  should.be_true(string.contains(sample_payload(), "\"prerelease\""))
}

pub fn payload_includes_target_commitish_test() {
  let body = sample_payload()
  should.be_true(string.contains(body, "\"target_commitish\""))
  should.be_true(string.contains(body, "main"))
}

pub fn parse_repo_url_https_test() {
  github_api.parse_repo_url("https://github.com/octocat/hello-world.git")
  |> should.equal(Ok(#("octocat", "hello-world")))
}

pub fn parse_repo_url_https_no_git_suffix_test() {
  github_api.parse_repo_url("https://github.com/octocat/hello-world")
  |> should.equal(Ok(#("octocat", "hello-world")))
}

pub fn parse_repo_url_https_trailing_slash_test() {
  github_api.parse_repo_url("https://github.com/octocat/hello-world/")
  |> should.equal(Ok(#("octocat", "hello-world")))
}

pub fn parse_repo_url_ssh_scp_form_test() {
  github_api.parse_repo_url("git@github.com:octocat/hello-world.git")
  |> should.equal(Ok(#("octocat", "hello-world")))
}

pub fn parse_repo_url_ssh_scp_form_no_git_test() {
  github_api.parse_repo_url("git@github.com:octocat/hello-world")
  |> should.equal(Ok(#("octocat", "hello-world")))
}

pub fn parse_repo_url_ssh_scheme_form_test() {
  github_api.parse_repo_url("ssh://git@github.com/octocat/hello-world.git")
  |> should.equal(Ok(#("octocat", "hello-world")))
}

pub fn parse_repo_url_git_scheme_form_test() {
  github_api.parse_repo_url("git://github.com/octocat/hello-world.git")
  |> should.equal(Ok(#("octocat", "hello-world")))
}

pub fn parse_repo_url_invalid_returns_error_test() {
  github_api.parse_repo_url("not-a-valid-url")
  |> should.be_error
}

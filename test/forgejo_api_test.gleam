import gleam/string
import gleeunit/should
import version_bump/forgejo_api

fn sample_payload() -> String {
  forgejo_api.build_release_payload(
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

pub fn release_endpoint_builds_api_v1_path_test() {
  forgejo_api.release_endpoint("https://codeberg.org", "owner", "repo")
  |> should.equal("https://codeberg.org/api/v1/repos/owner/repo/releases")
}

pub fn release_endpoint_trims_trailing_slash_test() {
  forgejo_api.release_endpoint("https://codeberg.org/", "owner", "repo")
  |> should.equal("https://codeberg.org/api/v1/repos/owner/repo/releases")
}

pub fn release_endpoint_keeps_custom_port_test() {
  forgejo_api.release_endpoint("https://git.example.com:3000", "owner", "repo")
  |> should.equal(
    "https://git.example.com:3000/api/v1/repos/owner/repo/releases",
  )
}

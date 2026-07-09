import gleeunit/should
import version_bump/repo_url.{RepoRef}

pub fn parse_https_with_git_suffix_test() {
  repo_url.parse("https://github.com/octocat/hello-world.git")
  |> should.equal(Ok(RepoRef("github.com", "octocat", "hello-world")))
}

pub fn parse_https_no_git_suffix_test() {
  repo_url.parse("https://codeberg.org/forgejo/forgejo")
  |> should.equal(Ok(RepoRef("codeberg.org", "forgejo", "forgejo")))
}

pub fn parse_https_trailing_slash_test() {
  repo_url.parse("https://codeberg.org/forgejo/forgejo/")
  |> should.equal(Ok(RepoRef("codeberg.org", "forgejo", "forgejo")))
}

pub fn parse_https_with_port_keeps_port_in_host_test() {
  repo_url.parse("https://git.example.com:3000/owner/repo.git")
  |> should.equal(Ok(RepoRef("git.example.com:3000", "owner", "repo")))
}

pub fn parse_scp_form_test() {
  repo_url.parse("git@codeberg.org:owner/repo.git")
  |> should.equal(Ok(RepoRef("codeberg.org", "owner", "repo")))
}

pub fn parse_scp_form_no_git_suffix_test() {
  repo_url.parse("git@github.com:octocat/hello-world")
  |> should.equal(Ok(RepoRef("github.com", "octocat", "hello-world")))
}

pub fn parse_ssh_scheme_with_userinfo_test() {
  repo_url.parse("ssh://git@codeberg.org/owner/repo.git")
  |> should.equal(Ok(RepoRef("codeberg.org", "owner", "repo")))
}

pub fn parse_git_scheme_test() {
  repo_url.parse("git://github.com/octocat/hello-world.git")
  |> should.equal(Ok(RepoRef("github.com", "octocat", "hello-world")))
}

pub fn parse_git_plus_prefix_test() {
  repo_url.parse("git+https://codeberg.org/owner/repo.git")
  |> should.equal(Ok(RepoRef("codeberg.org", "owner", "repo")))
}

pub fn parse_keeps_first_repo_segment_only_test() {
  repo_url.parse("https://codeberg.org/owner/repo/extra/segments")
  |> should.equal(Ok(RepoRef("codeberg.org", "owner", "repo")))
}

pub fn parse_invalid_returns_error_test() {
  repo_url.parse("not-a-valid-url")
  |> should.equal(Error(Nil))
}

pub fn parse_missing_repo_returns_error_test() {
  repo_url.parse("https://codeberg.org/owner")
  |> should.equal(Error(Nil))
}

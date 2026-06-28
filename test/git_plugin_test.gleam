//// Tests for the git plugin's PURE helpers and its hook wiring.

import gleam/option.{type Option, None, Some}
import gleeunit/should
import version_bump/plugins/git

pub fn render_message_substitutes_version_test() {
  git.render_message("chore(release): ${version} [skip ci]", "1.2.3")
  |> should.equal("chore(release): 1.2.3 [skip ci]")
}

pub fn parse_assets_splits_and_trims_test() {
  git.parse_assets("gleam.toml, CHANGELOG.md ,")
  |> should.equal(["gleam.toml", "CHANGELOG.md"])
}

pub fn plugin_registers_under_name_test() {
  git.plugin().name
  |> should.equal("git")
}

/// The git plugin only commits (in `prepare`); creating and pushing the tag is
/// the engine's job, so it must not claim `publish`.
pub fn plugin_implements_only_prepare_test() {
  let p = git.plugin()
  present(p.prepare) |> should.be_true
  present(p.publish) |> should.be_false
}

fn present(hook: Option(a)) -> Bool {
  case hook {
    Some(_) -> True
    None -> False
  }
}

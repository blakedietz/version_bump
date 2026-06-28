//// The git plugin (plugin name "git").
////
//// Mirrors `@semantic-release/git`. In `prepare` it stages the release assets
//// that earlier plugins changed (e.g. the `gleam.toml` version bumped by `hex`,
//// or a `CHANGELOG.md`) and commits them. Because the engine creates the release
//// tag *after* all `prepare` hooks and pushes the branch alongside the tag, the
//// tag then points at the commit containing the bump — keeping the committed
//// version, the tag, and the published version consistent.
////
//// List this plugin AFTER the plugins that modify files (e.g. `hex`). Options
//// (all optional, with sensible defaults):
////   - `assets`         comma-separated paths to stage (default "gleam.toml")
////   - `message`        commit message template; `${version}` is substituted
////                      (default "chore(release): ${version} [skip ci]")
////   - `committerName`  commit author/committer name (default "version_bump")
////   - `committerEmail` commit author/committer email

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

import version_bump/config.{type PluginSpec}
import version_bump/context.{type Context}
import version_bump/error.{type ReleaseError, PluginError}
import version_bump/git
import version_bump/plugin.{type Plugin, Plugin}
import version_bump/release.{type NextRelease}

const name = "git"

const default_assets = "gleam.toml"

const default_message = "chore(release): ${version} [skip ci]"

const default_committer_name = "version_bump"

const default_committer_email = "version_bump@users.noreply.github.com"

/// Build the git plugin: implements only `prepare` (the commit). The engine
/// handles creating and pushing the tag and the branch.
pub fn plugin() -> Plugin {
  Plugin(..plugin.new(name), prepare: Some(do_prepare))
}

fn do_prepare(spec: PluginSpec, context: Context) -> Result(Nil, ReleaseError) {
  use next <- result.try(require_next_release(context))
  let assets = parse_assets(option_or(spec, "assets", default_assets))
  let message =
    render_message(option_or(spec, "message", default_message), next.version)
  let committer_name = option_or(spec, "committerName", default_committer_name)
  let committer_email =
    option_or(spec, "committerEmail", default_committer_email)

  use _ <- result.try(git.stage(context.cwd, assets))
  git.commit(context.cwd, message, committer_name, committer_email)
}

// --- pure helpers (exported for testing) ------------------------------------

/// Render the commit message, substituting `${version}`. PURE.
pub fn render_message(template: String, version: String) -> String {
  string.replace(template, "${version}", version)
}

/// Parse a comma-separated `assets` option into a trimmed, non-empty path list.
/// PURE.
pub fn parse_assets(raw: String) -> List(String) {
  raw
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(path) { path != "" })
}

// --- internal ---------------------------------------------------------------

/// Look up an option, treating a present-but-blank value as absent.
fn option_or(spec: PluginSpec, key: String, fallback: String) -> String {
  case dict.get(spec.options, key) {
    Ok(value) ->
      case string.trim(value) {
        "" -> fallback
        _ -> value
      }
    Error(_) -> fallback
  }
}

fn require_next_release(context: Context) -> Result(NextRelease, ReleaseError) {
  case context.next_release {
    Some(next) -> Ok(next)
    None -> Error(PluginError(name, "no next release determined"))
  }
}

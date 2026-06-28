//// The `release-notes-generator` plugin.
////
//// A port of semantic-release's `@semantic-release/release-notes-generator`.
//// It implements only the `generate_notes` hook: given the parsed conventional
//// commits in the context and the version of the pending release, it renders
//// the Markdown release notes via the shared `notes` module.
////
//// When there is no `next_release` (nothing to release) the hook returns an
//// empty string, matching semantic-release where notes are only generated for a
//// release that is actually happening.

import gleam/option.{type Option, None, Some}
import version_bump/config.{type PluginSpec}
import version_bump/context.{type Context}
import version_bump/error.{type ReleaseError}
import version_bump/note
import version_bump/plugin.{type Plugin, Plugin}

const plugin_name = "release-notes-generator"

/// Build the `release-notes-generator` plugin. It implements `generate_notes`
/// and leaves every other hook unset.
pub fn plugin() -> Plugin {
  Plugin(..plugin.new(plugin_name), generate_notes: Some(generate_notes))
}

/// `generate_notes` hook: render Markdown release notes for the pending release.
///
/// `_spec` is unused — this plugin takes no options. The notes are derived
/// entirely from the context's commits, the next release's version, and the
/// configured repository URL.
fn generate_notes(
  _spec: PluginSpec,
  context: Context,
) -> Result(String, ReleaseError) {
  Ok(notes_for(context))
}

/// Pure core of the hook: render the release notes for a context, or `""` when
/// there is no pending release. Kept separate from `generate_notes` so it can
/// be unit-tested without constructing a `Result`.
pub fn notes_for(context: Context) -> String {
  case context.next_release {
    None -> ""
    Some(next) ->
      note.generate(context.commits, next.version, repository_url(context))
  }
}

/// The configured repository URL, threaded through to the notes renderer for
/// future link generation.
fn repository_url(context: Context) -> Option(String) {
  context.config.repository_url
}

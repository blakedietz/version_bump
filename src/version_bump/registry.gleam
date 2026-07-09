//// The built-in plugin registry.
////
//// Maps each built-in plugin's spec name to its `Plugin` record. The engine
//// resolves a configured `PluginSpec.name` against this registry to obtain the
//// hook implementations to run; an unknown name is a configuration error.
////
//// The registry is intentionally a plain `Dict` so it stays a pure value with
//// no IO. Names mirror the semantic-release package short-names (the `@…/`
//// scope is dropped, matching how they are written in config).

import gleam/dict.{type Dict}
import version_bump/plugin.{type Plugin}
import version_bump/plugins/commit_analyzer
import version_bump/plugins/exec
import version_bump/plugins/forgejo
import version_bump/plugins/git
import version_bump/plugins/github
import version_bump/plugins/hex
import version_bump/plugins/npm
import version_bump/plugins/release_notes

/// The default registry of built-in plugins, keyed by spec name.
pub fn default() -> Dict(String, Plugin) {
  [
    #("commit-analyzer", commit_analyzer.plugin()),
    #("release-notes-generator", release_notes.plugin()),
    #("npm", npm.plugin()),
    #("hex", hex.plugin()),
    #("git", git.plugin()),
    #("github", github.plugin()),
    #("forgejo", forgejo.plugin()),
    #("exec", exec.plugin()),
  ]
  |> dict.from_list
}

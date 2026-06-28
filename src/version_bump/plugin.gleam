//// The plugin contract — the extensibility surface of the whole tool.
////
//// semantic-release plugins are JS modules that duck-type which lifecycle hooks
//// they implement. Gleam has no dynamic dispatch, so a plugin is a record of
//// optional hook functions. A plugin implements a hook by setting that field to
//// `Some(fn)`; the engine skips `None` fields.
////
//// Per-hook return semantics (enforced by the engine, not plugins):
////   - analyze_commits: highest `ReleaseType` across plugins wins
////   - generate_notes:  results are concatenated in plugin order
////   - publish:         `Some(release)` published, `None` means "not handled"
////   - others:          run for effect; failure aborts the pipeline

import gleam/option.{type Option, None}
import version_bump/config.{type PluginSpec}
import version_bump/context.{type Context}
import version_bump/error.{type ReleaseError}
import version_bump/release.{type Release}
import version_bump/semver.{type ReleaseType}
import version_bump/task.{type Task}

pub type VerifyConditions =
  fn(PluginSpec, Context) -> Result(Nil, ReleaseError)

pub type AnalyzeCommits =
  fn(PluginSpec, Context) -> Result(Option(ReleaseType), ReleaseError)

pub type VerifyRelease =
  fn(PluginSpec, Context) -> Result(Nil, ReleaseError)

pub type GenerateNotes =
  fn(PluginSpec, Context) -> Result(String, ReleaseError)

pub type AddChannel =
  fn(PluginSpec, Context) -> Result(Option(Release), ReleaseError)

pub type Prepare =
  fn(PluginSpec, Context) -> Result(Nil, ReleaseError)

/// `publish` is asynchronous (it may perform network I/O), so it returns a
/// `Task`. On the Erlang target the task is synchronous; on JavaScript it is a
/// promise. See `bump/task`.
pub type Publish =
  fn(PluginSpec, Context) -> Task(Result(Option(Release), ReleaseError))

pub type Success =
  fn(PluginSpec, Context) -> Result(Nil, ReleaseError)

pub type Fail =
  fn(PluginSpec, Context) -> Result(Nil, ReleaseError)

pub type Plugin {
  Plugin(
    name: String,
    verify_conditions: Option(VerifyConditions),
    analyze_commits: Option(AnalyzeCommits),
    verify_release: Option(VerifyRelease),
    generate_notes: Option(GenerateNotes),
    add_channel: Option(AddChannel),
    prepare: Option(Prepare),
    publish: Option(Publish),
    success: Option(Success),
    fail: Option(Fail),
  )
}

/// A plugin implementing no hooks. Build concrete plugins with record updates,
/// e.g. `Plugin(..new("npm"), publish: Some(do_publish))`.
pub fn new(name: String) -> Plugin {
  Plugin(
    name: name,
    verify_conditions: None,
    analyze_commits: None,
    verify_release: None,
    generate_notes: None,
    add_channel: None,
    prepare: None,
    publish: None,
    success: None,
    fail: None,
  )
}

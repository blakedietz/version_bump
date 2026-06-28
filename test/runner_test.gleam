//// Tests for the hook runners. These exercise the PURE combination semantics
//// of `runner` by wiring up in-memory plugins whose hooks are constant pure
//// functions — no git, no network, no filesystem. The runners themselves only
//// fold over the plugin list and combine results, so this fully covers their
//// behaviour.

import gleam/dict
import gleam/option.{type Option, None, Some}
import gleeunit/should
import version_bump/branch.{type Branch, Branch, ReleaseBranch}
import version_bump/config.{type PluginSpec, Config, PluginSpec}
import version_bump/context.{type Context}
import version_bump/error.{AggregateError, PluginError}
import version_bump/plugin.{type Plugin, Plugin}
import version_bump/release.{type Release, Release}
import version_bump/runner
import version_bump/semver.{type ReleaseType, Major, Minor, Patch, Stable}
import version_bump/task

// --- fixtures ---------------------------------------------------------------

fn test_spec(name: String) -> PluginSpec {
  PluginSpec(name, dict.new())
}

fn test_branch() -> Branch {
  Branch(
    name: "main",
    type_: ReleaseBranch,
    channel: None,
    prerelease: None,
    range: None,
    main: True,
  )
}

fn test_context() -> Context {
  let config =
    Config(
      repository_url: None,
      tag_format: "v${version}",
      branches: [],
      plugins: [],
      dry_run: False,
      ci: True,
      versioning_mode: Stable,
    )
  context.new(
    cwd: "/tmp",
    env: dict.new(),
    config: config,
    branch: test_branch(),
    branches: [],
  )
}

/// A plugin that contributes the given release type from `analyze_commits`.
fn analyzer(name: String, rtype: Option(ReleaseType)) -> Plugin {
  Plugin(
    ..plugin.new(name),
    analyze_commits: Some(fn(_spec, _ctx) { Ok(rtype) }),
  )
}

/// A plugin whose `generate_notes` yields a fixed string.
fn note_maker(name: String, note: String) -> Plugin {
  Plugin(..plugin.new(name), generate_notes: Some(fn(_spec, _ctx) { Ok(note) }))
}

/// A plugin whose `publish` yields the given optional release. `publish` is
/// asynchronous, so the result is wrapped in an already-resolved task.
fn publisher(name: String, rel: Option(Release)) -> Plugin {
  Plugin(
    ..plugin.new(name),
    publish: Some(fn(_spec, _ctx) { task.resolve(Ok(rel)) }),
  )
}

/// A plugin whose `verify_conditions` succeeds or fails.
fn verifier(name: String, ok: Bool) -> Plugin {
  let hook = case ok {
    True -> fn(_spec, _ctx) { Ok(Nil) }
    False -> fn(_spec, _ctx) { Error(PluginError(name, "boom")) }
  }
  Plugin(..plugin.new(name), verify_conditions: Some(hook))
}

fn resolved(plugin: Plugin) -> #(PluginSpec, Plugin) {
  #(test_spec(plugin.name), plugin)
}

fn a_release(name: String) -> Release {
  Release(
    name: name,
    url: None,
    version: "1.0.0",
    git_tag: "v1.0.0",
    channel: None,
    plugin_name: name,
  )
}

// --- analyze_commits --------------------------------------------------------

pub fn analyze_highest_wins_test() {
  let plugins = [
    resolved(analyzer("a", Some(Patch))),
    resolved(analyzer("b", Some(Major))),
    resolved(analyzer("c", Some(Minor))),
  ]
  runner.run_analyze_commits(plugins, test_context())
  |> should.equal(Ok(Some(Major)))
}

pub fn analyze_none_when_no_opinions_test() {
  let plugins = [resolved(analyzer("a", None)), resolved(analyzer("b", None))]
  runner.run_analyze_commits(plugins, test_context())
  |> should.equal(Ok(None))
}

pub fn analyze_skips_plugins_without_hook_test() {
  let plugins = [
    resolved(plugin.new("noop")),
    resolved(analyzer("a", Some(Minor))),
  ]
  runner.run_analyze_commits(plugins, test_context())
  |> should.equal(Ok(Some(Minor)))
}

pub fn analyze_empty_is_none_test() {
  runner.run_analyze_commits([], test_context())
  |> should.equal(Ok(None))
}

// --- generate_notes ---------------------------------------------------------

pub fn generate_notes_concatenates_in_order_test() {
  let plugins = [
    resolved(note_maker("a", "first")),
    resolved(note_maker("b", "second")),
  ]
  runner.run_generate_notes(plugins, test_context())
  |> should.equal(Ok("first\n\nsecond"))
}

pub fn generate_notes_skips_empty_sections_test() {
  let plugins = [
    resolved(note_maker("a", "")),
    resolved(note_maker("b", "only")),
    resolved(plugin.new("noop")),
  ]
  runner.run_generate_notes(plugins, test_context())
  |> should.equal(Ok("only"))
}

pub fn generate_notes_empty_when_no_plugins_test() {
  runner.run_generate_notes([], test_context())
  |> should.equal(Ok(""))
}

// --- publish ----------------------------------------------------------------

pub fn publish_collects_some_results_test() {
  let plugins = [
    resolved(publisher("a", Some(a_release("a")))),
    resolved(publisher("b", None)),
    resolved(publisher("c", Some(a_release("c")))),
  ]
  // `run_publish` returns a Task; on the Erlang test target `task.run` invokes
  // the continuation synchronously, so the assertion runs in-test.
  runner.run_publish(plugins, test_context())
  |> task.run(fn(result) {
    result
    |> should.equal(Ok([a_release("a"), a_release("c")]))
  })
}

pub fn publish_empty_when_none_handled_test() {
  let plugins = [resolved(publisher("a", None)), resolved(plugin.new("noop"))]
  runner.run_publish(plugins, test_context())
  |> task.run(fn(result) {
    result
    |> should.equal(Ok([]))
  })
}

// --- verify_conditions (effect, AggregateError) -----------------------------

pub fn verify_conditions_all_ok_test() {
  let plugins = [resolved(verifier("a", True)), resolved(verifier("b", True))]
  runner.run_verify_conditions(plugins, test_context())
  |> should.equal(Ok(Nil))
}

pub fn verify_conditions_aggregates_failures_test() {
  let plugins = [
    resolved(verifier("a", False)),
    resolved(verifier("b", True)),
    resolved(verifier("c", False)),
  ]
  runner.run_verify_conditions(plugins, test_context())
  |> should.equal(
    Error(
      AggregateError([
        PluginError("a", "boom"),
        PluginError("c", "boom"),
      ]),
    ),
  )
}

pub fn verify_conditions_empty_is_ok_test() {
  runner.run_verify_conditions([], test_context())
  |> should.equal(Ok(Nil))
}

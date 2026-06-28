//// Hook runners — the glue that drives a list of resolved plugins through one
//// lifecycle hook each, applying the per-hook combination semantics the plugin
//// contract documents.
////
//// A "resolved plugin" is a `#(PluginSpec, Plugin)` pair: the spec carries the
//// user's options, the plugin carries the hook implementations. Each runner
//// folds over the list, looks up the relevant `Option(hook)` on each plugin,
//// skips plugins that don't implement it (`None`), and combines the results:
////
////   - verify_conditions / verify_release / prepare / success / fail
////       run every implementing plugin for effect; ALL errors are collected and,
////       if any occurred, surfaced together as an `AggregateError`.
////   - analyze_commits   highest `ReleaseType` (by `release_type_rank`) wins; a
////       single error short-circuits.
////   - generate_notes    notes are concatenated in plugin order; a single error
////       short-circuits.
////   - publish           every implementing plugin runs; the `Some(release)`
////       results are collected in order; a single error short-circuits.

import gleam/list
import gleam/option.{type Option, None, Some}
import version_bump/config.{type PluginSpec}
import version_bump/context.{type Context}
import version_bump/error.{type ReleaseError, AggregateError}
import version_bump/plugin.{type Plugin}
import version_bump/release.{type Release}
import version_bump/semver.{type ReleaseType}
import version_bump/task.{type Task}

/// A plugin resolved against the registry: its configured spec plus the hook
/// implementations to run.
pub type ResolvedPlugin =
  #(PluginSpec, Plugin)

// --- Effect hooks (collect-all, AggregateError) ----------------------------

/// Run `verify_conditions` across all plugins, aggregating any failures.
pub fn run_verify_conditions(
  plugins: List(ResolvedPlugin),
  context: Context,
) -> Result(Nil, ReleaseError) {
  run_effect_hook(plugins, context, fn(p) { p.verify_conditions })
}

/// Run `verify_release` across all plugins, aggregating any failures.
pub fn run_verify_release(
  plugins: List(ResolvedPlugin),
  context: Context,
) -> Result(Nil, ReleaseError) {
  run_effect_hook(plugins, context, fn(p) { p.verify_release })
}

/// Run `prepare` across all plugins, aggregating any failures.
pub fn run_prepare(
  plugins: List(ResolvedPlugin),
  context: Context,
) -> Result(Nil, ReleaseError) {
  run_effect_hook(plugins, context, fn(p) { p.prepare })
}

/// Run `success` across all plugins, aggregating any failures.
pub fn run_success(
  plugins: List(ResolvedPlugin),
  context: Context,
) -> Result(Nil, ReleaseError) {
  run_effect_hook(plugins, context, fn(p) { p.success })
}

/// Run `fail` across all plugins, aggregating any failures.
pub fn run_fail(
  plugins: List(ResolvedPlugin),
  context: Context,
) -> Result(Nil, ReleaseError) {
  run_effect_hook(plugins, context, fn(p) { p.fail })
}

/// Shared driver for the for-effect hooks. Runs every plugin that implements
/// the selected hook, collecting every error rather than stopping at the first.
/// Returns `Ok(Nil)` when nothing failed, otherwise an `AggregateError` of all
/// collected failures (a single failure is still wrapped for a uniform shape).
fn run_effect_hook(
  plugins: List(ResolvedPlugin),
  context: Context,
  select: fn(Plugin) ->
    Option(fn(PluginSpec, Context) -> Result(Nil, ReleaseError)),
) -> Result(Nil, ReleaseError) {
  let errors =
    list.fold(plugins, [], fn(acc, resolved) {
      let #(spec, plugin) = resolved
      case select(plugin) {
        None -> acc
        Some(hook) ->
          case hook(spec, context) {
            Ok(Nil) -> acc
            Error(err) -> [err, ..acc]
          }
      }
    })

  case list.reverse(errors) {
    [] -> Ok(Nil)
    collected -> Error(AggregateError(collected))
  }
}

// --- analyze_commits (highest release type wins) ---------------------------

/// Run `analyze_commits` across all plugins and return the highest implied
/// `ReleaseType` (by `release_type_rank`), or `None` when no plugin warrants a
/// release. The first error short-circuits.
pub fn run_analyze_commits(
  plugins: List(ResolvedPlugin),
  context: Context,
) -> Result(Option(ReleaseType), ReleaseError) {
  list.try_fold(plugins, None, fn(acc, resolved) {
    let #(spec, plugin) = resolved
    case plugin.analyze_commits {
      None -> Ok(acc)
      Some(hook) -> {
        case hook(spec, context) {
          Ok(candidate) -> Ok(keep_highest(acc, candidate))
          Error(err) -> Error(err)
        }
      }
    }
  })
}

/// Keep whichever of two optional release types ranks higher; `None` (no
/// release) ranks below any concrete type.
fn keep_highest(
  current: Option(ReleaseType),
  candidate: Option(ReleaseType),
) -> Option(ReleaseType) {
  case current, candidate {
    None, other -> other
    other, None -> other
    Some(a), Some(b) ->
      case semver.release_type_rank(b) > semver.release_type_rank(a) {
        True -> Some(b)
        False -> Some(a)
      }
  }
}

// --- generate_notes (concatenate in order) ---------------------------------

/// Run `generate_notes` across all plugins, concatenating each plugin's notes
/// in plugin order. Empty contributions add nothing; non-empty ones are joined
/// with a blank line between sections. The first error short-circuits.
pub fn run_generate_notes(
  plugins: List(ResolvedPlugin),
  context: Context,
) -> Result(String, ReleaseError) {
  use sections <- result_map(
    list.try_fold(plugins, [], fn(acc, resolved) {
      let #(spec, plugin) = resolved
      case plugin.generate_notes {
        None -> Ok(acc)
        Some(hook) ->
          case hook(spec, context) {
            Ok(notes) -> Ok([notes, ..acc])
            Error(err) -> Error(err)
          }
      }
    }),
  )
  sections
  |> list.reverse
  |> list.filter(fn(section) { section != "" })
  |> join_sections
}

/// Join non-empty note sections with a blank line between them.
fn join_sections(sections: List(String)) -> String {
  case sections {
    [] -> ""
    [first, ..rest] ->
      list.fold(rest, first, fn(acc, section) { acc <> "\n\n" <> section })
  }
}

// --- publish (collect Some releases) ---------------------------------------

/// Run `publish` across all plugins, collecting the `Some(release)` results in
/// plugin order. Plugins returning `None` (not handled) contribute nothing. The
/// first error short-circuits.
///
/// `publish` is asynchronous, so the plugins are chained sequentially through a
/// `Task`: each plugin's publish runs after the previous one resolves, and the
/// whole sequence yields a single `Task` of the collected releases.
pub fn run_publish(
  plugins: List(ResolvedPlugin),
  context: Context,
) -> Task(Result(List(Release), ReleaseError)) {
  let accumulated =
    list.fold(plugins, task.resolve(Ok([])), fn(acc_task, resolved) {
      let #(spec, plugin) = resolved
      use acc <- task.await(acc_task)
      case acc {
        Error(err) -> task.resolve(Error(err))
        Ok(releases) ->
          case plugin.publish {
            None -> task.resolve(Ok(releases))
            Some(hook) -> {
              use published <- task.map(hook(spec, context))
              case published {
                Ok(Some(release)) -> Ok([release, ..releases])
                Ok(None) -> Ok(releases)
                Error(err) -> Error(err)
              }
            }
          }
      }
    })

  use collected <- task.map(accumulated)
  case collected {
    Ok(releases) -> Ok(list.reverse(releases))
    Error(err) -> Error(err)
  }
}

// --- helpers ---------------------------------------------------------------

/// `result.map` written as a `use`-friendly continuation so the post-processing
/// of a `try_fold` result reads top-to-bottom without an extra import alias.
fn result_map(result: Result(a, e), transform: fn(a) -> b) -> Result(b, e) {
  case result {
    Ok(value) -> Ok(transform(value))
    Error(err) -> Error(err)
  }
}

//// The `commit-analyzer` plugin: determines the release type implied by a set
//// of conventional commits, mirroring `@semantic-release/commit-analyzer`.
////
//// Rules (the highest matching type wins):
////   - any breaking change            -> Major
////   - else any `feat`                -> Minor
////   - else any `fix` or `perf`       -> Patch
////   - otherwise                      -> no release
////
//// The pure `analyze` function holds all the logic so it can be unit-tested
//// without a context; `plugin/0` wraps it as the `analyze_commits` hook.

import gleam/list
import gleam/option.{type Option, None, Some}
import version_bump/commit_parser.{type ConventionalCommit}
import version_bump/config.{type PluginSpec}
import version_bump/context.{type Context}
import version_bump/error.{type ReleaseError}
import version_bump/plugin.{type Plugin, Plugin}
import version_bump/semver.{type ReleaseType, Major, Minor, Patch}

/// Classify a single commit into the release type it warrants, if any.
fn classify(commit: ConventionalCommit) -> Option(ReleaseType) {
  case commit.breaking {
    True -> Some(Major)
    False ->
      case commit.type_ {
        Some("feat") -> Some(Minor)
        Some("fix") | Some("perf") -> Some(Patch)
        _ -> None
      }
  }
}

/// Keep whichever of two optional release types is higher in precedence.
/// `None` means "no release", which is lower than any concrete type.
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

/// Determine the release type for a list of conventional commits.
///
/// Returns the highest release type any commit warrants, or `None` when no
/// commit triggers a release. This is the pure core of the plugin.
pub fn analyze(commits: List(ConventionalCommit)) -> Option(ReleaseType) {
  list.fold(commits, None, fn(acc, commit) {
    keep_highest(acc, classify(commit))
  })
}

/// The `analyze_commits` hook: read already-parsed commits from the context and
/// report the implied release type.
fn analyze_commits(
  _spec: PluginSpec,
  context: Context,
) -> Result(Option(ReleaseType), ReleaseError) {
  Ok(analyze(context.commits))
}

/// The `commit-analyzer` plugin, implementing only `analyze_commits`.
pub fn plugin() -> Plugin {
  Plugin(
    ..plugin.new("commit-analyzer"),
    analyze_commits: Some(analyze_commits),
  )
}

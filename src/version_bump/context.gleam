//// The shared context threaded through every plugin hook, mirroring
//// semantic-release's `context` object. It is immutable: the engine produces a
//// new `Context` as the pipeline advances (e.g. after analysing commits it sets
//// `next_release`).

import gleam/dict.{type Dict}
import gleam/option.{type Option, None}
import version_bump/branch.{type Branch}
import version_bump/commit_parser.{type ConventionalCommit}
import version_bump/config.{type Config}
import version_bump/release.{type LastRelease, type NextRelease, type Release}

pub type Context {
  Context(
    cwd: String,
    env: Dict(String, String),
    config: Config,
    branch: Branch,
    branches: List(Branch),
    commits: List(ConventionalCommit),
    last_release: Option(LastRelease),
    next_release: Option(NextRelease),
    releases: List(Release),
    errors: List(String),
    dry_run: Bool,
  )
}

/// Build an initial context with the empty/None fields the pipeline fills in.
pub fn new(
  cwd cwd: String,
  env env: Dict(String, String),
  config config: Config,
  branch branch: Branch,
  branches branches: List(Branch),
) -> Context {
  Context(
    cwd: cwd,
    env: env,
    config: config,
    branch: branch,
    branches: branches,
    commits: [],
    last_release: None,
    next_release: None,
    releases: [],
    errors: [],
    dry_run: config.dry_run,
  )
}

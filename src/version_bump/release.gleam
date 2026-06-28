//// Release records produced and consumed across the pipeline: the previous
//// release discovered in git, the release about to be made, and the artifacts a
//// `publish` / `add_channel` hook produces.

import gleam/option.{type Option}
import version_bump/semver.{type ReleaseType}

/// The most recent release reachable on the current channel, if any.
pub type LastRelease {
  LastRelease(
    version: String,
    git_tag: String,
    git_head: String,
    channels: List(Option(String)),
  )
}

/// The release about to be made.
pub type NextRelease {
  NextRelease(
    version: String,
    type_: ReleaseType,
    git_tag: String,
    git_head: String,
    channel: Option(String),
    notes: String,
  )
}

/// A release produced by a `publish` / `add_channel` hook.
pub type Release {
  Release(
    name: String,
    url: Option(String),
    version: String,
    git_tag: String,
    channel: Option(String),
    plugin_name: String,
  )
}

//// The branching / channel model (MVP).
////
//// semantic-release resolves the configured branches against the branches that
//// actually exist in the repository, classifying each into one of three kinds:
////
////   * `ReleaseBranch`     — a normal release line (e.g. `main`, `master`,
////     `next`). The first such branch is the "main" branch.
////   * `MaintenanceBranch` — a branch whose name is a version range such as
////     `1.x`, `1.2.x` or `1.x.x`. Releases here are constrained to that range.
////   * `PrereleaseBranch`  — a branch with a `prerelease` identifier (e.g.
////     `beta`, `alpha`). Releases here carry a `-id.N` prerelease suffix.
////
//// This module is pure: it never shells out to git. The caller passes in the
//// list of branch names discovered in the repository (`git_branches`) and the
//// list of tags (`tags`); everything here is string / semver manipulation.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/regexp
import gleam/result
import gleam/string
import version_bump/config.{type BranchConfig, type Config}
import version_bump/error.{type ReleaseError, ConfigError}
import version_bump/release.{type LastRelease, LastRelease}
import version_bump/semver.{
  type ReleaseType, type Version, type VersioningMode, InitialDevelopment,
  Stable,
}

/// How a branch participates in the release flow.
pub type BranchType {
  ReleaseBranch
  MaintenanceBranch
  PrereleaseBranch
}

/// A resolved release branch (after merging config with discovered git branches).
pub type Branch {
  Branch(
    name: String,
    type_: BranchType,
    channel: Option(String),
    prerelease: Option(String),
    range: Option(String),
    main: Bool,
  )
}

/// Resolve the configured branches against the branches that exist in the
/// repository, returning the resolved `current` branch together with every
/// resolved branch.
///
/// Each `BranchConfig` whose name appears in `git_branches` is classified into
/// a `Branch`. Configured branches that do not exist in the repository are
/// dropped (they cannot be released against). The `current` branch must be one
/// of the resolved branches, otherwise a `ConfigError` is returned.
pub fn resolve(
  config: Config,
  git_branches: List(String),
  current: String,
) -> Result(#(Branch, List(Branch)), ReleaseError) {
  // Keep only configured branches that actually exist in the repository.
  let existing =
    list.filter(config.branches, fn(bc) { list.contains(git_branches, bc.name) })

  // The "main" release branch is the first configured branch that is neither a
  // prerelease branch nor a maintenance branch.
  let main_name = first_main_name(config.branches)

  let resolved = list.map(existing, fn(bc) { classify(bc, main_name) })

  case list.find(resolved, fn(b) { b.name == current }) {
    Ok(branch) -> Ok(#(branch, resolved))
    Error(_) ->
      Error(ConfigError(
        "Current branch '" <> current <> "' is not a configured release branch",
      ))
  }
}

/// Pick the highest existing release on `branch` from a list of git tags.
///
/// Tags are matched against `tag_format` (e.g. `"v${version}"`); the embedded
/// version is parsed as semver. Only versions compatible with the branch are
/// considered:
///
///   * `PrereleaseBranch`  — only versions whose first prerelease identifier is
///     the branch's prerelease id (e.g. `1.0.0-beta.2` on the `beta` branch).
///   * `MaintenanceBranch` — only non-prerelease versions inside the branch's
///     range (e.g. `1.x` admits `1.*.*`, `1.2.x` admits `1.2.*`).
///   * `ReleaseBranch`     — only non-prerelease versions.
///
/// Returns the highest matching version as a `LastRelease`, or `None` when no
/// tag matches.
pub fn last_release(
  tags: List(String),
  branch: Branch,
  tag_format: String,
) -> Option(LastRelease) {
  let #(prefix, suffix) = tag_format_parts(tag_format)

  let candidates =
    tags
    |> list.filter_map(fn(tag) {
      case extract_version_string(tag, prefix, suffix) {
        Ok(version_str) ->
          case semver.parse(version_str) {
            Ok(version) ->
              case version_matches_branch(version, branch) {
                True -> Ok(#(tag, version))
                False -> Error(Nil)
              }
            Error(_) -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    })

  case highest(candidates) {
    None -> None
    Some(#(tag, version)) ->
      Some(
        LastRelease(
          version: semver.to_string(version),
          git_tag: tag,
          git_head: "",
          channels: [branch.channel],
        ),
      )
  }
}

/// Compute the next version string for `branch`, given the last release and the
/// `ReleaseType` the commits warrant.
///
/// With no previous release the first version is `1.0.0` (or `0.1.0` in
/// `InitialDevelopment` mode), with the branch's prerelease identifier appended
/// on a prerelease branch. Otherwise the last version is bumped by `rtype` — in
/// `InitialDevelopment` mode a breaking change is downshifted to a minor bump
/// while major is 0 (see `semver.effective_release_type`).
pub fn next_version(
  last: Option(LastRelease),
  rtype: ReleaseType,
  branch: Branch,
  mode: VersioningMode,
) -> Result(String, ReleaseError) {
  case last {
    None -> {
      let base = case mode {
        InitialDevelopment -> "0.1.0"
        Stable -> "1.0.0"
      }
      case branch.prerelease {
        Some(id) -> Ok(base <> "-" <> id <> ".1")
        None -> Ok(base)
      }
    }
    Some(release) -> {
      use version <- result.try(semver.parse(release.version))
      let effective = semver.effective_release_type(version, rtype, mode)
      case branch.prerelease {
        Some(id) ->
          Ok(
            semver.to_string(semver.bump_with_prerelease(version, effective, id)),
          )
        None -> Ok(semver.to_string(semver.bump(version, effective)))
      }
    }
  }
}

// --- Internal helpers -------------------------------------------------------

/// Classify a single configured branch into a resolved `Branch`.
fn classify(bc: BranchConfig, main_name: Option(String)) -> Branch {
  let is_main = main_name == Some(bc.name)
  case bc.prerelease {
    Some(id) ->
      Branch(
        name: bc.name,
        type_: PrereleaseBranch,
        // A prerelease branch publishes to a channel named after its id unless
        // an explicit channel was configured.
        channel: option.or(bc.channel, Some(id)),
        prerelease: Some(id),
        range: bc.range,
        main: False,
      )
    None ->
      case maintenance_range(bc.name, bc.range) {
        Some(range) ->
          Branch(
            name: bc.name,
            type_: MaintenanceBranch,
            channel: option.or(bc.channel, Some(bc.name)),
            prerelease: None,
            range: Some(range),
            main: False,
          )
        None ->
          Branch(
            name: bc.name,
            type_: ReleaseBranch,
            channel: bc.channel,
            prerelease: None,
            range: bc.range,
            main: is_main,
          )
      }
  }
}

/// The name of the first configured branch that is a plain release branch
/// (neither prerelease nor maintenance), i.e. the "main" branch.
fn first_main_name(branches: List(BranchConfig)) -> Option(String) {
  branches
  |> list.find(fn(bc) {
    case bc.prerelease {
      Some(_) -> False
      None -> maintenance_range(bc.name, bc.range) == None
    }
  })
  |> result.map(fn(bc) { bc.name })
  |> option.from_result
}

/// If `name` looks like a maintenance range (`N.x`, `N.x.x`, `N.N.x`), return
/// the normalised range string. An explicit configured `range` takes priority.
fn maintenance_range(
  name: String,
  configured: Option(String),
) -> Option(String) {
  case configured {
    Some(r) -> Some(r)
    None ->
      case parse_maintenance_name(name) {
        Ok(range) -> Some(range)
        Error(_) -> None
      }
  }
}

/// Parse a maintenance branch name into a range string.
///
/// `1.x` / `1.x.x` -> `">=1.0.0 <2.0.0"`, `1.2.x` -> `">=1.2.0 <1.3.0"`.
fn parse_maintenance_name(name: String) -> Result(String, Nil) {
  // `1.x` or `1.x.x`  (major only fixed)
  let major_only = case regexp.from_string("^(\\d+)\\.x(\\.x)?$") {
    Ok(re) -> regexp.scan(re, name)
    Error(_) -> []
  }
  // `1.2.x`  (major.minor fixed)
  let major_minor = case regexp.from_string("^(\\d+)\\.(\\d+)\\.x$") {
    Ok(re) -> regexp.scan(re, name)
    Error(_) -> []
  }
  case major_only, major_minor {
    [regexp.Match(_, [Some(maj), ..]), ..], _ ->
      case int.parse(maj) {
        Ok(m) ->
          Ok(
            ">="
            <> int.to_string(m)
            <> ".0.0 <"
            <> int.to_string(m + 1)
            <> ".0.0",
          )
        Error(_) -> Error(Nil)
      }
    _, [regexp.Match(_, [Some(maj), Some(min)]), ..] ->
      case int.parse(maj), int.parse(min) {
        Ok(m), Ok(n) ->
          Ok(
            ">="
            <> int.to_string(m)
            <> "."
            <> int.to_string(n)
            <> ".0 <"
            <> int.to_string(m)
            <> "."
            <> int.to_string(n + 1)
            <> ".0",
          )
        _, _ -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

/// True when `version` belongs on `branch`.
fn version_matches_branch(version: Version, branch: Branch) -> Bool {
  case branch.type_ {
    PrereleaseBranch ->
      case branch.prerelease, version.prerelease {
        Some(id), [first, ..] -> first == id
        _, _ -> False
      }
    MaintenanceBranch ->
      // Only stable versions count, and they must fall inside the range.
      case version.prerelease {
        [] -> in_range(version, branch.range)
        _ -> False
      }
    ReleaseBranch ->
      // The main / release line tracks stable versions only.
      version.prerelease == []
  }
}

/// True when `version` falls inside a maintenance range string of the shape
/// `">=A.B.C <D.E.F"`. An absent range admits everything.
fn in_range(version: Version, range: Option(String)) -> Bool {
  case range {
    None -> True
    Some(r) ->
      case parse_range(r) {
        Ok(#(low, high)) -> gte(version, low) && lt(version, high)
        Error(_) -> True
      }
  }
}

/// Parse a `">=lo <hi"` range into its two bounds.
fn parse_range(r: String) -> Result(#(Version, Version), Nil) {
  case string.split(string.trim(r), " ") {
    [lo, hi] -> {
      let lo_str = string.replace(lo, ">=", "")
      let hi_str = string.replace(hi, "<", "")
      case semver.parse(lo_str), semver.parse(hi_str) {
        Ok(low), Ok(high) -> Ok(#(low, high))
        _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn gte(a: Version, b: Version) -> Bool {
  case semver.compare(a, b) {
    order.Lt -> False
    _ -> True
  }
}

fn lt(a: Version, b: Version) -> Bool {
  case semver.compare(a, b) {
    order.Lt -> True
    _ -> False
  }
}

/// The pair with the highest version per semver `compare`.
fn highest(candidates: List(#(String, Version))) -> Option(#(String, Version)) {
  case candidates {
    [] -> None
    [first, ..rest] ->
      Some(
        list.fold(rest, first, fn(acc, cand) {
          case semver.compare(cand.1, acc.1) {
            order.Gt -> cand
            _ -> acc
          }
        }),
      )
  }
}

/// Split a tag format like `"v${version}"` into its prefix and suffix around
/// the `${version}` placeholder. If the placeholder is missing, the whole
/// format is treated as a prefix (best effort).
fn tag_format_parts(tag_format: String) -> #(String, String) {
  case string.split_once(tag_format, "${version}") {
    Ok(#(prefix, suffix)) -> #(prefix, suffix)
    Error(_) -> #(tag_format, "")
  }
}

/// Extract the version substring from a tag given the format's prefix/suffix.
/// Fails when the tag does not start with `prefix` and end with `suffix`.
fn extract_version_string(
  tag: String,
  prefix: String,
  suffix: String,
) -> Result(String, Nil) {
  case string.starts_with(tag, prefix), string.ends_with(tag, suffix) {
    True, True -> {
      let without_prefix = string.drop_start(tag, string.length(prefix))
      let core = string.drop_end(without_prefix, string.length(suffix))
      case core {
        "" -> Error(Nil)
        _ -> Ok(core)
      }
    }
    _, _ -> Error(Nil)
  }
}

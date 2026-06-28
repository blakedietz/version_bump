//// Semantic Versioning (SemVer 2.0.0) over the foundation `Version` type.
////
//// This module is pure: parsing a string into a `Version`, rendering it back,
//// comparing two versions per the SemVer precedence rules (build metadata
//// ignored, prerelease identifiers compared field-by-field), and bumping a
//// version by a `ReleaseType`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import version_bump/error.{type ReleaseError, VersionError}

/// The kind of release a set of commits warrants. Ordered Patch < Minor < Major
/// so the "highest type wins" rule is a simple max over `release_type_rank`.
pub type ReleaseType {
  Patch
  Minor
  Major
}

pub fn release_type_rank(t: ReleaseType) -> Int {
  case t {
    Patch -> 1
    Minor -> 2
    Major -> 3
  }
}

pub fn release_type_to_string(t: ReleaseType) -> String {
  case t {
    Patch -> "patch"
    Minor -> "minor"
    Major -> "major"
  }
}

/// A semantic version. `build` metadata is preserved but ignored in precedence.
pub type Version {
  Version(
    major: Int,
    minor: Int,
    patch: Int,
    prerelease: List(String),
    build: List(String),
  )
}

/// Parse a SemVer string into a `Version`.
///
/// Accepts an optional leading `v` (e.g. `v1.2.3`), an optional `-prerelease`
/// section of dot-separated identifiers, and an optional `+build` metadata
/// section of dot-separated identifiers. The order of the optional sections is
/// `core[-prerelease][+build]` per the spec.
///
/// Returns a `VersionError` when the string is not a valid version.
pub fn parse(s: String) -> Result(Version, ReleaseError) {
  let trimmed = string.trim(s)
  let without_v = strip_leading_v(trimmed)

  // Split off build metadata first (everything after the first '+').
  let #(core_and_pre, build) = split_once(without_v, "+")

  // Then split off the prerelease (everything after the first '-'). Track
  // whether a '-' separator was actually present so a trailing '-' with no
  // identifiers (e.g. "1.2.3-") is rejected rather than treated as no
  // prerelease at all.
  let #(core, prerelease, has_pre) = case string.split_once(core_and_pre, "-") {
    Ok(#(before, after)) -> #(before, after, True)
    Error(_) -> #(core_and_pre, "", False)
  }

  case parse_core(core) {
    Error(e) -> Error(e)
    Ok(#(major, minor, patch)) -> {
      let pre_ids = case has_pre {
        True -> string.split(prerelease, ".")
        False -> []
      }
      let build_ids = split_dot_section(build)
      case validate_prerelease(pre_ids), validate_build(build_ids) {
        Ok(_), Ok(_) ->
          Ok(Version(
            major: major,
            minor: minor,
            patch: patch,
            prerelease: pre_ids,
            build: build_ids,
          ))
        Error(e), _ -> Error(e)
        _, Error(e) -> Error(e)
      }
    }
  }
}

/// Render a `Version` back to its canonical SemVer string (no leading `v`).
pub fn to_string(v: Version) -> String {
  let core =
    int.to_string(v.major)
    <> "."
    <> int.to_string(v.minor)
    <> "."
    <> int.to_string(v.patch)
  let with_pre = case v.prerelease {
    [] -> core
    ids -> core <> "-" <> string.join(ids, ".")
  }
  case v.build {
    [] -> with_pre
    ids -> with_pre <> "+" <> string.join(ids, ".")
  }
}

/// Compare two versions per SemVer 2.0.0 precedence.
///
/// Core version (major, minor, patch) is compared numerically. Build metadata
/// is ignored. A version WITH a prerelease has LOWER precedence than the same
/// version WITHOUT one. Prerelease identifiers are compared field-by-field:
/// numeric identifiers compare numerically and always rank below alphanumeric
/// ones; a longer set of identifiers wins when all preceding fields are equal.
pub fn compare(a: Version, b: Version) -> order.Order {
  case int.compare(a.major, b.major) {
    order.Eq ->
      case int.compare(a.minor, b.minor) {
        order.Eq ->
          case int.compare(a.patch, b.patch) {
            order.Eq -> compare_prerelease(a.prerelease, b.prerelease)
            other -> other
          }
        other -> other
      }
    other -> other
  }
}

/// Bump a version by a release type.
///
/// Clears any prerelease and build metadata. `Major` increments major and
/// resets minor and patch to 0. `Minor` increments minor and resets patch to 0.
/// `Patch` increments patch.
pub fn bump(v: Version, t: ReleaseType) -> Version {
  case t {
    Major -> Version(v.major + 1, 0, 0, [], [])
    Minor -> Version(v.major, v.minor + 1, 0, [], [])
    Patch -> Version(v.major, v.minor, v.patch + 1, [], [])
  }
}

/// Whether a package is in SemVer's initial-development phase (`0.y.z` — spec
/// clause 4, where the public API is not yet stable) or has a stable public API.
pub type VersioningMode {
  InitialDevelopment
  Stable
}

/// The release type to actually apply, given the versioning mode. In
/// `InitialDevelopment` while the major version is 0, a breaking change is
/// downshifted to a *minor* bump so it stays in `0.x` instead of jumping to
/// `1.0.0`; features and fixes are unaffected, and once major >= 1 the mode has
/// no effect.
pub fn effective_release_type(
  version: Version,
  t: ReleaseType,
  mode: VersioningMode,
) -> ReleaseType {
  case mode {
    Stable -> t
    InitialDevelopment ->
      case version.major == 0 {
        False -> t
        True ->
          case t {
            Major -> Minor
            Minor -> Minor
            Patch -> Patch
          }
      }
  }
}

/// Bump a version by a release type, attaching a prerelease identifier.
///
/// The core version is bumped exactly as `bump` does, then a prerelease of
/// `[id, "1"]` is attached, e.g. bumping `1.1.0` by `Minor` with `"beta"`
/// yields `1.2.0-beta.1`.
pub fn bump_with_prerelease(v: Version, t: ReleaseType, id: String) -> Version {
  let bumped = bump(v, t)
  Version(..bumped, prerelease: [id, "1"])
}

/// The greatest version in a list per `compare`, or `None` if the list is empty.
pub fn max(versions: List(Version)) -> Option(Version) {
  case versions {
    [] -> None
    [first, ..rest] ->
      Some(
        list.fold(rest, first, fn(acc, v) {
          case compare(v, acc) {
            order.Gt -> v
            _ -> acc
          }
        }),
      )
  }
}

// --- Internal helpers -------------------------------------------------------

fn strip_leading_v(s: String) -> String {
  case string.starts_with(s, "v") || string.starts_with(s, "V") {
    True -> string.drop_start(s, 1)
    False -> s
  }
}

/// Split a string into the part before the first occurrence of `sep` and the
/// part after it. If `sep` is not present, the second element is the empty
/// string. The separator itself is dropped.
fn split_once(s: String, sep: String) -> #(String, String) {
  case string.split_once(s, sep) {
    Ok(#(before, after)) -> #(before, after)
    Error(_) -> #(s, "")
  }
}

/// Split a dot-separated section into identifiers, treating the empty string as
/// "no section" (an empty list) rather than a single empty identifier.
fn split_dot_section(s: String) -> List(String) {
  case s {
    "" -> []
    _ -> string.split(s, ".")
  }
}

/// Parse the `major.minor.patch` core into a triple of ints.
fn parse_core(core: String) -> Result(#(Int, Int, Int), ReleaseError) {
  case string.split(core, ".") {
    [maj, min, pat] ->
      case parse_numeric_id(maj), parse_numeric_id(min), parse_numeric_id(pat) {
        Ok(a), Ok(b), Ok(c) -> Ok(#(a, b, c))
        _, _, _ ->
          Error(VersionError(
            "Invalid version core, expected numeric major.minor.patch: " <> core,
          ))
      }
    _ ->
      Error(VersionError(
        "Invalid version, expected major.minor.patch: " <> core,
      ))
  }
}

/// Parse a non-negative integer that has no leading zeros (per SemVer the core
/// and numeric prerelease identifiers must not have leading zeros). `0` itself
/// is allowed.
fn parse_numeric_id(s: String) -> Result(Int, Nil) {
  case s {
    "" -> Error(Nil)
    "0" -> Ok(0)
    _ ->
      case string.starts_with(s, "0") {
        True -> Error(Nil)
        False ->
          case int.parse(s) {
            Ok(n) if n >= 0 -> Ok(n)
            _ -> Error(Nil)
          }
      }
  }
}

/// Validate prerelease identifiers: each must be non-empty, contain only
/// [0-9A-Za-z-], and numeric identifiers must not have leading zeros.
fn validate_prerelease(ids: List(String)) -> Result(Nil, ReleaseError) {
  list.try_each(ids, fn(id) {
    case id {
      "" -> Error(VersionError("Empty prerelease identifier"))
      _ ->
        case is_valid_alnum_id(id) {
          False -> Error(VersionError("Invalid prerelease identifier: " <> id))
          True ->
            case is_numeric(id) {
              True ->
                case has_leading_zero(id) {
                  True ->
                    Error(VersionError(
                      "Numeric prerelease identifier has leading zero: " <> id,
                    ))
                  False -> Ok(Nil)
                }
              False -> Ok(Nil)
            }
        }
    }
  })
}

/// Validate build identifiers: each must be non-empty and contain only
/// [0-9A-Za-z-]. Leading zeros are allowed in build metadata.
fn validate_build(ids: List(String)) -> Result(Nil, ReleaseError) {
  list.try_each(ids, fn(id) {
    case id {
      "" -> Error(VersionError("Empty build identifier"))
      _ ->
        case is_valid_alnum_id(id) {
          False -> Error(VersionError("Invalid build identifier: " <> id))
          True -> Ok(Nil)
        }
    }
  })
}

/// A string is a valid SemVer identifier character set: ASCII alphanumerics
/// and hyphens only.
fn is_valid_alnum_id(s: String) -> Bool {
  s
  |> string.to_graphemes
  |> list.all(is_id_char)
}

fn is_id_char(c: String) -> Bool {
  is_digit(c) || is_letter(c) || c == "-"
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn is_letter(c: String) -> Bool {
  case string.lowercase(c) {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z" -> True
    _ -> False
  }
}

/// True when every character of a non-empty string is a digit.
fn is_numeric(s: String) -> Bool {
  case s {
    "" -> False
    _ ->
      s
      |> string.to_graphemes
      |> list.all(is_digit)
  }
}

fn has_leading_zero(s: String) -> Bool {
  s != "0" && string.starts_with(s, "0")
}

/// Compare two prerelease identifier lists per SemVer precedence rules.
///
/// An empty list means "no prerelease" (a normal release), which outranks any
/// prerelease. This release-vs-prerelease distinction only applies at the top
/// level; once both versions are known to have prerelease identifiers, the
/// lists are compared field-by-field where a larger set of fields wins when all
/// preceding fields are equal (see `compare_pre_fields`).
fn compare_prerelease(a: List(String), b: List(String)) -> order.Order {
  case a, b {
    // No prerelease == release; release outranks any prerelease.
    [], [] -> order.Eq
    [], _ -> order.Gt
    _, [] -> order.Lt
    _, _ -> compare_pre_fields(a, b)
  }
}

/// Compare two non-empty prerelease identifier lists field-by-field. When all
/// compared fields are equal, the list with MORE fields has higher precedence.
fn compare_pre_fields(a: List(String), b: List(String)) -> order.Order {
  case a, b {
    [], [] -> order.Eq
    [], _ -> order.Lt
    _, [] -> order.Gt
    [x, ..xs], [y, ..ys] ->
      case compare_identifier(x, y) {
        order.Eq -> compare_pre_fields(xs, ys)
        other -> other
      }
  }
}

/// Compare two individual prerelease identifiers. Numeric identifiers compare
/// numerically and rank lower than alphanumeric identifiers.
fn compare_identifier(a: String, b: String) -> order.Order {
  case is_numeric(a), is_numeric(b) {
    True, True ->
      case int.parse(a), int.parse(b) {
        Ok(na), Ok(nb) -> int.compare(na, nb)
        _, _ -> string.compare(a, b)
      }
    True, False -> order.Lt
    False, True -> order.Gt
    False, False -> string.compare(a, b)
  }
}

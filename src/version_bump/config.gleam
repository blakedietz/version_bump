//// Configuration shapes plus the entry point for loading config from a project.
//// The `load` implementation (reading .releaserc / release.config / package.json)
//// is fleshed out by the config module work; the type is owned here so every
//// other module can depend on it without a cycle.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tom
import version_bump/error.{type ReleaseError}
import version_bump/semver.{type VersioningMode, InitialDevelopment, Stable}

/// A configured plugin: its module name plus raw, string-keyed options.
/// Options are kept as strings here to avoid a dynamic value type in the core;
/// individual plugins parse what they need.
pub type PluginSpec {
  PluginSpec(name: String, options: Dict(String, String))
}

/// A single branch entry from configuration (before resolution against git).
pub type BranchConfig {
  BranchConfig(
    name: String,
    channel: Option(String),
    prerelease: Option(String),
    range: Option(String),
  )
}

pub type Config {
  Config(
    repository_url: Option(String),
    tag_format: String,
    branches: List(BranchConfig),
    plugins: List(PluginSpec),
    dry_run: Bool,
    ci: Bool,
    /// SemVer "initial development" (0.y.z) mode. In `InitialDevelopment`, while
    /// major is 0 a breaking change bumps the minor version instead of jumping
    /// to 1.0.0, and the first release starts at 0.1.0. Parsed from the boolean
    /// `initial_development` config key.
    versioning_mode: VersioningMode,
  )
}

/// The default configuration for a Gleam project: commit analysis, release
/// notes, publishing to Hex, and a GitHub release, over the conventional release
/// branches. (This is the Gleam-first analogue of semantic-release's defaults,
/// which publish to npm; swap `hex` for `npm` to release a JavaScript package.)
pub fn default() -> Config {
  Config(
    repository_url: None,
    tag_format: "v${version}",
    branches: [
      BranchConfig("main", None, None, None),
      BranchConfig("master", None, None, None),
      BranchConfig("next", channel: Some("next"), prerelease: None, range: None),
      BranchConfig("beta", None, prerelease: Some("beta"), range: None),
      BranchConfig("alpha", None, prerelease: Some("alpha"), range: None),
    ],
    plugins: [
      PluginSpec("commit-analyzer", dict.new()),
      PluginSpec("release-notes-generator", dict.new()),
      PluginSpec("hex", dict.new()),
      PluginSpec("git", dict.new()),
      PluginSpec("github", dict.new()),
    ],
    dry_run: False,
    ci: True,
    versioning_mode: Stable,
  )
}

/// Map the boolean `initial_development` config key to a `VersioningMode`.
fn versioning_mode_of(initial_development: Bool) -> VersioningMode {
  case initial_development {
    True -> InitialDevelopment
    False -> Stable
  }
}

// --- Loading ---------------------------------------------------------------

/// The config filenames searched (in order) inside the project directory.
/// `.releaserc` is parsed as JSON, matching semantic-release's behaviour for
/// the extension-less rc file.
const json_candidates = [".releaserc.json", ".releaserc", "release.config.json"]

/// Load configuration from the project rooted at `cwd`, falling back to
/// `default()` when no config file is present.
///
/// The lookup order is:
///   1. `.releaserc.json`
///   2. `.releaserc`                       (parsed as JSON)
///   3. `release.config.json`
///   4. `.releaserc.toml`                  (parsed as TOML)
///   5. `[tools.version_bump]` in `gleam.toml` (the Gleam-native location;
///      also derives `repository_url` from the `[repository]` field)
///   6. the `"release"` key of `package.json`
///
/// The first file that exists and parses wins; its values are merged over
/// `default()`. Since every Gleam project has a `gleam.toml`, step 5 means a
/// Gleam package needs no separate config file: with no `[tools.version_bump]`
/// table it still releases using the defaults plus the derived repository URL.
/// When nothing is found, `Ok(default())` is returned.
pub fn load(cwd cwd: String) -> Result(Config, ReleaseError) {
  case find_and_parse(cwd) {
    Some(result) -> result
    None -> Ok(default())
  }
}

/// Walk the candidate sources in order, returning the parsed config (or parse
/// error) for the first source that exists, or `None` if none exist.
fn find_and_parse(cwd: String) -> Option(Result(Config, ReleaseError)) {
  let json_files =
    list.map(json_candidates, fn(name) { #(name, parse_json_config) })
  let sources =
    list.append(json_files, [
      #(".releaserc.toml", parse_toml_config),
      #("gleam.toml", parse_gleam_toml_config),
      #("package.json", parse_package_json_config),
    ])
  try_sources(cwd, sources)
}

fn try_sources(
  cwd: String,
  sources: List(#(String, fn(String) -> Result(Config, ReleaseError))),
) -> Option(Result(Config, ReleaseError)) {
  case sources {
    [] -> None
    [#(filename, parser), ..rest] -> {
      let path = join_path(cwd, filename)
      case read_if_present(path) {
        Some(contents) -> Some(parser(contents))
        None -> try_sources(cwd, rest)
      }
    }
  }
}

/// Read a file, returning `Some(contents)` when it can be read and `None`
/// otherwise. Unreadable or missing files are treated as absent so the loader
/// falls through to the next candidate (and ultimately to `default()`).
fn read_if_present(path: String) -> Option(String) {
  case simplifile.read(path) {
    Ok(contents) -> Some(contents)
    Error(_) -> None
  }
}

/// Join a directory and a filename with a single `/` separator, tolerating a
/// trailing slash on the directory.
fn join_path(dir: String, name: String) -> String {
  case string.ends_with(dir, "/") {
    True -> dir <> name
    False -> dir <> "/" <> name
  }
}

// --- JSON parsing ----------------------------------------------------------

/// Parse a JSON configuration document, merging any recognised keys over the
/// defaults. Unknown keys are ignored. Exposed for testing.
pub fn parse_json_config(json_string: String) -> Result(Config, ReleaseError) {
  json.parse(from: json_string, using: config_decoder())
  |> result.map_error(fn(err) {
    error.ConfigError("invalid JSON config: " <> describe_json_error(err))
  })
}

/// Parse the `"release"` object out of a `package.json` document. If there is
/// no `"release"` key the project simply has no semantic-release config there,
/// so the defaults are returned.
pub fn parse_package_json_config(
  json_string: String,
) -> Result(Config, ReleaseError) {
  let release_decoder = {
    use release <- decode.optional_field("release", default(), config_decoder())
    decode.success(release)
  }
  json.parse(from: json_string, using: release_decoder)
  |> result.map_error(fn(err) {
    error.ConfigError("invalid package.json: " <> describe_json_error(err))
  })
}

/// Decode a `Config`, starting from `default()` and overriding each field that
/// is present in the document.
fn config_decoder() -> decode.Decoder(Config) {
  let d = default()
  use repository_url <- decode.optional_field(
    "repositoryUrl",
    d.repository_url,
    decode.optional(decode.string),
  )
  use tag_format <- decode.optional_field(
    "tagFormat",
    d.tag_format,
    decode.string,
  )
  use branches <- decode.optional_field(
    "branches",
    d.branches,
    decode.list(branch_decoder()),
  )
  use plugins <- decode.optional_field(
    "plugins",
    d.plugins,
    decode.list(plugin_decoder()),
  )
  use dry_run <- decode.optional_field("dryRun", d.dry_run, decode.bool)
  use ci <- decode.optional_field("ci", d.ci, decode.bool)
  use initial_development <- decode.optional_field(
    "initialDevelopment",
    False,
    decode.bool,
  )
  decode.success(Config(
    repository_url: repository_url,
    tag_format: tag_format,
    branches: branches,
    plugins: plugins,
    dry_run: dry_run,
    ci: ci,
    versioning_mode: versioning_mode_of(initial_development),
  ))
}

/// A branch entry is either a bare string (the branch name) or an object with
/// a `name` plus optional `channel`, `prerelease`, and `range` keys.
fn branch_decoder() -> decode.Decoder(BranchConfig) {
  let string_branch =
    decode.string
    |> decode.map(fn(name) { BranchConfig(name, None, None, None) })
  let object_branch = {
    use name <- decode.field("name", decode.string)
    use channel <- decode.optional_field(
      "channel",
      None,
      decode.optional(decode.string),
    )
    use prerelease <- decode.optional_field(
      "prerelease",
      None,
      prerelease_decoder(),
    )
    use range <- decode.optional_field(
      "range",
      None,
      decode.optional(decode.string),
    )
    decode.success(BranchConfig(name, channel, prerelease, range))
  }
  decode.one_of(string_branch, or: [object_branch])
}

/// `prerelease` may be given as a string (the identifier) or as `true`, in
/// which case the branch name is used as the identifier. We can only know the
/// name in the object case, so a bare `true` maps to an empty identifier that
/// branch resolution can later default from the name.
fn prerelease_decoder() -> decode.Decoder(Option(String)) {
  let as_bool =
    decode.bool
    |> decode.map(fn(b) {
      case b {
        True -> Some("")
        False -> None
      }
    })
  decode.one_of(decode.optional(decode.string), or: [as_bool])
}

/// A plugin entry is either a bare string (the module name with no options) or
/// a two-element array of `[name, options]`.
fn plugin_decoder() -> decode.Decoder(PluginSpec) {
  let string_plugin =
    decode.string
    |> decode.map(fn(name) { PluginSpec(name, dict.new()) })
  let array_plugin = {
    use name <- decode.field(0, decode.string)
    use options <- decode.optional_field(1, dict.new(), options_decoder())
    decode.success(PluginSpec(name, options))
  }
  decode.one_of(string_plugin, or: [array_plugin])
}

/// Plugin options are kept as a string-keyed dictionary of stringified scalar
/// values. Non-scalar values (nested objects / arrays) are skipped, since the
/// core keeps options as strings and individual plugins reparse what they need.
fn options_decoder() -> decode.Decoder(Dict(String, String)) {
  decode.dict(decode.string, scalar_to_string_decoder())
}

/// Decode any scalar JSON value (string / bool / int / float) into its string
/// form. Values that are not scalars decode to an empty string.
fn scalar_to_string_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, or: [
    decode.bool |> decode.map(bool.to_string),
    decode.int |> decode.map(int.to_string),
    decode.float |> decode.map(float.to_string),
    decode.success(""),
  ])
}

fn describe_json_error(err: json.DecodeError) -> String {
  case err {
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedByte(byte) -> "unexpected byte " <> byte
    json.UnexpectedSequence(seq) -> "unexpected sequence " <> seq
    json.UnableToDecode(errors) ->
      "unable to decode: "
      <> string.join(list.map(errors, describe_decode_error), "; ")
  }
}

fn describe_decode_error(err: decode.DecodeError) -> String {
  "expected "
  <> err.expected
  <> ", found "
  <> err.found
  <> case err.path {
    [] -> ""
    path -> " at " <> string.join(path, ".")
  }
}

// --- TOML parsing ----------------------------------------------------------

/// Parse a TOML configuration document, merging recognised keys over the
/// defaults. Exposed for testing.
pub fn parse_toml_config(toml_string: String) -> Result(Config, ReleaseError) {
  use table <- result.try(
    tom.parse(toml_string)
    |> result.map_error(fn(_) { error.ConfigError("invalid TOML config") }),
  )
  let d = default()
  let repository_url = case tom.get_string(table, ["repositoryUrl"]) {
    Ok(url) -> Some(url)
    Error(_) -> d.repository_url
  }
  let tag_format =
    tom.get_string(table, ["tagFormat"])
    |> result.unwrap(d.tag_format)
  let dry_run =
    tom.get_bool(table, ["dryRun"])
    |> result.unwrap(d.dry_run)
  let ci =
    tom.get_bool(table, ["ci"])
    |> result.unwrap(d.ci)
  let initial_development =
    tom.get_bool(table, ["initialDevelopment"])
    |> result.unwrap(False)
  let branches = case tom.get_array(table, ["branches"]) {
    Ok(items) -> list.map(items, toml_branch)
    Error(_) -> d.branches
  }
  let plugins = case tom.get_array(table, ["plugins"]) {
    Ok(items) -> list.map(items, toml_plugin)
    Error(_) -> d.plugins
  }
  Ok(Config(
    repository_url: repository_url,
    tag_format: tag_format,
    branches: branches,
    plugins: plugins,
    dry_run: dry_run,
    ci: ci,
    versioning_mode: versioning_mode_of(initial_development),
  ))
}

/// Parse the `[tools.version_bump]` table out of a `gleam.toml` — the
/// Gleam-native config location. Keys use snake_case (`tag_format`, `dry_run`,
/// `branches`, `plugins`). `repository_url` is taken from the table if present,
/// otherwise derived from gleam.toml's standard `[repository]` field. Per-plugin
/// options live in `[tools.version_bump.plugin_options.<name>]` sub-tables.
///
/// A `gleam.toml` with no `[tools.version_bump]` table still yields a working
/// config (defaults plus the derived repository URL). Exposed for testing.
pub fn parse_gleam_toml_config(
  toml_string: String,
) -> Result(Config, ReleaseError) {
  use table <- result.try(
    tom.parse(toml_string)
    |> result.map_error(fn(_) { error.ConfigError("invalid gleam.toml") }),
  )
  let d = default()
  let repository_url = case tom.get_string(table, sr(["repository_url"])) {
    Ok(url) -> Some(url)
    Error(_) -> option.or(derive_repository_url(table), d.repository_url)
  }
  let tag_format =
    tom.get_string(table, sr(["tag_format"]))
    |> result.unwrap(d.tag_format)
  let dry_run = tom.get_bool(table, sr(["dry_run"])) |> result.unwrap(d.dry_run)
  let ci = tom.get_bool(table, sr(["ci"])) |> result.unwrap(d.ci)
  let initial_development =
    tom.get_bool(table, sr(["initial_development"]))
    |> result.unwrap(False)
  let branches = case tom.get_array(table, sr(["branches"])) {
    Ok(items) -> list.map(items, toml_branch)
    Error(_) -> d.branches
  }
  let plugins = case tom.get_array(table, sr(["plugins"])) {
    Ok(items) -> apply_plugin_options(list.map(items, toml_plugin), table)
    Error(_) -> d.plugins
  }
  Ok(Config(
    repository_url: repository_url,
    tag_format: tag_format,
    branches: branches,
    plugins: plugins,
    dry_run: dry_run,
    ci: ci,
    versioning_mode: versioning_mode_of(initial_development),
  ))
}

/// Prefix a key path with the `[tools.version_bump]` table location.
fn sr(keys: List(String)) -> List(String) {
  list.append(["tools", "version_bump"], keys)
}

/// Derive a repository URL from gleam.toml's standard `[repository]` field, e.g.
/// `repository = { type = "github", user = "u", repo = "r" }` -> the GitHub URL.
fn derive_repository_url(table: Dict(String, tom.Toml)) -> Option(String) {
  case
    tom.get_string(table, ["repository", "user"]),
    tom.get_string(table, ["repository", "repo"])
  {
    Ok(user), Ok(repo) ->
      case repository_host(table) {
        Some(host) -> Some("https://" <> host <> "/" <> user <> "/" <> repo)
        None -> None
      }
    _, _ -> None
  }
}

/// The host for a gleam.toml `[repository]` field, by its `type` (falling back to
/// an explicit `host` key for `type = "custom"`).
fn repository_host(table: Dict(String, tom.Toml)) -> Option(String) {
  case tom.get_string(table, ["repository", "type"]) {
    Ok("github") -> Some("github.com")
    Ok("gitlab") -> Some("gitlab.com")
    Ok("bitbucket") -> Some("bitbucket.org")
    Ok("codeberg") -> Some("codeberg.org")
    Ok("sourcehut") -> Some("git.sr.ht")
    _ ->
      case tom.get_string(table, ["repository", "host"]) {
        Ok(host) -> Some(host)
        Error(_) -> None
      }
  }
}

/// Merge any `[tools.version_bump.plugin_options.<name>]` sub-tables into the
/// matching plugin specs' options.
fn apply_plugin_options(
  plugins: List(PluginSpec),
  table: Dict(String, tom.Toml),
) -> List(PluginSpec) {
  list.map(plugins, fn(spec) {
    case tom.get_table(table, sr(["plugin_options", spec.name])) {
      Ok(opts) ->
        PluginSpec(spec.name, dict.merge(spec.options, toml_options(opts)))
      Error(_) -> spec
    }
  })
}

fn toml_branch(value: tom.Toml) -> BranchConfig {
  case value {
    tom.String(name) -> BranchConfig(name, None, None, None)
    tom.InlineTable(fields) | tom.Table(fields) ->
      BranchConfig(
        name: toml_table_string(fields, "name") |> option.unwrap(""),
        channel: toml_table_string(fields, "channel"),
        prerelease: toml_table_string(fields, "prerelease"),
        range: toml_table_string(fields, "range"),
      )
    _ -> BranchConfig("", None, None, None)
  }
}

fn toml_plugin(value: tom.Toml) -> PluginSpec {
  case value {
    tom.String(name) -> PluginSpec(name, dict.new())
    tom.Array(items) ->
      case items {
        [tom.String(name), tom.InlineTable(opts)]
        | [tom.String(name), tom.Table(opts)] ->
          PluginSpec(name, toml_options(opts))
        [tom.String(name)] -> PluginSpec(name, dict.new())
        _ -> PluginSpec("", dict.new())
      }
    tom.InlineTable(fields) | tom.Table(fields) ->
      PluginSpec(
        name: toml_table_string(fields, "name") |> option.unwrap(""),
        options: dict.new(),
      )
    _ -> PluginSpec("", dict.new())
  }
}

fn toml_options(fields: Dict(String, tom.Toml)) -> Dict(String, String) {
  dict.fold(fields, dict.new(), fn(acc, key, value) {
    case toml_scalar_to_string(value) {
      Some(s) -> dict.insert(acc, key, s)
      None -> acc
    }
  })
}

fn toml_table_string(
  fields: Dict(String, tom.Toml),
  key: String,
) -> Option(String) {
  case dict.get(fields, key) {
    Ok(value) -> toml_scalar_to_string(value)
    Error(_) -> None
  }
}

fn toml_scalar_to_string(value: tom.Toml) -> Option(String) {
  case value {
    tom.String(s) -> Some(s)
    tom.Bool(b) -> Some(bool.to_string(b))
    tom.Int(i) -> Some(int.to_string(i))
    tom.Float(f) -> Some(float.to_string(f))
    _ -> None
  }
}

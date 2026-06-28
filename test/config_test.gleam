import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import version_bump/config.{BranchConfig, PluginSpec}
import version_bump/semver.{InitialDevelopment, Stable}

// --- default() is unchanged -------------------------------------------------

pub fn default_unchanged_test() {
  let d = config.default()

  d.repository_url |> should.equal(None)
  d.tag_format |> should.equal("v${version}")
  d.dry_run |> should.equal(False)
  d.ci |> should.equal(True)
  d.versioning_mode |> should.equal(Stable)

  d.branches
  |> should.equal([
    BranchConfig("main", None, None, None),
    BranchConfig("master", None, None, None),
    BranchConfig("next", Some("next"), None, None),
    BranchConfig("beta", None, Some("beta"), None),
    BranchConfig("alpha", None, Some("alpha"), None),
  ])

  d.plugins
  |> should.equal([
    PluginSpec("commit-analyzer", dict.new()),
    PluginSpec("release-notes-generator", dict.new()),
    PluginSpec("hex", dict.new()),
    PluginSpec("git", dict.new()),
    PluginSpec("github", dict.new()),
  ])
}

// --- parse_gleam_toml_config (the [tools.version_bump] table) ------------

const sample_gleam_toml = "name = \"demo\"
version = \"1.0.0\"
description = \"a demo\"
licences = [\"Apache-2.0\"]
repository = { type = \"github\", user = \"octo\", repo = \"demo\" }

[tools.version_bump]
tag_format = \"release-${version}\"
branches = [\"main\", { name = \"beta\", prerelease = \"beta\" }]
plugins = [\"commit-analyzer\", \"release-notes-generator\", \"hex\", \"exec\"]

[tools.version_bump.plugin_options.exec]
publishCmd = \"echo published\"
"

pub fn gleam_toml_derives_repository_url_test() {
  let assert Ok(cfg) = config.parse_gleam_toml_config(sample_gleam_toml)
  cfg.repository_url
  |> should.equal(Some("https://github.com/octo/demo"))
}

pub fn gleam_toml_reads_tag_format_test() {
  let assert Ok(cfg) = config.parse_gleam_toml_config(sample_gleam_toml)
  cfg.tag_format |> should.equal("release-${version}")
}

pub fn gleam_toml_reads_plugins_in_order_test() {
  let assert Ok(cfg) = config.parse_gleam_toml_config(sample_gleam_toml)
  list.map(cfg.plugins, fn(p) { p.name })
  |> should.equal(["commit-analyzer", "release-notes-generator", "hex", "exec"])
}

pub fn gleam_toml_applies_plugin_options_subtable_test() {
  let assert Ok(cfg) = config.parse_gleam_toml_config(sample_gleam_toml)
  let assert Ok(exec) = list.find(cfg.plugins, fn(p) { p.name == "exec" })
  dict.get(exec.options, "publishCmd")
  |> should.equal(Ok("echo published"))
}

pub fn gleam_toml_parses_prerelease_branch_test() {
  let assert Ok(cfg) = config.parse_gleam_toml_config(sample_gleam_toml)
  let assert Ok(beta) = list.find(cfg.branches, fn(b) { b.name == "beta" })
  beta.prerelease |> should.equal(Some("beta"))
}

/// With only a `[repository]` field and no `[tools.version_bump]` table, the
/// repo URL is still derived and the (Gleam-first) defaults are used.
pub fn gleam_toml_without_table_uses_defaults_test() {
  let minimal =
    "name = \"x\"\nversion = \"0.0.0\"\nrepository = { type = \"gitlab\", user = \"o\", repo = \"r\" }\n"
  let assert Ok(cfg) = config.parse_gleam_toml_config(minimal)
  cfg.repository_url |> should.equal(Some("https://gitlab.com/o/r"))
  cfg.plugins |> should.equal(config.default().plugins)
  cfg.tag_format |> should.equal(config.default().tag_format)
}

pub fn gleam_toml_reads_initial_development_test() {
  let toml =
    "name = \"x\"\nversion = \"0.0.0\"\n\n[tools.version_bump]\ninitial_development = true\n"
  let assert Ok(cfg) = config.parse_gleam_toml_config(toml)
  cfg.versioning_mode |> should.equal(InitialDevelopment)
}

// --- parse_json_config ------------------------------------------------------

const sample_json = "{
  \"repositoryUrl\": \"https://github.com/octocat/hello.git\",
  \"tagFormat\": \"${version}\",
  \"dryRun\": true,
  \"ci\": false,
  \"branches\": [
    \"main\",
    { \"name\": \"next\", \"channel\": \"next\" },
    { \"name\": \"beta\", \"prerelease\": \"beta\" },
    { \"name\": \"1.x\", \"range\": \"1.x\", \"channel\": \"1.x\" }
  ],
  \"plugins\": [
    \"@semantic-release/commit-analyzer\",
    [\"@semantic-release/npm\", { \"npmPublish\": false }],
    [\"@semantic-release/github\", { \"assets\": \"dist/**\", \"draftRelease\": true }]
  ]
}"

pub fn parse_json_scalars_test() {
  let cfg = config.parse_json_config(sample_json) |> should.be_ok

  cfg.repository_url
  |> should.equal(Some("https://github.com/octocat/hello.git"))
  cfg.tag_format |> should.equal("${version}")
  cfg.dry_run |> should.equal(True)
  cfg.ci |> should.equal(False)
}

pub fn parse_json_branches_test() {
  let cfg = config.parse_json_config(sample_json) |> should.be_ok

  cfg.branches
  |> should.equal([
    BranchConfig("main", None, None, None),
    BranchConfig("next", Some("next"), None, None),
    BranchConfig("beta", None, Some("beta"), None),
    BranchConfig("1.x", Some("1.x"), None, Some("1.x")),
  ])
}

pub fn parse_json_plugins_names_test() {
  let cfg = config.parse_json_config(sample_json) |> should.be_ok

  list.map(cfg.plugins, fn(p) { p.name })
  |> should.equal([
    "@semantic-release/commit-analyzer",
    "@semantic-release/npm",
    "@semantic-release/github",
  ])
}

pub fn parse_json_plugin_options_test() {
  let cfg = config.parse_json_config(sample_json) |> should.be_ok

  let npm =
    list.find(cfg.plugins, fn(p) { p.name == "@semantic-release/npm" })
    |> should.be_ok
  dict.get(npm.options, "npmPublish") |> should.equal(Ok("False"))

  let github =
    list.find(cfg.plugins, fn(p) { p.name == "@semantic-release/github" })
    |> should.be_ok
  dict.get(github.options, "assets") |> should.equal(Ok("dist/**"))
  dict.get(github.options, "draftRelease") |> should.equal(Ok("True"))
}

pub fn parse_json_empty_object_uses_defaults_test() {
  let cfg = config.parse_json_config("{}") |> should.be_ok
  cfg |> should.equal(config.default())
}

pub fn parse_json_partial_merges_over_defaults_test() {
  let cfg =
    config.parse_json_config("{ \"tagFormat\": \"release-${version}\" }")
    |> should.be_ok

  // Only tagFormat overridden; everything else stays at the defaults.
  cfg.tag_format |> should.equal("release-${version}")
  cfg.branches |> should.equal(config.default().branches)
  cfg.plugins |> should.equal(config.default().plugins)
}

pub fn parse_json_invalid_is_error_test() {
  config.parse_json_config("{ not valid json")
  |> should.be_error
}

// --- parse_package_json_config ---------------------------------------------

pub fn parse_package_json_with_release_test() {
  let pkg =
    "{
    \"name\": \"my-pkg\",
    \"version\": \"1.0.0\",
    \"release\": {
      \"tagFormat\": \"v${version}-pkg\",
      \"branches\": [\"main\", \"release\"]
    }
  }"
  let cfg = config.parse_package_json_config(pkg) |> should.be_ok

  cfg.tag_format |> should.equal("v${version}-pkg")
  cfg.branches
  |> should.equal([
    BranchConfig("main", None, None, None),
    BranchConfig("release", None, None, None),
  ])
}

pub fn parse_package_json_without_release_uses_defaults_test() {
  let pkg = "{ \"name\": \"my-pkg\", \"version\": \"1.0.0\" }"
  config.parse_package_json_config(pkg)
  |> should.be_ok
  |> should.equal(config.default())
}

// --- parse_toml_config ------------------------------------------------------

pub fn parse_toml_scalars_and_branches_test() {
  let toml =
    "tagFormat = \"${version}\"\n"
    <> "dryRun = true\n"
    <> "branches = [\"main\", \"next\"]\n"
    <> "plugins = [\"@semantic-release/commit-analyzer\"]\n"
  let cfg = config.parse_toml_config(toml) |> should.be_ok

  cfg.tag_format |> should.equal("${version}")
  cfg.dry_run |> should.equal(True)
  cfg.branches
  |> should.equal([
    BranchConfig("main", None, None, None),
    BranchConfig("next", None, None, None),
  ])
  list.map(cfg.plugins, fn(p) { p.name })
  |> should.equal(["@semantic-release/commit-analyzer"])
}

pub fn parse_toml_empty_uses_defaults_test() {
  config.parse_toml_config("")
  |> should.be_ok
  |> should.equal(config.default())
}

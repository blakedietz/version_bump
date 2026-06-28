# version_bump

A port of [semantic-release](https://github.com/semantic-release/semantic-release)
to [Gleam](https://gleam.run), running on the Erlang/BEAM. It automates the
release workflow: it reads the conventional commits since the last release,
decides the next [semantic version](https://semver.org), generates release
notes, commits and tags the bump, and publishes to Hex (or npm) and GitHub.

The lifecycle mirrors upstream semantic-release:

1. resolve the current branch and build the shared context
2. resolve each configured plugin against the registry
3. `verify_conditions`
4. find the last release from the git tags
5. read & parse the commits since that release
6. `analyze_commits` -> a release type (or stop: "no release")
7. compute the next version and build the next release
8. `verify_release`
9. `generate_notes` -> attach to the next release
10. (dry-run) report and stop
11. `prepare`, then create & push the git tag
12. `publish` -> collect the produced releases
13. `success`

Any error after `verify_conditions` runs every plugin's `fail` hook before the
error is returned.

## Prerequisites

- **Gleam** (developed against 1.17)
- **Erlang/OTP** — Gleam compiles to the BEAM, so an Erlang runtime is required
- **git** — the pipeline shells out to git to read branches, tags, and commits,
  and to commit & push the release
- **gleam** — the default `hex` plugin runs `gleam publish`
- **npm** — only needed if you use the `npm` plugin instead of `hex`
- A clean checkout on a configured release branch (`main`, `master`, `next`,
  `beta`, or `alpha` by default)

### Environment variables

Tokens are read from the process environment (plugins also accept them through
the context env). None are needed for `--dry-run`:

- `HEXPM_API_KEY` — required by the `hex` plugin to `gleam publish` (create one
  with `gleam hex authenticate`).
- `NPM_TOKEN` — required by the `npm` plugin's `verify_conditions`.
- `GITHUB_TOKEN` (or `GH_TOKEN`) — required by the `github` plugin's
  `verify_conditions`. `GITHUB_TOKEN` takes precedence over `GH_TOKEN`.

## Install / build

Clone the repository and fetch dependencies:

```sh
git clone <this-repo>
cd version_bump
gleam deps download
```

## Usage

Run the full release pipeline against the current working directory:

```sh
gleam run
```

Compute and preview the next release without tagging or publishing:

```sh
gleam run -- --dry-run
```

In a dry run the pipeline stops after generating notes: it logs the computed
version and release notes but skips `prepare`, tagging, `publish`, and
`success`.

> **See it working:** `examples/run-demo.sh` builds a throwaway Gleam-package
> repo and runs the tool across four scenarios (first release → patch → minor →
> major), printing the computed version and notes each time. Runs on both
> targets (`TARGET=javascript examples/run-demo.sh`). See `examples/README.md`.

Run against a project in another directory (e.g. a monorepo package) with
`--cwd` (the `--cwd=<path>` form also works):

```sh
gleam run -- --cwd ../packages/api --dry-run
```

Other commands:

```sh
gleam run -- --version   # print the tool version and exit
gleam run -- --help      # print usage and exit
```

Unknown flags are rejected with a non-zero exit so mistakes are visible rather
than silently ignored.

A typical CI invocation provides the tokens inline:

```sh
NPM_TOKEN=... GITHUB_TOKEN=... gleam run
```

## Configuration

Configuration is optional. With no config at all the tool uses Gleam-first
defaults — the plugins `commit-analyzer`, `release-notes-generator`, `hex`,
`git`, and `github`, over the conventional branches (`main`, `master`, `next`,
`beta`, `alpha`). (`git` commits the version bump back; see the note below.)

### Recommended: `gleam.toml`

For a Gleam package, put config under `[tools.version_bump]` in `gleam.toml`
— the conventions-blessed location for tool config:

```toml
name = "my_package"
version = "1.4.2"                  # the tool bumps this on release
description = "..."
licences = ["Apache-2.0"]
repository = { type = "github", user = "my-org", repo = "my-package" }

[tools.version_bump]
tag_format = "v${version}"
branches = ["main", { name = "beta", prerelease = "beta" }]
plugins = ["commit-analyzer", "release-notes-generator", "hex", "git", "github"]

# per-plugin options go in sub-tables:
[tools.version_bump.plugin_options.exec]
publishCmd = "./scripts/extra.sh ${nextRelease.version}"
```

`repository_url` is derived from the standard `[repository]` field, and
`name`/`version` are reused from `gleam.toml`, so a typical Gleam package needs
little or no `[tools.version_bump]` config.

### Lookup order

Config is loaded from the project root; the first source that exists and parses
wins (values merge over the defaults):

1. `.releaserc.json` (JSON)
2. `.releaserc` (JSON)
3. `release.config.json` (JSON)
4. `.releaserc.toml` (TOML)
5. `[tools.version_bump]` in `gleam.toml` (TOML; also derives `repository_url`)
6. the `"release"` key of `package.json` (JSON)

Any recognised keys override the defaults; unknown keys are ignored. Fields
(`gleam.toml` snake_case key / `.releaserc.*` camelCase key):

| gleam.toml / `.releaserc.*`        | Type   | Default        | Meaning                                       |
| ---------------------------------- | ------ | -------------- | --------------------------------------------- |
| `repository_url` / `repositoryUrl` | string | derived / none | repo URL; used by the `github` plugin         |
| `tag_format` / `tagFormat`         | string | `v${version}`  | git tag template; `${version}` is substituted |
| `branches` / `branches`            | array  | the 5 defaults | release branches (see below)                  |
| `plugins` / `plugins`              | array  | the 5 defaults | plugin pipeline (see below)                   |
| `dry_run` / `dryRun`               | bool   | `false`        | force dry-run (`--dry-run` also turns it on)  |
| `ci` / `ci`                        | bool   | `true`         | whether running in CI                         |
| `initial_development` / `initialDevelopment` | bool | `false` | 0.x mode (see below)                  |

Note: `--dry-run` is only ever an override that turns dry-run *on*; it cannot
force a real release when the config disables it.

### Initial development (0.x)

By default the first release is `1.0.0` and a breaking change is a major bump —
so a breaking change in `0.x` would jump straight to `1.0.0`. Setting
`initial_development = true` enables SemVer's "initial development" semantics
(spec clause 4 — the `0.y.z` phase where the public API isn't yet stable):

- the first release starts at **`0.1.0`** instead of `1.0.0`, and
- while the major version is `0`, a **breaking change is a minor bump**
  (`0.3.1` → `0.4.0`) rather than `1.0.0`. Features and fixes are unchanged
  (`feat` → minor, `fix` → patch).

This keeps the package in `0.x` until you're ready to commit to a stable API —
release `1.0.0` yourself (set `version` in `gleam.toml` and tag it), after which
the flag has no further effect.

### Branches

A branch entry is either a bare string (just the name) or an object:

```json
"branches": [
  "main",
  { "name": "next", "channel": "next" },
  { "name": "beta", "prerelease": "beta" },
  { "name": "alpha", "prerelease": true }
]
```

`prerelease` may be a string (the prerelease identifier) or `true` (use the
branch name). `channel` and `range` are optional.

### Plugins

A plugin entry is either a bare string (the plugin name, no options) or a
two-element `[name, options]` array. Options are kept as a flat dictionary of
stringified scalar values; nested objects/arrays in options are skipped (each
plugin reparses what it needs).

```json
"plugins": [
  "commit-analyzer",
  "release-notes-generator",
  ["npm", { "npmPublish": true }],
  "github"
]
```

The built-in plugin names are: `commit-analyzer`, `release-notes-generator`,
`hex`, `npm`, `git`, `github`, and `exec`. An unknown plugin name is a
configuration error. In `gleam.toml`, plugin options live in
`[tools.version_bump.plugin_options.<name>]` sub-tables (shown above); the
JSON sources use the `[name, { options }]` array form shown here.

### The `git` plugin (committing the version bump)

`git` (in the defaults, listed after `hex`) commits the files the release
changed — by default the bumped `gleam.toml` — in its `prepare` hook. The engine
then pushes the branch alongside the tag, so the release **tag points at the
commit containing the new version** and the working tree is left clean. Options:
`assets` (comma-separated, default `gleam.toml`), `message` (default
`chore(release): ${version} [skip ci]`), `committerName`, `committerEmail`.

This means a real release **pushes a commit to your release branch**, so the CI
token needs branch-push permission. If you prefer the tag-only model (leave the
committed `gleam.toml` version as a placeholder and treat the tag + Hex as the
source of truth), simply drop `git` from `plugins`.

## Releasing in CI (GitHub Actions)

A ready-to-copy workflow lives at
[`.github/workflows/release.yml.example`](.github/workflows/release.yml.example) —
copy it to `.github/workflows/release.yml` in your package. (`version_bump`'s own
[`.github/workflows/release.yml`](.github/workflows/release.yml) dogfoods this:
it's the same setup but runs `gleam run` since the tool releases *itself*.)

On GitHub, **two** things need authorization, and both are covered by the
built-in `GITHUB_TOKEN`:

- **git push** — the `git` plugin commits the version bump and the engine pushes
  the branch + tag.
- **GitHub API** — the `github` plugin creates the Release.

The one thing you must provision is write access:

```yaml
permissions:
  contents: write
```

Without it, both the push and the release creation return **403** (many repos
default `GITHUB_TOKEN` to read-only). The rest:

- `actions/checkout` with `fetch-depth: 0` — full history + tags (a shallow clone
  makes every run look like a first release). Its default
  `persist-credentials: true` is what lets `git push` use `GITHUB_TOKEN`
  automatically.
- Pass `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` to the run step for the
  `github` plugin, and `HEXPM_API_KEY: ${{ secrets.HEX_API_KEY }}` for `hex`
  (create the Hex key once with `gleam hex authenticate`, then add it as a repo
  secret).

So `GITHUB_TOKEN` itself is automatic — the only setup is the `contents: write`
permission and the `HEX_API_KEY` secret.

### Caveats

- **`GITHUB_TOKEN` pushes don't trigger other workflows** (loop prevention by
  design); the `git` plugin's default `[skip ci]` message is extra insurance.
- **Branch protection** on the release branch can reject a direct push from
  `GITHUB_TOKEN`. Allow a bypass actor, release from an unprotected branch, or
  drop the `git` plugin (tag-only model).
- If you need the release commit to **trigger** downstream workflows, or to
  **bypass branch protection**, the built-in token can't — use a fine-grained
  **PAT** (Contents: read+write) or a **GitHub App** token, and pass it to *both*
  `actions/checkout` (`token:`) and the run step (`GITHUB_TOKEN:`). See the
  commented block in the example workflow.

> Distribution note: `gleam run -m version_bump` assumes the tool is
> available to your project (e.g. as a dev dependency once it's published to
> Hex). Until then, adjust the invocation to how you run it.

## The plugin model

Upstream semantic-release plugins are JS modules that duck-type which lifecycle
hooks they implement. Gleam has no dynamic dispatch, so a plugin is instead a
**record of optional hook functions** (`version_bump/plugin.Plugin`). A
plugin implements a hook by setting that field to `Some(fn)`; the engine skips
`None` fields.

```gleam
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
```

Every hook has the shape `fn(PluginSpec, Context) -> Result(..., ReleaseError)`,
where `PluginSpec` carries the plugin's configured options and `Context` is the
immutable state threaded through the pipeline. The engine enforces the
per-hook return semantics:

- `analyze_commits`: the highest `ReleaseType` across plugins wins
  (`Patch < Minor < Major`)
- `generate_notes`: results are concatenated in plugin order
- `publish`: `Some(release)` is published; `None` means "not handled"
- all others: run for effect; a failure aborts the pipeline

Build a concrete plugin by starting from `plugin.new(name)` (all hooks `None`)
and overriding the fields you implement:

```gleam
import gleam/option.{Some}
import version_bump/plugin

pub fn my_plugin() -> plugin.Plugin {
  plugin.Plugin(..plugin.new("my-plugin"), publish: Some(do_publish))
}

fn do_publish(spec, ctx) {
  // ... create the release for ctx.next_release ...
  Ok(option.None)
}
```

### The `exec` escape hatch

You don't have to write Gleam to add behavior. The built-in `exec` plugin lets
you wire a shell command to any lifecycle step through its options. Each option
key maps to one hook; the command runs through `sh -c` in the project's working
directory:

| Option key            | Hook                |
| --------------------- | ------------------- |
| `verifyConditionsCmd` | `verify_conditions` |
| `analyzeCommitsCmd`   | `analyze_commits`   |
| `verifyReleaseCmd`    | `verify_release`    |
| `generateNotesCmd`    | `generate_notes`    |
| `prepareCmd`          | `prepare`           |
| `publishCmd`          | `publish`           |
| `successCmd`          | `success`           |
| `failCmd`             | `fail`              |

For `analyzeCommitsCmd`, the trimmed stdout (`major`/`minor`/`patch`,
case-insensitive) is parsed into the release type; anything else means "no
release". For `generateNotesCmd`, the trimmed stdout becomes the notes. For the
effect-only hooks, a non-zero exit aborts the pipeline.

```json
"plugins": [
  "commit-analyzer",
  "release-notes-generator",
  ["exec", { "publishCmd": "./scripts/deploy.sh ${nextRelease.version}" }]
]
```

See [`.releaserc.example.json`](./.releaserc.example.json) for a complete
example combining branches, the four default plugins, and an `exec` step.

## Development

```sh
gleam run    # Run the release pipeline
gleam test   # Run the tests
```

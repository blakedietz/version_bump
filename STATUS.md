# STATUS — Gleam port of semantic-release

A native Gleam reimplementation of [semantic-release](https://github.com/semantic-release/semantic-release).
This document is an honest accounting of what is built, what the design
decisions were, and what is deliberately deferred or simplified relative to the
real tool. It does not overstate completeness: this is a focused MVP of the
release pipeline, not a drop-in replacement.

## Test status

`gleam test` passes on **both** compile targets:

```
gleam test                      -> 213 passed, no failures   (Erlang/BEAM)
gleam test --target javascript  -> 213 passed, no failures   (Node)
```

The suite is unit-level (pure functions, payload builders, parsers, config
decoders, hook runners with synthetic contexts). There is no automated test that
drives a real git repo through a real publish — but the full pipeline HAS been
run end-to-end in `--dry-run` against a scratch repo on **both** targets
(`gleam run [--target javascript] -- --cwd <repo> --dry-run`), exercising branch
resolution → commit analysis → version → notes through the async `Task` engine.

---

## (1) Target decision: native Gleam, BOTH Erlang/BEAM and JavaScript

### What was chosen

The port is **native Gleam** (no reuse of the original JavaScript) and now
compiles and runs on **both** Gleam targets:

```
gleam build                      # Erlang/BEAM  (default)
gleam build --target javascript  # Node
```

Concretely:

- **Cross-target async (`src/version_bump/task.gleam`):** the `publish` hook
  performs network I/O, which is synchronous on the BEAM but asynchronous (a
  `Promise`) on Node. To support both from one codebase, `Task(a)` is an opaque,
  FFI-backed type — an eager identity value on Erlang (`version_bump_task_ffi.erl`) and a
  real `Promise` on JavaScript (`version_bump_task_ffi.mjs`). The `publish` contract and
  the engine's publish tail are `Task`-typed; everything before publish stays
  synchronous. `task.run` settles the task at the top level (immediate on
  Erlang, `.then` on Node).
- **HTTP, per target:** `src/version_bump/github_api.gleam`'s `send` has a
  Gleam body using `gleam_httpc` (used on Erlang and any target without an
  external) plus an `@external(javascript, …)` that uses the native `fetch` API
  (`gh_http_ffi.mjs`). Both yield a `Task(#(status, body))`, so the create-release
  logic above them is target-agnostic.
- **Process exit FFI:** `version_bump_ffi.erl` (`erlang:halt/1`) and
  `version_bump_ffi.mjs` (`process.exit`) back the CLI's `halt`.
- **Subprocesses via `shellout`** (cross-target): `git` (log/tag/rev-parse/
  branch/push/remote), `npm publish`, `gleam publish` (the `hex` plugin), and
  `sh -c <cmd>` (the `exec` plugin).
- **Config / parsing:** `gleam_json`, `tom`, `simplifile`, `envoy`, `gleam/regexp`
  — all cross-target. (Regex patterns avoid inline flags like `(?s)`, which JS's
  `RegExp` rejects; e.g. the breaking-change footer matcher uses `[\s\S]`.)

> Caveat vs. the task framing: the prompt mentions "shelling out to git/npm/gh".
> There is **no `gh` CLI dependency** — GitHub is reached over HTTP (`httpc` on
> Erlang, `fetch` on JS), not by shelling out to `gh`.

### The JS-FFI ecosystem path still NOT taken

Supporting the JavaScript *target* is distinct from reusing the
`@semantic-release/*` **npm plugin ecosystem** via FFI — that is still not done.
The plugins here remain native Gleam reimplementations; running on Node does not
load any third-party JS plugins.

### The JS-FFI alternative that was NOT taken

An alternative considered was to compile Gleam to the **JavaScript target** and
call directly into the existing `semantic-release` npm package and its plugin
ecosystem via Gleam's JS FFI (wrapping the JS lifecycle/plugin APIs in Gleam
types). This was **not** taken. The consequences of that choice:

- We get a single self-contained BEAM artifact with no Node.js runtime
  dependency, and we can lean on OTP/Erlang for process and IO.
- We **lose** the entire existing JS plugin ecosystem. Every plugin we want has
  to be reimplemented in Gleam (see section 3), and third-party
  `@semantic-release/*` plugins cannot be loaded at all (see section 4).
- We re-derive behavior (conventional-commits parsing, semver, env-ci, branch
  resolution) from the spec/observed behavior rather than inheriting it, which
  is where the deferred/simplified items in section 4 come from.

---

## (2) Module map

### CLI / entrypoint

| Module | Responsibility |
|---|---|
| `src/version_bump.gleam` | CLI entrypoint. Pure `parse_args` (handles `--version`/`version`, `--help`/`-h`, `--dry-run`, rejects unknown flags), then loads config, applies the `--dry-run` override, runs `engine.run`, prints a summary. Uses `argv` for args and a hand-rolled parser. (`glint` is declared as a dependency but the parsing here is hand-rolled, not glint-based.) |
| `src/version_bump_ffi.erl` | One-function Erlang FFI: `halt/1` -> `erlang:halt` so the CLI can exit with a non-zero status. |

### Core domain (pure)

| Module | Responsibility |
|---|---|
| `src/version_bump/error.gleam` | `ReleaseError` variants (`ConfigError`, `GitError`, `PluginError`, `VersionError`, `NetworkError`, `ValidationError`, `AggregateError`) and `to_string`. `AggregateError` mirrors semantic-release collecting multiple failures. (Kept as a single cohesive domain error type, per the guide's "Design descriptive errors" pattern — not a "grouped by kind" module.) |
| `src/version_bump/semver.gleam` | The semantic-versioning domain. Owns `Version` and `ReleaseType` (Patch/Minor/Major with `release_type_rank`/`release_type_to_string`). `parse` (optional leading `v`, prerelease, build, leading-zero rejection), `to_string`, `compare` (full precedence incl. prerelease field-by-field, build ignored), `bump`, `bump_with_prerelease`, `max`. |
| `src/version_bump/commit_parser.gleam` | The commit domain. Owns `Commit`, `CommitNote`, `ConventionalCommit`, plus a pure conventional-commits/Angular `parse`: parses `type(scope)!: subject`, detects breaking changes (header `!` and `BREAKING CHANGE:`/`BREAKING-CHANGE:` footers), collects `#123` references, flags merge and revert commits. |
| `src/version_bump/release.gleam` | The release-records domain. Owns `LastRelease`, `NextRelease`, `Release`. No behavior. |
| `src/version_bump/note.gleam` | Pure Markdown release-notes generator. Groups commits into Features / Bug Fixes / Performance plus a BREAKING CHANGES section; omits empty sections. `repo_url` is accepted but currently unused (no commit/issue links yet). |
| `src/version_bump/branch.gleam` | The branch domain. Owns `Branch`/`BranchType`. Pure branch/channel model: classifies configured branches into Release / Maintenance / Prerelease, parses maintenance names (`1.x`, `1.2.x`) into ranges, picks the last release matching a branch from tags, and computes the next version (incl. prerelease bumps and `initial_development`/0.x mode, where a breaking change stays a minor bump while major is 0). No git IO. |
| `src/version_bump/env_ci.gleam` | Pure CI detection from an env dict: GitHub Actions, GitLab CI, generic `CI=true`; extracts branch/commit and whether it is a PR/MR build. A small subset of the `env-ci` package. |

### Configuration

| Module | Responsibility |
|---|---|
| `src/version_bump/config.gleam` | Config types (`Config`, `BranchConfig`, `PluginSpec`) and `default()` (Gleam-first defaults: branches main/master/next/beta/alpha, plugins commit-analyzer/release-notes-generator/**hex**/**git**/github). `load` searches `.releaserc.json`, `.releaserc` (JSON), `release.config.json`, `.releaserc.toml` (TOML), **`[tools.version_bump]` in `gleam.toml`** (deriving `repository_url` from the standard `[repository]` field; per-plugin options from `plugin_options.<name>` sub-tables), and the `"release"` key of `package.json`. Decoders merge over defaults; plugin options flatten to `Dict(String, String)` of scalars. |

### Plugin framework

| Module | Responsibility |
|---|---|
| `src/version_bump/plugin.gleam` | The plugin contract: a `Plugin` is a record of `Option(hook)` fields, one per lifecycle hook (`verify_conditions`, `analyze_commits`, `verify_release`, `generate_notes`, `add_channel`, `prepare`, `publish`, `success`, `fail`). `new(name)` builds an all-`None` plugin. (Gleam has no duck typing, so optional fields stand in for "does this hook exist?".) `publish` returns a `Task` (asynchronous); all other hooks are synchronous. |
| `src/version_bump/task.gleam` | Cross-target async primitive. Opaque `Task(a)` with `resolve`/`map`/`await`/`run`, backed by FFI: an eager value on Erlang (`version_bump_task_ffi.erl`), a `Promise` on JavaScript (`version_bump_task_ffi.mjs`). Lets the `publish` path be synchronous on the BEAM and promise-based on Node from one codebase. |
| `src/version_bump/context.gleam` | The immutable `Context` threaded through hooks (cwd, env, config, branch(es), commits, last/next release, releases, errors, dry_run) plus `new`. The engine produces a new `Context` as the pipeline advances. |
| `src/version_bump/registry.gleam` | The built-in plugin registry: a `Dict(String, Plugin)` mapping short names (`commit-analyzer`, `release-notes-generator`, `npm`, `github`, `exec`) to their `Plugin`. Resolution of an unknown name is a config error. Plain value, no IO, no dynamic loading. |
| `src/version_bump/runner.gleam` | Hook runners with per-hook combination semantics: effect hooks (verify_conditions/verify_release/prepare/success/fail) collect *all* errors into an `AggregateError`; `analyze_commits` keeps the highest `ReleaseType`; `generate_notes` concatenates in plugin order; `publish` collects the `Some(release)` results. |
| `src/version_bump/engine.gleam` | The pipeline orchestrator. Builds the context, resolves plugins, then runs verify_conditions -> last release -> commits -> analyze_commits -> next version/`NextRelease` -> verify_release -> generate_notes -> (dry-run short-circuit) -> prepare -> create+push tag -> publish -> success. Any failure from verify_conditions onward runs the `fail` hooks before propagating. Returns a `Summary`. |
| `src/version_bump/git.gleam` | Git access via `shellout` over the `git` binary. `parse_log` (pure) decodes a custom `--pretty` format delimited by ASCII unit/record separators; effectful helpers: `log_since`, `get_tags`, `current_branch`, `head_sha`, `list_branches`, `create_tag` (an annotated tag — sets a per-command committer identity so it works on a bare CI runner with no `user.name`/`user.email`), `push`, `get_remote_url`. |
| `src/version_bump/github_api.gleam` | Minimal GitHub REST client. Pure `build_create_release_request` and `parse_repo_url` (https/ssh/`git@` forms) separated from the effectful `create_release` (sends via `httpc`, maps non-2xx/transport errors to `NetworkError`, parses `html_url`). |
| `src/version_bump/logging.gleam` | Leveled, prefixed logger (`[version_bump]` + colorized level via `gleam_community/ansi`). `info`/`warn`/`error`/`success`; pure `format` for testing. |

### Plugins (`src/version_bump/plugins/`)

| Module | Responsibility |
|---|---|
| `commit_analyzer.gleam` | `@semantic-release/commit-analyzer` port. `analyze_commits` only: breaking -> Major, `feat` -> Minor, `fix`/`perf` -> Patch, else no release; highest wins. |
| `release_notes.gleam` | `@semantic-release/release-notes-generator` port. `generate_notes` only: renders Markdown via `note.gleam` for the pending release (empty string when there is no next release). |
| `npm.gleam` | `@semantic-release/npm` port. `verify_conditions` (require `package.json` + `NPM_TOKEN`, skipped on dry-run), `prepare` (rewrite the top-level `"version"` in `package.json` via a pure `set_version` string transform), `publish` (`npm publish`). |
| `hex.gleam` | Gleam-native plugin (no semantic-release equivalent) for publishing a Gleam package to **Hex**. `verify_conditions` (require `gleam.toml` with `description` + `licences`, and `HEXPM_API_KEY`, skipped on dry-run), `prepare` (rewrite the top-level `version` in `gleam.toml` via a pure `set_version`), `publish` (runs `gleam publish --yes` via `sh -c`, piping `I am not using semantic versioning` to stdin so sub-1.0.0 releases clear gleam's 0.x guard non-interactively, then **verifies** the captured output contains the `Published package` success line — `gleam publish` can exit 0 without publishing — failing loudly otherwise via the pure `published_ok`; reports the hex.pm URL). No `add_channel`: Hex has no dist-tags, so prereleases publish as ordinary semver prereleases. |
| `git.gleam` | `@semantic-release/git` port. `prepare` only: stages the configured `assets` (default `gleam.toml`) and commits them (`chore(release): ${version} [skip ci]` by default, with a per-command committer identity), so the engine's tag lands on the commit containing the bump. The engine then pushes the branch and the tag. Options: `assets`, `message`, `committerName`, `committerEmail`. PURE `render_message`/`parse_assets` helpers. |
| `github.gleam` | `@semantic-release/github` port. `verify_conditions` (require `GITHUB_TOKEN`/`GH_TOKEN` + a parseable `repositoryUrl`), `publish` (create the GitHub release via `github_api`), `success` (log line). |
| `exec.gleam` | `@semantic-release/exec` port. Wires all hooks to user-supplied shell commands (`verifyConditionsCmd`, `analyzeCommitsCmd`, `verifyReleaseCmd`, `generateNotesCmd`, `prepareCmd`, `publishCmd`, `successCmd`, `failCmd`) run via `sh -c`. analyze_commits parses stdout into a `ReleaseType`; generate_notes uses stdout as notes; publish reports "not handled". |

---

## (3) Lifecycle hooks and default plugins implemented

### Lifecycle hooks driven by the engine/runner

| Hook | Runner | Combination semantics | Wired in engine? |
|---|---|---|---|
| `verify_conditions` | `run_verify_conditions` | run all, aggregate errors | yes |
| `analyze_commits` | `run_analyze_commits` | highest `ReleaseType` wins | yes |
| `verify_release` | `run_verify_release` | run all, aggregate errors | yes |
| `generate_notes` | `run_generate_notes` | concatenate notes in order | yes |
| `prepare` | `run_prepare` | run all, aggregate errors | yes (skipped on dry-run) |
| `publish` | `run_publish` | collect `Some(release)` | yes (skipped on dry-run) |
| `success` | `run_success` | run all, aggregate errors | yes (skipped on dry-run) |
| `fail` | `run_fail` | run all, aggregate errors | yes (on any error after verify_conditions) |
| **`add_channel`** | **none** | **n/a** | **NOT wired — see below** |

The git tag is created and pushed by the engine itself (between `prepare` and
`publish`), matching where semantic-release does its git tagging.

> `add_channel` is declared in the plugin contract (`plugin.gleam` has the
> `AddChannel` type and the `add_channel` field), but it is **never run**: there
> is no `run_add_channel` in `runner.gleam`, the engine never invokes it, and no
> built-in plugin sets it (all leave it `None`). It is a placeholder for the
> channel-promotion flow that is deferred (see section 4).

### Default plugins

All four semantic-release default plugins plus `exec` are implemented as native
Gleam plugins and registered in `registry.gleam`:

- **commit-analyzer** — implemented (analyze_commits).
- **release-notes-generator** — implemented (generate_notes).
- **npm** — implemented (verify_conditions, prepare, publish).
- **github** — implemented (verify_conditions, publish, success).
- **exec** — implemented (all hooks, command-driven).

Plugin *resolution* is closed-world: a configured plugin name must be one of
these five built-ins or the run fails with `ConfigError("Unknown plugin ...")`.

---

## (4) Deferred / simplified vs. real semantic-release

This is where the port is intentionally narrower than the real tool. None of the
following are claimed to be complete.

### Branching / channel matrix — partially modeled, mostly deferred

- The **types and classification exist** (`branch.gleam`): Release,
  Maintenance, and Prerelease branches are recognized; maintenance names
  (`1.x`, `1.x.x`, `1.2.x`) are parsed into `>=lo <hi` ranges; `last_release`
  filters tags by branch compatibility; `next_version` does prerelease bumps.
- **Deferred:** the full branching/channel *matrix* that real semantic-release
  computes. In particular:
  - **`addChannel` promotion across channels** is not implemented at all — there
    is no `add_channel` runner and the engine never promotes a release from one
    channel (e.g. `next`/`beta`) onto another (e.g. the default channel) when a
    branch is merged forward. The `LastRelease.channels` / `Release.channel`
    fields exist but no cross-channel logic uses them.
  - The maintenance-range *bounds checking against existing releases* (ensuring a
    maintenance release stays inside its window relative to higher lines) is not
    enforced beyond the per-branch tag filter.
  - The branch ordering/validation that semantic-release performs (verifying the
    configured branches form a valid release graph, computing each branch's
    merge range and "tagged" channels) is not done.
  - Building the commit range so it excludes commits already released on another
    channel is not implemented; the range is simply `lastTag..HEAD`.

### Plugins not ported

- **`@semantic-release/gitlab`** — not implemented (no GitLab release creation).
  Note: `env_ci.gleam` *detects* GitLab CI, but there is no GitLab publish
  plugin.
- **`@semantic-release/changelog`** — not implemented (no `CHANGELOG.md`
  generation/maintenance). Note: once added, list it before `git` so its file is
  committed; `git`'s `assets` would include `CHANGELOG.md`.
- **`@semantic-release/git`** — **implemented** (`git.gleam`, and in the default
  plugin set). Commits the configured `assets` (default `gleam.toml`) in
  `prepare`; the engine pushes the branch alongside the tag, so the tag points at
  the release commit and the working tree is left clean. Not yet supported:
  per-asset glob patterns, commit signing.

### JS plugin ecosystem / dynamic loading — deferred (by design)

- Plugins are a **closed set of five built-ins** resolved through a static
  `Dict`. There is **no dynamic plugin loading**: you cannot point config at an
  arbitrary `@semantic-release/*` package or a local JS/Gleam module. This is a
  direct consequence of the native-BEAM target (section 1) — the JS plugin
  ecosystem is unreachable, and Gleam has no runtime module loading.

### Config formats — partial

- **Supported:** `.releaserc.json`, `.releaserc` (as JSON), `release.config.json`,
  `.releaserc.toml`, **`[tools.version_bump]` in `gleam.toml`** (the
  Gleam-native location; derives `repository_url` from `[repository]`), and the
  `"release"` key of `package.json`.
- **Deferred:** **YAML** config (`.releaserc.yaml`/`.yml`) and **JavaScript**
  config (`.releaserc.js`, `release.config.js`, `release.config.cjs`/`.mjs`,
  and an exported function) are not supported. TOML is offered instead of YAML
  as the structured-but-not-JS option.
- Plugin options are coerced to a flat `Dict(String, String)` of scalars;
  **nested object/array plugin options are silently dropped**, so plugins that
  expect rich option shapes cannot be fully configured.
- `prerelease: true` (without an explicit id) decodes to an empty identifier
  intended to default from the branch name later; that defaulting is not fully
  wired through, so prefer specifying the prerelease id explicitly.

### Issue / PR success comments — not implemented

- The real `@semantic-release/github` (and gitlab) plugins comment on, and
  optionally close, the issues and PRs referenced by released commits, and add
  released labels. **None of this is implemented.** Commit references are parsed
  (`commit_parser.gleam` collects `#123`), but the `github` plugin's `success`
  hook only logs a line — it does not open issues on failure, comment on
  resolved issues/PRs, or label them. Release assets/upload are also not
  supported.

### Prerelease edge cases — simplified

- First prerelease is `1.0.0-<id>.1`; subsequent bumps use
  `bump_with_prerelease`, which always resets to `<id>.1` after a core bump
  rather than incrementing an existing prerelease counter (e.g. it does not turn
  `1.2.0-beta.1` into `1.2.0-beta.2` for a follow-up patch on the same
  prerelease line). Cross-identifier transitions (alpha -> beta), and reconciling
  a prerelease number against already-published prerelease tags, are not handled.
- `is_prerelease` in the github plugin is a substring check for `-` in the
  version string rather than a structural prerelease check.

### Other simplifications

- **No CI guard enforcement:** `config.ci` and `env_ci.gleam` exist, but the
  engine does not refuse to run outside CI, skip PR builds, or verify the build
  branch matches the checked-out branch the way real semantic-release does.
- **No `git_head` recorded on tags:** `last_release` sets `git_head` to `""`, so
  the commit range falls back to ranging from the tag itself.
- **No release commit / asset push:** only the tag is pushed (`git push origin
  <tag>`); there is no `--follow-tags`, no pushing of changed files.
- **Notes lack links:** `note.gleam` accepts `repo_url` but emits no
  commit/compare/issue links yet.
- **CLI surface is minimal:** only `--dry-run`, `--version`, `--help`. No
  `--branches`, `--plugins`, `--repository-url`, `--debug`, `--no-ci`, etc.

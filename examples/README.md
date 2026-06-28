# Example: watching the release version get computed

This directory contains a runnable demo of the Gleam semantic-release port. It
builds a throwaway **Gleam package** git repo, seeds it with conventional
commits, and runs the tool in `--dry-run` mode so you can watch it read the git
history and compute the next version + release notes. Nothing is published.

## Run it

```sh
# from the project root
examples/run-demo.sh                      # Erlang/BEAM target (default)
TARGET=javascript examples/run-demo.sh    # JavaScript/Node target
```

Prerequisites: `gleam`, `git`, and a runtime for your chosen target (Erlang for
the default, Node for `TARGET=javascript`). The demo produces **identical**
output on both targets.

The script leaves the generated repo at `examples/scratch/demo-pkg/` (gitignored)
so you can inspect its history (`git -C examples/scratch/demo-pkg log --oneline`)
and config.

## What it shows

The demo repo is configured the **Gleam-native** way — under
`[tools.version_bump]` in its `gleam.toml` (no separate `.releaserc` file) —
using the `commit-analyzer`, `release-notes-generator`, and **`hex`** plugins.
`repository_url` is derived from the standard `[repository]` field:

```toml
repository = { type = "github", user = "demo-org", repo = "demo-package" }

[tools.version_bump]
plugins = ["commit-analyzer", "release-notes-generator", "hex"]
```

It then walks four scenarios, each adding commits and re-running the tool:

| Scenario | Commits since last release | Result |
|---|---|---|
| 1. First release (no tags) | `feat:`, `docs:` | **1.0.0** (first release is always 1.0.0) |
| 2. A bug fix | `fix:` | **1.0.1** (patch) |
| 3. A feature | `fix:` + `feat:` | **1.1.0** (minor — highest wins) |
| 4. A breaking change | `fix:` + `feat:` + `feat!:` | **2.0.0** (major) |

## Actual output (excerpts)

**Scenario 1 — first release:**

```
[version_bump] info No previous release found
[version_bump] info Found 2 commit(s)
[version_bump] info The next release version is 1.0.0 (minor)
[version_bump] info ## 1.0.0

### Features

* initial public API (426e7fa)
[version_bump] info Dry-run: next release would be 1.0.0
```

**Scenario 4 — breaking change reads the `v1.0.0` tag and bumps to major, with
grouped notes:**

```
[version_bump] info Found previous release 1.0.0
[version_bump] info Found 3 commit(s)
[version_bump] info The next release version is 2.0.0 (major)
[version_bump] info ## 2.0.0

### Features

* **api:** rename hello to greet (6125d77)
* **api:** add goodbye/0 (74bc94e)

### Bug Fixes

* **api:** handle empty input (2ba064d)

### BREAKING CHANGES

* **api:** hello/0 has been removed in favour of greet/0.
[version_bump] info Dry-run: next release would be 2.0.0
```

## From dry-run to a real release

This demo is dry-run only. A real run (omit `--dry-run`) would, after computing
the version, run the plugins' effecting hooks:

1. **prepare** — `hex` writes the new version into `gleam.toml`; then `git`
   commits that change (`chore(release): 2.0.0 [skip ci]`)
2. tag the **release commit** (`v2.0.0`), then push the branch and the tag — so
   the tag points at the commit containing the bump and the working tree stays
   clean
3. **publish** — run `gleam publish` (the `hex` plugin), which needs
   `HEXPM_API_KEY` in the environment

(Add `git` to the demo's `plugins` to commit the bump; it's in the defaults but
the demo trims the plugin list for a clean dry-run. A real run pushes a commit to
the branch, so the CI token needs push permission.)

Swap the `hex` plugin for `npm` (with `NPM_TOKEN`) to release a JavaScript
package instead, or add `github` (with `GITHUB_TOKEN`) to also create a GitHub
Release. See `../.releaserc.gleam.example.json` and `../.releaserc.example.json`.

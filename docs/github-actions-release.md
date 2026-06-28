# Automating Gleam releases with GitHub Actions

This guide sets up `version_bump` so **every push to `main` cuts a release**:
it reads the Conventional Commits since the last tag, computes the next version,
bumps `gleam.toml`, commits and tags it, publishes to **Hex**, and creates a
**GitHub Release** — with no manual steps.

It's written for a Gleam package that depends on `version_bump`. (`version_bump`
releases *itself* the same way; see [Releasing version_bump itself](#releasing-version_bump-itself).)

---

## Prerequisites

- A Gleam package hosted on GitHub.
- A [hex.pm](https://hex.pm) account (email verified).
- The [`gh`](https://cli.github.com/) CLI authenticated (`gh auth status`) — or
  you can do the GitHub steps in the web UI.

---

## 1. Add version_bump

Add it as a dev dependency and (optionally) configure it under `gleam.toml`:

```toml
[dev_dependencies]
version_bump = ">= 0.1.0"

# Optional — Gleam-native config. Omit for the defaults.
[tools.version_bump]
# Stay in 0.x: first release is 0.1.0 and breaking changes bump the minor
# instead of jumping to 1.0.0. Drop this to release 1.0.0 first.
initial_development = true
```

The default plugin pipeline is `commit-analyzer`, `release-notes-generator`,
`hex`, `git`, `github` — exactly what a typical Gleam package wants.

---

## 2. Create a Hex API key (with publish permission)

`gleam publish` authenticates with the `HEXPM_API_KEY` environment variable. You
need a key that is allowed to **publish**:

1. Sign in at **hex.pm → Dashboard → [Keys](https://hex.pm/dashboard/keys)**.
2. Generate a new key with a name like `mypackage-ci` and **API (write)
   permission**.
3. Copy the value — Hex shows it **once**.

> **The permission matters.** A read-only key authenticates fine but *cannot
> publish*. If your key lacks publish permission the release will fail at the
> publish step (now loudly — see [How releases are verified](#how-releases-are-verified)).

Alternatives:

- `mix hex.user key generate --key-name mypackage-ci --permission api:write`
  (if you have Elixir/Mix) prints a key directly.
- `gleam hex authenticate` is for publishing **from your own machine** — it
  stores a key locally behind a password (and prompts for 2FA on publish). It
  does **not** give you a copyable value for CI; use the dashboard for that.

---

## 3. Store the key as a repository secret

In **your own terminal** (so the key isn't captured in any shared log):

```sh
gh secret set HEX_API_KEY --repo <owner>/<repo>
# paste the key at the hidden prompt
```

Or via the web UI: **Settings → Secrets and variables → Actions → New repository
secret**, name `HEX_API_KEY`.

Verify it exists (this only lists names, never values):

```sh
gh secret list --repo <owner>/<repo>
```

> `GITHUB_TOKEN` is **automatic** — GitHub injects it into every workflow run.
> You do not create a secret for it.

---

## 4. Add the workflow

Create `.github/workflows/release.yml`:

```yaml
name: release

on:
  push:
    branches: [main]

# Lets GITHUB_TOKEN push the release commit + tag and create the GitHub Release.
permissions:
  contents: write

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          # Full history + tags — a shallow clone makes every run look like a
          # first release. The default persisted credentials let `git push`
          # authenticate with GITHUB_TOKEN.
          fetch-depth: 0

      - uses: erlef/setup-beam@v1
        with:
          otp-version: "27"
          gleam-version: "1.17.0"

      - run: gleam deps download
      - run: gleam test            # gate the release on a green build

      - run: gleam run -m version_bump
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          HEXPM_API_KEY: ${{ secrets.HEX_API_KEY }}
```

What each piece does:

| Piece | Why |
| --- | --- |
| `on: push: branches: [main]` | release on every merge to `main` |
| `permissions: contents: write` | the **only** access you must grant (see below) |
| `fetch-depth: 0` | version_bump reads tags/history to find the last release |
| `setup-beam` | installs Gleam + Erlang/OTP |
| `gleam test` | don't release a broken build |
| `gleam run -m version_bump` | runs the real release pipeline |
| `HEXPM_API_KEY` ← `secrets.HEX_API_KEY` | maps your secret to the env var gleam reads |

---

## 5. Permissions

The workflow's `permissions: contents: write` block grants the run's
`GITHUB_TOKEN` write access **even if your repo defaults `GITHUB_TOKEN` to
read-only** (the default for repos created since 2023). The explicit block is
GitHub's supported way to request write — no repo-settings change is required.

If you ever hit a **403** on the push or the release, belt-and-suspenders is to
flip the repo default too:

```sh
gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow \
  -f default_workflow_permissions=write -F can_approve_pull_request_reviews=false
```

---

## 6. The first release

Two things to know before your first push:

1. **A release only fires if the commits warrant one.** version_bump runs
   `analyze_commits` first; a history of only `chore:`/`docs:` commits produces
   *no* release. Make sure at least one `feat:` or `fix:` commit is present.
2. **First version** is `1.0.0` by default, or `0.1.0` if you set
   `initial_development = true`.

Then push:

```sh
git push -u origin main
```

That triggers the workflow. Watch it:

```sh
gh run watch --exit-status            # follows the latest run
```

> **Chicken-and-egg note:** CI can do the very first publish itself. If you'd
> rather publish the first version by hand (e.g. to confirm your Hex login),
> run `gleam publish` locally first, then let CI take over for subsequent
> releases.

---

## Gotchas (learned the hard way)

- **Publishing a 0.x version.** `gleam publish` guards releases below `1.0.0`
  behind a prompt that makes you type `I am not using semantic versioning`, and
  `--yes` does **not** auto-accept it. Non-interactively (in CI) that prompt
  hits EOF and the publish **silently aborts but still exits 0**. version_bump
  pipes the phrase in for you, so 0.x releases publish fine — but if you script
  `gleam publish` yourself, you'll need to handle it (or release `1.0.0`).
- **Read-only Hex key.** It passes the "is the key present?" check but fails to
  publish. Use a key with API/write permission.
- **Annotated tags need a git identity.** Fresh runners have no
  `user.name`/`user.email`; version_bump sets one per-command so tagging works.
- **`GITHUB_TOKEN` pushes don't trigger other workflows** (loop prevention).
  version_bump's release commit also carries `[skip ci]`.
- **Branch protection** on `main` can reject the `GITHUB_TOKEN` push. Allow a
  bypass actor, or drop the `git` plugin for a tag-only model.

---

## How releases are verified

Because `gleam publish` can exit `0` without actually publishing (see the 0.x
gotcha above), version_bump's `hex` plugin **confirms the package reached Hex**
from `gleam publish`'s own output and fails the release loudly otherwise — so a
green check always means a real publish. You can double-check any release:

```sh
gh run view <run-id> --log                  # the publish output is in the log
curl -s -o /dev/null -w "%{http_code}\n" \
  https://hex.pm/api/packages/<name>/releases/<version>   # 200 == published
```

---

## Command reference

Everything used to set this up and operate it:

```sh
# auth / secrets
gh auth status
gh secret set HEX_API_KEY --repo <owner>/<repo>
gh secret list --repo <owner>/<repo>

# permissions
gh api repos/<owner>/<repo>/actions/permissions/workflow            # inspect
gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow \   # set write
  -f default_workflow_permissions=write -F can_approve_pull_request_reviews=false

# releasing + observing
git push -u origin main
gh run list --workflow=release.yml -L 5
gh run watch <run-id> --exit-status
gh run view <run-id> --log-failed
```

---

## Releasing version_bump itself

`version_bump` dogfoods this exact setup. Its
[`.github/workflows/release.yml`](../.github/workflows/release.yml) is identical
except the run step is `gleam run` (no `-m version_bump`) because the tool *is*
the project. It stays in 0.x via `[tools.version_bump] initial_development =
true` and plans to graduate to `1.0.0` later. See
[`.github/workflows/release.yml.example`](../.github/workflows/release.yml.example)
for the ready-to-copy consumer version.

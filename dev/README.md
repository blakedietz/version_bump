# Generators (`dev/`)

The Gleam equivalent of Phoenix's `mix phx.gen.*` generators.

Gleam has no custom-task system like Mix, so there is no `gleam gen.plugin`.
Instead, generators are ordinary Gleam modules in this `dev/` directory, run with
`gleam run -m`. This is the use the Gleam conventions guide reserves `dev/` for
("development helpers like generators"); code here can import `src/` and
dependencies and is **not** included when the package is published.

> Note: a module literally named `gen` is rejected by the compiler because it
> collides with Erlang's built-in `gen` module — so generators live under a
> `gen/` *directory* (module `gen/<thing>`, Erlang module `gen@<thing>`), which
> also reads nicely: `gen/plugin` ≈ `phx.gen.<thing>`.

## `gen/plugin` — scaffold a release plugin

```sh
gleam run -m gen/plugin -- <name> --hooks <h1,h2,...> [--force]
```

Example:

```sh
gleam run -m gen/plugin -- slack --hooks verify_conditions,success
```

It writes, and `gleam format`s, two files that compile as-is:

- `src/version_bump/plugins/<name>.gleam` — a `Plugin` wiring up exactly the
  hooks you asked for, each with the correct signature and a neutral body behind
  a `// TODO` (so the project keeps compiling until you fill them in). Only the
  imports the chosen hooks actually need are emitted (e.g. `--hooks publish`
  pulls in `task` and `release`; `--hooks analyze_commits` pulls in `semver`).
- `test/<name>_test.gleam` — a gleeunit smoke test asserting the plugin
  registers under its name.

`<name>` may be given kebab- or snake-cased: the registry name is kebab
(`slack-notify`) and the module/file is snake (`slack_notify`).

Valid hooks: `verify_conditions`, `analyze_commits`, `verify_release`,
`generate_notes`, `add_channel`, `prepare`, `publish`, `success`, `fail`.

After generating, the command prints the one manual step it can't safely do for
you — registering the plugin in `src/version_bump/registry.gleam` (it prints
the exact import + `default()` entry to paste, the way `phx.gen` prints router
lines).

## Adding a new generator

Create `dev/gen/<thing>.gleam` with a `pub fn main() -> Nil`, parse
`argv.load().arguments`, and write files with `simplifile`. Run it with
`gleam run -m gen/<thing> -- ...`. Keep it cross-target (no Erlang-only FFI) so
it compiles under both `gleam build` and `gleam build --target javascript`.

(An end-user-facing `init` that scaffolds a `.releaserc.json` into *another*
project belongs in the `version_bump` CLI itself — `version_bump init` —
rather than here, since `dev/` generators run inside *this* repo.)

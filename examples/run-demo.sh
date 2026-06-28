#!/usr/bin/env bash
#
# Builds a throwaway Gleam-package git repo and runs the semantic-release tool
# against it in --dry-run mode, so you can watch the next version be computed
# from conventional commits. Nothing is published and no tags are pushed.
#
# Usage:
#   examples/run-demo.sh              # run on the Erlang/BEAM target (default)
#   TARGET=javascript examples/run-demo.sh   # run on the Node target instead
#
set -euo pipefail

# Resolve the project root (this script lives in <root>/examples).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SCRATCH="$SCRIPT_DIR/scratch/demo-pkg"
TARGET="${TARGET:-erlang}"

git_q() { git -C "$SCRATCH" "$@" >/dev/null 2>&1; }
commit() { git -C "$SCRATCH" commit --allow-empty -q -m "$1"; }

# Run the release tool against the scratch repo, showing only its log output
# (compile chatter on stderr is suppressed; ANSI colour is stripped).
run_release() {
  ( cd "$PROJECT_ROOT" \
      && gleam run --target "$TARGET" -- --cwd "$SCRATCH" --dry-run 2>/dev/null ) \
    | sed 's/\x1b\[[0-9;]*m//g'
}

banner() {
  echo
  echo "──────────────────────────────────────────────────────────────────────"
  echo "  $1"
  echo "──────────────────────────────────────────────────────────────────────"
}

# --- Build a fresh scratch package ------------------------------------------
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/src"
git_q init -b main
git -C "$SCRATCH" config user.email "demo@example.com"
git -C "$SCRATCH" config user.name "Demo Author"

# Release config lives in gleam.toml under [tools.version_bump] — the
# Gleam-native location. repository_url is derived from [repository], and Hex
# auth is only required for a real publish, not for --dry-run.
cat > "$SCRATCH/gleam.toml" <<'TOML'
name = "demo_package"
version = "0.0.0"
description = "A demo Gleam package released with the Gleam semantic-release port"
licences = ["Apache-2.0"]
repository = { type = "github", user = "demo-org", repo = "demo-package" }

[tools.version_bump]
plugins = ["commit-analyzer", "release-notes-generator", "hex"]
TOML

cat > "$SCRATCH/src/demo_package.gleam" <<'GLEAM'
pub fn hello() -> String {
  "hello"
}
GLEAM

git -C "$SCRATCH" add -A
commit "feat: initial public API"
commit "docs: add README"

echo "Demo package built at: $SCRATCH"
echo "Running the tool on the '$TARGET' target (dry-run, nothing is published)."

# --- Scenario 1: first release ----------------------------------------------
banner "1) First release — no tags yet (first release is always 1.0.0)"
run_release

# Tag the first release so later scenarios compute a bump relative to it.
git -C "$SCRATCH" tag "v1.0.0"

# --- Scenario 2: a bug fix => patch -----------------------------------------
banner "2) After v1.0.0, a 'fix:' commit => PATCH (expect 1.0.1)"
commit "fix(api): handle empty input"
run_release

# --- Scenario 3: a feature => minor (highest wins over the fix) -------------
banner "3) Add a 'feat:' commit => MINOR (expect 1.1.0)"
commit "feat(api): add goodbye/0"
run_release

# --- Scenario 4: a breaking change => major ---------------------------------
banner "4) Add a breaking change => MAJOR (expect 2.0.0)"
commit "feat(api)!: rename hello to greet

BREAKING CHANGE: hello/0 has been removed in favour of greet/0."
run_release

banner "Done. This was a dry-run — a real run would update gleam.toml, create"
echo "  and push the git tag, and run 'gleam publish' (with HEXPM_API_KEY set)."
echo "  The scratch repo is left at $SCRATCH for you to inspect."

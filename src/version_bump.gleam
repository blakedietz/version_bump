//// CLI entrypoint for version_bump, a native Gleam port of semantic-release.
////
//// The default invocation runs the full release pipeline against the working
//// directory (`--cwd <path>`, default `.`):
////
////   1. read every environment variable into a `Dict(String, String)`
////   2. load configuration from the project (`config.load`)
////   3. apply CLI overrides (e.g. `--dry-run`)
////   4. run `engine.run` and report the resulting `Summary`
////
//// On error the formatted message is printed and the process exits non-zero.
//// `--version`/`version` prints the tool version; `--help`/`-h` prints usage.

import argv
import envoy
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import version_bump/config.{type Config, Config}
import version_bump/engine.{type Summary}
import version_bump/error.{type ReleaseError}
import version_bump/logging
import version_bump/task

/// The tool version, kept in sync with `gleam.toml`. Bump this alongside a
/// release: the pipeline updates `gleam.toml` but not this compiled-in constant,
/// so it must be set to the version the release will publish.
const version = "0.1.2"

/// The parsed CLI invocation. The default run is `Release(cwd, dry_run)`; the
/// other variants short-circuit before touching the pipeline. Public so the pure
/// argument parser can be unit-tested.
pub type Command {
  Release(cwd: String, dry_run: Bool)
  ShowVersion
  ShowHelp
}

pub fn main() -> Nil {
  let args = argv.load().arguments
  case parse_args(args) {
    Ok(ShowVersion) -> io.println(version)
    Ok(ShowHelp) -> io.println(usage())
    Ok(Release(cwd, dry_run)) -> run_release(cwd, dry_run)
    Error(message) -> {
      logging.error(message)
      io.println(usage())
      halt(2)
    }
  }
}

// --- Argument parsing -------------------------------------------------------

/// Classify the raw arguments into a `Command`. Unknown flags are rejected so
/// the user gets clear feedback rather than a silent no-op. Pure, so it is
/// unit-tested directly.
pub fn parse_args(args: List(String)) -> Result(Command, String) {
  case list.contains(args, "--version") || list.contains(args, "version") {
    True -> Ok(ShowVersion)
    False ->
      case list.contains(args, "--help") || list.contains(args, "-h") {
        True -> Ok(ShowHelp)
        False -> parse_release_args(args)
      }
  }
}

/// Parse the flags accepted by the default (release) command: `--dry-run` and
/// `--cwd <path>` (the `--cwd=<path>` form is also accepted). Unknown flags are
/// rejected so the user gets clear feedback rather than a silent no-op.
fn parse_release_args(args: List(String)) -> Result(Command, String) {
  accumulate_release(args, ".", False)
}

/// Walk the release flags, threading the working directory and dry-run state.
fn accumulate_release(
  args: List(String),
  cwd: String,
  dry_run: Bool,
) -> Result(Command, String) {
  case args {
    [] -> Ok(Release(cwd: cwd, dry_run: dry_run))
    ["--dry-run", ..rest] -> accumulate_release(rest, cwd, True)
    ["--cwd"] -> Error("--cwd requires a path argument")
    ["--cwd", value, ..rest] ->
      case string.starts_with(value, "-") {
        True -> Error("--cwd requires a path argument")
        False -> accumulate_release(rest, value, dry_run)
      }
    [arg, ..rest] ->
      case string.split_once(arg, "=") {
        Ok(#("--cwd", "")) -> Error("--cwd requires a path argument")
        Ok(#("--cwd", value)) -> accumulate_release(rest, value, dry_run)
        _ -> Error("Unknown flag: " <> arg)
      }
  }
}

// --- Release run ------------------------------------------------------------

/// Load config, apply the `--dry-run` override, run the pipeline, and report.
fn run_release(cwd: String, dry_run: Bool) -> Nil {
  let env = envoy.all()
  case config.load(cwd) {
    Error(err) -> fail(err)
    Ok(loaded) -> {
      let config = apply_dry_run(loaded, dry_run)
      // `engine.run` is asynchronous (a `Task`); run it and report when it
      // settles. On Erlang this is immediate; on JavaScript it awaits the
      // underlying promise.
      use result <- task.run(engine.run(config, cwd, env))
      case result {
        Ok(summary) -> print_summary(summary)
        Error(err) -> fail(err)
      }
    }
  }
}

/// Apply the `--dry-run` flag, only ever turning dry-run on (the flag is an
/// override, never a way to force a real release when config disables it). Pure,
/// so it is unit-tested directly.
pub fn apply_dry_run(config: Config, dry_run: Bool) -> Config {
  case dry_run {
    True -> Config(..config, dry_run: True)
    False -> config
  }
}

/// Print a human-readable summary of a successful (or no-op) run.
fn print_summary(summary: Summary) -> Nil {
  case summary.released, summary.version {
    True, Some(v) -> logging.success("Published release " <> v)
    False, Some(v) -> logging.info("Dry-run: next release would be " <> v)
    _, None -> logging.info("No release published")
  }
}

/// Report an error to the log and exit non-zero.
fn fail(err: ReleaseError) -> Nil {
  logging.error(error.to_string(err))
  halt(1)
}

// --- Help text --------------------------------------------------------------

fn usage() -> String {
  string.join(
    [
      "version_bump " <> version,
      "",
      "Usage:",
      "  version_bump [--cwd <path>] [--dry-run]   Run the release pipeline",
      "  version_bump --version                    Print the version and exit",
      "  version_bump --help                       Print this help and exit",
      "",
      "Flags:",
      "  --cwd <path>   Run against the project at <path> (default: .)",
      "  --dry-run      Compute the next release without tagging or publishing",
    ],
    "\n",
  )
}

// --- Side effects -----------------------------------------------------------

/// Halt the BEAM with the given exit code.
@external(erlang, "version_bump_ffi", "halt")
@external(javascript, "./version_bump_ffi.mjs", "halt")
fn halt(code: Int) -> Nil

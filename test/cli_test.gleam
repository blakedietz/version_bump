//// Tests for the pure CLI argument parsing in `version_bump`.

import gleeunit/should
import version_bump.{Release, ShowHelp, ShowVersion}
import version_bump/config

// --- parse_args -------------------------------------------------------------

pub fn parse_args_empty_is_release_test() {
  version_bump.parse_args([])
  |> should.equal(Ok(Release(cwd: ".", dry_run: False)))
}

pub fn parse_args_dry_run_flag_test() {
  version_bump.parse_args(["--dry-run"])
  |> should.equal(Ok(Release(cwd: ".", dry_run: True)))
}

pub fn parse_args_cwd_space_form_test() {
  version_bump.parse_args(["--cwd", "/tmp/proj"])
  |> should.equal(Ok(Release(cwd: "/tmp/proj", dry_run: False)))
}

pub fn parse_args_cwd_equals_form_test() {
  version_bump.parse_args(["--cwd=./packages/api"])
  |> should.equal(Ok(Release(cwd: "./packages/api", dry_run: False)))
}

pub fn parse_args_cwd_with_dry_run_test() {
  version_bump.parse_args(["--cwd", "/tmp/proj", "--dry-run"])
  |> should.equal(Ok(Release(cwd: "/tmp/proj", dry_run: True)))
}

pub fn parse_args_cwd_order_independent_test() {
  version_bump.parse_args(["--dry-run", "--cwd", "/tmp/proj"])
  |> should.equal(Ok(Release(cwd: "/tmp/proj", dry_run: True)))
}

pub fn parse_args_cwd_missing_value_is_error_test() {
  version_bump.parse_args(["--cwd"])
  |> should.equal(Error("--cwd requires a path argument"))
}

pub fn parse_args_cwd_missing_value_before_flag_is_error_test() {
  version_bump.parse_args(["--cwd", "--dry-run"])
  |> should.equal(Error("--cwd requires a path argument"))
}

pub fn parse_args_cwd_empty_equals_is_error_test() {
  version_bump.parse_args(["--cwd="])
  |> should.equal(Error("--cwd requires a path argument"))
}

pub fn parse_args_version_flag_test() {
  version_bump.parse_args(["--version"])
  |> should.equal(Ok(ShowVersion))
}

pub fn parse_args_version_subcommand_test() {
  version_bump.parse_args(["version"])
  |> should.equal(Ok(ShowVersion))
}

pub fn parse_args_help_long_flag_test() {
  version_bump.parse_args(["--help"])
  |> should.equal(Ok(ShowHelp))
}

pub fn parse_args_help_short_flag_test() {
  version_bump.parse_args(["-h"])
  |> should.equal(Ok(ShowHelp))
}

pub fn parse_args_version_takes_precedence_over_dry_run_test() {
  version_bump.parse_args(["--dry-run", "--version"])
  |> should.equal(Ok(ShowVersion))
}

pub fn parse_args_version_takes_precedence_over_help_test() {
  version_bump.parse_args(["--help", "--version"])
  |> should.equal(Ok(ShowVersion))
}

pub fn parse_args_unknown_flag_is_error_test() {
  version_bump.parse_args(["--nope"])
  |> should.equal(Error("Unknown flag: --nope"))
}

pub fn parse_args_unknown_flag_reported_even_with_dry_run_test() {
  version_bump.parse_args(["--dry-run", "--bogus"])
  |> should.equal(Error("Unknown flag: --bogus"))
}

// --- apply_dry_run ----------------------------------------------------------

pub fn apply_dry_run_true_sets_flag_test() {
  let cfg = config.default()
  version_bump.apply_dry_run(cfg, True).dry_run
  |> should.be_true
}

pub fn apply_dry_run_false_keeps_config_default_test() {
  let cfg = config.default()
  version_bump.apply_dry_run(cfg, False).dry_run
  |> should.be_false
}

pub fn apply_dry_run_false_preserves_config_dry_run_true_test() {
  // When config already enables dry-run, omitting the flag must not disable it.
  let cfg = config.Config(..config.default(), dry_run: True)
  version_bump.apply_dry_run(cfg, False).dry_run
  |> should.be_true
}

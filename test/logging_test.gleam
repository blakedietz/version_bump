import gleam/string
import gleeunit/should
import version_bump/logging

/// Smoke test: logging at Info returns Nil.
pub fn log_returns_nil_test() {
  logging.log(logging.Info, "x")
  |> should.equal(Nil)
}

/// Each convenience helper returns Nil.
pub fn helpers_return_nil_test() {
  logging.info("hello")
  |> should.equal(Nil)
  logging.warn("careful")
  |> should.equal(Nil)
  logging.error("boom")
  |> should.equal(Nil)
  logging.success("done")
  |> should.equal(Nil)
}

/// format is pure and includes the prefix and the message.
pub fn format_includes_prefix_test() {
  let line = logging.format(logging.Info, "deploying")
  string.contains(line, "[version_bump]")
  |> should.be_true
}

pub fn format_includes_message_test() {
  let line = logging.format(logging.Success, "released 1.2.3")
  string.contains(line, "released 1.2.3")
  |> should.be_true
}

pub fn format_includes_level_tag_test() {
  logging.format(logging.Warn, "x")
  |> string.contains("warn")
  |> should.be_true
}

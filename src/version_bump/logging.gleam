//// A tiny leveled logger for the release pipeline.
////
//// Mirrors semantic-release's use of a prefixed, leveled signale/console
//// logger. Each message is printed to stdout with a `[version_bump]` prefix and a
//// colorized level tag. Logging is a side effect, so every function returns
//// `Nil`.

import gleam/io
import gleam_community/ansi

/// Severity level of a log message.
pub type Level {
  Info
  Warn
  Err
  Success
  Debug
}

const prefix = "[version_bump]"

/// Log a message at the given level. This is the single primitive that the
/// convenience helpers below delegate to.
pub fn log(level: Level, msg: String) -> Nil {
  io.println(format(level, msg))
}

/// Log an informational message.
pub fn info(msg: String) -> Nil {
  log(Info, msg)
}

/// Log a warning.
pub fn warn(msg: String) -> Nil {
  log(Warn, msg)
}

/// Log an error.
pub fn error(msg: String) -> Nil {
  log(Err, msg)
}

/// Log a success message.
pub fn success(msg: String) -> Nil {
  log(Success, msg)
}

/// Render a level + message into a single colorized, prefixed line. Pure so it
/// can be unit-tested without producing side effects.
pub fn format(level: Level, msg: String) -> String {
  prefix <> " " <> tag(level) <> " " <> msg
}

fn tag(level: Level) -> String {
  case level {
    Info -> ansi.cyan("info")
    Warn -> ansi.yellow("warn")
    Err -> ansi.red("error")
    Success -> ansi.green("success")
    Debug -> ansi.dim("debug")
  }
}

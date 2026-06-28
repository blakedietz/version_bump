//// Error types for the release pipeline. Mirrors semantic-release's use of
//// AggregateError to collect multiple problems before failing.

import gleam/list
import gleam/string

pub type ReleaseError {
  ConfigError(message: String)
  GitError(message: String)
  PluginError(plugin: String, message: String)
  VersionError(message: String)
  NetworkError(message: String)
  ValidationError(message: String)
  /// Collection of multiple errors gathered across plugins/hooks.
  AggregateError(errors: List(ReleaseError))
}

pub fn to_string(error: ReleaseError) -> String {
  case error {
    ConfigError(m) -> "Config error: " <> m
    GitError(m) -> "Git error: " <> m
    PluginError(p, m) -> "Plugin '" <> p <> "' error: " <> m
    VersionError(m) -> "Version error: " <> m
    NetworkError(m) -> "Network error: " <> m
    ValidationError(m) -> "Validation error: " <> m
    AggregateError(errs) ->
      "Multiple errors:\n" <> string.join(list.map(errs, to_string), "\n")
  }
}

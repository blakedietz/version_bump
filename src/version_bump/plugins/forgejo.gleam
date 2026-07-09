//// The Forgejo publish plugin (Codeberg and self-hosted Forgejo instances).
////
//// The Forgejo counterpart of the `github` plugin: authenticate with a
//// Forgejo token, resolve the target repository and instance, and create a
//// Forgejo release for the version semantic-release just determined. Forgejo
//// runs Codeberg, so `plugins = [..., "forgejo"]` with a
//// `https://codeberg.org/...` repository URL is the common setup.
////
//// Hooks implemented:
////   - verify_conditions: a `FORGEJO_TOKEN`/`GITEA_TOKEN` and a resolvable
////     repository URL must be present, otherwise the pipeline aborts.
////   - publish:           create the Forgejo release and return it.
////   - success:           log that the release was published.
////
//// Unlike GitHub, Forgejo is self-hostable, so the API base URL is derived
//// from the repository URL's host — overridable with the `url` plugin option
//// or the `FORGEJO_URL`/`GITEA_URL` environment variables (useful when the git
//// remote host differs from the API host, e.g. an SSH alias or a custom port).
////
//// Effectful work (HTTP, environment access) is kept in the hook bodies; the
//// pure decision logic lives in helpers (`resolve_token`, `resolve_api_base`,
//// `is_prerelease`, `verify`) so it can be unit-tested without a network or
//// live environment.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/string

import envoy

import version_bump/config.{type Config}
import version_bump/context.{type Context}
import version_bump/error.{type ReleaseError, PluginError}
import version_bump/forgejo_api
import version_bump/logging
import version_bump/plugin.{type Plugin, Plugin}
import version_bump/release.{type NextRelease, type Release}
import version_bump/repo_url
import version_bump/task.{type Task}

const name = "forgejo"

/// The plugin record, wiring up the Forgejo hooks.
pub fn plugin() -> Plugin {
  Plugin(
    ..plugin.new(name),
    verify_conditions: Some(do_verify_conditions),
    publish: Some(do_publish),
    success: Some(do_success),
  )
}

// --- verify_conditions -----------------------------------------------------

/// Ensure a Forgejo token and a resolvable repository are available before the
/// pipeline does any work.
fn do_verify_conditions(
  _spec: config.PluginSpec,
  context: Context,
) -> Result(Nil, ReleaseError) {
  // A dry run never creates a Forgejo release, so a token is not required to
  // preview the next release — matching the other publish plugins' behaviour.
  case context.dry_run {
    True -> Ok(Nil)
    False -> {
      let token = resolve_token(context.env)
      verify(token, context.config)
    }
  }
}

/// PURE verification: given a resolved token (if any) and the config, decide
/// whether the Forgejo plugin can run. Separated out so it can be tested
/// without touching the process environment.
pub fn verify(
  token: Option(String),
  config: Config,
) -> Result(Nil, ReleaseError) {
  case token {
    None ->
      Error(PluginError(
        name,
        "No Forgejo token found. Set the FORGEJO_TOKEN or GITEA_TOKEN "
          <> "environment variable.",
      ))
    Some(_) ->
      case resolve_repo_url(config) {
        None ->
          Error(PluginError(
            name,
            "No repository URL configured. Set `repositoryUrl` so the Forgejo "
              <> "release can be created.",
          ))
        Some(url) ->
          case repo_url.parse(url) {
            Ok(_) -> Ok(Nil)
            Error(_) ->
              Error(PluginError(
                name,
                "Could not parse a host/owner/repo from repository URL: "
                  <> url,
              ))
          }
      }
  }
}

// --- publish ---------------------------------------------------------------

/// Create a Forgejo release for the upcoming version and return it.
///
/// The synchronous pre-flight (token, repo URL, next release, API base) is
/// gathered first; only the HTTP create-release call is asynchronous.
fn do_publish(
  spec: config.PluginSpec,
  context: Context,
) -> Task(Result(Option(Release), ReleaseError)) {
  case gather_publish_inputs(spec, context) {
    Error(err) -> task.resolve(Error(err))
    Ok(#(token, base_url, owner, repo, next_release)) -> {
      let prerelease = is_prerelease(next_release)
      let head = next_release.git_head

      forgejo_api.create_release(
        base_url,
        token,
        owner,
        repo,
        next_release.git_tag,
        next_release.version,
        next_release.notes,
        prerelease,
        head,
      )
      |> task.map(fn(result) {
        case result {
          Ok(release) -> Ok(Some(release))
          Error(err) -> Error(adapt_error(err))
        }
      })
    }
  }
}

/// Collect the synchronous inputs `do_publish` needs, short-circuiting with a
/// `PluginError` if any are missing or unparseable.
fn gather_publish_inputs(
  spec: config.PluginSpec,
  context: Context,
) -> Result(#(String, String, String, String, NextRelease), ReleaseError) {
  use token <- with_token(context.env)
  use url <- with_repo_url(context.config)
  use next_release <- with_next_release(context)
  use ref <- with_parsed_repo(url)
  let repo_url.RepoRef(host, owner, repo) = ref
  let base_url = resolve_api_base(explicit_base_url(spec, context.env), host)
  Ok(#(token, base_url, owner, repo, next_release))
}

// --- success ---------------------------------------------------------------

/// Log that the Forgejo release was published. MVP: a single log line.
fn do_success(
  _spec: config.PluginSpec,
  context: Context,
) -> Result(Nil, ReleaseError) {
  let message = case context.next_release {
    Some(next_release) -> "Published Forgejo release " <> next_release.git_tag
    None -> "Published Forgejo release"
  }
  logging.success(message)
  Ok(Nil)
}

// --- pure helpers ----------------------------------------------------------

/// Whether the upcoming release is a prerelease (i.e. its channel-tied version
/// carries a prerelease identifier such as `-beta.1`).
pub fn is_prerelease(next_release: NextRelease) -> Bool {
  string.contains(next_release.version, "-")
}

/// The base URL of the Forgejo instance the release is created on.
///
/// PURE: an explicit override (the `url` plugin option or the
/// `FORGEJO_URL`/`GITEA_URL` environment variables) wins; otherwise the host
/// from the repository URL is assumed to serve the API over https.
pub fn resolve_api_base(explicit: Option(String), host: String) -> String {
  case explicit {
    Some(url) -> string.trim(url)
    None -> "https://" <> host
  }
}

/// An explicitly configured instance URL, if any: the `url` plugin option
/// first, then the `FORGEJO_URL`/`GITEA_URL` environment variables.
fn explicit_base_url(
  spec: config.PluginSpec,
  env: Dict(String, String),
) -> Option(String) {
  case env_lookup(spec.options, "url") {
    Some(url) -> Some(url)
    None ->
      case resolve_env(env, "FORGEJO_URL") {
        Some(url) -> Some(url)
        None -> resolve_env(env, "GITEA_URL")
      }
  }
}

/// Resolve a Forgejo token from the supplied environment, preferring
/// `FORGEJO_TOKEN` over `GITEA_TOKEN`, falling back to the live process
/// environment when neither key is present in the passed-in dictionary.
fn resolve_token(env: Dict(String, String)) -> Option(String) {
  case resolve_env(env, "FORGEJO_TOKEN") {
    Some(token) -> Some(token)
    None -> resolve_env(env, "GITEA_TOKEN")
  }
}

/// Look up a key in the passed-in environment, falling back to the live
/// process environment via `envoy`.
fn resolve_env(env: Dict(String, String), key: String) -> Option(String) {
  case env_lookup(env, key) {
    Some(value) -> Some(value)
    None -> envoy_lookup(key)
  }
}

/// The configured repository URL, treating an empty/whitespace value as absent.
fn resolve_repo_url(config: Config) -> Option(String) {
  case config.repository_url {
    Some(url) ->
      case string.trim(url) {
        "" -> None
        trimmed -> Some(trimmed)
      }
    None -> None
  }
}

/// Look up a key in a string dictionary, treating empty/whitespace-only values
/// as absent.
fn env_lookup(env: Dict(String, String), key: String) -> Option(String) {
  case dict.get(env, key) {
    Ok(value) -> non_empty(value)
    Error(_) -> None
  }
}

/// Look up a key in the live process environment via `envoy`.
fn envoy_lookup(key: String) -> Option(String) {
  case envoy.get(key) {
    Ok(value) -> non_empty(value)
    Error(_) -> None
  }
}

fn non_empty(value: String) -> Option(String) {
  case string.trim(value) {
    "" -> None
    trimmed -> Some(trimmed)
  }
}

/// Map a transport-level error onto the plugin's namespace so failures are
/// attributed to the Forgejo plugin in aggregate reporting.
fn adapt_error(err: ReleaseError) -> ReleaseError {
  PluginError(name, error.to_string(err))
}

// --- `use`-friendly guard helpers ------------------------------------------
// Each returns the required value or short-circuits with a PluginError, keeping
// `gather_publish_inputs` a flat sequence of `use` bindings.

fn with_token(
  env: Dict(String, String),
  next: fn(String) -> Result(a, ReleaseError),
) -> Result(a, ReleaseError) {
  case resolve_token(env) {
    Some(token) -> next(token)
    None ->
      Error(PluginError(
        name,
        "No Forgejo token found. Set the FORGEJO_TOKEN or GITEA_TOKEN "
          <> "environment variable.",
      ))
  }
}

fn with_repo_url(
  config: Config,
  next: fn(String) -> Result(a, ReleaseError),
) -> Result(a, ReleaseError) {
  case resolve_repo_url(config) {
    Some(url) -> next(url)
    None -> Error(PluginError(name, "No repository URL configured."))
  }
}

fn with_next_release(
  context: Context,
  next: fn(NextRelease) -> Result(a, ReleaseError),
) -> Result(a, ReleaseError) {
  case context.next_release {
    Some(next_release) -> next(next_release)
    None -> Error(PluginError(name, "No next release to publish to Forgejo."))
  }
}

fn with_parsed_repo(
  url: String,
  next: fn(repo_url.RepoRef) -> Result(a, ReleaseError),
) -> Result(a, ReleaseError) {
  case repo_url.parse(url) {
    Ok(ref) -> next(ref)
    Error(Nil) ->
      Error(PluginError(
        name,
        "Could not parse a host/owner/repo from repository URL: " <> url,
      ))
  }
}

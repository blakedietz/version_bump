//// Pure parsing of git remote URLs into host + owner + repo.
////
//// Shared by the forge plugins: `github` only needs `owner`/`repo`, while
//// `forgejo` also needs the host so it can derive the API base URL of a
//// self-hosted instance. Handles the common remote forms:
////
////   - `https://host/owner/repo.git` (also `http://`, optional `:port`)
////   - `git@host:owner/repo.git` (scp-like)
////   - `ssh://git@host/owner/repo.git`
////   - `git://host/owner/repo.git`
////   - any of the above wrapped in a `git+` prefix
////
//// The trailing `.git` suffix and trailing slashes are stripped; extra path
//// segments after the repository name are ignored.

import gleam/string

/// A parsed repository reference. `host` keeps an explicit `:port` when an
/// http(s) URL carries one (e.g. a self-hosted forge on a non-standard port).
pub type RepoRef {
  RepoRef(host: String, owner: String, repo: String)
}

/// Extract host, owner and repo from a git remote URL.
pub fn parse(url: String) -> Result(RepoRef, Nil) {
  let trimmed = string.trim(url)

  let without_prefix = case trimmed {
    "git+" <> rest -> rest
    other -> other
  }

  // Scheme URLs put the host (possibly `host:port`) before the first `/`;
  // scp-like `git@host:path` and bare `host:path` forms put it before `:`.
  let split = case without_prefix {
    "https://" <> rest -> split_scheme_remainder(rest)
    "http://" <> rest -> split_scheme_remainder(rest)
    "ssh://" <> rest -> split_scheme_remainder(rest)
    "git://" <> rest -> split_scheme_remainder(rest)
    "git@" <> rest -> split_scp_remainder(rest)
    other -> split_scp_remainder(other)
  }

  case split {
    Error(Nil) -> Error(Nil)
    Ok(#(host, path)) -> {
      let path =
        path
        |> drop_leading_slash
        |> strip_git_suffix
        |> drop_trailing_slash
      case string.split_once(path, "/") {
        Ok(#(owner, repo)) -> {
          // `repo` may still contain a path tail (e.g. extra segments); keep
          // only the first segment as the repository name.
          let repo = first_segment(repo)
          case owner, repo {
            "", _ | _, "" -> Error(Nil)
            _, _ -> Ok(RepoRef(host: host, owner: owner, repo: repo))
          }
        }
        Error(_) -> Error(Nil)
      }
    }
  }
}

// --- internal helpers --------------------------------------------------------

/// Split a scheme URL's remainder (after `https://` etc.) at the first `/`,
/// keeping any `:port` as part of the host.
fn split_scheme_remainder(rest: String) -> Result(#(String, String), Nil) {
  case string.split_once(strip_userinfo(rest), "/") {
    Ok(#(host, path)) -> Ok(#(host, path))
    Error(_) -> Error(Nil)
  }
}

/// Split an scp-like remainder (`host:owner/repo`, with the `git@` already
/// stripped) at the first `:`, falling back to `/` for bare `host/owner/repo`.
fn split_scp_remainder(rest: String) -> Result(#(String, String), Nil) {
  case string.split_once(rest, ":") {
    Ok(#(host, path)) -> Ok(#(host, path))
    Error(_) ->
      case string.split_once(rest, "/") {
        Ok(#(host, path)) -> Ok(#(host, path))
        Error(_) -> Error(Nil)
      }
  }
}

/// Strip an optional `user@` prefix from a host portion (e.g. `git@github.com`).
fn strip_userinfo(rest: String) -> String {
  case string.split_once(rest, "@") {
    // Only treat as userinfo when the `@` appears before any `/` (host part).
    Ok(#(before, after)) ->
      case string.contains(before, "/") {
        True -> rest
        False -> after
      }
    Error(_) -> rest
  }
}

fn drop_leading_slash(s: String) -> String {
  case s {
    "/" <> rest -> drop_leading_slash(rest)
    _ -> s
  }
}

fn drop_trailing_slash(s: String) -> String {
  case string.ends_with(s, "/") {
    True -> drop_trailing_slash(string.drop_end(s, 1))
    False -> s
  }
}

fn strip_git_suffix(s: String) -> String {
  case string.ends_with(s, ".git") {
    True -> string.drop_end(s, 4)
    False -> s
  }
}

fn first_segment(s: String) -> String {
  case string.split_once(s, "/") {
    Ok(#(head, _)) -> head
    Error(_) -> s
  }
}

// JavaScript FFI for the GitHub create-release POST.
//
// Returns a Promise resolving to a Gleam `#(Int, String)` tuple (represented as
// a 2-element array on the JS target): `[status_code, body]`. A status of 0
// signals a transport failure, with the message in the body slot. The Promise
// IS the `Task(#(Int, String))` on the JavaScript target.

export function post(url, token, body) {
  return fetch(url, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + token,
      Accept: "application/vnd.github+json",
      "Content-Type": "application/json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "version_bump",
    },
    body: body,
  })
    .then((resp) => resp.text().then((text) => [resp.status, text]))
    .catch((err) => [0, err && err.message ? err.message : String(err)]);
}

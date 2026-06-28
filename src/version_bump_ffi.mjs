// JavaScript FFI for the bump entrypoint, mirroring
// version_bump_ffi.erl. Used when compiling to the JavaScript target.

// Terminate the process with the given exit code (Node). Returns Nil
// (undefined) for non-Node environments where there is nothing to halt.
export function halt(code) {
  if (globalThis.process && typeof globalThis.process.exit === "function") {
    globalThis.process.exit(code);
  }
  return undefined;
}

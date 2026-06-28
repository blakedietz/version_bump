//// A minimal cross-target async abstraction.
////
//// `Task(a)` is a deferred computation yielding an `a`. On the JavaScript target
//// it is backed by a `Promise`; on the Erlang/BEAM target there are no promises,
//// so it is simply the eagerly-computed value (an identity "monad"). The
//// combinators have target-specific FFI implementations (`version_bump_task_ffi.erl` and
//// `version_bump_task_ffi.mjs`) so the rest of the pipeline can sequence asynchronous work
//// — chiefly the GitHub HTTP request — without caring which target it compiles
//// for.
////
//// On Erlang every combinator runs immediately and synchronously; on JavaScript
//// they defer onto the microtask/promise queue.

/// A deferred value. Opaque: build and combine it only through this module.
pub type Task(a)

/// A task that is already complete with `value`.
@external(erlang, "version_bump_task_ffi", "resolve")
@external(javascript, "./version_bump_task_ffi.mjs", "resolve")
pub fn resolve(value: a) -> Task(a)

/// Transform the eventual value of a task.
@external(erlang, "version_bump_task_ffi", "map")
@external(javascript, "./version_bump_task_ffi.mjs", "map")
pub fn map(task: Task(a), with f: fn(a) -> b) -> Task(b)

/// Chain a task-producing function onto a task (monadic bind / promise "then").
@external(erlang, "version_bump_task_ffi", "await")
@external(javascript, "./version_bump_task_ffi.mjs", "then_")
pub fn await(task: Task(a), then f: fn(a) -> Task(b)) -> Task(b)

/// Run a task for its effect once it settles, passing the value to `f`. On
/// Erlang this is immediate; on JavaScript `f` runs when the promise resolves.
@external(erlang, "version_bump_task_ffi", "run")
@external(javascript, "./version_bump_task_ffi.mjs", "run")
pub fn run(task: Task(a), and_then f: fn(a) -> Nil) -> Nil

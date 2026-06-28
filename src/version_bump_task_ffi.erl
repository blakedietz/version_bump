-module(version_bump_task_ffi).
-export([resolve/1, map/2, await/2, run/2]).

%% On the BEAM a Task is just its value: every combinator is synchronous.

resolve(Value) -> Value.

map(Task, F) -> F(Task).

await(Task, F) -> F(Task).

run(Task, F) ->
    F(Task),
    nil.

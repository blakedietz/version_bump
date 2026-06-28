// JavaScript FFI for `task.gleam`: a Task is a Promise.

export function resolve(value) {
  return Promise.resolve(value);
}

export function map(task, f) {
  return task.then(f);
}

// `await` is a reserved word in JS, so the Gleam external points here.
export function then_(task, f) {
  return task.then(f);
}

export function run(task, f) {
  task.then(f);
  return undefined;
}

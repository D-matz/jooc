import gleam/dynamic.{type Dynamic}
import gleam/javascript/promise.{type Promise}
import lustre/effect.{type Effect}

pub type Database

pub fn open(
  bytes: BitArray,
  to_msg: fn(Result(Database, String)) -> msg,
) -> Effect(msg) {
  perform(fn() { do_open(bytes) }, to_msg)
}

pub fn exec(
  db: Database,
  sql: String,
  to_msg: fn(Result(Nil, String)) -> msg,
) -> Effect(msg) {
  perform(fn() { do_exec(db, sql) }, to_msg)
}

pub fn query(
  db: Database,
  sql: String,
  to_msg: fn(Result(Dynamic, String)) -> msg,
) -> Effect(msg) {
  perform(fn() { do_query(db, sql) }, to_msg)
}

fn perform(
  task: fn() -> Promise(Result(a, String)),
  to_msg: fn(Result(a, String)) -> msg,
) -> Effect(msg) {
  use dispatch <- effect.from
  let _ = task() |> promise.map(to_msg) |> promise.tap(dispatch)
  Nil
}

@external(javascript, "./sqlite_ffi.mjs", "open")
fn do_open(bytes: BitArray) -> Promise(Result(Database, String))

@external(javascript, "./sqlite_ffi.mjs", "exec")
fn do_exec(db: Database, sql: String) -> Promise(Result(Nil, String))

@external(javascript, "./sqlite_ffi.mjs", "query")
fn do_query(db: Database, sql: String) -> Promise(Result(Dynamic, String))

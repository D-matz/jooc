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

pub fn query(
  db: Database,
  sql: String,
  bind: List(String),
  to_msg: fn(Result(Dynamic, String)) -> msg,
) -> Effect(msg) {
  perform(fn() { do_query(db, sql, bind) }, to_msg)
}

pub fn check_cached_etag(
  to_msg: fn(Result(String, Nil)) -> msg,
) -> Effect(msg) {
  perform(do_check_cached_etag, to_msg)
}

pub fn load_cached(to_msg: fn(Result(BitArray, Nil)) -> msg) -> Effect(msg) {
  perform(do_load_cached, to_msg)
}

pub fn save_cached(etag: String, bits: BitArray) -> Effect(msg) {
  use _dispatch <- effect.from
  let _ = do_save_cached(etag, bits)
  Nil
}

fn perform(task: fn() -> Promise(a), to_msg: fn(a) -> msg) -> Effect(msg) {
  use dispatch <- effect.from
  let _ = task() |> promise.map(to_msg) |> promise.tap(dispatch)
  Nil
}

@external(javascript, "./sqlite_ffi.mjs", "open")
fn do_open(bytes: BitArray) -> Promise(Result(Database, String))

@external(javascript, "./sqlite_ffi.mjs", "query")
fn do_query(
  db: Database,
  sql: String,
  bind: List(String),
) -> Promise(Result(Dynamic, String))

@external(javascript, "./sqlite_ffi.mjs", "check_cached_etag")
fn do_check_cached_etag() -> Promise(Result(String, Nil))

@external(javascript, "./sqlite_ffi.mjs", "load_cached")
fn do_load_cached() -> Promise(Result(BitArray, Nil))

@external(javascript, "./sqlite_ffi.mjs", "save_cached")
fn do_save_cached(etag: String, bits: BitArray) -> Promise(Result(Nil, String))

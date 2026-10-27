import gleam/http
import gleam/http/request.{type Request}
import gleam/javascript/promise.{type Promise}
import lustre/effect.{type Effect}

@external(javascript, "./slop_ffi.mjs", "sign")
fn sign(
  method: String,
  host: String,
  path: String,
  body: BitArray,
  region: String,
  access_key_id: String,
  secret_access_key: String,
) -> Promise(#(String, String, String))

/// Build a signed PUT request for an R2 (S3-compatible) object.
pub fn put_object(
  host host: String,
  access_key_id access_key_id: String,
  secret_access_key secret_access_key: String,
  bucket bucket: String,
  key key: String,
  body body: BitArray,
  content_type content_type: String,
) -> Promise(Request(BitArray)) {
  let path = "/" <> bucket <> "/" <> key
  use #(amz_date, payload_hash, authorization) <- promise.map(sign(
    "PUT",
    host,
    path,
    body,
    "auto",
    access_key_id,
    secret_access_key,
  ))

  request.new()
  |> request.set_method(http.Put)
  |> request.set_scheme(http.Https)
  |> request.set_host(host)
  |> request.set_path(path)
  |> request.set_header("content-type", content_type)
  |> request.set_header("x-amz-date", amz_date)
  |> request.set_header("x-amz-content-sha256", payload_hash)
  |> request.set_header("authorization", authorization)
  |> request.set_body(body)
}

pub fn put_object_effect(
  host host: String,
  access_key_id access_key_id: String,
  secret_access_key secret_access_key: String,
  bucket bucket: String,
  key key: String,
  body body: BitArray,
  on_built on_built: fn(Request(BitArray)) -> msg,
  content_type content_type: String,
) -> Effect(msg) {
  use dispatch <- effect.from
  let _ =
    put_object(
      host:,
      access_key_id:,
      secret_access_key:,
      bucket:,
      key:,
      body:,
      content_type:,
    )
    |> promise.map(fn(request) { dispatch(on_built(request)) })
  Nil
}

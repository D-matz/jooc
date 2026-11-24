import gleam/bit_array
import gleam/fetch
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import lustre/effect.{type Effect}
import rsvp

pub fn load_bits(
  request: Request(BitArray),
  progress_message: fn(Float) -> message,
  run_handler: fn(Result(Response(BitArray), rsvp.Error(BitArray))) -> message,
) -> Effect(message) {
  use dispatch <- effect.from

  fetch.send_bits(request)
  |> promise.try_await(fn(resp) {
    let assert Ok(content_length) = response.get_header(resp, "content-length")
    let assert Ok(total) = int.parse(content_length)
    let assert Ok(reader) = fetch.stream_body(resp)

    read_chunks(resp, reader, [], 0, total, dispatch, progress_message)
  })
  |> promise.map(
    result.map_error(_, fn(error) {
      case error {
        fetch.NetworkError(_) -> rsvp.NetworkError
        fetch.UnableToReadBody -> rsvp.BadBody
        fetch.InvalidJsonBody -> rsvp.BadBody
      }
    }),
  )
  |> promise.rescue(fn(_) { Error(rsvp.NetworkError) })
  |> promise.map(run_handler)
  |> promise.tap(dispatch)

  Nil
}

fn read_chunks(
  resp: Response(fetch.FetchBody),
  reader: fetch.BodyReader,
  chunks: List(BitArray),
  received: Int,
  total: Int,
  dispatch: fn(message) -> Nil,
  progress_message: fn(Float) -> message,
) -> promise.Promise(Result(Response(BitArray), fetch.FetchError)) {
  use chunk <- promise.try_await(fetch.read_chunk(reader))

  case chunk {
    Some(bytes) -> {
      let received = received + bit_array.byte_size(bytes)
      let progress = int.to_float(received) /. int.to_float(total)

      dispatch(progress_message(progress))

      read_chunks(
        resp,
        reader,
        [bytes, ..chunks],
        received,
        total,
        dispatch,
        progress_message,
      )
    }

    None -> {
      let body = bit_array.concat(list.reverse(chunks))
      promise.resolve(Ok(response.set_body(resp, body)))
    }
  }
}

import gleam/list

pub fn range(
  from start: Int,
  to stop: Int,
  run num_to_thing: fn(Int) -> a,
) -> List(a) {
  let increment = case start < stop {
    True -> 1
    False -> -1
  }
  range_loop_reversed(start, stop, increment, [], num_to_thing) |> list.reverse
}

fn range_loop_reversed(
  current: Int,
  stop: Int,
  increment: Int,
  acc: List(a),
  num_to_thing: fn(Int) -> a,
) -> List(a) {
  case current == stop {
    True -> acc
    False -> {
      let acc = [num_to_thing(current), ..acc]
      let current = current + increment
      range_loop_reversed(current, stop, increment, acc, num_to_thing)
    }
  }
}

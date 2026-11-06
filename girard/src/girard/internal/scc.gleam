//// Tarjan's strongly-connected-components algorithm over a string-keyed graph.
//// Used to group mutually-recursive top-level definitions and order them so
//// that dependencies are inferred (and generalized) before their dependents,
//// mirroring the compiler's `call_graph` + `dep_tree`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/set.{type Set}

type Tarjan {
  Tarjan(
    counter: Int,
    indices: Dict(String, Int),
    lowlinks: Dict(String, Int),
    on_stack: Set(String),
    stack: List(String),
    /// Completed components, most-recently-completed first.
    components: List(List(String)),
  )
}

/// Compute strongly-connected components of `nodes` under `edges` (an adjacency
/// list mapping each node to the nodes it depends on), returned in topological
/// order: a component appears before any component that depends on it.
pub fn components(
  nodes: List(String),
  edges: Dict(String, List(String)),
) -> List(List(String)) {
  let initial =
    Tarjan(
      counter: 0,
      indices: dict.new(),
      lowlinks: dict.new(),
      on_stack: set.new(),
      stack: [],
      components: [],
    )
  let final =
    list.fold(nodes, initial, fn(state, node) {
      case dict.has_key(state.indices, node) {
        True -> state
        False -> strong_connect(state, node, edges)
      }
    })
  // Each completed component is prepended, so `components` is dependents-first;
  // reversing yields dependency-first (topological) order.
  list.reverse(final.components)
}

fn strong_connect(
  state: Tarjan,
  node: String,
  edges: Dict(String, List(String)),
) -> Tarjan {
  let index = state.counter
  let state =
    Tarjan(
      ..state,
      counter: index + 1,
      indices: dict.insert(state.indices, node, index),
      lowlinks: dict.insert(state.lowlinks, node, index),
      on_stack: set.insert(state.on_stack, node),
      stack: [node, ..state.stack],
    )

  let neighbours = case dict.get(edges, node) {
    Ok(ns) -> ns
    Error(_) -> []
  }

  let state =
    list.fold(neighbours, state, fn(state, w) {
      case dict.get(state.indices, w) {
        Error(_) -> {
          // w has not been visited; recurse and take its lowlink.
          let state = strong_connect(state, w, edges)
          set_min_lowlink(state, node, get(state.lowlinks, w))
        }
        Ok(w_index) ->
          case set.contains(state.on_stack, w) {
            True -> set_min_lowlink(state, node, w_index)
            False -> state
          }
      }
    })

  // If node is a root of an SCC, pop the stack down to it.
  case get(state.lowlinks, node) == get(state.indices, node) {
    True -> pop_component(state, node, [])
    False -> state
  }
}

fn set_min_lowlink(state: Tarjan, node: String, candidate: Int) -> Tarjan {
  let current = get(state.lowlinks, node)
  Tarjan(
    ..state,
    lowlinks: dict.insert(state.lowlinks, node, int.min(current, candidate)),
  )
}

fn pop_component(state: Tarjan, root: String, acc: List(String)) -> Tarjan {
  case state.stack {
    [] -> state
    [top, ..rest] -> {
      let state =
        Tarjan(..state, stack: rest, on_stack: set.delete(state.on_stack, top))
      let acc = [top, ..acc]
      case top == root {
        True -> Tarjan(..state, components: [acc, ..state.components])
        False -> pop_component(state, root, acc)
      }
    }
  }
}

// Look up an index/lowlink. Tarjan always assigns these before reading them,
// so the default is unreachable; return one rather than crash.
fn get(d: Dict(String, Int), key: String) -> Int {
  case dict.get(d, key) {
    Ok(value) -> value
    Error(_) -> 0
  }
}

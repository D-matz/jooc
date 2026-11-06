//// Collect the names a definition's body refers to, used to build the call
//// graph between top-level definitions.
////
//// References are tracked with lexical scoping: a name bound locally
//// (function parameter, `let`/`use` binding, pattern variable, `fn` parameter,
//// or `case` clause pattern) shadows any top-level definition of the same name,
//// so its uses are *not* recorded as dependency edges. Without this, a function
//// with a parameter named `pool` that also has a top-level `pool` would be
//// wrongly grouped into `pool`'s recursive component, deferring its
//// generalization and over-unifying its type.
////
//// References are split into two kinds:
////   - *values*: names used in value position (`f`, `f(x)`, shorthand fields).
////   - *qualifiers*: the bare name of a field access (`x` in `x.label`), which
////     is usually qualified module access (`string.trim`) rather than a real
////     dependency. The caller keeps a qualifier edge only when the name is a
////     local definition rather than an imported module — so a `string` helper
////     does not get grouped with `gleam/string`, while a `config.field` access
////     on a local `config` constant still orders that constant first.

import glance
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}

// Reference collection
//
// Walk a function body or constant value and gather the value and qualifier
// references it makes, threading the set of locally-bound names so a shadowed
// reference is dropped rather than recorded as a dependency edge.

/// `#(value references, field-access qualifier names)` in a function body.
pub fn in_function(function: glance.Function) -> #(List(String), List(String)) {
  let bound = set.from_list(list.flat_map(function.parameters, param_names))
  in_statements(function.body, bound, #([], []))
}

/// `#(value references, field-access qualifier names)` in a constant's value.
pub fn in_constant(constant: glance.Constant) -> #(List(String), List(String)) {
  in_expr(constant.value, set.new(), #([], []))
}

type Acc =
  #(List(String), List(String))

fn value(acc: Acc, bound: Set(String), name: String) -> Acc {
  use <- bool.guard(when: set.contains(bound, name), return: acc)
  #([name, ..acc.0], acc.1)
}

fn qualifier(acc: Acc, bound: Set(String), name: String) -> Acc {
  use <- bool.guard(when: set.contains(bound, name), return: acc)
  #(acc.0, [name, ..acc.1])
}

fn in_statements(
  statements: List(glance.Statement),
  bound: Set(String),
  acc: Acc,
) -> Acc {
  // Bindings introduced by `let`/`use` are in scope for *subsequent*
  // statements, so the scope grows as we fold left to right.
  let #(_bound, acc) =
    list.fold(statements, #(bound, acc), fn(state, statement) {
      let #(bound, acc) = state
      case statement {
        glance.Expression(expr) -> #(bound, in_expr(expr, bound, acc))
        glance.Assignment(_, _, pattern, _, value) -> {
          let acc = in_expr(value, bound, acc)
          let inner = set.union(bound, set.from_list(pattern_names(pattern)))
          #(inner, pattern_refs(pattern, inner, acc))
        }
        glance.Assert(_, expr, message) -> #(
          bound,
          in_optional(message, bound, in_expr(expr, bound, acc)),
        )
        glance.Use(_, patterns, function) -> {
          let acc = in_expr(function, bound, acc)
          let names =
            list.flat_map(patterns, fn(p) { pattern_names(p.pattern) })
          let inner = set.union(bound, set.from_list(names))
          let acc =
            list.fold(patterns, acc, fn(acc, p) {
              pattern_refs(p.pattern, inner, acc)
            })
          #(inner, acc)
        }
      }
    })
  acc
}

fn in_optional(
  expr: Option(glance.Expression),
  bound: Set(String),
  acc: Acc,
) -> Acc {
  case expr {
    Some(e) -> in_expr(e, bound, acc)
    None -> acc
  }
}

fn in_exprs(
  exprs: List(glance.Expression),
  bound: Set(String),
  acc: Acc,
) -> Acc {
  list.fold(exprs, acc, fn(acc, e) { in_expr(e, bound, acc) })
}

fn in_fields(
  fields: List(glance.Field(glance.Expression)),
  bound: Set(String),
  acc: Acc,
) -> Acc {
  list.fold(fields, acc, fn(acc, field) {
    case field {
      glance.UnlabelledField(item) -> in_expr(item, bound, acc)
      glance.LabelledField(_, _, item) -> in_expr(item, bound, acc)
      glance.ShorthandField(label, _) -> value(acc, bound, label)
    }
  })
}

fn in_expr(expr: glance.Expression, bound: Set(String), acc: Acc) -> Acc {
  case expr {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> acc

    glance.Variable(_, name) -> value(acc, bound, name)

    glance.NegateInt(_, v) | glance.NegateBool(_, v) -> in_expr(v, bound, acc)

    glance.Block(_, statements) -> in_statements(statements, bound, acc)

    glance.Panic(_, message) | glance.Todo(_, message) ->
      in_optional(message, bound, acc)

    glance.Tuple(_, elements) -> in_exprs(elements, bound, acc)

    glance.List(_, elements, rest) ->
      in_optional(rest, bound, in_exprs(elements, bound, acc))

    // An anonymous function's parameters shadow within its body.
    glance.Fn(_, arguments, _return, body) -> {
      let bound =
        set.union(
          bound,
          set.from_list(list.flat_map(arguments, fn_param_names)),
        )
      in_statements(body, bound, acc)
    }

    glance.RecordUpdate(_, _, _, record, fields) ->
      list.fold(fields, in_expr(record, bound, acc), fn(acc, field) {
        in_optional(field.item, bound, acc)
      })

    // `x.label` with a bare-name container records `x` as a *qualifier*: it is
    // usually module access (`string.trim`). A non-variable container
    // (`f().field`) is a real value reference.
    glance.FieldAccess(_, glance.Variable(_, name), _label) ->
      qualifier(acc, bound, name)
    glance.FieldAccess(_, container, _label) -> in_expr(container, bound, acc)

    glance.Call(_, function, arguments) ->
      in_fields(arguments, bound, in_expr(function, bound, acc))

    glance.TupleIndex(_, tuple, _index) -> in_expr(tuple, bound, acc)

    glance.FnCapture(_, _label, function, before, after) ->
      in_fields(
        after,
        bound,
        in_fields(before, bound, in_expr(function, bound, acc)),
      )

    glance.BitString(_, segments) ->
      list.fold(segments, acc, fn(acc, segment) {
        in_expr(segment.0, bound, acc)
      })

    // Each clause's patterns bind names visible in its guard and body.
    glance.Case(_, subjects, clauses) ->
      list.fold(clauses, in_exprs(subjects, bound, acc), fn(acc, clause) {
        let patterns = list.flatten(clause.patterns)
        let names = list.flat_map(patterns, pattern_names)
        let bound = set.union(bound, set.from_list(names))
        let acc =
          list.fold(patterns, acc, fn(acc, p) { pattern_refs(p, bound, acc) })
        in_optional(clause.guard, bound, in_expr(clause.body, bound, acc))
      })

    glance.BinaryOperator(_, _name, left, right) ->
      in_expr(right, bound, in_expr(left, bound, acc))

    glance.Echo(_, expression, message) ->
      in_optional(message, bound, in_optional(expression, bound, acc))
  }
}

// Bound-name extraction
//
// The names a parameter or pattern introduces. These are the locals that
// shadow top-level definitions, and so are excluded from the references
// collected above.

fn assignment_name(name: glance.AssignmentName) -> List(String) {
  case name {
    glance.Named(n) -> [n]
    glance.Discarded(_) -> []
  }
}

fn param_names(param: glance.FunctionParameter) -> List(String) {
  assignment_name(param.name)
}

fn fn_param_names(param: glance.FnParameter) -> List(String) {
  assignment_name(param.name)
}

/// Every variable a pattern binds. Reference collection needs it to know which
/// names a clause's body sees locally; inference needs it to know which names a
/// pattern rebinds, since a rebound name is not narrowed.
pub fn pattern_names(pattern: glance.Pattern) -> List(String) {
  case pattern {
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..) -> []

    glance.PatternVariable(_, name) -> [name]

    glance.PatternTuple(_, elements) -> list.flat_map(elements, pattern_names)

    glance.PatternList(_, elements, tail) ->
      case tail {
        Some(t) ->
          list.append(list.flat_map(elements, pattern_names), pattern_names(t))
        None -> list.flat_map(elements, pattern_names)
      }

    glance.PatternAssignment(_, pattern, name) -> [
      name,
      ..pattern_names(pattern)
    ]

    glance.PatternConcatenate(_, _prefix, prefix_name, rest_name) ->
      list.append(
        case prefix_name {
          Some(n) -> assignment_name(n)
          None -> []
        },
        assignment_name(rest_name),
      )

    glance.PatternBitString(_, segments) ->
      list.flat_map(segments, fn(segment) { pattern_names(segment.0) })

    // A shorthand field in a constructor pattern (`Work(work:, receive:)`)
    // binds the label as a variable.
    glance.PatternVariant(_, _module, _constructor, arguments, _spread) ->
      list.flat_map(arguments, fn(field) {
        case field {
          glance.UnlabelledField(p) -> pattern_names(p)
          glance.LabelledField(_, _, p) -> pattern_names(p)
          glance.ShorthandField(label, _) -> [label]
        }
      })
  }
}

// Value references made *inside* a pattern. Patterns almost always only bind,
// but a bit-array segment size (glance 7.0+) is an expression that references
// already-bound variables or top-level constants (`<<v:size(len)>>`,
// `<<v:bytes-size(key_size)>>`). Those top-level references are real dependency
// edges — without them a constant used only as a pattern size is not ordered
// before its user and reads as unbound. `bound` already carries the pattern's
// own bindings, so a size naming a pattern-bound variable is dropped.
fn pattern_refs(pattern: glance.Pattern, bound: Set(String), acc: Acc) -> Acc {
  case pattern {
    glance.PatternTuple(_, elements) ->
      list.fold(elements, acc, fn(acc, p) { pattern_refs(p, bound, acc) })

    glance.PatternList(_, elements, tail) -> {
      let acc =
        list.fold(elements, acc, fn(acc, p) { pattern_refs(p, bound, acc) })
      case tail {
        Some(t) -> pattern_refs(t, bound, acc)
        None -> acc
      }
    }

    glance.PatternAssignment(_, pattern, _) -> pattern_refs(pattern, bound, acc)

    glance.PatternBitString(_, segments) ->
      list.fold(segments, acc, fn(acc, segment) {
        list.fold(segment.1, acc, fn(acc, option) {
          case option {
            glance.SizeValueOption(size) ->
              bit_array_size_refs(size, bound, acc)
            _ -> acc
          }
        })
      })

    glance.PatternVariant(_, _module, _constructor, arguments, _spread) ->
      list.fold(arguments, acc, fn(acc, field) {
        case field {
          glance.UnlabelledField(p) -> pattern_refs(p, bound, acc)
          glance.LabelledField(_, _, p) -> pattern_refs(p, bound, acc)
          glance.ShorthandField(_, _) -> acc
        }
      })

    // Leaf patterns and `PatternConcatenate` bind or match but reference nothing.
    _ -> acc
  }
}

// The top-level constants (or non-local variables) a bit-array pattern size
// refers to, filtered against the names already in scope.
fn bit_array_size_refs(
  size: glance.BitArraySize,
  bound: Set(String),
  acc: Acc,
) -> Acc {
  case size {
    glance.BitArraySizeInt(..) -> acc
    glance.BitArraySizeVariable(_, name) -> value(acc, bound, name)
    glance.BitArraySizeBinaryOperator(_, _, left, right) ->
      bit_array_size_refs(right, bound, bit_array_size_refs(left, bound, acc))
    glance.BitArraySizeBlock(_, inner) -> bit_array_size_refs(inner, bound, acc)
  }
}

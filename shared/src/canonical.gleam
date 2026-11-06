//// Canonical forms for Gleam custom types and functions.
//// Two definitions that differ only in names, labels, or order get the same
//// canonical string.
////
//// Dependencies: gleam_stdlib, glance, girard

import girard
import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// One definition in a module.
/// kind: 0 = custom type, 1 = function
/// start_pos, end_pos: byte offsets of the definition in the source.
pub type Entry {
  Entry(kind: Int, canonical: String, start_pos: Int, end_pos: Int)
}

/// Parse `source` and return an entry for each custom type and each function.
///
/// type Abc{ Abc1(a: Int, b: Int) Abc2(a: String, b: Int) }
/// type Xyz{ Xyz1(x: Int, y: String) Xyz2(x: Int, y: Int) }
///   both give "0:[[Int,Int],[Int,String]]"
///
/// fn add(a: Int, b: Int) -> Int          gives "fn:[Int,Int]->Int"
/// fn map(l: List(a), f: fn(a) -> b) -> List(b)
///                                        gives "fn:[List($0),fn($0)->$1]->List($1)"
///
/// A function with a missing type annotation gets its signature from girard,
/// the type inference library. If girard cannot type the module, each missing
/// type gives "_".
pub fn parse(source: String) -> Result(List(Entry), glance.Error) {
  use parsed <- result.try(glance.module(source))
  // Run girard only when a function needs it.
  let needs_inference =
    list.any(parsed.functions, fn(definition) {
      !fully_annotated(definition.definition)
    })
  let inferred = case needs_inference {
    True -> infer_signatures(parsed)
    False -> dict.new()
  }
  let types =
    list.map(parsed.custom_types, fn(definition) {
      let custom_type = definition.definition
      Entry(
        kind: 0,
        canonical: canonical_type(custom_type),
        start_pos: custom_type.location.start,
        end_pos: custom_type.location.end,
      )
    })
  let functions =
    list.map(parsed.functions, fn(definition) {
      let function = definition.definition
      Entry(
        kind: 1,
        canonical: case fully_annotated(function) {
          True -> canonical_function(function)
          False ->
            case dict.get(inferred, function.name) {
              Ok(form) -> form
              Error(_) -> canonical_function(function)
            }
        },
        start_pos: function.location.start,
        end_pos: function.location.end,
      )
    })
  Ok(list.append(types, functions))
}

fn canonical_type(custom_type: glance.CustomType) -> String {
  let arity = list.length(custom_type.parameters)
  // Try every order of the type parameters. Keep the smallest result.
  let body =
    custom_type.parameters
    |> list.permutations
    |> list.map(fn(names) {
      render_variants(custom_type.variants, number_parameters(names))
    })
    |> list.sort(string.compare)
    |> list.first
    |> result.unwrap("")
  int.to_string(arity) <> ":" <> body
}

fn canonical_function(function: glance.Function) -> String {
  let param_types =
    list.map(function.parameters, fn(parameter) { parameter.type_ })
  canonical_signature(param_types, function.return)
}

// Canonical form of a function signature. None means no type annotation.
fn canonical_signature(
  param_types: List(Option(glance.Type)),
  return_type: Option(glance.Type),
) -> String {
  // A function has no list of type variables. Collect them from the signature.
  let names =
    list.append(
      list.flat_map(param_types, option_variables),
      option_variables(return_type),
    )
    |> list.unique
  // Try every order of the type variables. Keep the smallest result.
  let body =
    names
    |> list.permutations
    |> list.map(fn(order) {
      render_function(param_types, return_type, number_parameters(order))
    })
    |> list.sort(string.compare)
    |> list.first
    |> result.unwrap("")
  "fn:" <> body
}

// Parameter names and labels are dropped. Parameter types are sorted.
// To keep the parameter order, remove the list.sort call.
fn render_function(
  param_types: List(Option(glance.Type)),
  return_type: Option(glance.Type),
  params: Dict(String, Int),
) -> String {
  let rendered =
    param_types
    |> list.map(render_option(_, params))
    |> list.sort(string.compare)
  "["
  <> string.join(rendered, ",")
  <> "]->"
  <> render_option(return_type, params)
}

// A missing type annotation gives "_".
fn render_option(
  type_: Option(glance.Type),
  params: Dict(String, Int),
) -> String {
  case type_ {
    Some(type_) -> render_type(type_, params)
    None -> "_"
  }
}

fn option_variables(type_: Option(glance.Type)) -> List(String) {
  case type_ {
    Some(type_) -> type_variables(type_)
    None -> []
  }
}

fn type_variables(type_: glance.Type) -> List(String) {
  case type_ {
    glance.NamedType(parameters: args, ..) ->
      list.flat_map(args, type_variables)
    glance.TupleType(elements: elements, ..) ->
      list.flat_map(elements, type_variables)
    glance.FunctionType(parameters: args, return: return, ..) ->
      list.append(list.flat_map(args, type_variables), type_variables(return))
    glance.VariableType(name: name, ..) -> [name]
    glance.HoleType(..) -> []
  }
}

fn number_parameters(names: List(String)) -> Dict(String, Int) {
  names
  |> list.index_map(fn(name, index) { #(name, index) })
  |> dict.from_list
}

fn render_variants(
  variants: List(glance.Variant),
  params: Dict(String, Int),
) -> String {
  let rendered =
    variants
    |> list.map(render_variant(_, params))
    |> list.sort(string.compare)
  "[" <> string.join(rendered, ",") <> "]"
}

// Variant names and field labels are dropped. Field types are sorted.
fn render_variant(
  variant: glance.Variant,
  params: Dict(String, Int),
) -> String {
  let fields =
    variant.fields
    |> list.map(fn(field) { render_type(field_type(field), params) })
    |> list.sort(string.compare)
  "[" <> string.join(fields, ",") <> "]"
}

fn field_type(field: glance.VariantField) -> glance.Type {
  case field {
    glance.LabelledVariantField(item: item, ..) -> item
    glance.UnlabelledVariantField(item: item) -> item
  }
}

fn render_type(type_: glance.Type, params: Dict(String, Int)) -> String {
  case type_ {
    // The module qualifier is ignored on purpose.
    glance.NamedType(name: name, parameters: args, ..) ->
      case args {
        [] -> name
        _ -> name <> "(" <> render_list(args, params) <> ")"
      }
    glance.TupleType(elements: elements, ..) ->
      "#(" <> render_list(elements, params) <> ")"
    glance.FunctionType(parameters: args, return: return, ..) ->
      "fn(" <> render_list(args, params) <> ")->" <> render_type(return, params)
    glance.VariableType(name: name, ..) ->
      case dict.get(params, name) {
        Ok(number) -> "$" <> int.to_string(number)
        Error(_) -> "$" <> name
      }
    glance.HoleType(..) -> "_"
  }
}

fn render_list(types: List(glance.Type), params: Dict(String, Int)) -> String {
  types
  |> list.map(render_type(_, params))
  |> string.join(",")
}

// True when every parameter and the return type have an annotation.
fn fully_annotated(function: glance.Function) -> Bool {
  option.is_some(function.return)
  && list.all(function.parameters, fn(parameter) {
    option.is_some(parameter.type_)
  })
}

// Infer the types of the functions with girard. Return a dict from function
// name to canonical form. The dict is empty if girard cannot type the module.
// No imports are resolved, so a module that imports other modules may fail.
fn infer_signatures(module: glance.Module) -> Dict(String, String) {
  let options =
    girard.default_options()
    |> girard.with_resolver(fn(_) { Error(Nil) })
  case girard.annotate_module(module, options) {
    Ok(annotated) ->
      annotated.functions
      |> list.filter_map(fn(entry) {
        let #(name, scheme) = entry
        case scheme.type_ {
          girard.Fn(arguments: arguments, return: return) ->
            Ok(#(
              name,
              canonical_signature(
                list.map(arguments, fn(argument) { Some(from_girard(argument)) }),
                Some(from_girard(return)),
              ),
            ))
          _ -> Error(Nil)
        }
      })
      |> dict.from_list
    Error(_) -> dict.new()
  }
}

// Convert a girard type to a glance type, so that one renderer is used for
// all. A type variable id becomes the name "v<id>".
fn from_girard(type_: girard.Type) -> glance.Type {
  let span = glance.Span(start: 0, end: 0)
  case type_ {
    girard.Named(name: name, arguments: arguments, ..) ->
      glance.NamedType(
        location: span,
        name: name,
        module: None,
        parameters: list.map(arguments, from_girard),
      )
    girard.Var(id: id) ->
      glance.VariableType(location: span, name: "v" <> int.to_string(id))
    girard.Tuple(elements: elements) ->
      glance.TupleType(
        location: span,
        elements: list.map(elements, from_girard),
      )
    girard.Fn(arguments: arguments, return: return) ->
      glance.FunctionType(
        location: span,
        parameters: list.map(arguments, from_girard),
        return: from_girard(return),
      )
  }
}

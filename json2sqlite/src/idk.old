//// Download the first "good" Hex package from already_read.json and add its
//// modules and the canonical forms of their types and functions to a SQLite db.
////
//// Create the db first: sqlite3 packages.db < schema.sql
//// Dependencies: gleam_stdlib, glance, gleam_json, gleam_package_interface,
////               gleam_http, gleam_httpc, gleam_time, star, sqlight

import glance
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/package_interface
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import sqlight
import star

const db_path = "packages.db"

const already_read_url = "https://bucket.correctarity.com/already_read.json"

const upsert_package_sql =
  "
INSERT INTO packages (name, description, repository, updated_at, owners,
                      total_downloads, recent_downloads, latest_version)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (name) DO UPDATE SET
  description      = excluded.description,
  repository       = excluded.repository,
  updated_at       = excluded.updated_at,
  owners           = excluded.owners,
  total_downloads  = excluded.total_downloads,
  recent_downloads = excluded.recent_downloads,
  latest_version   = excluded.latest_version
RETURNING id"

const select_updated_at = "SELECT updated_at FROM packages WHERE name = ?"

const insert_module =
  "INSERT INTO modules (package_id, name, source) VALUES (?, ?, ?) RETURNING id"

// The definitions_in view makes the canonical form when it does not exist.
const insert_definition =
  "INSERT INTO definitions_in (module_id, kind, canonical, start_pos, end_pos) VALUES (?, ?, ?, ?, ?)"

/// A Hex package, as listed in already_read.json.
pub type Package {
  Package(
    name: String,
    description: String,
    repository: Option(String),
    updated_at: Timestamp,
    owners: List(String),
    total_downloads: Int,
    recent_downloads: Int,
    latest_version: String,
  )
}

pub fn package_decoder() -> decode.Decoder(Package) {
  use name <- decode.field("name", decode.string)
  use description <- decode.field("description", decode.string)
  use repository <- decode.field("repository", decode.optional(decode.string))
  use updated_at <- decode.field(
    "updated-at",
    decode.int |> decode.map(timestamp.from_unix_seconds),
  )
  use owners <- decode.field("owners", decode.list(decode.string))
  use total_downloads <- decode.field("total-downloads", decode.int)
  use recent_downloads <- decode.field("recent-downloads", decode.int)
  use latest_version <- decode.field("latest-version", decode.string)
  decode.success(Package(
    name:,
    description:,
    repository:,
    updated_at:,
    owners:,
    total_downloads:,
    recent_downloads:,
    latest_version:,
  ))
}

fn unix_seconds(time: Timestamp) -> Int {
  time |> timestamp.to_unix_seconds |> float.round
}

/// One definition in a module.
/// kind: 0 = custom type, 1 = function
type Entry {
  Entry(kind: Int, canonical: String, start_pos: Int, end_pos: Int)
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  case all_packages() {
    Ok(packages) -> list.each(packages, process)
    Error(message) -> io.println("Error: " <> message)
  }
}

// An error in one package does not stop the others.
fn process(package: Package) -> Nil {
  case update(package) {
    Ok(message) -> io.println(message)
    Error(message) -> io.println("Error: " <> package.name <> ": " <> message)
  }
}

fn update(package: Package) -> Result(String, String) {
  let label = package.name <> " " <> package.latest_version
  use current <- result.try(
    is_current(package) |> result.map_error(string.inspect),
  )
  case current {
    True -> Ok("Skipped " <> label <> ": already up to date")
    False -> {
      use count <- result.try(add_package(package))
      Ok("Added " <> int.to_string(count) <> " definition(s) for " <> label)
    }
  }
}

// All packages in the "good" list of already_read.json.
fn all_packages() -> Result(List(Package), String) {
  use bits <- result.try(fetch(already_read_url))
  use text <- result.try(
    bit_array.to_string(bits)
    |> result.replace_error("already_read.json is not text"),
  )
  json.parse(text, using: {
    use good <- decode.field("good", decode.list(package_decoder()))
    decode.success(good)
  })
  |> result.map_error(string.inspect)
}

fn add_package(package: Package) -> Result(Int, String) {
  let interface_url =
    "https://"
    <> string.replace(package.name, "_", "-")
    <> ".hexdocs.pm/"
    <> package.latest_version
    <> "/package-interface.json"
  let tarball_url =
    "https://repo.hex.pm/tarballs/"
    <> package.name
    <> "-"
    <> package.latest_version
    <> ".tar"

  // Interface: the types that the compiler inferred.
  use interface_bits <- result.try(fetch(interface_url))
  use interface_text <- result.try(
    bit_array.to_string(interface_bits)
    |> result.replace_error("The interface is not text"),
  )
  use interface <- result.try(parse_interface(interface_text))

  // Source: the files that we cut the original text from.
  use tarball <- result.try(fetch(tarball_url))
  use files <- result.try(source_files(tarball))

  use modules <- result.try(
    list.try_map(files, fn(file) {
      let #(path, source) = file
      // "src/gleam/httpc.gleam" -> "gleam/httpc"
      let module_path = path |> string.drop_start(4) |> string.drop_end(6)
      let signatures = interface_signatures(interface, module_path)
      use entries <- result.try(
        canonical_all(source, signatures)
        |> result.map_error(string.inspect),
      )
      Ok(#(module_path, source, entries))
    }),
  )

  sqlight.with_connection(db_path, store_package(_, package, modules))
  |> result.map_error(string.inspect)
}

// ---------------------------------------------------------------------------
// Download
// ---------------------------------------------------------------------------

fn fetch(url: String) -> Result(BitArray, String) {
  use req <- result.try(
    request.to(url)
    |> result.replace_error("Bad URL: " <> url),
  )
  use resp <- result.try(
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.dispatch_bits(request.set_body(req, <<>>))
    |> result.map_error(string.inspect),
  )
  case resp.status {
    200 -> Ok(resp.body)
    status -> Error("HTTP " <> int.to_string(status) <> " for " <> url)
  }
}

// A Hex tarball is a tar file. It holds contents.tar.gz, and that holds src/.
// Return the path and text of each src/*.gleam file.
fn source_files(tarball: BitArray) -> Result(List(#(String, String)), String) {
  use outer <- result.try(
    star.extract_memory(
      from: star.FromData(tarball),
      compression: star.Uncompressed,
      filter: star.Only(["contents.tar.gz"]),
    )
    |> result.map_error(string.inspect),
  )
  use archive <- result.try(
    list.first(outer)
    |> result.replace_error("contents.tar.gz not found"),
  )
  use entries <- result.try(
    star.extract_memory(
      from: star.FromData(archive.contents),
      compression: star.Gzip,
      filter: star.AllEntries,
    )
    |> result.map_error(string.inspect),
  )
  entries
  |> list.filter_map(fn(entry) {
    let name = entry.header.name
    case string.starts_with(name, "src/") && string.ends_with(name, ".gleam") {
      True ->
        bit_array.to_string(entry.contents)
        |> result.map(fn(source) { #(name, source) })
      False -> Error(Nil)
    }
  })
  |> Ok
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

// True when the db has this package with the same updated_at.
fn is_current(package: Package) -> Result(Bool, sqlight.Error) {
  sqlight.with_connection(db_path, fn(conn) {
    use found <- result.try(sqlight.query(
      select_updated_at,
      on: conn,
      with: [sqlight.text(package.name)],
      expecting: id_decoder(),
    ))
    Ok(found == [unix_seconds(package.updated_at)])
  })
}

fn store_package(
  conn: sqlight.Connection,
  package: Package,
  modules: List(#(String, String, List(Entry))),
) -> Result(Int, sqlight.Error) {
  // Foreign keys must be on, so that deletes cascade.
  use _ <- result.try(sqlight.exec("PRAGMA foreign_keys = ON", conn))
  use _ <- result.try(sqlight.exec("BEGIN", conn))
  case store_all(conn, package, modules) {
    Ok(count) -> sqlight.exec("COMMIT", conn) |> result.replace(count)
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", conn)
      Error(error)
    }
  }
}

fn store_all(
  conn: sqlight.Connection,
  package: Package,
  modules: List(#(String, String, List(Entry))),
) -> Result(Int, sqlight.Error) {
  // A new updated_at makes a trigger delete the old modules.
  use package_id <- result.try(upsert_package(conn, package))
  use counts <- result.try(
    list.try_map(modules, fn(module) {
      let #(name, source, entries) = module
      store_module(conn, package_id, name, source, entries)
    }),
  )
  Ok(int.sum(counts))
}

fn upsert_package(
  conn: sqlight.Connection,
  package: Package,
) -> Result(Int, sqlight.Error) {
  use ids <- result.try(sqlight.query(
    upsert_package_sql,
    on: conn,
    with: [
      sqlight.text(package.name),
      sqlight.text(package.description),
      sqlight.nullable(sqlight.text, package.repository),
      sqlight.int(unix_seconds(package.updated_at)),
      sqlight.text(string.join(package.owners, " ")),
      sqlight.int(package.total_downloads),
      sqlight.int(package.recent_downloads),
      sqlight.text(package.latest_version),
    ],
    expecting: id_decoder(),
  ))
  let assert [id, ..] = ids
  Ok(id)
}

fn store_module(
  conn: sqlight.Connection,
  package_id: Int,
  name: String,
  source: String,
  entries: List(Entry),
) -> Result(Int, sqlight.Error) {
  use ids <- result.try(sqlight.query(
    insert_module,
    on: conn,
    with: [sqlight.int(package_id), sqlight.text(name), sqlight.text(source)],
    expecting: id_decoder(),
  ))
  let assert [module_id, ..] = ids

  use _ <- result.try(
    list.try_each(entries, fn(entry) {
      sqlight.query(
        insert_definition,
        on: conn,
        with: [
          sqlight.int(module_id),
          sqlight.int(entry.kind),
          sqlight.text(entry.canonical),
          sqlight.int(entry.start_pos),
          sqlight.int(entry.end_pos + 1),
        ],
        expecting: decode.success(Nil),
      )
      |> result.replace(Nil)
    }),
  )
  Ok(list.length(entries))
}

fn id_decoder() -> decode.Decoder(Int) {
  use id <- decode.field(0, decode.int)
  decode.success(id)
}

// ---------------------------------------------------------------------------
// Package interface: function forms from the types that the compiler inferred
// ---------------------------------------------------------------------------

fn parse_interface(text: String) -> Result(package_interface.Package, String) {
  json.parse(text, using: package_interface.decoder())
  |> result.map_error(string.inspect)
}

// A dict from function name to canonical form for one module.
// The interface has only public functions. A module that is not in the
// interface gives an empty dict.
fn interface_signatures(
  package: package_interface.Package,
  module_name: String,
) -> Dict(String, String) {
  case dict.get(package.modules, module_name) {
    Ok(module) ->
      dict.map_values(module.functions, fn(_, function) {
        interface_signature(function)
      })
    Error(_) -> dict.new()
  }
}

fn interface_signature(function: package_interface.Function) -> String {
  let param_types =
    list.map(function.parameters, fn(parameter) {
      Some(convert(parameter.type_))
    })
  canonical_signature(param_types, Some(convert(function.return)))
}

// Convert an interface type to a glance type, so that one renderer is used
// for both. A type variable id becomes the name "v<id>".
fn convert(type_: package_interface.Type) -> glance.Type {
  let span = glance.Span(start: 0, end: 0)
  case type_ {
    package_interface.Named(name: name, parameters: parameters, ..) ->
      glance.NamedType(
        location: span,
        name: name,
        module: None,
        parameters: list.map(parameters, convert),
      )
    package_interface.Variable(id: id) ->
      glance.VariableType(location: span, name: "v" <> int.to_string(id))
    package_interface.Tuple(elements: elements) ->
      glance.TupleType(location: span, elements: list.map(elements, convert))
    package_interface.Fn(parameters: parameters, return: return) ->
      glance.FunctionType(
        location: span,
        parameters: list.map(parameters, convert),
        return: convert(return),
      )
  }
}

// ---------------------------------------------------------------------------
// Canonical forms
// ---------------------------------------------------------------------------

// Parse `source` and return an entry for each custom type and each function.
// `signatures` maps function names to forms from the package interface.
// Pass dict.new() to use only the annotations in the source.
//
// type Abc{ Abc1(a: Int, b: Int) Abc2(a: String, b: Int) }
// type Xyz{ Xyz1(x: Int, y: String) Xyz2(x: Int, y: Int) }
//   both give "0:[[Int,Int],[Int,String]]"
//
// fn add(a: Int, b: Int) -> Int          gives "fn:[Int,Int]->Int"
// fn map(l: List(a), f: fn(a) -> b) -> List(b)
//                                        gives "fn:[List($0),fn($0)->$1]->List($1)"
fn canonical_all(
  source: String,
  signatures: Dict(String, String),
) -> Result(List(Entry), glance.Error) {
  use parsed <- result.try(glance.module(source))
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
        // Use the form from the package interface when it has this function.
        canonical: case dict.get(signatures, function.name) {
          Ok(form) -> form
          Error(_) -> canonical_function(function)
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

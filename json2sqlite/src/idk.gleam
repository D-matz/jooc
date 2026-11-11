//// Download the first "good" Hex package from already_read.json and add its
//// modules and the canonical forms of their types and functions to a SQLite db.
////
//// Create the db first: sqlite3 packages.db < schema.sql
//// Dependencies: gleam_stdlib, glance, girard, gleam_json,
////               gleam_package_interface, gleam_http, gleam_httpc, gleam_time,
////               star, sqlight

import argv
import bucket
import bucket/put_object
import canonical
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
import simplifile
import sqlight
import star

const db_path = "packages.sqlite"

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

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  case argv.load().arguments {
    [credentials] -> {
      case all_packages() {
        Ok(packages) -> list.each(packages, process)
        Error(message) -> io.println("Error: " <> message)
      }
      upload(credentials)
      io.println("Uploaded " <> db_path)
    }
    _ -> io.println("Usage: gleam run ACCESS_KEY_ID,SECRET_ACCESS_KEY")
  }
}

fn upload(credentials: String) -> Nil {
  let assert Ok(#(access_key_id, secret_access_key)) =
    string.split_once(credentials, ",")
    as "Use the format ACCESS_KEY_ID,SECRET_ACCESS_KEY"

  let creds =
    bucket.credentials(
      "21d22098b8563166bdc93387685252e4.r2.cloudflarestorage.com",
      access_key_id,
      secret_access_key,
    )
    |> bucket.with_region("auto")

  let assert Ok(data) = simplifile.read_bits(db_path) as "Cannot read the db"

  let request =
    put_object.request(bucket: "pkglist", key: db_path, body: data)
    |> put_object.build(creds)

  let assert Ok(response) = httpc.send_bits(request)
    as "Cannot send the request"
  let assert Ok(_) = put_object.response(response) as "The upload failed"
  Nil
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
        module_entries(source, signatures)
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
  modules: List(#(String, String, List(canonical.Entry))),
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
  modules: List(#(String, String, List(canonical.Entry))),
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
  entries: List(canonical.Entry),
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
  canonical.canonical_signature(param_types, Some(convert(function.return)))
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
// Entries: interface forms first, canonical.parse only when needed
// ---------------------------------------------------------------------------

// canonical.parse is needed for custom types and for functions that the
// interface does not have (private functions). When the module has none of
// these, the entries come from the interface alone.
fn module_entries(
  source: String,
  signatures: Dict(String, String),
) -> Result(List(canonical.Entry), glance.Error) {
  use parsed <- result.try(glance.module(source))
  let all_in_interface =
    list.all(parsed.functions, fn(definition) {
      dict.has_key(signatures, definition.definition.name)
    })
  case parsed.custom_types, all_in_interface {
    [], True ->
      Ok(
        list.map(parsed.functions, fn(definition) {
          let function = definition.definition
          canonical.Entry(
            kind: 1,
            canonical: dict.get(signatures, function.name)
              |> result.unwrap(""),
            start_pos: function.location.start,
            end_pos: function.location.end,
          )
        }),
      )
    _, _ ->
      canonical.parse(source)
      |> result.map(with_signatures(_, parsed, signatures))
  }
}

// Replace the form of each function that has an interface form.
// An entry is matched to its function by start position.
fn with_signatures(
  entries: List(canonical.Entry),
  parsed: glance.Module,
  signatures: Dict(String, String),
) -> List(canonical.Entry) {
  let names =
    parsed.functions
    |> list.map(fn(definition) {
      #(definition.definition.location.start, definition.definition.name)
    })
    |> dict.from_list
  list.map(entries, fn(entry) {
    let form = case entry.kind, dict.get(names, entry.start_pos) {
      1, Ok(name) -> dict.get(signatures, name)
      _, _ -> Error(Nil)
    }
    case form {
      Ok(form) -> canonical.Entry(..entry, canonical: form)
      Error(_) -> entry
    }
  })
}

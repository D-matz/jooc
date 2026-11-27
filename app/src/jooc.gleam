import canonical
import edit_distance
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import localstorage
import lustre
import lustre/attribute as a
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event
import modem
import range_map
import rsvp
import sql
import sqlite
import storage
import streamer
import timeago

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

type Model {
  Model(
    database: Db,
    search_result: List(SearchResult),
    lucy: Search,
    all_pkg_names: List(String),
    search_text: String,
    auto_download_sqlite: Bool,
  )
}

type SearchResult {
  SearchResult(package: storage.Package, snippet: List(ModuleSnippet))
}

type ModuleSnippet {
  ModuleSnippet(module_name: String, snippet: Snippet)
}

type Snippet {
  FuzzyMatch(before: String, match: String, after: String)
  Definitions(definitions: List(String))
}

type Db {
  DbLoading
  DbLoaded(PkgDb)
  DbError(String)
}

type PkgDb {
  Metadata(db: List(PackageLowercase), loading_percent: Option(Float))
  Code(db: sqlite.Database)
}

type PackageLowercase {
  PackageLowercase(
    package: storage.Package,
    name: String,
    description: String,
    owners: List(String),
  )
}

type Search {
  Searching
  NotSearching
}

const metadata_src_json = "https://bucket.correctarity.com/good.json"

const data_src = "https://bucket.correctarity.com/packages.sqlite"

fn init(_) -> #(Model, Effect(Msg)) {
  let query_from_initial_uri = case modem.initial_uri() {
    Ok(initial_uri) ->
      case initial_uri.query {
        Some(initial_uri_query) ->
          case uri.percent_decode(initial_uri_query) {
            Ok(initial_uri_query) -> Some(initial_uri_query)
            Error(_) -> None
          }
        None -> None
      }
    Error(_) -> None
  }
  #(
    Model(
      DbLoading,
      [],
      NotSearching,
      [],
      option.unwrap(query_from_initial_uri, ""),
      localstorage.get_autodownload(),
    ),
    sqlite.check_cached_etag(CacheReturnedEtag),
  )
}

type Msg {
  CacheReturnedEtag(Result(String, Nil))
  ServerReturnedEtag(
    cached: String,
    result: Result(response.Response(String), rsvp.Error(String)),
  )
  CacheLoaded(Result(BitArray, Nil))
  ServerReturnedMetadata(Result(List(storage.Package), rsvp.Error(String)))
  UserClickedDownloadCode
  ServerReturnedCode(Result(Response(BitArray), rsvp.Error(BitArray)))
  ServerReturnedLoadProgress(Float)
  SqliteReturnedOpen(Result(sqlite.Database, String))
  SqliteReturnedQuery(
    query_was: SqliteQuery,
    search_text_was: String,
    got: Result(Dynamic, String),
  )
  UserTypedQuery(String)
  UserClickedButton(String)
  UserCheckedAutomaticallyDownloadSqlite(Bool)
}

type SqliteQuery {
  Names
  Query(SqliteSearch)
}

type SqliteSearch {
  Canonical
  Fuzzy
}

type AutomaticallyDownloadSqlite {
  AutomaticallyDownload
  DoNotDownloadUnlessClicked
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    CacheReturnedEtag(cached_etag) ->
      case cached_etag {
        Ok(cached_etag) -> {
          let assert Ok(req) = request.to(data_src)
          let get_server_etag =
            req
            |> request.set_method(http.Head)
            |> rsvp.send(
              rsvp.expect_ok_response(fn(result) {
                ServerReturnedEtag(cached_etag, result)
              }),
            )
          #(model, get_server_etag)
        }
        Error(_) -> download_server_json(model)
      }
    ServerReturnedEtag(cached_etag, server_response) ->
      case server_response {
        Error(_) -> download_server_json(model)
        Ok(server_response) ->
          case server_response |> response.get_header("etag") {
            Ok(server_etag) ->
              case server_etag == cached_etag {
                True -> #(model, sqlite.load_cached(CacheLoaded))
                False -> download_server_json(model)
              }
            Error(_) -> download_server_json(model)
          }
      }
    CacheLoaded(Ok(cache_data)) -> open_db(model, cache_data)
    CacheLoaded(Error(_)) -> download_server_json(model)
    UserClickedDownloadCode -> download_server_db(model)
    ServerReturnedCode(load_result) ->
      case load_result {
        Ok(resp) -> {
          // we rely on having etag to save db so we will know if there is newer version
          let save = case response.get_header(resp, "etag") {
            Ok(etag) -> sqlite.save_cached(etag, resp.body)
            Error(_) -> effect.none()
          }
          let #(model, open) = open_db(model, resp.body)
          #(model, effect.batch([save, open]))
        }
        Error(err) -> {
          echo err
          let model =
            Model(
              ..model,
              database: DbError(
                "Failed to load package database from "
                <> data_src
                <> ". Maybe the database is no longer available. You could try checking connection and reloading.",
              ),
            )
          #(model, effect.none())
        }
      }
    ServerReturnedMetadata(load_result) ->
      case load_result {
        Ok(resp) -> {
          let resp =
            list.sort(resp, fn(a, b) {
              timestamp.compare(a.updated_at, b.updated_at) |> order.negate
            })
            |> list.map(fn(pkg) {
              PackageLowercase(
                pkg,
                name: string.lowercase(pkg.name),
                description: string.lowercase(pkg.description),
                owners: list.map(pkg.owners, string.lowercase),
              )
            })
          let all_pkg_names = list.map(resp, fn(pkg) { pkg.name })
          let model =
            Model(
              ..model,
              database: DbLoaded(Metadata(db: resp, loading_percent: None)),
              all_pkg_names:,
            )
          let search_result = search_metadata(resp, model.search_text)
          let model = Model(..model, search_result:)

          case localstorage.get_autodownload() {
            True -> download_server_db(model)
            False -> #(model, effect.none())
          }
        }
        Error(err) -> {
          echo err
          let model =
            Model(
              ..model,
              database: DbError(
                "Failed to load metadata json from "
                <> metadata_src_json
                <> ". Maybe good.json is no longer available. You could try checking connection and reloading.",
              ),
            )
          #(model, effect.none())
        }
      }
    SqliteReturnedOpen(Error(_)) -> panic as "db open failed xdd"
    SqliteReturnedOpen(Ok(db)) -> {
      let model = Model(..model, database: DbLoaded(Code(db)))
      case model.all_pkg_names {
        [] -> {
          let get_all_pkg_names =
            sqlite.query(db, sql.all_pkgs_by_recent, [], SqliteReturnedQuery(
              Names,
              model.search_text,
              _,
            ))
          #(model, get_all_pkg_names)
        }
        _ -> text_to_query(model.search_text, model)
      }
    }

    SqliteReturnedQuery(Names, _, got) -> {
      let all_pkg_names = case got {
        Ok(rows) ->
          case decode.run(rows, decode.list(canonical_result_decoder())) {
            Ok(rows) ->
              rows |> result.values |> list.map(fn(p) { p.package.name })
            Error(_) -> []
          }
        Error(_) -> []
      }
      text_to_query(model.search_text, Model(..model, all_pkg_names:))
    }
    SqliteReturnedQuery(Query(query_was), search_text_was, got) ->
      case search_text_was == model.search_text {
        False -> #(model, effect.none())
        True -> {
          let decoder = case query_was {
            Fuzzy -> decode.list(search_result_decoder(search_text_was))
            Canonical -> decode.list(canonical_result_decoder())
          }
          handle_query_result(model, got, decoder)
        }
      }

    UserTypedQuery(text) -> text_to_query(text, model)
    UserClickedButton(premade_query) -> {
      let exec = case model.database {
        DbLoaded(Code(db)) -> {
          sqlite.query(db, premade_query, [], SqliteReturnedQuery(
            Query(Fuzzy),
            "",
            _,
          ))
        }
        _ -> effect.none()
      }
      let model = Model(..model, lucy: Searching, search_text: "")
      #(model, exec)
    }
    ServerReturnedLoadProgress(progress) ->
      case model.database {
        DbLoaded(Metadata(_old_load_percent, db:)) -> {
          let database =
            DbLoaded(Metadata(db:, loading_percent: Some(progress)))
          let model = Model(..model, database:)
          #(model, effect.none())
        }
        _ -> #(model, effect.none())
      }
    UserCheckedAutomaticallyDownloadSqlite(auto_download_sqlite) -> {
      let model = Model(..model, auto_download_sqlite:)
      let save_pref =
        effect.from(fn(_) {
          localstorage.set_autodownload(auto_download_sqlite)
        })
      #(model, save_pref)
    }
  }
}

fn handle_query_result(
  model: Model,
  query_result: Result(Dynamic, String),
  decoder: decode.Decoder(List(Result(SearchResult, Nil))),
) -> #(Model, Effect(Msg)) {
  let search_result =
    case query_result {
      Ok(query_resp) ->
        case decode.run(query_resp, decoder) {
          Ok(resp) -> resp
          Error(err) -> {
            echo err
            []
          }
        }
      Error(err) -> {
        echo err
        []
      }
    }
    |> result.values
    |> merge_modules_by_package
  #(Model(..model, search_result:, lucy: NotSearching), effect.none())
}

fn open_db(model: Model, sqlite_db: BitArray) -> #(Model, Effect(Msg)) {
  #(model, sqlite.open(sqlite_db, SqliteReturnedOpen))
}

fn download_server_db(model: Model) {
  case model.database {
    DbLoaded(Metadata(_loading_percent, db:)) -> {
      let loading_percent = Some(0.0)
      // (0.0)
      let model =
        Model(..model, database: DbLoaded(Metadata(db:, loading_percent:)))
      let assert Ok(req) = request.to(data_src)
      let download_effect =
        req
        |> request.set_body(<<>>)
        |> streamer.load_bits(ServerReturnedLoadProgress, ServerReturnedCode)
      #(model, download_effect)
    }
    _ -> {
      echo "should not be able to download server db from anything other than already have json"
      #(model, effect.none())
    }
  }
}

fn download_server_json(model) {
  let assert Ok(req) = request.to(metadata_src_json)
  let handler =
    rsvp.expect_json(
      decode.list(storage.package_decoder()),
      ServerReturnedMetadata,
    )
  let download_effect =
    req
    |> rsvp.send(handler)
  #(model, download_effect)
}

// usually query text is from the user typing, but could also be from initial url
fn text_to_query(text, model) {
  let push_url = modem.push("", Some(uri.percent_encode(text)), None)
  let model = Model(..model, search_text: text)
  let text = string.trim(text)
  case model.database {
    DbLoaded(Code(db)) -> {
      let chars = string.to_graphemes(text)
      let exec = case chars {
        [] ->
          sqlite.query(db, sql.all_pkgs_by_recent, [], SqliteReturnedQuery(
            Query(Fuzzy),
            model.search_text,
            _,
          ))
        [_] | [_, _] ->
          sqlite.query(
            db,
            sql.info_only,
            [text, text, text],
            SqliteReturnedQuery(Query(Fuzzy), model.search_text, _),
          )
        [_, _, ..] -> {
          case parse_type_or_fn(chars) {
            Ok(canonical) ->
              sqlite.query(db, sql.canonical, [canonical], SqliteReturnedQuery(
                Query(Canonical),
                model.search_text,
                _,
              ))
            Error(_) -> {
              let bm25_threshold = text |> string.length
              let bm25_threshold =
                float.to_string(8.0 -. { int.to_float(bm25_threshold) *. 1.5 })
              sqlite.query(
                db,
                sql.code_and_package,
                [
                  text,
                  query_to_trigrams(text),
                  text
                    |> similar_pkg_names(model.all_pkg_names)
                    |> json.array(json.string)
                    |> json.to_string,
                  bm25_threshold,
                ],
                SqliteReturnedQuery(Query(Fuzzy), model.search_text, _),
              )
            }
          }
        }
      }
      let effect = effect.batch([exec, push_url])
      let model = Model(..model, lucy: Searching)
      #(model, effect)
    }
    DbLoaded(Metadata(_, db:)) -> {
      let search_result = search_metadata(db, text)
      let model = Model(..model, search_result:)
      #(model, push_url)
    }
    _ -> #(model, effect.none())
  }
}

fn search_metadata(
  db: List(PackageLowercase),
  text: String,
) -> List(SearchResult) {
  let text = string.lowercase(text)
  let contains_user_text = fn(check) { check |> string.contains(text) }
  list.filter(db, fn(pkg) {
    pkg.name |> contains_user_text
    || pkg.description |> contains_user_text
    || pkg.owners
    |> list.any(contains_user_text)
  })
  |> list.map(fn(pkg) { SearchResult(pkg.package, []) })
}

// see if we can parse the user's query into a type or function
fn parse_type_or_fn(query_chars: List(String)) -> Result(String, Nil) {
  // fn parser doesnt like anonymous fn
  // so we help out eg fn(x){x+1} -> fn w(x){x+1}
  let query_chars = case query_chars {
    ["f", "n", "(", ..rest]
    | ["f", "n", " ", "(", ..rest]
    | ["f", "n", " ", " ", "(", ..rest] -> {
      Ok(["f", "n", " ", "w", "(", ..rest])
    }
    ["{", ..rest] -> Ok(["t", "y", "p", "e", " ", "W", "{", ..rest])
    ["f", "n", ..]
    | ["p", "u", "b", " ", "f", "n", ..]
    | ["t", "y", "p", "e", ..]
    | ["p", "u", "b", " ", "t", "y", "p", "e", ..] -> Ok(query_chars)
    _ -> Error(Nil)
  }
  let parsed = case query_chars {
    Error(Nil) -> Error(Nil)
    Ok(query_chars) ->
      case query_chars |> string.concat |> canonical.parse {
        Ok(canonical) -> Ok(canonical)
        Error(_) -> Error(Nil)
      }
  }
  case parsed {
    Ok([parsed]) -> Ok(parsed.canonical)
    _ -> Error(Nil)
  }
}

fn query_to_trigrams(query: String) -> String {
  query
  |> string.lowercase
  |> string.to_graphemes
  |> list.window(3)
  |> list.map(fn(w) {
    "\"" <> string.replace(string.concat(w), "\"", "\"\"") <> "\""
  })
  |> list.unique
  |> string.join(" OR ")
}

fn search_result_decoder(
  search_text: String,
) -> decode.Decoder(Result(SearchResult, Nil)) {
  use name <- decode.field(0, decode.string)
  use description <- decode.field(1, decode.string)
  use repository <- decode.field(2, decode.optional(decode.string))
  use updated_at <- decode.field(3, decode.int)
  use owners <- decode.field(4, decode.string)
  use total_downloads <- decode.field(5, decode.int)
  use recent_downloads <- decode.field(6, decode.int)
  use latest_version <- decode.field(7, decode.string)
  use module_name <- decode.field(8, decode.optional(decode.string))
  use code <- decode.field(9, decode.optional(decode.string))
  let package =
    storage.Package(
      name:,
      description:,
      repository:,
      updated_at: timestamp.from_unix_seconds(updated_at),
      owners: owners |> string.split(" ") |> list.filter(fn(o) { o != "" }),
      total_downloads:,
      recent_downloads:,
      latest_version:,
    )
  case module_name, code {
    Some(module_name), Some(code) ->
      case parse_code(code, search_text) {
        Ok(match) ->
          decode.success(
            Ok(
              SearchResult(package:, snippet: [
                ModuleSnippet(module_name, match),
              ]),
            ),
          )
        Error(_) -> decode.success(Error(Nil))
      }
    _, _ -> {
      let search = string.lowercase(search_text)
      let acceptable_distance = case string.length(search_text) {
        n if n <= 4 -> 1
        n if n <= 9 -> 2
        n if n <= 13 -> 3
        n if n <= 20 -> 4
        n if n <= 50 -> 5
        _ -> 6
      }
      let matches =
        similar_pkg_names(search_text, [name]) != []
        || list.any([name, owners, description], fn(field) {
          fuzzy_contains(string.lowercase(field), search, acceptable_distance)
        })
      case matches {
        True -> decode.success(Ok(SearchResult(package:, snippet: [])))
        False -> decode.success(Error(Nil))
      }
    }
  }
}

fn fuzzy_contains(text: String, search: String, distance: Int) -> Bool {
  let window = string.slice(text, 0, string.length(search))
  edit_distance.levenshtein(window, search) <= distance
  || case text {
    "" -> False
    _ -> fuzzy_contains(string.drop_start(text, 1), search, distance)
  }
}

fn parse_code(code: String, search_text: String) -> Result(Snippet, Nil) {
  let acceptable_distance = case string.length(search_text) {
    n if n <= 4 -> 0
    n if n <= 9 -> 1
    n if n <= 13 -> 2
    n if n <= 20 -> 3
    n if n <= 50 -> 4
    _ -> 5
  }
  parse_code_loop("", code, string.lowercase(search_text), acceptable_distance)
}

fn parse_code_loop(
  seen: String,
  rest: String,
  search_text: String,
  acceptable_distance: Int,
) -> Result(Snippet, Nil) {
  use #(before, rest) <- result.try(string.split_once(rest, "\u{2}"))
  let seen = seen <> string.replace(before, "\u{3}", "")
  let text = rest |> string.replace("\u{2}", "") |> string.replace("\u{3}", "")
  let len = string.length(search_text)
  let #(match, distance) =
    int.range(
      int.max(len - acceptable_distance, 1),
      len + acceptable_distance + 1,
      #("", 999),
      fn(best, l) {
        let m = string.slice(text, 0, l)
        let d = edit_distance.levenshtein(string.lowercase(m), search_text)
        case d <= best.1 {
          True -> #(m, d)
          False -> best
        }
      },
    )
  case distance {
    d if d <= acceptable_distance ->
      Ok(FuzzyMatch(seen, match, string.drop_start(text, string.length(match))))
    _ -> parse_code_loop(seen, rest, search_text, acceptable_distance)
  }
}

fn canonical_result_decoder() -> decode.Decoder(Result(SearchResult, Nil)) {
  use name <- decode.field(0, decode.string)
  use description <- decode.field(1, decode.string)
  use repository <- decode.field(2, decode.optional(decode.string))
  use updated_at <- decode.field(3, decode.int)
  use owners <- decode.field(4, decode.string)
  use total_downloads <- decode.field(5, decode.int)
  use recent_downloads <- decode.field(6, decode.int)
  use latest_version <- decode.field(7, decode.string)
  use module_name <- decode.field(8, decode.optional(decode.string))
  use code <- decode.field(9, decode.optional(decode.string))
  let package =
    storage.Package(
      name:,
      description:,
      repository:,
      updated_at: timestamp.from_unix_seconds(updated_at),
      owners: owners |> string.split(" ") |> list.filter(fn(o) { o != "" }),
      total_downloads:,
      recent_downloads:,
      latest_version:,
    )
  let snippet = case module_name, code {
    Some(module_name), Some(code) -> [
      ModuleSnippet(module_name, Definitions([code])),
    ]
    _, _ -> []
  }
  decode.success(Ok(SearchResult(package:, snippet:)))
}

fn merge_modules_by_package(results: List(SearchResult)) -> List(SearchResult) {
  let groups = list.group(results, fn(r) { r.package.name })
  results
  |> list.map(fn(r) { r.package.name })
  |> list.unique
  |> list.filter_map(fn(name) {
    use group <- result.try(dict.get(groups, name))
    use first <- result.map(list.first(group))
    SearchResult(..first, snippet: list.flat_map(group, fn(r) { r.snippet }))
  })
}

fn similar_pkg_names(query: String, pkgs: List(String)) {
  case string.length(query) {
    n if n < 50 -> {
      let acceptable_distance = case n {
        n if n <= 4 -> 1
        n if n <= 11 -> 2
        n if n <= 20 -> 3
        n if n <= 50 -> 4
        _ -> panic as "xdd"
      }
      list.filter(pkgs, fn(pkg) {
        edit_distance.levenshtein(query, pkg) <= acceptable_distance
      })
    }
    _ -> []
  }
}

fn view(model: Model) -> Element(Msg) {
  case model.database {
    DbLoading -> element.none()
    DbLoaded(pkg_db) -> main_view(model, pkg_db)
    DbError(err) -> h.text(err)
  }
}

fn main_view(model: Model, pkg_db: PkgDb) -> Element(Msg) {
  h.div(
    [
      a.styles([
        #("--w", "770px"),
        #("box-sizing", "border-box"),
        #("max-width", "var(--w)"),
        #("margin", "0 auto"),
        #("padding", "2rem 1.2rem 0"),
      ]),
    ],
    [
      h.p([a.style("height", "8rem")], case pkg_db {
        Metadata(_, loading_percent:) ->
          case loading_percent {
            Some(percent) -> {
              let percent = float.round(percent *. 20.0)
              range_map.range(from: 0, to: 20, run: fn(num) {
                let src = case num < percent {
                  True -> "/static/jooc/lucy.svg"
                  False -> "/static/jooc/lucy-empty-inside.svg"
                }
                h.img([a.src(src), a.style("width", "5%")])
              })
            }
            None -> [
              h.button(
                [
                  pressable(),
                  event.on_click(UserClickedDownloadCode),
                  a.style("font-size", "1rem"),
                  ..btn_styles()
                ],
                [
                  h.text("enable search on type/fn"),
                  h.br([]),
                  h.text("and on fuzzy code text"),
                  h.br([]),
                  h.text("(downloads 150MB for"),
                  h.br([]),
                  h.text("in-browser search)"),
                ],
              ),
            ]
          }
        Code(_) -> [
          h.text("code search enabled, for example:"),
          h.ul(
            [a.style("margin", "0")],
            list.map(
              [
                "type Wibble{Wobble(Int) Woo}",
                "fn idk(x: String) -> Int",
                "helo world",
              ],
              fn(search_text) {
                h.li([], [
                  h.button(
                    [pressable(), event.on_click(UserTypedQuery(search_text))],
                    [
                      h.text(search_text),
                    ],
                  ),
                ])
              },
            ),
          ),
          h.label([], [
            h.text(
              "if new packages available, automatically download to device",
            ),
            h.input([
              a.type_("checkbox"),
              a.checked(model.auto_download_sqlite),
              event.on_check(UserCheckedAutomaticallyDownloadSqlite),
            ]),
          ]),
        ]
      }),
      h.div(
        [
          a.styles([
            #("position", "relative"),
            #("margin-bottom", "1rem"),
          ]),
        ],
        [
          view_star(model),
          h.input([
            // doesn't really need to be controlled input except maybe nice to clear when user clicks button "popular" etc
            a.value(model.search_text),
            a.type_("search"),
            a.placeholder(case pkg_db {
              Metadata(_, _) -> "name"
              Code(_) -> "name, code, type, or fn"
            }),
            event.on_input(UserTypedQuery) |> event.debounce(200),
            a.styles([
              #("box-sizing", "border-box"),
              #("width", "100%"),
              #("height", "3.5rem"),
              #("display", "block"),
              #("margin", "0"),
              #("padding", "0 1rem 0 3rem"),
              #("font-size", "1.1rem"),
              #("border", "1px solid #3a3a3a"),
              #("border-radius", "1.75rem"),
              #("background", "var(--bg)"),
            ]),
          ]),
        ],
      ),
      view_results(model, timeago.new()),
    ],
  )
}

fn pressable() -> a.Attribute(Msg) {
  a.class("pressable")
}

fn view_star(model: Model) -> Element(Msg) {
  let src = case model.lucy {
    Searching -> "/static/jooc/lucyhappy.svg"
    NotSearching -> "/static/jooc/lucy.svg"
  }

  h.img([
    a.src(src),
    a.styles([
      #("position", "absolute"),
      #("left", "8px"),
      #("top", "50%"),
      #("transform", "translateY(-50%)"),
      #("width", "32px"),
      #("height", "32px"),
      #("pointer-events", "none"),
    ]),
  ])
}

fn view_results(model: Model, time_ago) -> Element(Msg) {
  h.div([], [
    case model.search_result {
      [] ->
        h.p([a.style("margin", "0")], [
          h.text(
            "No matching packages found here, but this is not a complete index of all gleam packages. Maybe try ",
          ),
          link(
            "https://packages.gleam.run?search=" <> model.search_text,
            "packages.gleam.run",
          ),
        ])
      search_results ->
        h.table(
          [
            a.styles([
              #("width", "100%"),
              //#("table-layout", "fixed"),
              #("border-collapse", "collapse"),
            ]),
          ],
          [
            // h.colgroup([], [
            //   h.col([a.style("width", "30%")]),
            //   h.col([a.style("width", "20%")]),
            //   h.col([a.style("width", "20%")]),
            //   h.col([a.style("width", "17%")]),
            //   h.col([a.style("width", "13%")]),
            // ]),
            h.thead([], [
              h.tr([], [
                th("package", False),
                th("author", True),
                th("links", False),
                th("updated", True),
                th("downloads", True),
              ]),
            ]),
            ..list.map(search_results, fn(search_result) {
              view_result(search_result, time_ago)
            })
          ],
        )
    },
    h.footer(
      [
        a.style("padding-top", "10px"),
        a.style("padding-bottom", "10px"),
      ],
      [
        h.text(
          "This includes only Gleam packages that spark joy for me, i.e. not all packages are included. This package list is ",
        ),
        h.strong([], [h.text("not maintained by the Gleam team")]),
        h.text(", it is not official or objective or anything. "),
        link("https://packages.gleam.run", "packages.gleam.run"),
        h.text(
          " Is Gleam's official site for seeing all packages. Thanks also to ",
        ),
        link("https://hex.pm/", "hex.pm"),
        h.text(" and "),
        link("https://gloogle.run", "gloogle.run"),
        h.text(".  Gleam Lucy starfish mascot © 2026 Louis Pilfold."),
        h.br([]),
        h.text("See all packages ordered by: "),
        h.span([a.style("display", "inline-block")], [
          btn("new", sql.all_pkgs_by_recent),
          btn("popular", sql.all_pkgs_by_downloaded),
          btn("big", sql.all_pkgs_by_big),
          btn("small", sql.all_pkgs_by_small),
        ]),
      ],
    ),
  ])
}

fn view_result(
  result: SearchResult,
  time_ago: timeago.TimeAgo,
) -> Element(msg) {
  let package = result.package
  // these go twice so they can show up different place for mobile vs desktop
  let updated = h.text(timeago.format(time_ago, package.updated_at))
  let author = h.text(string.join(package.owners, ", "))
  let downloads = h.text(int.to_string(package.total_downloads))

  h.tbody([], [
    h.tr([], [
      td(
        [
          h.div([a.style("font-size", "1.25rem")], [
            h.text(package.name),
            h.wbr([]),
            h.text("@" <> package.latest_version),
          ]),
          h.span([a.class("mobile-only")], [author]),
        ],
        False,
      ),
      td([author], True),
      td(
        [
          h.div(
            [
              a.styles([
                #("display", "flex"),
                #("flex-wrap", "wrap"),
                #("gap", "0.25rem 0.75rem"),
              ]),
            ],
            [
              link(
                "https://"
                  <> string.replace(package.name, "_", "-")
                  <> ".hexdocs.pm",
                "docs",
              ),
              case package.repository {
                Some(url) -> link(url, "repo")
                None -> element.none()
              },
              link("https://hex.pm/packages/" <> package.name, "hex"),
            ],
          ),
        ],
        False,
      ),
      td([updated], True),
      td([downloads], True),
    ]),
    h.tr([], [
      h.td(
        [
          a.colspan(5),
          a.styles([
            #("padding", "0.25rem 0 0.75rem"),
            #("border-bottom", "1px solid #3a3a3a"),
            #("overflow-wrap", "anywhere"),
          ]),
        ],
        [
          h.p([a.style("margin", "0")], [
            h.text(package.description),
            h.span([a.class("mobile-only")], [
              h.span([a.style("white-space", "nowrap")], [
                h.text("updated "),
                updated,
                h.text(", "),
              ]),
              h.wbr([]),
              h.span([a.style("white-space", "nowrap")], [
                downloads,
                h.text(" downloads"),
              ]),
            ]),
          ]),
          ..list.map(result.snippet, code_snippet)
        ],
      ),
    ]),
  ])
}

fn code_snippet(snippet: ModuleSnippet) -> Element(msg) {
  h.div(
    [
      a.styles([
        #("margin", "0.75rem 0 0.75rem 1rem"),
        // mysterious ai css to not make page zoom on mobile from snippet idk is it needed?
        #("width", "0"),
        #("min-width", "calc(100% - 1rem)"),
      ]),
    ],
    [
      h.p([a.styles([#("margin", "0 0 0.25rem"), #("font-weight", "600")])], [
        h.text(snippet.module_name),
      ]),
      ..case snippet.snippet {
        FuzzyMatch(before:, match:, after:) -> [
          code_block([
            h.text(before),
            h.mark([a.style("background-color", "#ffaff3")], [h.text(match)]),
            h.text(after),
          ]),
        ]
        Definitions(definitions:) ->
          list.map(definitions, fn(source) { code_block([h.text(source)]) })
      }
    ],
  )
}

fn code_block(elts) {
  h.pre(
    [
      a.styles([
        #("margin", "0"),
        #("margin-bottom", "0.5rem"),
        #("padding", "0.5rem 0.75rem"),
        #("background", "rgba(128, 128, 128, 0.15)"),
        #("border-radius", "0.3rem"),
        #("white-space", "pre"),
        #("overflow-x", "auto"),
      ]),
    ],
    [h.code([], elts)],
  )
}

fn th(label: String, desktop_only: Bool) -> Element(msg) {
  h.th(
    [
      a.styles([
        #("text-align", "left"),
        #("padding", "0.5rem 1rem 0.5rem 0"),
        #("border-bottom", "1px solid #3a3a3a"),
      ]),
      a.classes([#("desktop-only", desktop_only)]),
    ],
    [h.text(label)],
  )
}

fn td(children: List(Element(msg)), desktop_only: Bool) -> Element(msg) {
  h.td(
    [
      a.classes([#("desktop-only", desktop_only)]),
      a.styles([
        #("padding", "0.75rem 1rem 0 0"),
        #("vertical-align", "top"),
        #("overflow-wrap", "anywhere"),
      ]),
    ],
    children,
  )
}

fn link(href: String, label: String) -> Element(msg) {
  h.a(
    [
      a.href(href),
      a.styles([
        #("white-space", "nowrap"),
      ]),
    ],
    [h.text(label)],
  )
}

fn btn(text, premade_query) {
  h.button(
    [
      pressable(),
      event.on_click(UserClickedButton(premade_query)),
      ..btn_styles()
    ],
    [
      h.text(text),
    ],
  )
}

fn btn_styles() {
  [
    a.style("margin", "5px"),
    a.style("padding", "5px 10px"),
    a.style("cursor", "pointer"),
  ]
}

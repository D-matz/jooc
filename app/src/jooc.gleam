import canonical
import edit_distance
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import lustre
import lustre/attribute as a
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event
import modem
import rsvp
import sql
import sqlite
import storage
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
    query_from_initial_uri: Option(String),
  )
}

type SearchResult {
  SearchResult(package: storage.Package, snippet: List(Snippet))
}

type Snippet {
  Snippet(module_name: String, code: List(String))
}

type Db {
  DbLoadingFromCache
  DbLoadingFromServer
  DbLoaded(db: sqlite.Database, animation: Option(Animation))
  DbError(String)
}

type Animation {
  Finishing
  Done
}

type Search {
  Searching
  NotSearching
}

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
      DbLoadingFromCache,
      [],
      NotSearching,
      [],
      option.unwrap(query_from_initial_uri, ""),
      query_from_initial_uri,
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
  ServerReturnedData(Result(Response(BitArray), rsvp.Error(BitArray)))
  SqliteReturnedOpen(Result(sqlite.Database, String))
  SpinFinished
  SqliteReturnedQuery(Result(Dynamic, String))
  UserTypedQuery(String)
  UserClickedButton(String)
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
        Error(_) -> download_server_db(model)
      }
    ServerReturnedEtag(cached_etag, server_response) ->
      case server_response {
        Error(_) -> download_server_db(model)
        Ok(server_response) ->
          case server_response |> response.get_header("etag") {
            Ok(server_etag) ->
              case server_etag == cached_etag {
                True -> #(model, sqlite.load_cached(CacheLoaded))
                False -> download_server_db(model)
              }
            Error(_) -> download_server_db(model)
          }
      }
    CacheLoaded(Ok(cache_data)) -> open_db(model, cache_data)
    CacheLoaded(Error(_)) -> download_server_db(model)
    ServerReturnedData(load_result) ->
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
        Error(_) -> {
          let model =
            Model(
              ..model,
              database: DbError("could not load data from " <> data_src),
            )
          #(model, effect.none())
        }
      }
    SqliteReturnedOpen(load_result) -> {
      let #(database, exec) = case load_result {
        Ok(db) -> #(
          case model.database {
            DbLoadingFromCache -> DbLoaded(db, None)
            DbLoadingFromServer -> DbLoaded(db, Some(Finishing))
            DbLoaded(_, _) -> panic as "xd"
            DbError(_) -> panic as "xdd"
          },
          sqlite.query(db, sql.all_pkgs_by_recent, [], SqliteReturnedQuery),
        )
        Error(err) -> #(DbError(err), effect.none())
      }
      let model = Model(..model, database:, lucy: Searching)
      #(model, exec)
    }
    SpinFinished -> {
      let model = case model.database {
        DbLoaded(database, _) ->
          Model(..model, database: DbLoaded(database, Some(Done)))
        _ -> model
      }
      #(model, effect.none())
    }
    SqliteReturnedQuery(query_result) -> {
      let query_resp =
        case query_result {
          Ok(query_resp) -> {
            let resp = decode.run(query_resp, trigram_snippet_decoder())
            case resp {
              Ok(resp) -> {
                resp
              }
              Error(err) -> {
                echo err
                []
              }
            }
          }
          Error(err) -> {
            echo err
            []
          }
        }
        |> merge_modules_by_package
      // the first time we run this will be empty and on loading it gets all packages
      // so we fill out name list so we can do levenshtein edit distance on package names in gleam
      // as fts5 trigrams doesnt seem great for eg luster -> lustre
      // also first time we get response, run user's initial query from url...
      // can't just run it immediately because we need to load package names first here
      // the pkg name list kind of doing double duty to indicate we ready for user url query, kind of confusing

      case model.all_pkg_names {
        [] -> {
          let all_pkg_names = list.map(query_resp, fn(pkg) { pkg.package.name })
          let model = Model(..model, all_pkg_names:)
          case model.query_from_initial_uri {
            Some(text) -> text_to_query(text, model)
            None -> {
              let model =
                Model(..model, search_result: query_resp, lucy: NotSearching)
              #(model, effect.none())
            }
          }
        }
        _ -> {
          let model =
            Model(..model, search_result: query_resp, lucy: NotSearching)
          #(model, effect.none())
        }
      }
    }
    UserTypedQuery(text) -> text_to_query(text, model)
    UserClickedButton(premade_query) -> {
      let exec = case model.database {
        DbLoaded(db, _) -> {
          sqlite.query(db, premade_query, [], SqliteReturnedQuery)
        }
        _ -> effect.none()
      }
      let model = Model(..model, lucy: Searching, search_text: "")
      #(model, exec)
    }
  }
}

fn open_db(model: Model, sqlite_db: BitArray) -> #(Model, Effect(Msg)) {
  #(model, sqlite.open(sqlite_db, SqliteReturnedOpen))
}

fn download_server_db(model) {
  let model = Model(..model, database: DbLoadingFromServer)
  let assert Ok(req) = request.to(data_src)
  let download_effect =
    req
    |> request.set_body(<<>>)
    |> rsvp.send_bits(rsvp.expect_ok_response(ServerReturnedData))
  #(model, download_effect)
}

// usually query text is from the user typing, but could also be from initial url
fn text_to_query(text, model) {
  let push_url = modem.push("", Some(uri.percent_encode(text)), None)
  let model = Model(..model, search_text: text)
  let text = string.trim(text)
  let exec = case model.database {
    DbLoaded(db, _) -> {
      let chars = string.to_graphemes(text)
      case chars {
        [] -> sqlite.query(db, sql.all_pkgs_by_recent, [], SqliteReturnedQuery)
        [_] | [_, _] ->
          sqlite.query(
            db,
            sql.info_only,
            [text, text, text],
            SqliteReturnedQuery,
          )
        [_, _, ..] -> {
          case parse_type_or_fn(chars) {
            Ok(canonical) ->
              sqlite.query(db, sql.canonical, [canonical], SqliteReturnedQuery)
            Error(_) -> {
              let trigram_count = string.length(text) - 4
              let bm25_threshold = int.to_string(-6 * trigram_count)
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
                SqliteReturnedQuery,
              )
            }
          }
        }
      }
    }
    _ -> effect.none()
  }
  let effect = effect.batch([exec, push_url])
  let model = Model(..model, lucy: Searching)
  #(model, effect)
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

fn trigram_snippet_decoder() {
  decode.list(search_result_decoder())
}

fn search_result_decoder() -> decode.Decoder(SearchResult) {
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
  let snippet = case module_name, code {
    Some(module_name), Some(code) -> [Snippet(module_name:, code: [code])]
    _, _ -> []
  }
  decode.success(SearchResult(
    package: storage.Package(
      name:,
      description:,
      repository:,
      updated_at: timestamp.from_unix_seconds(updated_at),
      owners: owners |> string.split(" ") |> list.filter(fn(o) { o != "" }),
      total_downloads:,
      recent_downloads:,
      latest_version:,
    ),
    snippet:,
  ))
}

fn merge_modules_by_package(results: List(SearchResult)) -> List(SearchResult) {
  let groups = list.group(results, fn(r) { r.package.name })
  results
  |> list.map(fn(r) { r.package.name })
  |> list.unique
  |> list.filter_map(fn(name) {
    use group <- result.try(dict.get(groups, name))
    use first <- result.map(list.first(group))
    let snippet =
      group
      |> list.flat_map(fn(r) { r.snippet })
      |> list.group(fn(s) { s.module_name })
      |> dict.map_values(fn(name, same) {
        Snippet(name, list.flat_map(same, fn(s) { s.code }))
      })
      |> dict.values
    SearchResult(..first, snippet: snippet)
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

// -------------- view ---------------

fn view(model: Model) -> Element(Msg) {
  case model.database {
    DbLoadingFromCache -> element.none()
    DbLoadingFromServer | DbLoaded(_, _) -> main_view(model)
    DbError(err) -> h.text(err)
  }
}

fn main_view(model: Model) -> Element(Msg) {
  let #(done, animated) = case model.database {
    DbLoaded(_, None) -> #(True, False)
    DbLoaded(_, Some(Done)) -> #(True, True)
    _ -> #(False, True)
  }
  let spin_events = case model.database {
    DbLoaded(_, Some(Finishing)) -> [
      event.on("animationiteration", {
        use name <- decode.field("animationName", decode.string)
        case name {
          "spin" -> decode.success(SpinFinished)
          _ -> decode.failure(SpinFinished, "spin")
        }
      }),
    ]
    _ -> []
  }

  h.div(
    [
      a.classes([#("done", done && animated)]),
      a.styles([
        #("--w", "770px"),
        #("box-sizing", "border-box"),
        #("max-width", "var(--w)"),
        #("margin", "0 auto"),
        #("padding", "2rem 1.2rem 0"),
      ]),
    ],
    [
      view_star(done, animated, spin_events, model),
      h.input([
        // doesn't really need to be controlled input except maybe nice to clear when user clicks button "popular" etc
        a.value(model.search_text),
        a.type_("search"),
        a.placeholder("search package by name, code, type, fn"),
        a.disabled(!done),
        event.on_input(UserTypedQuery) |> event.debounce(200),
        a.styles([
          #("box-sizing", "border-box"),
          #("width", "100%"),
          #("height", "3.5rem"),
          #("margin", "0 0 1rem"),
          #("padding", "0 1rem 0 3rem"),
          #("font-size", "1rem"),
          #("border", "1px solid #3a3a3a"),
          #("border-radius", "1.75rem"),
          #("background", "var(--bg)"),
          #("color", "var(--text)"),
          #("transition", "opacity 1s"),
          #("opacity", case done {
            True -> "1"
            False -> "0"
          }),
          #("pointer-events", case done {
            True -> "auto"
            False -> "none"
          }),
        ]),
      ]),
      view_results(model, timeago.new()),
    ],
  )
}

fn view_star(
  done: Bool,
  animated: Bool,
  spin_events: List(a.Attribute(Msg)),
  model: Model,
) -> Element(Msg) {
  let position = case done {
    False -> [
      #("top", "50%"),
      #("left", "50%"),
      #("width", "min(400px, 70vmin)"),
      #("height", "min(400px, 70vmin)"),
    ]
    True -> [
      #("top", "3.75rem"),
      #("left", "calc(max(0px, 50% - var(--w) / 2) + 1.2rem + 24px)"),
      #("width", "32px"),
      #("height", "32px"),
    ]
  }

  h.div(
    [
      a.class("mover"),
      a.styles([
        #("position", "absolute"),
        #("z-index", "1"),
        #("transform", "translate(-50%, -50%)"),
        #(
          "transition",
          "top var(--move) ease-in-out, width var(--move) ease-in-out, height var(--move) ease-in-out",
        ),
        ..position
      ]),
    ],
    [
      h.div(
        [
          a.classes([#("spin", animated)]),
          a.styles([
            #("position", "relative"),
            #("width", "100%"),
            #("height", "100%"),
          ]),
          ..spin_events
        ],
        [
          {
            let svg = case model.lucy {
              Searching -> "https://gleam.run/images/lucy/lucyhappy.svg"
              NotSearching ->
                // this is a mess because the css to control during spin animation is class slop
                // and we know havent loaded yet because all_pkg_names is empty
                case model.search_result, model.all_pkg_names {
                  _, [] -> "https://gleam.run/images/lucy/lucy.svg"
                  [], _ -> "https://gleam.run/images/lucy/lucydebugfail.svg"
                  _, _ -> "https://gleam.run/images/lucy/lucy.svg"
                }
            }
            star_image(
              case animated {
                True -> "normal"
                False -> ""
              },
              svg,
            )
          },
          case animated {
            True ->
              star_image("happy", "https://gleam.run/images/lucy/lucyhappy.svg")
            False -> element.none()
          },
        ],
      ),
    ],
  )
}

fn star_image(name: String, src: String) -> Element(Msg) {
  h.img([
    a.class(name),
    a.src(src),
    a.styles([
      #("position", "absolute"),
      #("width", "100%"),
      #("height", "100%"),
    ]),
  ])
}

fn view_results(model: Model, time_ago) -> Element(Msg) {
  case model.database {
    // never actually get here we just echo err
    // should probably take it out
    DbError(message) -> h.p([a.style("margin", "0")], [h.text(message)])
    DbLoaded(_, None) | DbLoaded(_, Some(Done)) ->
      // case model.lucy {
      //   Searching -> element.none()
      //   NotSearching ->
      // could make it show nothing as soon as you search, but kind of jarring
      h.div([], [
        case model.search_result {
          [] ->
            h.p([a.style("margin", "0")], [
              h.text(
                "No matching packages found here, but this is not a complete index of all gleam packages. Maybe try ",
              ),
              link(
                "https://packages.gleam.run?search=" <> model.search_text,
                "https://packages.gleam.run?search=" <> model.search_text,
              ),
            ])
          search_results ->
            h.table(
              [
                a.styles([
                  #("width", "100%"),
                  #("table-layout", "fixed"),
                  #("border-collapse", "collapse"),
                ]),
              ],
              [
                h.colgroup([], [
                  h.col([a.style("width", "30%")]),
                  h.col([a.style("width", "20%")]),
                  h.col([a.style("width", "20%")]),
                  h.col([a.style("width", "17%")]),
                  h.col([a.style("width", "13%")]),
                ]),
                h.thead([], [
                  h.tr([], [
                    th("package"),
                    th("author"),
                    th("links"),
                    th("updated"),
                    th("downloads"),
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
            btn("new", sql.all_pkgs_by_recent),
            btn("popular", sql.all_pkgs_by_downloaded),
            btn("big", sql.all_pkgs_by_big),
            btn("small", sql.all_pkgs_by_small),
          ],
        ),
      ])
    // }
    _ -> element.none()
  }
}

fn view_result(
  result: SearchResult,
  time_ago: timeago.TimeAgo,
) -> Element(msg) {
  let package = result.package
  h.tbody([], [
    h.tr([], [
      td([
        h.span([a.style("font-size", "1.25rem")], [
          h.text(package.name),
          h.wbr([]),
          h.text("@" <> package.latest_version),
        ]),
      ]),
      td([h.text(string.join(package.owners, ", "))]),
      td([
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
      ]),
      td([h.text(timeago.format(time_ago, package.updated_at))]),
      td([h.text(int.to_string(package.total_downloads))]),
    ]),
    h.tr([], [
      h.td(
        [
          a.colspan(5),
          a.styles([
            #("padding", "0.25rem 0 0.75rem"),
            #("border-bottom", "1px solid #3a3a3a"),
          ]),
        ],
        [
          h.p([a.style("margin", "0")], [h.text(package.description)]),
          ..list.map(result.snippet, code_snippet)
        ],
      ),
    ]),
  ])
}

fn code_snippet(snippet: Snippet) -> Element(msg) {
  h.div([a.styles([#("margin", "0.75rem 0 0.75rem 1rem")])], [
    h.p([a.styles([#("margin", "0 0 0.25rem"), #("font-weight", "600")])], [
      h.text(snippet.module_name),
    ]),
    ..list.map(snippet.code, fn(source) {
      h.pre(
        [
          a.styles([
            #("margin", "0"),
            #("margin-bottom", "0.5rem"),
            #("padding", "0.5rem 0.75rem"),
            #("background", "rgba(128, 128, 128, 0.15)"),
            #("border-radius", "0.3rem"),
            #("white-space", "pre-wrap"),
            #("overflow-x", "auto"),
          ]),
        ],
        [h.code([], [h.text(source)])],
      )
    })
  ])
}

fn th(label: String) -> Element(msg) {
  h.th(
    [
      a.styles([
        #("text-align", "left"),
        #("padding", "0.5rem 1rem 0.5rem 0"),
        #("border-bottom", "1px solid #3a3a3a"),
      ]),
    ],
    [h.text(label)],
  )
}

fn td(children: List(Element(msg))) -> Element(msg) {
  h.td(
    [
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
      event.on_click(UserClickedButton(premade_query)),
      a.style("margin", "5px"),
      a.style("padding", "5px 10px"),
      a.style("color", "var(--text)"),
      a.style("cursor", "pointer"),
    ],
    [h.text(text)],
  )
}

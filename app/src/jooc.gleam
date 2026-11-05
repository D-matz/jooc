import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp
import lustre
import lustre/attribute as a
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event
import rsvp
import sqlite
import storage
import timeago

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

type Model {
  Model(database: Db, search_result: List(SearchResult))
}

type SearchResult {
  SearchResult(package: storage.Package, snippet: List(Snippet))
}

type Snippet {
  Snippet(module_name: String, code: String)
}

type Db {
  DbLoaded(db: sqlite.Database)
  DbLoading
  DbError(String)
}

const data_src = "https://bucket.correctarity.com/packages.sqlite"

fn init(_) -> #(Model, Effect(Msg)) {
  let assert Ok(req) = request.to(data_src)
  let load_data =
    req
    |> request.set_body(<<>>)
    |> rsvp.send_bits(rsvp.expect_ok_response(ServerReturnedData))
  #(Model(DbLoading, []), load_data)
}

type Msg {
  ServerReturnedData(Result(Response(BitArray), rsvp.Error(BitArray)))
  SqliteReturnedOpen(Result(sqlite.Database, String))
  SqliteReturnedQuery(Result(Dynamic, String))
  UserTypedQuery(String)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ServerReturnedData(load_result) ->
      case load_result {
        Ok(resp) -> #(model, sqlite.open(resp.body, SqliteReturnedOpen))
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
      let database = case load_result {
        Ok(db) -> DbLoaded(db)
        Error(err) -> DbError(err)
      }
      let model = Model(..model, database:)
      #(model, effect.none())
    }
    SqliteReturnedQuery(query_result) -> {
      echo "SqliteReturnedQuery"
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
      let model = Model(..model, search_result: query_resp)
      #(model, effect.none())
    }
    UserTypedQuery(text) -> {
      echo text
      let exec = case model.database {
        DbLoaded(db) -> {
          case string.to_utf_codepoints(text) {
            [] ->
              sqlite.query(
                db,
                "SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
                  p.total_downloads, p.recent_downloads, p.latest_version,
                  NULL AS module, NULL AS snippet
                FROM packages p
                ORDER BY p.recent_downloads DESC, p.id",
                [],
                SqliteReturnedQuery,
              )
            [_] | [_, _] ->
              sqlite.query(
                db,
                "SELECT p.name, p.description, p.repository,
                  p.updated_at, p.owners, p.total_downloads, p.recent_downloads,
                  p.latest_version, NULL AS module, NULL AS snippet
                FROM packages p
                WHERE instr(lower(p.name), lower(?)) > 0
                ORDER BY p.recent_downloads DESC, p.id",
                [string.trim(text)],
                SqliteReturnedQuery,
              )
            [first, second, ..rest] -> {
              let search_trigrams = query_to_trigrams(first, second, rest)
              sqlite.query(
                db,
                code_and_package_sql,
                [exact_match(text), search_trigrams],
                SqliteReturnedQuery,
              )
            }
          }
        }
        _ -> effect.none()
      }
      #(model, exec)
    }
  }
}

fn exact_match(text: String) -> String {
  "\"" <> string.replace(text, "\"", "\"\"") <> "\""
}

type TrigramsAcc {
  TrigramsAcc(trigrams: List(String), first: UtfCodepoint, second: UtfCodepoint)
}

// const code_search_sql =
//   "SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//     p.total_downloads, p.recent_downloads, p.latest_version,
//     m.name AS module,
//     snippet(modules_fts, -1, char(2), char(3), '', 64) AS snippet
//   FROM modules_fts f
//   JOIN modules m ON m.id = f.rowid
//   JOIN packages p ON p.id = m.package_id
//   WHERE modules_fts MATCH ?
//   ORDER BY f.rank"

// const code_and_package_sql =
//   "SELECT * FROM (
//   SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//          p.total_downloads, p.recent_downloads, p.latest_version,
//          NULL AS module, NULL AS snippet,
//          0 AS kind,
//          lower(p.name) = lower(?2) AS exact,
//          -p.recent_downloads AS score
//   FROM packages_fts f
//   JOIN packages p ON p.id = f.rowid
//   WHERE packages_fts MATCH ?1
//   UNION ALL
//   SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//          p.total_downloads, p.recent_downloads, p.latest_version,
//          m.name AS module,
//          snippet(modules_fts, -1, char(2), char(3), '', 64) AS snippet,
//          1 AS kind,
//          0 AS exact,
//          f.rank AS score
//   FROM modules_fts f
//   JOIN modules m ON m.id = f.rowid
//   JOIN packages p ON p.id = m.package_id
//   WHERE modules_fts MATCH ?1
// )
// ORDER BY kind, exact DESC, score"

// const code_and_package_sql =
//   "SELECT name, description, repository, updated_at, owners,
//   total_downloads, recent_downloads, latest_version, module, snippet FROM (
//   SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//          p.total_downloads, p.recent_downloads, p.latest_version,
//          m.name AS module,
//          snippet(modules_fts, -1, char(2), char(3), '', 64) AS snippet,
//          0 AS kind, f.rank AS score
//   FROM modules_fts f
//   JOIN modules m ON m.id = f.rowid
//   JOIN packages p ON p.id = m.package_id
//   WHERE modules_fts MATCH ?1
//   UNION ALL
//   SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//          p.total_downloads, p.recent_downloads, p.latest_version,
//          m.name,
//          snippet(modules_fts, -1, char(2), char(3), '', 64),
//          1, f.rank
//   FROM modules_fts f
//   JOIN modules m ON m.id = f.rowid
//   JOIN packages p ON p.id = m.package_id
//   WHERE modules_fts MATCH ?2
//     AND f.rowid NOT IN (SELECT rowid FROM modules_fts WHERE modules_fts MATCH ?1)
// )
// ORDER BY kind, score
// LIMIT 100"

const code_and_package_sql =
  "WITH exact AS (
  SELECT rowid AS id FROM modules_fts
  WHERE modules_fts MATCH ?1 ORDER BY rank LIMIT 100
),
fuzzy AS (
  SELECT rowid AS id FROM modules_fts
  WHERE modules_fts MATCH ?2
    AND rowid NOT IN (SELECT id FROM exact)
  ORDER BY rank LIMIT 100
)
SELECT name, description, repository, updated_at, owners,
  total_downloads, recent_downloads, latest_version, module, snippet FROM (
  SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
         p.total_downloads, p.recent_downloads, p.latest_version,
         m.name AS module,
         snippet(modules_fts, -1, '', '', '', 64) AS snippet,
         0 AS kind, f.rank AS score
  FROM modules_fts f
  JOIN modules m ON m.id = f.rowid
  JOIN packages p ON p.id = m.package_id
  WHERE modules_fts MATCH ?1 AND f.rowid IN (SELECT id FROM exact)
  UNION ALL
  SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
         p.total_downloads, p.recent_downloads, p.latest_version,
         m.name,
         snippet(modules_fts, -1, '', '', '', 64),
         1, f.rank
  FROM modules_fts f
  JOIN modules m ON m.id = f.rowid
  JOIN packages p ON p.id = m.package_id
  WHERE modules_fts MATCH ?2 AND f.rowid IN (SELECT id FROM fuzzy)
)
ORDER BY kind, score"

fn query_to_trigrams(
  first: UtfCodepoint,
  second: UtfCodepoint,
  rest: List(UtfCodepoint),
) -> String {
  let starting_acc = TrigramsAcc(trigrams: [], first:, second:)
  let acc =
    list.fold(over: rest, from: starting_acc, with: fn(acc, third) {
      // FTS5 quoting: wrap in double quotes and double any inner double quote.
      let trigram =
        string.from_utf_codepoints([acc.first, acc.second, third])
        |> string.replace("\"", "\"\"")
      TrigramsAcc(
        trigrams: ["\"" <> trigram <> "\"", ..acc.trigrams],
        first: acc.second,
        second: third,
      )
    })
  acc.trigrams |> list.unique |> string.join(" OR ")
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
    Some(module_name), Some(code) -> [Snippet(module_name:, code:)]
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
  let order = results |> list.map(fn(r) { r.package.name }) |> list.unique
  let groups = list.group(results, fn(r) { r.package.name })
  list.filter_map(order, fn(name) {
    case dict.get(groups, name) {
      Ok([first, ..] as group) ->
        Ok(
          SearchResult(
            ..first,
            snippet: list.flat_map(group, fn(r) { r.snippet }),
          ),
        )
      _ -> Error(Nil)
    }
  })
}

fn view(model: Model) -> Element(Msg) {
  let time_ago = timeago.new()
  h.div(
    [
      a.styles([
        #("max-width", "992px"),
        #("margin", "0 auto"),
        #("padding", "0 1.2rem"),
      ]),
    ],
    [
      h.input([
        a.type_("search"),
        a.placeholder("Search packages"),
        a.autofocus(True),
        event.on_input(UserTypedQuery) |> event.debounce(200),
        a.styles([
          #("box-sizing", "border-box"),
          #("width", "100%"),
          #("margin", "2rem 0 1rem"),
          #("padding", "1rem"),
          #("font-size", "1rem"),
          #("border", "1px solid #3a3a3a"),
          #("border-radius", "0.4rem"),
          #("background", "var(--bg)"),
          #("color", "var(--text)"),
        ]),
      ]),
      case model.search_result {
        [] -> h.p([a.style("margin", "0")], [h.text("No packages found")])
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
                h.col([a.style("width", "15%")]),
                h.col([a.style("width", "15%")]),
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
    ],
  )
}

fn view_result(
  result: SearchResult,
  time_ago: timeago.TimeAgo,
) -> Element(msg) {
  let package = result.package
  h.tbody([], [
    h.tr([], [
      td([h.text(package.name <> "@" <> package.latest_version)]),
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
          case result.snippet {
            [] -> h.p([a.style("margin", "0")], [h.text(package.description)])
            snippets -> h.p([], list.map(snippets, code_snippet))
          },
        ],
      ),
    ]),
  ])
}

fn code_snippet(snippet: Snippet) -> Element(msg) {
  h.div([], [
    h.p([a.style("margin", "0 0 0.25rem")], [h.text(snippet.module_name)]),
    h.pre([a.styles([#("margin", "0"), #("white-space", "pre-wrap")])], [
      h.code([], [h.text(snippet.code)]),
    ]),
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

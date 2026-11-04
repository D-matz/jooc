import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event
import rsvp
import sqlite

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

type Model {
  Model(database: Db, trigram_snippet_response: List(SearchResult))
}

pub type SearchResult {
  SearchResult(package: String, module: String, snippet: String)
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
      let query_resp = case query_result {
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
      let model = Model(..model, trigram_snippet_response: query_resp)
      #(model, effect.none())
    }
    UserTypedQuery(query) -> {
      let parsed_user_query = case string.to_utf_codepoints(query) {
        [] -> todo
        [first] -> todo
        [first, second] -> todo
        [first, second, ..rest] -> {
          query_to_trigrams(first, second, rest)
        }
      }
      let exec = case model.database {
        DbLoaded(db) ->
          sqlite.query(
            db,
            parsed_user_query.0,
            parsed_user_query.1,
            SqliteReturnedQuery,
          )
        _ -> effect.none()
      }
      #(model, exec)
    }
  }
}

fn short_query(chars: List(UtfCodepoint)) -> String {
  let text =
    chars
    |> string.from_utf_codepoints
    |> string.replace("!", "!!")
    |> string.replace("%", "!%")
    |> string.replace("_", "!_")
    |> string.replace("'", "''")
  "SELECT Name FROM track_search
   WHERE Name LIKE '%" <> text <> "%' ESCAPE '!'
   LIMIT 20;"
}

type TrigramsAcc {
  TrigramsAcc(trigrams: List(String), first: UtfCodepoint, second: UtfCodepoint)
}

const search_sql =
  "SELECT p.name AS package, m.name AS module,
  snippet(modules_fts, -1, char(2), char(3), '...', 64) AS snippet
FROM modules_fts f
JOIN modules m ON m.id = f.rowid
JOIN packages p ON p.id = m.package_id
WHERE modules_fts MATCH ?
ORDER BY f.rank LIMIT 10"

// Returns #(sql, match), query puts match bind list
fn query_to_trigrams(
  first: UtfCodepoint,
  second: UtfCodepoint,
  rest: List(UtfCodepoint),
) -> #(String, List(String)) {
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
  #(search_sql, [string.join(acc.trigrams, " OR ")])
}

fn trigram_snippet_decoder() {
  decode.list(search_result_decoder())
}

fn search_result_decoder() {
  use package <- decode.field(0, decode.string)
  use module <- decode.field(1, decode.string)
  use snippet <- decode.field(2, decode.string)
  decode.success(SearchResult(package:, module:, snippet:))
}

fn view(model: Model) -> Element(Msg) {
  h.main([], [
    h.text(case model.database {
      DbLoaded(_db) -> "loaded"
      DbLoading -> "loading"
      DbError(err) -> "error " <> err
    }),
    h.input([event.on_input(UserTypedQuery)]),
    ..list.map(model.trigram_snippet_response, fn(resp) {
      h.p([], [
        h.text(resp.module),
        h.br([]),
        element.unsafe_raw_html(
          "",
          "span",
          [],
          resp.snippet
            |> string.replace("&", "&amp;")
            |> string.replace("<", "&lt;")
            |> string.replace(">", "&gt;")
            |> string.replace("\u{2}", "<mark>")
            |> string.replace("\u{3}", "</mark>"),
        ),
      ])
    })
  ])
}

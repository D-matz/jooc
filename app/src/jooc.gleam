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
  Model(database: Db, query_response: Option(String))
}

type Db {
  DbLoaded(db: sqlite.Database)
  DbLoading
  DbError(String)
}

const data_src = "https://raw.githubusercontent.com/lerocha/chinook-database/master/ChinookDatabase/DataSources/Chinook_Sqlite.sqlite"

fn init(_) -> #(Model, Effect(Msg)) {
  let assert Ok(req) = request.to(data_src)
  let load_data =
    req
    |> request.set_body(<<>>)
    |> rsvp.send_bits(rsvp.expect_ok_response(ServerReturnedData))
  #(Model(DbLoading, None), load_data)
}

type Msg {
  ServerReturnedData(Result(Response(BitArray), rsvp.Error(BitArray)))
  SqliteReturnedOpen(Result(sqlite.Database, String))
  SqliteReturnedCreated(Result(Nil, String))
  SqliteReturnedQuery(Result(Dynamic, String))
  UserTypedQuery(String)
  UserClickedExec
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
    SqliteReturnedCreated(create_result) -> {
      let database = case create_result {
        Ok(_) -> model.database
        Error(err) -> DbError(err)
      }
      let model = Model(..model, database:)
      #(model, effect.none())
    }
    SqliteReturnedQuery(query_result) -> {
      let query_resp = case query_result {
        Ok(query_resp) -> {
          let resp =
            decode.run(query_resp, decode.list(decode.list(decode.string)))
          case resp {
            Ok(resp) -> {
              resp
              |> list.map(fn(r) { string.join(r, ",") })
              |> string.join(";")
            }
            Error(_err) -> "decode error"
          }
        }
        Error(err) -> err
      }
      let model = Model(..model, query_response: Some(query_resp))
      #(model, effect.none())
    }
    UserTypedQuery(query) -> {
      let parsed_user_query = case string.to_utf_codepoints(query) {
        [] -> "none idk"
        [first] -> short_query([first])
        [first, second] -> short_query([first, second])
        [first, second, ..rest] -> {
          query_to_trigrams(first, second, rest)
        }
      }
      let exec = case model.database {
        DbLoaded(db) -> sqlite.query(db, parsed_user_query, SqliteReturnedQuery)
        _ -> effect.none()
      }
      #(model, exec)
    }
    UserClickedExec -> {
      let exec = case model.database {
        DbLoaded(db) ->
          sqlite.exec(
            db,
            // "
            // CREATE VIRTUAL TABLE track_fts USING fts5(Name);
            // INSERT INTO track_fts(Name) SELECT Name FROM Track;
            //   ",
            "
            CREATE VIRTUAL TABLE track_search USING fts5(Name, tokenize='trigram');
            INSERT INTO track_search(Name) SELECT Name FROM Track;
            ",
            SqliteReturnedCreated,
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

fn query_to_trigrams(
  first: UtfCodepoint,
  second: UtfCodepoint,
  rest: List(UtfCodepoint),
) {
  let starting_acc = TrigramsAcc(trigrams: [], first:, second:)
  let trigrams =
    list.fold(over: rest, from: starting_acc, with: fn(acc, third) {
      let trigram =
        string.from_utf_codepoints([acc.first, acc.second, third])
        |> string.replace("\"", "\"\"")
        |> string.replace("'", "''")
      let trigrams = ["\"" <> trigram <> "\"", ..acc.trigrams]
      TrigramsAcc(trigrams:, second: third, first: acc.second)
    })
  "SELECT Name FROM track_search WHERE track_search MATCH '"
  <> string.join(trigrams.trigrams, " OR ")
  <> "' ORDER BY rank LIMIT 10"
}

fn view(model: Model) -> Element(Msg) {
  h.main([], [
    h.text(case model.database {
      DbLoaded(_db) -> "loaded"
      DbLoading -> "loading"
      DbError(err) -> "error " <> err
    }),
    h.button([event.on_click(UserClickedExec)], [h.text("create idk")]),
    h.input([event.on_input(UserTypedQuery)]),
    case model.query_response {
      Some(resp) -> h.p([], [h.text(resp)])
      None -> element.none()
    },
  ])
}

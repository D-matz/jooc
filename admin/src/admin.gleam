// all packages from https://packages.gleam.run/api/packages
// already read from https://bucket.correctarity.com/already_read.json
// make list of all |> filter already read
//

import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import lustre
import lustre/attribute as a
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event
import rsvp
import slop
import sqlite
import storage

// MAIN ------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

// MODEL -----------------------------------------------------------------------

type Model {
  Model(
    all: List(storage.Package),
    already_read: Judged,
    upload_message: Option(String),
    access_key_id: Option(String),
    secret_access_key: Option(String),
    packages_db: Option(sqlite.Database),
  )
}

type Judged {
  Judged(
    good: List(storage.Package),
    bad: List(storage.Package),
    unsure: List(storage.Package),
  )
}

fn get_pkgs_all(
  site: String,
  msg: fn(Result(List(storage.Package), rsvp.Error(String))) -> a,
) -> Effect(a) {
  let handle_pkg_json = rsvp.expect_json(pkg_all_decoder(), msg)
  rsvp.get(site, handle_pkg_json)
}

fn pkg_all_decoder() {
  use all <- decode.field("data", decode.list(storage.package_decoder()))
  decode.success(all)
}

fn get_pkgs_judged(
  site: String,
  msg: fn(Result(Judged, rsvp.Error(String))) -> a,
) -> Effect(a) {
  let handle_pkg_json = rsvp.expect_json(pkg_judged_decoder(), msg)
  rsvp.get(site, handle_pkg_json)
}

fn pkg_judged_decoder() {
  use good <- decode.field("good", decode.list(storage.package_decoder()))
  use bad <- decode.field("bad", decode.list(storage.package_decoder()))
  use unsure <- decode.field("unsure", decode.list(storage.package_decoder()))
  decode.success(Judged(good:, bad:, unsure:))
}

fn pkg_judged_to_json(already_read: Judged) {
  json.object([
    #("good", json.array(already_read.good, storage.package_to_json)),
    #("bad", json.array(already_read.bad, storage.package_to_json)),
    #("unsure", json.array(already_read.unsure, storage.package_to_json)),
  ])
}

fn init(_) -> #(Model, Effect(Message)) {
  let model =
    Model(
      all: [],
      already_read: Judged([], [], []),
      upload_message: None,
      access_key_id: None,
      secret_access_key: None,
      packages_db: None,
    )
  // CORS !!! :)) :<<<< -.- XDDDDD
  // idc if this is bad, just for admin page
  // it is not like i have an api key!
  let get_all =
    get_pkgs_all(
      "https://proxy.cors.dev/https://packages.gleam.run/api/packages",
      ReturnedPackagesAll,
    )
  let get_already =
    get_pkgs_judged(
      "https://bucket.correctarity.com/already_read.json",
      ReturnedPackagesRead,
    )
  #(model, effect.batch([get_all, get_already]))
}

// UPDATE ----------------------------------------------------------------------

type Message {
  ReturnedPackagesAll(Result(List(storage.Package), rsvp.Error(String)))
  ReturnedPackagesRead(Result(Judged, rsvp.Error(String)))
  UserClickedJudge(pkg: storage.Package, is: Rating)
  UserClickedUpload
  RequestBuilt(request: Request(BitArray))
  UploadSucceeded
  UploadFailed(rsvp.Error(BitArray))
  UserEnteredBucketInfo(String)
  ServerReturnedDatabase(Result(Response(BitArray), rsvp.Error(BitArray)))
  BrowserOpenedDatabase(Result(sqlite.Database, String))
}

type Rating {
  Good
  Bad
  // unsure is effectively like bad ie wont be included
  Unsure
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ReturnedPackagesAll(Error(err)) -> {
      echo err
      panic as "error getting all packages"
    }
    ReturnedPackagesAll(Ok(all)) -> {
      let model = Model(..model, all:)
      #(model, effect.none())
    }
    ReturnedPackagesRead(Error(err)) -> {
      echo "what"
      echo err
      panic as "error getting read packages"
    }
    ReturnedPackagesRead(Ok(already_read)) -> {
      let model = Model(..model, already_read:)
      #(model, effect.none())
    }
    UserClickedJudge(pkg:, is:) -> {
      let already_read = case is {
        Good ->
          Judged(..model.already_read, good: [pkg, ..model.already_read.good])
        Bad ->
          Judged(..model.already_read, bad: [pkg, ..model.already_read.bad])
        Unsure ->
          Judged(..model.already_read, unsure: [
            pkg,
            ..model.already_read.unsure
          ])
      }
      let model = Model(..model, already_read:)
      #(model, effect.none())
    }
    UserClickedUpload -> {
      // before uploading, update to newer version from packages.gleam.run if available
      let all_by_name =
        list.map(model.all, fn(pkg) { #(pkg.name, pkg) })
        |> dict.from_list
      let update_pkg_metadata = fn(pkgs: List(storage.Package)) {
        list.map(pkgs, fn(pkg) {
          case all_by_name |> dict.get(pkg.name) {
            Ok(found_pkg) -> found_pkg
            Error(_) -> {
              echo "already_read missing " <> pkg.name
              pkg
            }
          }
        })
      }
      let good = model.already_read.good |> update_pkg_metadata
      let bad = model.already_read.bad |> update_pkg_metadata
      let unsure = model.already_read.unsure |> update_pkg_metadata
      let model = Model(..model, already_read: Judged(good:, bad:, unsure:))

      // ok now upload
      #(
        model,
        slop.put_object_effect(
          host: "21d22098b8563166bdc93387685252e4.r2.cloudflarestorage.com",
          access_key_id: model.access_key_id
            |> option.unwrap("no access key id"),
          secret_access_key: model.secret_access_key
            |> option.unwrap("no secret access key"),
          bucket: "pkglist",
          key: "already_read.json",
          body: model.already_read
            |> pkg_judged_to_json
            |> json.to_string
            |> bit_array.from_string,
          on_built: RequestBuilt,
          content_type: "application/json",
        ),
      )
    }
    RequestBuilt(request) -> #(
      model,
      rsvp.send_bits(
        request,
        rsvp.expect_ok_response(fn(result) {
          case result {
            Ok(_) -> UploadSucceeded
            Error(err) -> UploadFailed(err)
          }
        }),
      ),
    )
    UploadSucceeded -> {
      let now = timestamp.system_time() |> timestamp.to_rfc3339(duration.empty)
      let model =
        Model(..model, upload_message: Some("good json upload (" <> now <> ")"))
      let assert Ok(req) =
        request.to("https://bucket.correctarity.com/packages.db")
      let get_db = rsvp.send_bits(
        request.set_body(req, <<>>),
        rsvp.expect_ok_response(ServerReturnedDatabase),
      )
      #(model, get_db)
    }
    UploadFailed(err) -> {
      echo err
      let now = timestamp.system_time() |> timestamp.to_rfc3339(duration.empty)
      let model =
        Model(..model, upload_message: Some("UPLOAD FAILED AT " <> now))
      #(model, effect.none())
    }
    UserEnteredBucketInfo(info) -> {
      let model = case string.split(info, ",") {
        [a, b] ->
          Model(..model, access_key_id: Some(a), secret_access_key: Some(b))
        _ -> model
      }
      #(model, effect.none())
    }
    ServerReturnedDatabase(Error(err)) -> {
      echo err
      let now = timestamp.system_time() |> timestamp.to_rfc3339(duration.empty)
      let model =
        Model(
          ..model,
          upload_message: Some("DATABASE DOWNLOAD FAILED AT " <> now),
        )
      #(model, effect.none())
    }
    ServerReturnedDatabase(Ok(resp_db)) -> {
      let open_db = sqlite.open(resp_db.body, BrowserOpenedDatabase)
      #(model, open_db)
    }
    BrowserOpenedDatabase(Error(err)) -> {
      let model =
        Model(
          ..model,
          upload_message: Some(
            "database downlaoded but failed to open: " <> err,
          ),
        )
      #(model, effect.none())
    }
    BrowserOpenedDatabase(Ok(packages_db)) -> {
      let model =
        Model(
          ..model,
          packages_db: Some(packages_db),
          upload_message: Some("downloaded packages db"),
        )
      echo model
      #(model, effect.none())
    }
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Message) {
  let read_names =
    model.already_read.good
    |> list.append(model.already_read.bad)
    |> list.append(model.already_read.unsure)
    |> list.map(fn(pkg) { pkg.name })
    |> set.from_list
  let unread =
    model.all
    |> list.filter(fn(pkg) { read_names |> set.contains(pkg.name) == False })
  h.main([], [
    h.div([], [
      h.input([
        a.placeholder("Access Key ID,Secret Access Key"),
        event.on_input(UserEnteredBucketInfo),
      ]),
      h.button(
        [
          event.on_click(UserClickedUpload),
          a.disabled(model.secret_access_key == None),
        ],
        [h.text("Upload to r2")],
      ),
      case model.upload_message {
        Some(upload_message) -> h.text(upload_message)
        None -> element.none()
      },
    ]),
    ..list.map(unread, fn(pkg) {
      h.div(
        [
          a.style("display", "flex"),
          a.style("gap", "5px"),
          a.style("margin", "5px"),
        ],
        [
          h.button(
            [
              event.on_click(UserClickedJudge(pkg, Good)),
              a.style("padding", "5px"),
            ],
            [h.text("good")],
          ),
          h.button(
            [
              event.on_click(UserClickedJudge(pkg, Bad)),
              a.style("padding", "5px"),
            ],
            [h.text("bad")],
          ),
          h.button(
            [
              event.on_click(UserClickedJudge(pkg, Unsure)),
              a.style("padding", "5px"),
            ],
            [h.text("unsure")],
          ),
          h.a(
            [
              a.href(
                "https://"
                <> string.replace(pkg.name, "_", "-")
                <> ".hexdocs.pm/",
              ),
            ],
            [
              h.text(pkg.name),
            ],
          ),
          h.span([], [h.text(pkg.owners |> string.join("; "))]),
        ],
      )
    })
  ])
}

import gleam/float
import gleam/json
import gleam/dynamic/decode
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}

// copying from packages.gleam
// eg
// {
// "name":"lustre",
// "description":"Create HTML templates, single page applications, Web Components, and real-time server components in Gleam!",
// "latest-version":"5.7.1",
// "repository":"https://github.com/lustre-labs/lustre",
// "updated-at":1783984546,
// "owners":["hayleigh"],
// "total-downloads":331575,
// "recent-downloads":60677
// }

pub type Package {
  Package(
    name: String,
    description: String,
    repository: Option(String),
    updated_at: Timestamp,
    owners: List(String),
    total_downloads: Int,
    recent_downloads: Int,
  )
}

pub fn package_to_json(package: Package) -> json.Json {
  let Package(name:, description:, repository:, updated_at:, owners:, total_downloads:, recent_downloads:) = package
  json.object([
    #("name", json.string(name)),
    #("description", json.string(description)),
    #("repository", case repository {
      option.None -> json.null()
      option.Some(value) -> json.string(value)
    }),
    #("updated-at", json_timestamp(updated_at)),
    #("owners", json.array(owners, json.string)),
    #("total-downloads", json.int(total_downloads)),
    #("recent-downloads", json.int(recent_downloads)),
  ])
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
  decode.success(Package(
    name:,
    description:,
    repository:,
    updated_at:,
    owners:,
    total_downloads:,
    recent_downloads:,
  ))
}

fn json_timestamp(timestamp: timestamp.Timestamp) -> json.Json {
  timestamp
  |> timestamp.to_unix_seconds
  |> float.round
  |> json.int
}

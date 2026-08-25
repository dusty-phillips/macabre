import errors
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/result
import gleam/string
import shellout

/// Resolves a Gleam version constraint (e.g. `>= 1.0.0 and < 2.0.0` or
/// `~> 1.0`) against the hex.pm API to a concrete version, choosing the newest
/// stable release that satisfies the constraint.
pub fn resolve(
  name: String,
  constraint: String,
) -> Result(String, errors.Error) {
  use output <- result.try(
    shellout.command(
      "curl",
      ["-s", "-L", "--max-time", "60", "https://hex.pm/api/packages/" <> name],
      ".",
      [],
    )
    |> result.map_error(fn(_error) {
      errors.HexResolveError(name, constraint, "hex.pm API request failed")
    }),
  )
  case matching_version(output, constraint) {
    option.Some(version) -> Ok(version_to_string(version))
    option.None ->
      Error(errors.HexResolveError(
        name,
        constraint,
        "no version satisfies the constraint",
      ))
  }
}

fn matching_version(
  output: String,
  constraint: String,
) -> option.Option(Version) {
  case json.parse(output, release_versions_decoder()) {
    Ok(versions) ->
      versions
      |> list.filter_map(parse_version)
      |> list.filter(fn(version) { version_matches(version, constraint) })
      |> highest
    Error(_) -> option.None
  }
}

fn release_versions_decoder() -> decode.Decoder(List(String)) {
  use entries <- decode.then(decode.at(
    ["releases"],
    decode.list(decode.dynamic),
  ))
  decode.success(
    list.filter_map(entries, fn(entry) {
      case decode.run(entry, version_decoder()) {
        Ok(version) -> Ok(version)
        Error(_) -> Error(Nil)
      }
    }),
  )
}

fn version_decoder() -> decode.Decoder(String) {
  use content <- decode.field("version", decode.string)
  decode.success(content)
}

pub type Version {
  Version(major: Int, minor: Int, patch: Int, pre: List(String))
}

fn parse_version(value: String) -> Result(Version, Nil) {
  let base = case string.split(value, "+") {
    [base, ..] -> base
    _ -> value
  }
  let #(version_text, pre) = case string.split(base, "-") {
    [version_text, ..pre] -> #(version_text, pre)
    _ -> #(base, [])
  }
  let parts = string.split(version_text, ".") |> list.map(int.parse)
  case parts {
    [Ok(major)] -> Ok(Version(major, 0, 0, pre))
    [Ok(major), Ok(minor)] -> Ok(Version(major, minor, 0, pre))
    [Ok(major), Ok(minor), Ok(patch), ..] ->
      Ok(Version(major, minor, patch, pre))
    _ -> Error(Nil)
  }
}

fn version_to_string(version: Version) -> String {
  case list.is_empty(version.pre) {
    True ->
      int.to_string(version.major)
      <> "."
      <> int.to_string(version.minor)
      <> "."
      <> int.to_string(version.patch)
    False ->
      int.to_string(version.major)
      <> "."
      <> int.to_string(version.minor)
      <> "."
      <> int.to_string(version.patch)
      <> "-"
      <> string.join(version.pre, ".")
  }
}

fn compare_versions(a: Version, b: Version) -> Order {
  let majors = int.compare(a.major, b.major)
  let minors = int.compare(a.minor, b.minor)
  let patches = int.compare(a.patch, b.patch)
  case majors {
    Eq ->
      case minors {
        Eq ->
          case patches {
            Eq -> compare_pre(a.pre, b.pre)
            order -> order
          }
        order -> order
      }
    order -> order
  }
}

// A version without a prerelease is newer than any prerelease of it; otherwise
// prerelease segments compare in order, with numeric segments sorting lower.
fn compare_pre(a: List(String), b: List(String)) -> Order {
  case a, b {
    [], [] -> Eq
    [], _ -> Gt
    _, [] -> Lt
    [a_first, ..a_rest], [b_first, ..b_rest] ->
      case compare_segments(a_first, b_first) {
        Eq -> compare_pre(a_rest, b_rest)
        order -> order
      }
  }
}

fn compare_segments(a: String, b: String) -> Order {
  case int.parse(a), int.parse(b) {
    Ok(a_int), Ok(b_int) -> int.compare(a_int, b_int)
    _, _ -> string.compare(a, b)
  }
}

fn highest(versions: List(Version)) -> option.Option(Version) {
  list.fold(versions, option.None, fn(acc, current) {
    case acc {
      option.None -> option.Some(current)
      option.Some(best) ->
        case compare_versions(current, best) {
          Gt -> option.Some(current)
          _ -> acc
        }
    }
  })
}

fn version_matches(version: Version, constraint: String) -> Bool {
  // Prerelease versions only match when the constraint mentions one, matching
  // the official resolver's rule of preferring stable releases.
  case list.is_empty(version.pre) || string.contains(constraint, "-") {
    False -> False
    True ->
      constraint
      |> string.split(" or ")
      |> list.any(fn(disjunction) { match_disjunction(version, disjunction) })
  }
}

fn match_disjunction(version: Version, disjunction: String) -> Bool {
  disjunction
  |> string.split(" and ")
  |> list.all(fn(clause) { match_clause(version, clause) })
}

fn match_clause(version: Version, clause: String) -> Bool {
  case string.split(clause, " ") {
    [operator, version_text] ->
      case parse_version(version_text) {
        Error(_) -> False
        Ok(required) ->
          case operator {
            ">=" ->
              case compare_versions(version, required) {
                Gt | Eq -> True
                _ -> False
              }
            ">" -> compare_versions(version, required) == Gt
            "<=" ->
              case compare_versions(version, required) {
                Lt | Eq -> True
                _ -> False
              }
            "<" -> compare_versions(version, required) == Lt
            "==" -> compare_versions(version, required) == Eq
            "~>" -> match_compatible(version, version_text)
            _ -> False
          }
      }
    _ -> False
  }
}

// Gleam's `~>` is RubyGems/Elixir style: `~> 2.0` allows `>= 2.0.0 and
// < 3.0.0`, `~> 2.3` allows `>= 2.3.0 and < 3.0.0`, and `~> 2.3.4` allows
// `>= 2.3.4 and < 2.4.0`.
fn match_compatible(version: Version, version_text: String) -> Bool {
  let base = case string.split(version_text, "-") {
    [base, ..] -> base
    _ -> version_text
  }
  let parts = base |> string.split(".") |> list.map(int.parse)
  case parse_version(version_text) {
    Error(_) -> False
    Ok(lower) -> {
      let upper = case parts {
        [Ok(major)] -> Version(major + 1, 0, 0, [])
        [Ok(major), Ok(_minor)] -> Version(major + 1, 0, 0, [])
        [Ok(major), Ok(minor), ..] -> Version(major, minor + 1, 0, [])
        _ -> Version(version.major + 1, 0, 0, [])
      }
      case compare_versions(version, lower) {
        Gt | Eq -> compare_versions(version, upper) == Lt
        _ -> False
      }
    }
  }
}

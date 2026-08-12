import compiler
import glance
import gleam/list
import gleam/string

pub fn forward_referenced_constants_test() {
  let assert Ok(module) =
    "pub const unix_epoch = DateTime(Date(0), TimeOfDay(0), utc)\npub const utc = Offset(0)\n\npub type Date {\n  Date(Int)\n}\n\npub type TimeOfDay {\n  TimeOfDay(Int)\n}\n\npub type Offset {\n  Offset(Int)\n}\n\npub type DateTime {\n  DateTime(Date, TimeOfDay, Offset)\n}\n"
    |> glance.module
  let py = compiler.compile_module(module)
  let lines = string.split(py, "\n")
  let utc_index =
    list.index_fold(lines, -1, fn(found, line, index) {
      case string.starts_with(line, "utc = Offset") {
        True -> index
        False -> found
      }
    })
  let epoch_index =
    list.index_fold(lines, -1, fn(found, line, index) {
      case string.starts_with(line, "unix_epoch = DateTime") {
        True -> index
        False -> found
      }
    })
  assert utc_index >= 0
  assert epoch_index >= 0
  assert utc_index < epoch_index
}

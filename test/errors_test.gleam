import errors
import gleam/string
import simplifile
import tom

pub fn git_clone_error_includes_output_test() {
  let message =
    errors.format_error(errors.GitCloneError("example", #(128, "fatal: nope")))
  assert string.contains(message, "error: Unable to clone dependency")
  assert string.contains(message, "fatal: nope")
  assert string.contains(message, "Hint: Check the repository URL")
}

pub fn git_clone_error_omits_empty_output_test() {
  let message = errors.format_error(errors.GitCloneError("example", #(128, "")))
  assert !string.contains(message, "Command output:")
}

pub fn hex_resolve_error_includes_detail_test() {
  let message =
    errors.format_error(errors.HexResolveError("wibble", ">= 1.0.0", "no match"))
  assert string.contains(message, "no match")
}

pub fn toml_parse_error_includes_detail_test() {
  let message =
    errors.format_error(errors.TomlParseError(
      "gleam.toml",
      tom.Unexpected("}", "a key"),
    ))
  assert string.contains(message, "error: Invalid TOML")
  assert string.contains(message, "unexpected `}`, expected a key")
}

pub fn file_write_error_includes_cause_test() {
  let message =
    errors.format_error(errors.FileWriteError("out.py", simplifile.Eacces))
  assert string.contains(message, "error: Unable to write file")
  assert string.contains(message, "Eacces")
}

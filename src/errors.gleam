import glance
import gleam/string
import internal/errors as internal
import simplifile
import tom

pub type Error {
  CopyFileError(src: String, dst: String, error: simplifile.FileError)
  DeleteError(path: String, error: simplifile.FileError)
  FileReadError(path: String, error: simplifile.FileError)
  FileOrDirectoryNotFound(path: String, error: simplifile.FileError)
  FileWriteError(path: String, error: simplifile.FileError)
  GlanceParseError(error: glance.Error, module: String, contents: String)
  GitCloneError(name: String, error: #(Int, String))
  MkdirError(path: String, error: simplifile.FileError)
  TomlFieldError(path: String, error: tom.GetError)
  TomlParseError(path: String, error: tom.ParseError)
}

pub fn format_error(error: Error) -> String {
  case error {
    FileOrDirectoryNotFound(filename, _) ->
      "File or directory not found " <> filename
    GitCloneError(name, _) -> "Unable to clone " <> name
    TomlParseError(filename, _) -> "Invalid toml file " <> filename
    TomlFieldError(filename, tom.NotFound(key)) ->
      "Missing toml field in " <> filename <> ": " <> string.join(key, ",")
    TomlFieldError(filename, tom.WrongType(key, expected, got)) ->
      "Incorrect toml field in "
      <> filename
      <> ": "
      <> string.join(key, ",")
      <> "\n(expected: "
      <> expected
      <> ", got: "
      <> got
      <> ")"
    FileReadError(filename, simplifile.Enoent) -> "File not found " <> filename
    FileReadError(filename, _) -> "Unable to read " <> filename
    FileWriteError(filename, _) -> "Unable to write " <> filename
    DeleteError(filename, _) -> "Unable to delete " <> filename
    MkdirError(filename, _) -> "Unable to mkdir " <> filename
    CopyFileError(src, dst, _) -> "Unable to copy " <> src <> " to " <> dst
    GlanceParseError(error, filename, contents) ->
      internal.format_glance_error(error, filename, contents)
  }
}

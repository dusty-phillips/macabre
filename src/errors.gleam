import glance
import gleam/string
import glimpse/error as glimpse_error
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
  GitCheckoutError(name: String, git_ref: String, error: #(Int, String))
  HexDownloadError(name: String, version: String, error: #(Int, String))
  HexExtractError(name: String, version: String, error: #(Int, String))
  MkdirError(path: String, error: simplifile.FileError)
  TomlFieldError(path: String, error: tom.GetError)
  TomlParseError(path: String, error: tom.ParseError)
  GlimpseImportError(error: glimpse_error.GlimpseImportError)
  GlimpseTypeCheckError(error: glimpse_error.TypeCheckError)
}

pub fn format_error(error: Error) -> String {
  case error {
    FileOrDirectoryNotFound(filename, _) ->
      "File or directory not found " <> filename
    GitCloneError(name, _) -> "Unable to clone " <> name
    GitCheckoutError(name, git_ref, _) ->
      "Unable to checkout " <> git_ref <> " in " <> name
    HexDownloadError(name, version, _) ->
      "Unable to download " <> name <> " version " <> version
    HexExtractError(name, version, _) ->
      "Unable to extract " <> name <> " version " <> version
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
    GlimpseImportError(error) -> format_glimpse_import_error(error)
    GlimpseTypeCheckError(error) -> "Type check failed"
  }
}

fn format_glimpse_import_error(
  error: glimpse_error.GlimpseImportError,
) -> String {
  case error {
    glimpse_error.CircularDependencyError(module_name) ->
      "Circular dependency detected for module " <> module_name
    glimpse_error.MissingImportError(module_name) ->
      "Missing import " <> module_name
    glimpse_error.SrcImportingDevDependency(module_name) ->
      "Source module imports dev dependency " <> module_name
  }
}

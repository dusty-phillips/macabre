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
  GlimpseTypeCheckError(module: String, error: glimpse_error.TypeCheckError)
  MissingDependency(entry: String, missing: String)
  UnsupportedTargetModule(module: String)
  HexResolveError(name: String, constraint: String, detail: String)
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
    GlimpseTypeCheckError(module, error) ->
      internal.format_glimpse_type_check_error(module, error)
    MissingDependency(entry, missing) ->
      "The test/dev module `"
      <> entry
      <> "` imports `"
      <> missing
      <> "` which is not available in this build"
    UnsupportedTargetModule(module) ->
      "The module `"
      <> module
      <> "` is only implemented for other build targets and cannot be part of a python build"
    HexResolveError(name, constraint, detail) ->
      "Unable to resolve "
      <> name
      <> " matching `"
      <> constraint
      <> "`: "
      <> detail
  }
}

fn format_glimpse_import_error(
  error: glimpse_error.GlimpseImportError,
) -> String {
  case error {
    glimpse_error.CircularDependencyError(module_name) ->
      "The module `"
      <> module_name
      <> "` forms a circular dependency with another module. Modules must not import each other directly or indirectly."
    glimpse_error.MissingImportError(module_name) ->
      "The module `"
      <> module_name
      <> "` could not be found. Check the module name and that it is part of this package or one of its dependencies."
    glimpse_error.SrcImportingDevDependency(module_name) ->
      "The module `"
      <> module_name
      <> "` is a dev-only dependency and cannot be imported from a source module. Move the import to a test or dev module."
  }
}

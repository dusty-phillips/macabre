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
  GlimpseTypeCheckError(
    module: String,
    error: glimpse_error.TypeCheckError,
    source: String,
    file: String,
  )
  MissingDependency(entry: String, missing: String)
  UnsupportedTargetModule(module: String)
  HexResolveError(name: String, constraint: String, detail: String)
}

pub fn format_error(error: Error) -> String {
  case error {
    FileOrDirectoryNotFound(filename, _) ->
      "error: File or directory not found\n\n`"
      <> filename
      <> "` was not found."
    GitCloneError(name, _) ->
      "error: Unable to clone dependency\n\nCould not clone `"
      <> name
      <> "`.\nHint: Check the repository URL and your network connection."
    GitCheckoutError(name, git_ref, _) ->
      "error: Unable to checkout dependency\n\nCould not checkout `"
      <> git_ref
      <> "` in `"
      <> name
      <> "`.\nHint: Check that the ref exists."
    HexDownloadError(name, version, _) ->
      "error: Unable to download package\n\nCould not download `"
      <> name
      <> "` version `"
      <> version
      <> "`.\nHint: Check the version and your network connection."
    HexExtractError(name, version, _) ->
      "error: Unable to extract package\n\nCould not extract `"
      <> name
      <> "` version `"
      <> version
      <> "`."
    TomlParseError(filename, _) ->
      "error: Invalid TOML\n\nCould not parse `" <> filename <> "`."
    TomlFieldError(filename, tom.NotFound(key)) ->
      "error: Missing configuration\n\nMissing field `"
      <> string.join(key, ",")
      <> "` in `"
      <> filename
      <> "`."
    TomlFieldError(filename, tom.WrongType(key, expected, got)) ->
      "error: Invalid configuration\n\nIncorrect field `"
      <> string.join(key, ",")
      <> "` in `"
      <> filename
      <> "`.\nExpected: "
      <> expected
      <> "\nGot: "
      <> got
    FileReadError(filename, simplifile.Enoent) ->
      "error: File not found\n\n`" <> filename <> "` was not found."
    FileReadError(filename, _) ->
      "error: Unable to read file\n\nCould not read `" <> filename <> "`."
    FileWriteError(filename, _) ->
      "error: Unable to write file\n\nCould not write `" <> filename <> "`."
    DeleteError(filename, _) ->
      "error: Unable to delete\n\nCould not delete `" <> filename <> "`."
    MkdirError(filename, _) ->
      "error: Unable to create directory\n\nCould not create `"
      <> filename
      <> "`."
    CopyFileError(src, dst, _) ->
      "error: Unable to copy file\n\nCould not copy `"
      <> src
      <> "` to `"
      <> dst
      <> "`."
    GlanceParseError(error, filename, contents) ->
      internal.format_glance_error(error, filename, contents)
    GlimpseImportError(error) -> format_glimpse_import_error(error)
    GlimpseTypeCheckError(module, error, source, file) ->
      internal.format_glimpse_type_check_error_with_source(
        module,
        error,
        source,
        file,
      )
    MissingDependency(entry, missing) ->
      "error: Missing dependency\n\nThe test/dev module `"
      <> entry
      <> "` imports `"
      <> missing
      <> "` which is not available in this build.\nHint: Add it to your `macabre.toml` dependencies."
    UnsupportedTargetModule(module) ->
      "error: Unsupported target\n\nThe module `"
      <> module
      <> "` is only implemented for other build targets and cannot be part of a python build.\nHint: Use a python-compatible alternative."
    HexResolveError(name, constraint, detail) ->
      "error: Unable to resolve package\n\nCould not resolve `"
      <> name
      <> "` matching `"
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
      "error: Circular dependency\n\nThe module `"
      <> module_name
      <> "` forms a circular dependency with another module.\nHint: Modules must not import each other directly or indirectly."
    glimpse_error.MissingImportError(module_name) ->
      "error: Unknown module\n\nThe module `"
      <> module_name
      <> "` could not be found.\nHint: Check the module name and that it is part of this package or one of its dependencies."
    glimpse_error.SrcImportingDevDependency(module_name) ->
      "error: Invalid import\n\nThe module `"
      <> module_name
      <> "` is a dev-only dependency and cannot be imported from a source module.\nHint: Move the import to a test or dev module."
  }
}

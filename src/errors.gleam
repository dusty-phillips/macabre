import glance
import internal/errors as internal
import simplifile

pub type Error {
  FileReadError(module: String, error: simplifile.FileError)
  FileWriteError(module: String, error: simplifile.FileError)
  GlanceParseError(error: glance.Error, module: String, contents: String)
}

pub fn format_error(error: Error) -> String {
  case error {
    FileReadError(filename, simplifile.Enoent) -> "File not found " <> filename
    FileReadError(filename, _) -> "Unable to read " <> filename
    FileWriteError(filename, _) -> "Unable to write " <> filename
    GlanceParseError(error, filename, contents) ->
      internal.format_glance_error(error, filename, contents)
  }
}

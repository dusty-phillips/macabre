import glance
import internal/errors as internal
import simplifile

pub type Error {
  FileOrDirectoryNotFound(path: String, error: simplifile.FileError)
  FileReadError(path: String, error: simplifile.FileError)
  FileWriteError(path: String, error: simplifile.FileError)
  DeleteError(path: String, error: simplifile.FileError)
  MkdirError(path: String, error: simplifile.FileError)
  GlanceParseError(error: glance.Error, module: String, contents: String)
}

pub fn format_error(error: Error) -> String {
  case error {
    FileOrDirectoryNotFound(filename, _) ->
      "File or directory not found " <> filename
    FileReadError(filename, simplifile.Enoent) -> "File not found " <> filename
    FileReadError(filename, _) -> "Unable to read " <> filename
    FileWriteError(filename, _) -> "Unable to write " <> filename
    DeleteError(filename, _) -> "Unable to delete " <> filename
    MkdirError(filename, _) -> "Unable to mkdir " <> filename
    GlanceParseError(error, filename, contents) ->
      internal.format_glance_error(error, filename, contents)
  }
}

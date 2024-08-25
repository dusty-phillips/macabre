import errors
import filepath
import gleam/io
import gleam/result
import python_prelude
import simplifile

pub fn write(contents: String, filename: String) -> Result(Nil, errors.Error) {
  simplifile.write(filename, contents)
  |> result.map_error(errors.FileWriteError(filename, _))
}

pub fn replace_extension(filename: String) -> String {
  filename |> filepath.strip_extension <> ".py"
}

pub fn replace_file(path: String, filename: String) -> String {
  path |> filepath.directory_name |> filepath.join(filename)
}

pub fn compile_result(filename: String, result: Result(Nil, String)) -> Nil {
  case result {
    Ok(_) ->
      io.println(
        "Compiled "
        <> filename
        <> " to "
        <> filename |> replace_extension
        <> " successfully",
      )
    Error(error) -> io.println("Error: " <> error)
  }
}

pub fn write_prelude_file(build_directory: String) -> Result(Nil, errors.Error) {
  let full_path = filepath.join(build_directory, "gleam_builtins.py")

  full_path
  |> simplifile.write(python_prelude.gleam_builtins)
  |> result.map_error(errors.FileWriteError(full_path, _))
}

pub fn write_error(error: errors.Error) -> Nil {
  error
  |> errors.format_error
  |> io.println
}

pub fn delete(path: String) -> Result(Nil, errors.Error) {
  simplifile.delete_all([path]) |> result.map_error(errors.DeleteError(path, _))
}

pub fn create_directory(path) -> Result(Nil, errors.Error) {
  simplifile.create_directory(path)
  |> result.map_error(errors.MkdirError(path, _))
}
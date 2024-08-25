import filepath
import gleam/io
import gleam/result
import python_prelude
import simplifile

pub fn write(contents: String, filename: String) -> Result(Nil, String) {
  simplifile.write(filename, contents)
  |> result.replace_error("Unable to write to '" <> filename <> "'")
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

pub fn write_prelude_file(filepath: String) -> Result(Nil, String) {
  filepath
  |> simplifile.write(python_prelude.gleam_builtins)
  |> result.replace_error("Unable to write prelude")
}

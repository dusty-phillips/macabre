import argv
import filepath
import generator
import glance
import gleam/io
import gleam/result
import gleam/string
import pprint
import python_prelude
import simplifile
import transformer

pub fn usage(message: String) -> Nil {
  io.println("Usage: macabre <filename.gleam>\n\n" <> message)
}

pub fn parse(contents: String) -> Result(glance.Module, String) {
  contents
  |> glance.module
  |> result.map_error(fn(x) {
    pprint.debug(x)
    "Unable to parse"
  })
}

pub fn write_output(contents: String, filename: String) -> Result(Nil, String) {
  simplifile.write(filename, contents)
  |> result.replace_error("Unable to write to '" <> filename <> "'")
}

pub fn replace_extension(filename: String) -> String {
  filename |> filepath.strip_extension <> ".py"
}

pub fn replace_file(path: String, filename: String) -> String {
  path |> filepath.directory_name |> filepath.join(filename)
}

pub fn output_result(filename: String, result: Result(Nil, String)) -> Nil {
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

pub fn output_prelude_file(filepath: String) -> Result(Nil, String) {
  filepath
  |> simplifile.write(python_prelude.gleam_builtins)
  |> result.replace_error("Unable to write prelude")
}

pub fn compile(module_contents: String) -> Result(String, String) {
  module_contents
  |> parse
  |> result.try(transformer.transform)
  |> result.try(generator.generate)
}

pub fn compile_module(filename: String) -> Result(Nil, String) {
  simplifile.read(filename)
  |> result.replace_error("Unable to read '" <> filename <> "'")
  |> result.try(compile)
  |> pprint.debug
  |> result.try(write_output(_, replace_extension(filename)))
  |> result.try(fn(_) {
    // TODO: eventually, this has to be output to a base directory,
    // not one copy per module.
    filename
    |> replace_file("gleam_builtins.py")
    |> output_prelude_file
  })
}

pub fn main() {
  case argv.load().arguments {
    [] -> usage("Not enough arguments")
    [input] ->
      case string.ends_with(input, ".gleam") {
        False -> usage("Not a gleam input file")
        True -> {
          compile_module(input) |> output_result(input, _)
        }
      }
    [_, _, ..] -> usage("Too many arguments")
  }
}

import argv
import generator
import glance
import gleam/io
import gleam/result
import gleam/string
import pprint
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
  filename |> string.drop_right(5) <> "py"
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
  |> result.try(write_output(_, replace_extension(filename)))
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

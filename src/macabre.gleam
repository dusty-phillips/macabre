import argv
import compiler
import compiler/program
import errors
import gleam/io
import gleam/result
import gleam/string
import internal/errors as error_functions
import output
import pprint
import simplifile

pub fn usage(message: String) -> Nil {
  io.println("Usage: macabre <filename.gleam>\n\n" <> message)
}

fn compile_module(filename: String) -> Result(Nil, String) {
  simplifile.read(filename)
  |> result.replace_error("Unable to read '" <> filename <> "'")
  |> result.try(fn(content) {
    content
    |> compiler.compile
    |> result.map_error(error_functions.format_glance_error(
      _,
      filename,
      content,
    ))
  })
  |> result.try(output.write(_, output.replace_extension(filename)))
  |> result.try(fn(_) {
    // TODO: eventually, this has to be output to a base directory,
    // not one copy per module.
    filename
    |> output.replace_file("gleam_builtins.py")
    |> output.write_prelude_file
  })
}

pub fn main() {
  case argv.load().arguments {
    [] -> usage("Not enough arguments")
    [input] ->
      case string.ends_with(input, ".gleam") {
        False -> usage(input <> ":" <> " Not a gleam input file")
        True -> {
          input
          |> program.load_program
          |> result.map(compiler.compile_program)
          |> result.try(output.write_program(_, "build"))
          |> result.map_error(output.write_error)
          |> result.unwrap_both
          // both nil
        }
      }
    [_, _, ..] -> usage("Too many arguments")
  }
}

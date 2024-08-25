import argv
import compiler
import gleam/dict
import gleam/io
import gleam/result
import gleam/string
import internal/errors
import output
import pprint
import program_parser
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
    |> result.map_error(errors.format_glance_error(_, filename, content))
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
          |> program_parser.load_program()
          |> pprint.debug
          Nil
        }
      }
    [_, _, ..] -> usage("Too many arguments")
  }
}

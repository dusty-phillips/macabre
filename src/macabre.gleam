import argv
import compiler
import compiler/program
import errors
import filepath
import gleam/dict
import gleam/io
import gleam/result
import output

pub fn main() {
  case argv.load().arguments {
    [] -> usage("Not enough arguments")
    [directory] ->
      directory
      |> program.load_program
      |> result.map(compiler.compile_program)
      |> result.try(write_program(_, filepath.join(directory, "build/")))
      |> result.map_error(output.write_error)
      |> result.unwrap_both
    // both nil
    [_, _, ..] -> usage("Too many arguments")
  }
}

pub fn usage(message: String) -> Nil {
  io.println("Usage: macabre <filename.gleam>\n\n" <> message)
}

fn write_program(
  program: program.CompiledProgram,
  build_directory: String,
) -> Result(Nil, errors.Error) {
  build_directory
  |> output.delete
  |> result.try(fn(_) { output.create_directory(build_directory) })
  |> result.try(fn(_) { output.write_prelude_file(build_directory) })
  |> result.try(fn(_) {
    output.write_py_main(build_directory, program.main_module)
  })
  |> result.try(fn(_) {
    dict.fold(program.modules, Ok(Nil), fn(state, name, module) {
      result.try(state, fn(_) {
        build_directory
        |> filepath.join(name)
        |> output.replace_extension()
        |> output.write(module, _)
      })
    })
  })
}

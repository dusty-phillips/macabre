import argv
import compiler
import compiler/program
import errors
import filepath
import gleam/dict
import gleam/io
import gleam/result
import gleam/set
import output

pub fn main() {
  case argv.load().arguments {
    [] -> usage("Not enough arguments")
    [directory] ->
      directory
      |> program.load_program
      |> result.map(compiler.compile_program)
      |> result.try(write_program)
      |> result.map_error(output.write_error)
      |> result.unwrap_both
    // both nil
    [_, _, ..] -> usage("Too many arguments")
  }
}

pub fn usage(message: String) -> Nil {
  io.println("Usage: macabre <filename.gleam>\n\n" <> message)
}

fn write_program(program: program.CompiledProgram) -> Result(Nil, errors.Error) {
  let build_directory = program.build_directory(program.base_directory)
  let source_directory = program.source_directory(program.base_directory)
  // TODO: would use make this more pleasant?
  output.delete(build_directory)
  |> result.try(fn(_) { output.create_directory(build_directory) })
  |> result.try(fn(_) { output.write_prelude_file(build_directory) })
  |> result.try(fn(_) {
    output.write_py_main(build_directory, program.main_module)
  })
  |> result.try(fn(_) {
    output.copy_externals(
      build_directory,
      source_directory,
      program.external_import_files |> set.to_list,
    )
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

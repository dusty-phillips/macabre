import argv
import compiler
import compiler/package
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
      |> package.load_package
      |> result.map(compiler.compile_package)
      |> result.try(write_package)
      |> result.map_error(output.write_error)
      |> result.unwrap_both
    // both nil
    [_, _, ..] -> usage("Too many arguments")
  }
}

pub fn usage(message: String) -> Nil {
  io.println("Usage: macabre <filename.gleam>\n\n" <> message)
}

pub fn write_package(
  package: package.CompiledPackage,
) -> Result(Nil, errors.Error) {
  let build_directory = package.build_directory(package.base_directory)
  let source_directory = package.source_directory(package.base_directory)
  output.delete(build_directory)
  |> result.try(fn(_) { output.create_directory(build_directory) })
  |> result.try(fn(_) { output.write_prelude_file(build_directory) })
  |> result.try(fn(_) {
    output.write_py_main(build_directory, package.main_module)
  })
  |> result.try(fn(_) {
    output.copy_externals(
      build_directory,
      source_directory,
      package.external_import_files |> set.to_list,
    )
  })
  |> result.try(fn(_) {
    dict.fold(package.modules, Ok(Nil), fn(state, name, module) {
      result.try(state, fn(_) {
        build_directory
        |> filepath.join(name)
        |> output.replace_extension()
        |> output.write(module, _)
      })
    })
  })
}

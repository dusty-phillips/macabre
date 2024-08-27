//// Wrapper of glance.parse that is able to parse multiple
//// modules and load them into a larger structure.
////
//// This module technically has side effects, as it needs to read from the
//// filesystem. 
//// It does not write to the filesystem.

import errors
import filepath
import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import simplifile

pub type GleamProgram {
  GleamProgram(
    base_directory: String,
    main_module: String,
    modules: dict.Dict(String, glance.Module),
    external_import_files: set.Set(String),
  )
}

pub type CompiledProgram {
  CompiledProgram(
    base_directory: String,
    main_module: option.Option(String),
    modules: dict.Dict(String, String),
    external_import_files: set.Set(String),
  )
}

/// Load the entry_point file and recursively load and parse any modules it
///returns.
pub fn load_program(
  source_directory: String,
) -> Result(GleamProgram, errors.Error) {
  source_directory
  |> simplifile.is_directory
  |> result.map_error(errors.FileOrDirectoryNotFound(source_directory, _))
  |> result.try(fn(_) { find_entrypoint(source_directory) })
  |> result.try(fn(entrypoint) {
    load_module(
      GleamProgram(
        source_directory,
        entrypoint,
        dict.new(),
        external_import_files: set.new(),
      ),
      entrypoint,
    )
  })
}

pub fn find_entrypoint(source_directory: String) -> Result(String, errors.Error) {
  let base_name = filepath.base_name(source_directory)
  let entrypoint = base_name <> ".gleam"
  simplifile.is_file(filepath.join(source_directory, entrypoint))
  |> result.replace(entrypoint)
  |> result.map_error(errors.FileOrDirectoryNotFound(entrypoint, _))
}

pub fn source_directory(base_directory: String) -> String {
  filepath.join(base_directory, "src")
}

pub fn build_directory(base_directory: String) -> String {
  filepath.join(base_directory, "build")
}

/// Parse the module and add it to the program's modules, if it can be parsed.
/// Then recursively parse any modules it imports.
fn load_module(
  program: GleamProgram,
  module_path: String,
) -> Result(GleamProgram, errors.Error) {
  case dict.get(program.modules, module_path) {
    Ok(_) -> Ok(program)
    Error(_) -> {
      let module_result =
        program.base_directory
        |> source_directory
        |> filepath.join(module_path)
        |> simplifile.read
        |> result.map_error(errors.FileReadError(module_path, _))
        |> result.try(parse(_, module_path))

      case module_result {
        Error(err) -> Error(err)
        Ok(module_contents) -> {
          add_module(program, module_path, module_contents)
          |> Ok
          |> list.fold(module_contents.imports, _, fold_load_module)
        }
      }
    }
  }
}

fn fold_load_module(
  program_result: Result(GleamProgram, errors.Error),
  import_def: glance.Definition(glance.Import),
) -> Result(GleamProgram, errors.Error) {
  case program_result {
    Error(error) -> Error(error)
    Ok(program) ->
      load_module(program, import_def.definition.module <> ".gleam")
  }
}

fn parse(
  contents: String,
  filename: String,
) -> Result(glance.Module, errors.Error) {
  glance.module(contents)
  |> result.map_error(errors.GlanceParseError(_, filename, contents))
}

fn add_module(
  program: GleamProgram,
  module_path: String,
  module_contents: glance.Module,
) -> GleamProgram {
  GleamProgram(
    ..program,
    modules: dict.insert(program.modules, module_path, module_contents),
    external_import_files: set.union(
      python_external_modules(module_contents.functions),
      program.external_import_files,
    ),
  )
}

fn python_external_modules(
  functions: List(glance.Definition(glance.Function)),
) -> set.Set(String) {
  list.filter_map(functions, fn(definition) {
    list.find_map(definition.attributes, identify_python_external_attribute)
  })
  |> set.from_list
}

fn identify_python_external_attribute(
  attribute: glance.Attribute,
) -> Result(String, Nil) {
  case attribute {
    glance.Attribute(
      "external",
      [glance.Variable("python"), glance.String(module), ..],
    ) -> Ok(module <> ".py")
    _ -> Error(Nil)
  }
}

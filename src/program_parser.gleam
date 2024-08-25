//// Wrapper of glance.parse that is able to parse multiple
//// modules and load them into a larger structure.
////
//// This module technically has side effects, as it needs to read from the
//// filesystem. 
//// It does not write to the filesystem.

import glance
import gleam/dict
import gleam/list
import gleam/result
import pprint
import simplifile

pub type ParseError {
  FileReadError(module: String, error: simplifile.FileError)
  GlanceParseError(glance.Error)
}

pub type GleamProgram {
  GleamProgram(modules: dict.Dict(String, glance.Module))
}

/// Load the entry_point file and recursively load and parse any modules it
///returns.
pub fn load_program(entry_point: String) -> Result(GleamProgram, ParseError) {
  GleamProgram(modules: dict.new())
  |> load_module(entry_point)
}

/// Parse the module and add it to the program's modules, if it can be parsed.
/// Then recursively parse any modules it imports.
fn load_module(
  program: GleamProgram,
  module_path: String,
) -> Result(GleamProgram, ParseError) {
  pprint.debug(module_path)
  case dict.get(program.modules, module_path) {
    Ok(_) -> Ok(program)
    Error(_) -> {
      let module_result =
        module_path
        |> simplifile.read
        |> result.map_error(FileReadError(module_path, _))
        |> result.try(parse)

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
  program_result: Result(GleamProgram, ParseError),
  import_def: glance.Definition(glance.Import),
) -> Result(GleamProgram, ParseError) {
  case program_result {
    Error(error) -> Error(error)
    Ok(program) ->
      load_module(program, import_def.definition.module <> ".gleam")
  }
}

fn parse(contents: String) -> Result(glance.Module, ParseError) {
  glance.module(contents) |> result.map_error(GlanceParseError)
}

fn add_module(
  program: GleamProgram,
  module_path: String,
  module_contents: glance.Module,
) -> GleamProgram {
  GleamProgram(modules: dict.insert(
    program.modules,
    module_path,
    module_contents,
  ))
}

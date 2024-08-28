//// Wrapper of glance.parse that is able to parse multiple
//// modules and load them into a larger structure.
////
//// This module technically has side effects, as it needs to read from the
//// filesystem. 
//// It does not write to the filesystem.

import compiler/project
import errors
import filepath
import filesystem
import glance
import gleam/dict
import gleam/list
import gleam/result
import gleam/set
import gleam/string

pub type GleamPackage {
  GleamPackage(
    project: project.Project,
    modules: dict.Dict(String, glance.Module),
    external_import_files: set.Set(String),
  )
}

pub type CompiledPackage {
  CompiledPackage(
    project: project.Project,
    has_main: Bool,
    modules: dict.Dict(String, String),
    external_import_files: set.Set(String),
  )
}

/// Load the entry_point file and recursively load and parse any modules it
///returns.
pub fn load(
  gleam_project: project.Project,
) -> Result(GleamPackage, errors.Error) {
  use _ <- result.try(filesystem.is_directory(project.src_dir(gleam_project)))
  use package <- result.try(load_module(
    GleamPackage(gleam_project, dict.new(), external_import_files: set.new()),
    project.entry_point(gleam_project),
  ))
  Ok(package)
}

/// Parse the module and add it to the package's modules, if it can be parsed.
/// Then recursively parse any modules it imports.
fn load_module(
  package: GleamPackage,
  module_path: String,
) -> Result(GleamPackage, errors.Error) {
  case dict.get(package.modules, module_path) {
    Ok(_) -> Ok(package)
    Error(_) -> {
      let module_result =
        project.build_src_dir(package.project)
        |> filepath.join(module_path)
        |> filesystem.read
        |> result.try(parse(_, module_path))

      case module_result {
        Error(err) -> Error(err)
        Ok(module_contents) -> {
          add_module(package, module_path, module_contents)
          |> Ok
          |> list.fold(module_contents.imports, _, fold_load_module)
        }
      }
    }
  }
}

fn fold_load_module(
  package_result: Result(GleamPackage, errors.Error),
  import_def: glance.Definition(glance.Import),
) -> Result(GleamPackage, errors.Error) {
  case package_result {
    Error(error) -> Error(error)
    Ok(package) ->
      load_module(package, import_def.definition.module <> ".gleam")
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
  package: GleamPackage,
  module_path: String,
  module_contents: glance.Module,
) -> GleamPackage {
  GleamPackage(
    ..package,
    modules: dict.insert(package.modules, module_path, module_contents),
    external_import_files: set.union(
      python_external_modules(module_contents.functions),
      package.external_import_files,
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
    ) -> Ok(string.replace(module, ".", "/") <> ".py")
    _ -> Error(Nil)
  }
}

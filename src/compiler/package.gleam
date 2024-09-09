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
import glimpse

pub type GleamPackage {
  GleamPackage(
    project: project.Project,
    package: glimpse.Package,
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
  use glimpse_package <- result.try(load_glimpse_package(gleam_project))
  Ok(GleamPackage(
    gleam_project,
    glimpse_package,
    python_externals(glimpse_package),
  ))
}

fn load_glimpse_package(
  project: project.Project,
) -> Result(glimpse.Package, errors.Error) {
  glimpse.load_package(project.name, fn(module_name) {
    let path =
      filepath.join(project.build_src_dir(project), module_name <> ".gleam")
    filesystem.read(path)
  })
  |> result.map_error(fn(error) {
    case error {
      glimpse.LoadError(error) -> error
      glimpse.ParseError(glance_error, name, content) ->
        errors.GlanceParseError(glance_error, name, content)
    }
  })
}

fn python_externals(package: glimpse.Package) -> set.Set(String) {
  dict.fold(package.modules, set.new(), fn(externals, _key, module) {
    set.union(externals, python_external_modules(module.module.functions))
  })
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

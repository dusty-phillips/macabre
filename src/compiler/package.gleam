//// Wrapper of glance.parse that is able to parse multiple
//// modules and load them into a larger structure.
////
//// This module technically has side effects, as it needs to read from the
//// filesystem. 
//// It does not write to the filesystem.

import compiler/internal/comments
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
import glimpse/error as glimpse_error
import simplifile

pub type GleamPackage {
  GleamPackage(
    project: project.Project,
    package: glimpse.Package,
    external_import_files: set.Set(String),
    comments: dict.Dict(String, List(comments.Comment)),
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
    extract_comments(gleam_project, glimpse_package),
  ))
}

// The comments for each loaded module, lexed from its source file with
// comments preserved. The source is re-read here because the parser (glance)
// discards comments before returning the module AST.
fn extract_comments(
  gleam_project: project.Project,
  package: glimpse.Package,
) -> dict.Dict(String, List(comments.Comment)) {
  dict.fold(package.modules, dict.new(), fn(acc, module_name, _module) {
    let path =
      filepath.join(
        project.build_src_dir(gleam_project),
        module_name <> ".gleam",
      )
    let module_comments =
      filesystem.read(path)
      |> result.map(comments.extract)
      |> result.unwrap([])
    dict.insert(acc, module_name, module_comments)
  })
}

fn load_glimpse_package(
  project: project.Project,
) -> Result(glimpse.Package, errors.Error) {
  let loader = fn(module_name) {
    let path =
      filepath.join(project.build_src_dir(project), module_name <> ".gleam")
    filesystem.read(path)
  }
  use main_package <- result.try(
    glimpse.load_package(project.name, loader)
    |> result.map_error(fn(error) {
      case error {
        glimpse_error.LoadError(error) -> error
        glimpse_error.ParseError(glance_error, name, content) ->
          errors.GlanceParseError(glance_error, name, content)
        glimpse_error.ImportError(import_error) ->
          errors.GlimpseImportError(import_error)
        glimpse_error.TypeCheckError(type_check_error) ->
          errors.GlimpseTypeCheckError(type_check_error)
      }
    }),
  )
  // The project's own test and dev modules are compiled alongside its src:
  // each is an extra entry point whose transitive imports resolve against the
  // same build src. A test/dev module whose dependencies are not available in
  // this build (e.g. a dev-only library like gleeunit that has no Python port)
  // is skipped rather than failing the whole build.
  let extra_entries =
    list.append(
      project.test_module_names(project),
      project.dev_module_names(project),
    )
  list.fold(extra_entries, Ok(main_package), fn(state, entry) {
    use package <- result.try(state)
    case load_module_recursively(package, entry, loader) {
      Ok(package) -> Ok(package)
      Error(errors.FileReadError(_, simplifile.Enoent)) -> Ok(package)
      Error(error) -> Error(error)
    }
  })
}

fn load_module_recursively(
  package: glimpse.Package,
  module_name: String,
  loader: fn(String) -> Result(String, errors.Error),
) -> Result(glimpse.Package, errors.Error) {
  case dict.has_key(package.modules, module_name) {
    True -> Ok(package)
    False -> {
      use content <- result.try(loader(module_name))
      use glance_module <- result.try(
        glance.module(content)
        |> result.map_error(fn(error) {
          errors.GlanceParseError(error, module_name, content)
        }),
      )
      let glimpse_module = glimpse.load_module(glance_module, module_name)
      let package =
        glimpse.Package(
          ..package,
          modules: dict.insert(package.modules, module_name, glimpse_module),
        )
      glimpse.filter_new_dependencies(glimpse_module, package)
      |> list.fold(Ok(package), fn(state, dependency) {
        use package <- result.try(state)
        load_module_recursively(package, dependency, loader)
      })
    }
  }
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
      [glance.Variable(_, "python"), glance.String(_, module), ..],
    ) -> Ok(string.replace(module, ".", "/") <> ".py")
    _ -> Error(Nil)
  }
}

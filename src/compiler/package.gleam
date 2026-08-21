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
import gleam/io
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import glimpse
import glimpse/error as glimpse_error
import glimpse/target
import glimpse/typecheck
import simplifile

pub type GleamPackage {
  GleamPackage(
    project: project.Project,
    package: glimpse.Package,
    external_import_files: set.Set(String),
    comments: dict.Dict(String, List(comments.Comment)),
    module_sources: dict.Dict(String, String),
  )
}

pub type CompiledPackage {
  CompiledPackage(
    project: project.Project,
    has_main: Bool,
    modules: dict.Dict(String, String),
    external_import_files: set.Set(String),
    /// The names of modules that define a top-level `main` function; these get
    /// an `if __name__ == "__main__"` block appended when written, so they can
    /// be run directly as scripts.
    main_modules: set.Set(String),
    /// Submodules `parent/seg` whose last segment collides with a public
    /// top-level value of `parent`, mapped to their mangled path
    /// `parent/seg_module`. The on-disk file and every import of the submodule
    /// use the mangled path, so the parent's re-exported value is not shadowed
    /// in Python.
    mangled_submodules: dict.Dict(String, String),
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
    extract_module_sources(gleam_project, glimpse_package),
  ))
}

// The raw source of each loaded module, used to compute line numbers for
// runtime panic payloads. Re-read here because glimpse discards the source
// after parsing.
fn extract_module_sources(
  gleam_project: project.Project,
  package: glimpse.Package,
) -> dict.Dict(String, String) {
  dict.fold(package.modules, dict.new(), fn(acc, module_name, _module) {
    let path =
      filepath.join(
        project.build_src_dir(gleam_project),
        module_name <> ".gleam",
      )
    let module_source = filesystem.read(path) |> result.unwrap("")
    dict.insert(acc, module_name, module_source)
  })
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
  // A package's entry module is normally named after the project itself, but
  // some libraries keep their root module under a different path (e.g.
  // `gleam_community/colour` for the `gleam_community_colour` project). When
  // the entry module is absent, start from an empty package and let the
  // project's test and dev modules pull in whatever src modules they import.
  let main_path =
    filepath.join(project.build_src_dir(project), project.name <> ".gleam")
  use main_package <- result.try(case filesystem.read(main_path) {
    Ok(_) ->
      glimpse.load_package(project.name, loader)
      |> result.map_error(fn(error) {
        case error {
          glimpse_error.LoadError(error) -> error
          glimpse_error.ParseError(glance_error, name, content) ->
            errors.GlanceParseError(glance_error, name, content)
          glimpse_error.ImportError(import_error) ->
            errors.GlimpseImportError(import_error)
          glimpse_error.TypeCheckError(type_check_error) ->
            errors.GlimpseTypeCheckError("", type_check_error)
        }
      })
    Error(_) -> Ok(glimpse.Package(project.name, dict.new(), []))
  })
  // The project's own test and dev modules are compiled alongside its src:
  // each is an extra entry point whose transitive imports resolve against the
  // same build src. A test/dev module whose dependencies are not available in
  // this build (e.g. a dev-only library like gleeunit that has no Python port)
  // is skipped rather than failing the whole build — but loudly: a skipped
  // module is reported so a broken or partially-available test module is never
  // silently dropped.
  let extra_entries =
    list.append(
      project.test_module_names(project),
      project.dev_module_names(project),
    )
  list.fold(extra_entries, Ok(main_package), fn(state, entry) {
    use package <- result.try(state)
    case load_module_recursively(package, entry, loader) {
      Ok(package) -> Ok(package)
      Error(errors.FileReadError(_, simplifile.Enoent)) -> {
        io.println_error(
          "warning: skipping test/dev module "
          <> entry
          <> " (a dependency of this module is not available in this build)",
        )
        Ok(package)
      }
      Error(error) -> Error(error)
    }
  })
  |> result.try(typecheck_package)
}

// Typechecks every module in the package for the python target using glimpse's
// typechecker, catching type errors, name errors, and exhaustiveness problems
// that macabre's transpiler would otherwise silently compile into runtime
// failures. Returns the typechecked package, whose modules carry the inferred
// types.
//
// glimpse's `typecheck.package` only checks the modules reachable from the
// single entry point named after the project, but macabre compiles every
// loaded module (the root module may live under a different path, and test and
// dev modules are additional entry points). So the full module set is sorted
// topologically and each module is checked individually.
fn typecheck_package(
  package: glimpse.Package,
) -> Result(glimpse.Package, errors.Error) {
  // An empty package (no root module named after the project and nothing
  // importing any other module) has nothing to check.
  case dict.is_empty(package.modules) {
    True -> Ok(package)
    False -> {
      let graph =
        dict.map_values(package.modules, fn(_, module) { module.dependencies })
      use sorted <- result.try(
        topo_sort(graph)
        |> result.map_error(errors.GlimpseImportError),
      )
      let target = target.Named("python")
      list.fold(sorted, Ok(#(package, dict.new())), fn(state, module_name) {
        use #(package, envs) <- result.try(state)
        use glimpse_module <- result.try(
          dict.get(package.modules, module_name)
          |> result.replace_error(
            errors.GlimpseImportError(glimpse_error.MissingImportError(
              module_name,
            )),
          ),
        )
        use #(new_module, env) <- result.try(
          typecheck.module(glimpse_module, envs, target, True)
          |> result.map_error(fn(error) {
            errors.GlimpseTypeCheckError(module_name, error)
          }),
        )
        let modules = dict.insert(package.modules, module_name, new_module)
        Ok(#(
          glimpse.Package(..package, modules: modules),
          dict.insert(envs, module_name, env),
        ))
      })
      |> result.map(fn(state) { state.0 })
    }
  }
}

// Topologically sorts every module in the import graph (not just those
// reachable from a single entry point) from leaves to roots: a module is only
// processed after all of its dependencies. Returns the module names in that
// order, or a circular-dependency error.
fn topo_sort(
  graph: dict.Dict(String, List(String)),
) -> Result(List(String), glimpse_error.GlimpseImportError) {
  let all_modules = dict.keys(graph)
  let module_set = set.from_list(all_modules)
  topo_sort_recurse(graph, module_set, [])
  |> result.map(list.reverse)
}

fn topo_sort_recurse(
  graph: dict.Dict(String, List(String)),
  remaining: set.Set(String),
  result: List(String),
) -> Result(List(String), glimpse_error.GlimpseImportError) {
  case set.is_empty(remaining) {
    True -> Ok(result)
    False -> {
      // A module is ready when none of its remaining dependencies are
      // unprocessed. A dependency that is not itself a module in the package
      // (e.g. an unavailable dev-only library) is treated as already
      // satisfied.
      let ready =
        set.filter(remaining, fn(module_name) {
          case dict.get(graph, module_name) {
            Ok(dependencies) ->
              list.all(dependencies, fn(dep) { !set.contains(remaining, dep) })
            Error(_) -> True
          }
        })
      case set.is_empty(ready) {
        True -> Error(glimpse_error.CircularDependencyError(""))
        False -> {
          let next =
            ready
            |> set.to_list
            |> list.first
            |> result.unwrap("")
          let remaining = set.delete(remaining, next)
          topo_sort_recurse(graph, remaining, list.prepend(result, next))
        }
      }
    }
  }
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

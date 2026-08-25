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
    case is_other_target_module(module_name) {
      True -> Error(errors.UnsupportedTargetModule(module_name))
      False -> {
        let path =
          filepath.join(project.build_src_dir(project), module_name <> ".gleam")
        filesystem.read(path)
      }
    }
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
  // The src-tree module set, captured before test/dev entries are folded in.
  // Type errors for these modules are always hard failures; modules loaded
  // only for test/dev entries get one leniency (see typecheck_package).
  let src_modules = set.from_list(dict.keys(main_package.modules))
  // The project's own test and dev modules are compiled alongside its src:
  // each is an extra entry point whose transitive imports resolve against the
  // same build src. A test/dev module whose dependency is missing from this
  // build is a hard error: a package that compiles on erlang/javascript
  // must not have its tests silently dropped.
  let extra_entries =
    list.append(
      project.test_module_names(project),
      project.dev_module_names(project),
    )
  list.fold(extra_entries, Ok(main_package), fn(state, entry) {
    use package <- result.try(state)
    case load_module_recursively(package, entry, loader) {
      Ok(package) -> Ok(package)
      Error(errors.FileReadError(missing, simplifile.Enoent)) ->
        Error(errors.MissingDependency(entry, missing))
      // Host-support modules for other targets (gleam/erlang,
      // gleam/javascript) can never be part of a python build. A test or dev
      // entry that transitively needs one is skipped with a loud warning
      // instead of failing the whole build; the src entry point still
      // hard-errors through glimpse.load_package above.
      Error(errors.UnsupportedTargetModule(missing)) -> {
        io.println_error(
          "Skipping test/dev module `"
          <> entry
          <> "`: it imports `"
          <> missing
          <> "`, which has no python implementation",
        )
        Ok(package)
      }
      Error(error) -> Error(error)
    }
  })
  |> result.try(typecheck_package(src_modules, _))
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
  src_modules: set.Set(String),
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
        // A module dropped earlier in the fold (skipped as target-locked
        // together with its transitive dependents) is simply absent here.
        case dict.get(package.modules, module_name) {
          Error(_) -> Ok(#(package, envs))
          Ok(glimpse_module) ->
            case typecheck.module(glimpse_module, envs, target, True) {
              Ok(#(new_module, env)) -> {
                let modules =
                  dict.insert(package.modules, module_name, new_module)
                Ok(#(
                  glimpse.Package(..package, modules: modules),
                  dict.insert(envs, module_name, env),
                ))
              }
              // A test/dev-only module whose code path needs erlang- or
              // javascript-only values (glimpse reports the first offending call
              // as UnsupportedTarget) cannot run on python. Skip it — and every
              // test/dev module that (transitively) imports it, since they cannot
              // typecheck without it — with a loud warning rather than failing
              // the build. Src-tree modules always hard-error so a broken
              // library can never be silenced here.
              Error(glimpse_error.UnsupportedTarget(name)) -> {
                let skippable = !set.contains(src_modules, module_name)
                case skippable {
                  True -> {
                    let dropped = dependent_closure(graph, module_name)
                    dropped
                    |> set.to_list
                    |> list.each(fn(dropped_name) {
                      io.println_error(
                        "Skipping test/dev module `"
                        <> dropped_name
                        <> "`: it depends on `"
                        <> module_name
                        <> "`, which uses `"
                        <> name
                        <> "`, which has no python implementation",
                      )
                    })
                    Ok(#(
                      glimpse.Package(
                        ..package,
                        modules: set.fold(dropped, package.modules, dict.delete),
                      ),
                      envs,
                    ))
                  }
                  False ->
                    Error(errors.GlimpseTypeCheckError(
                      module_name,
                      glimpse_error.UnsupportedTarget(name),
                    ))
                }
              }
              Error(error) ->
                Error(errors.GlimpseTypeCheckError(module_name, error))
            }
        }
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

// Modules under these namespaces are host-support shims for the erlang and
// javascript targets (e.g. the gleam_erlang and gleam_javascript packages).
// They never have a python implementation, so macabre treats them as absent:
// the module loader refuses them and test/dev entries that transitively need
// one are skipped with a warning.
fn is_other_target_module(module_name: String) -> Bool {
  string.starts_with(module_name, "gleam/erlang/")
  || string.starts_with(module_name, "gleam/javascript/")
}

// All modules that transitively depend on `module_name` (excluding itself),
// computed from the import graph. Used to drop the dependents of a skipped
// test/dev module: they cannot typecheck without it.
fn dependent_closure(
  graph: dict.Dict(String, List(String)),
  module_name: String,
) -> set.Set(String) {
  // Reverse edges: importer -> list of modules it is imported by.
  let reverse =
    dict.fold(graph, dict.new(), fn(acc, importer, dependencies) {
      list.fold(dependencies, acc, fn(acc, dependency) {
        case dict.get(acc, dependency) {
          Ok(importers) -> dict.insert(acc, dependency, [importer, ..importers])
          Error(_) -> dict.insert(acc, dependency, [importer])
        }
      })
    })
  dependent_closure_loop(reverse, set.from_list([module_name]), set.new())
}

fn dependent_closure_loop(
  reverse: dict.Dict(String, List(String)),
  frontier: set.Set(String),
  visited: set.Set(String),
) -> set.Set(String) {
  case set.is_empty(frontier) {
    True -> visited
    False -> {
      let next =
        frontier
        |> set.to_list
        |> list.flat_map(fn(name) {
          dict.get(reverse, name) |> result.unwrap([])
        })
        |> set.from_list
        |> set.drop(set.to_list(visited))
      let visited = set.union(visited, frontier)
      dependent_closure_loop(reverse, next, visited)
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

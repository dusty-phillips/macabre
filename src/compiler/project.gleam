// A project rooted at a gleam.toml
// maintains the build directory.
// Copies sources from src/ to build/src
// Downloads dependencies from github to build/packages
// copies sources from build/packages/src/* to build/src
// During compiling, all sources are treated like one "package"
// compiled to build/dev/python

import errors
import filepath
import filesystem
import git
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import hex
import simplifile
import tom

pub type Project {
  Project(
    name: String,
    packages: dict.Dict(String, Package),
    base_directory: String,
  )
}

/// A dependency, using the same syntax as the official Gleam build tool.
pub type Package {
  /// A dependency cloned from a git repository.
  GitPackage(git_url: String, git_ref: String, path: option.Option(String))
  /// A dependency downloaded from Hex.
  HexPackage(version: String)
  /// A dependency loaded from a local directory.
  LocalPackage(path: String)
}

pub fn load(base_directory: String) -> Result(Project, errors.Error) {
  use #(toml_path, toml_contents) <- result.try(find_project_config(
    base_directory,
  ))
  use parsed_toml <- result.try(
    tom.parse(toml_contents)
    |> result.map_error(errors.TomlParseError(toml_path, _)),
  )
  use name <- result.try(
    tom.get_string(parsed_toml, ["name"])
    |> result.map_error(errors.TomlFieldError(toml_path, _)),
  )
  use packages <- result.try(load_dependency_list(
    base_directory,
    parsed_toml,
    toml_path,
  ))

  Ok(Project(name, packages, base_directory))
}

/// Find and read the project configuration file.
///
/// Macabre projects use `macabre.toml` if it exists, falling back to the
/// official Gleam `gleam.toml` otherwise. The chosen path is returned along
/// with its contents.
fn find_project_config(
  base_directory: String,
) -> Result(#(String, String), errors.Error) {
  let macabre_path = filepath.join(base_directory, "macabre.toml")
  case simplifile.read(macabre_path) {
    Ok(contents) -> Ok(#(macabre_path, contents))
    Error(simplifile.Enoent) -> {
      let gleam_path = filepath.join(base_directory, "gleam.toml")
      simplifile.read(gleam_path)
      |> result.map(fn(contents) { #(gleam_path, contents) })
      |> result.map_error(errors.FileReadError(gleam_path, _))
    }
    Error(error) -> Error(errors.FileReadError(macabre_path, error))
  }
}

/// The entry_point for a project, relative to the build src directory.
pub fn entry_point(project: Project) -> String {
  project.name <> ".gleam"
}

pub fn src_dir(project: Project) -> String {
  project.base_directory |> filepath.join("src")
}

pub fn test_dir(project: Project) -> String {
  project.base_directory |> filepath.join("test")
}

pub fn dev_dir(project: Project) -> String {
  project.base_directory |> filepath.join("dev")
}

pub fn build_dir(project: Project) -> String {
  project.base_directory
  |> filepath.join("build")
}

/// The directory that all package sources (including dependencies)
/// are copied into and loaded from.
pub fn build_src_dir(project: Project) -> String {
  project
  |> build_dir
  |> filepath.join("src")
}

pub fn build_dev_dir(project: Project) -> String {
  project |> build_dir |> filepath.join("dev")
}

pub fn build_dev_python_dir(project: Project) -> String {
  project
  |> build_dev_dir
  |> filepath.join("python")
}

pub fn packages_dir(project: Project) -> String {
  project
  |> build_dir
  |> filepath.join("packages")
}

pub fn package_dir(project: Project, package_name: String) -> String {
  project
  |> packages_dir
  |> filepath.join(package_name)
}

pub fn package_src_dir(
  project: Project,
  package_name: String,
  package: Package,
) -> String {
  package_root(project, package_name, package) |> filepath.join("src")
}

/// The root directory of a package: where its own config file and `src/`
/// directory live. For a git package with a sub-directory `path`, that is the
/// root; otherwise it is the clone/fetch/local directory itself.
pub fn package_root(
  project: Project,
  package_name: String,
  package: Package,
) -> String {
  case package {
    GitPackage(path: option.Some(subdir), ..) ->
      package_dir(project, package_name) |> filepath.join(subdir)
    GitPackage(..) -> package_dir(project, package_name)
    HexPackage(..) -> package_dir(project, package_name)
    LocalPackage(path) -> path
  }
}

pub fn clone_packages(project: Project) -> Result(Project, errors.Error) {
  let package_directory = packages_dir(project)
  use _ <- result.try(
    simplifile.create_directory_all(package_directory)
    |> result.map_error(errors.MkdirError(package_directory, _)),
  )
  // Clone the direct dependencies, then discover each one's own dependencies
  // by reading its config file, and clone those too. Returns the project with
  // the fully expanded package set.
  clone_and_discover(
    project,
    package_directory,
    dict.keys(project.packages),
    set.new(),
  )
}

fn clone_and_discover(
  project: Project,
  package_directory: String,
  worklist: List(String),
  cloned: set.Set(String),
) -> Result(Project, errors.Error) {
  case worklist {
    [] -> Ok(project)
    [name, ..rest] ->
      case set.contains(cloned, name) {
        True -> clone_and_discover(project, package_directory, rest, cloned)
        False -> {
          let cloned = set.insert(cloned, name)
          case dict.get(project.packages, name) {
            Error(_) ->
              clone_and_discover(project, package_directory, rest, cloned)
            Ok(package) -> {
              use _ <- result.try(clone_one(package_directory, name, package))
              case
                load_package_dependencies(package_root(project, name, package))
              {
                Ok(deps) -> {
                  let #(project, new_names) = add_new_deps(project, deps)
                  clone_and_discover(
                    project,
                    package_directory,
                    list.append(rest, new_names),
                    cloned,
                  )
                }
                Error(_) ->
                  clone_and_discover(project, package_directory, rest, cloned)
              }
            }
          }
        }
      }
  }
}

fn clone_one(
  package_directory: String,
  name: String,
  package: Package,
) -> Result(Nil, errors.Error) {
  case package {
    GitPackage(git_url:, git_ref:, path: _) ->
      git.clone(name, git_url, git_ref, package_directory)
    HexPackage(version) -> hex.fetch(package_directory, name, version)
    LocalPackage(_) -> Ok(Nil)
  }
}

/// The dependencies of a package, read from its own config file. Only git and
/// local deps are followed: a dependency's config lists hex deps as version
/// constraints that macabre can't fetch, and in the macabre ecosystem those are
/// replaced by the `macabre_*` git forks anyway. A local dep's path is
/// relative to the declaring package's root, so it is resolved against it.
fn load_package_dependencies(
  package_root: String,
) -> Result(dict.Dict(String, Package), errors.Error) {
  case find_project_config(package_root) {
    Error(_) -> Ok(dict.new())
    Ok(#(toml_path, contents)) -> {
      use parsed_toml <- result.try(
        tom.parse(contents)
        |> result.map_error(errors.TomlParseError(toml_path, _)),
      )
      parse_gleam_dependencies(parsed_toml)
      |> result.map(fn(deps) {
        dict.map_values(deps, fn(_name, package) {
          case package {
            LocalPackage(path) ->
              case filepath.is_absolute(path) {
                True -> package
                False -> LocalPackage(filepath.join(package_root, path))
              }
            other -> other
          }
        })
        |> dict.filter(fn(_name, package) {
          case package {
            GitPackage(..) -> True
            LocalPackage(_) -> True
            HexPackage(_) -> False
          }
        })
      })
      |> result.map_error(errors.TomlFieldError(toml_path, _))
    }
  }
}

fn add_new_deps(
  project: Project,
  deps: dict.Dict(String, Package),
) -> #(Project, List(String)) {
  dict.fold(deps, #(project, []), fn(acc, name, package) {
    let #(project, new_names) = acc
    case dict.has_key(project.packages, name) {
      True -> acc
      False -> #(
        Project(
          ..project,
          packages: dict.insert(project.packages, name, package),
        ),
        [name, ..new_names],
      )
    }
  })
}

pub fn copy_package_srcs(project: Project) -> Result(Nil, errors.Error) {
  let project_src_dir = build_src_dir(project)
  use _ <- result.try(filesystem.create_directory(project_src_dir))
  dict.fold(project.packages, Ok(Nil), fn(state, name, package) {
    use _ <- result.try(state)
    use _ <- result.try(filesystem.copy_dir(
      package_src_dir(project, name, package),
      project_src_dir,
    ))
    Ok(Nil)
  })
}

pub fn copy_project_srcs(project: Project) -> Result(Nil, errors.Error) {
  filesystem.copy_dir(src_dir(project), build_src_dir(project))
}

// The project's own test/ and dev/ directories are copied into the shared
// build src so their modules can be compiled. A dependency's test/ and dev/
// directories are never copied: only its src/ is used (see copy_package_srcs).
pub fn copy_project_test_srcs(project: Project) -> Result(Nil, errors.Error) {
  copy_project_extra_srcs(project, test_dir(project))
}

pub fn copy_project_dev_srcs(project: Project) -> Result(Nil, errors.Error) {
  copy_project_extra_srcs(project, dev_dir(project))
}

fn copy_project_extra_srcs(
  project: Project,
  dir: String,
) -> Result(Nil, errors.Error) {
  case simplifile.is_directory(dir) {
    Ok(True) -> filesystem.copy_dir(dir, build_src_dir(project))
    _ -> Ok(Nil)
  }
}

/// The module names defined by the project's test/ directory, e.g.
/// `foo/bar_test` for `test/foo/bar_test.gleam`.
pub fn test_module_names(project: Project) -> List(String) {
  module_names_in(test_dir(project))
}

/// The module names defined by the project's dev/ directory.
pub fn dev_module_names(project: Project) -> List(String) {
  module_names_in(dev_dir(project))
}

fn module_names_in(dir: String) -> List(String) {
  case simplifile.get_files(dir) {
    Error(_) -> []
    Ok(files) ->
      files
      |> list.filter(fn(file) { string.ends_with(file, ".gleam") })
      |> list.map(fn(file) {
        file
        |> string.remove_prefix(dir)
        |> string.remove_prefix("/")
        |> filepath.strip_extension
      })
      |> list.sort(string.compare)
  }
}

pub fn clean(project: Project) -> Result(Nil, errors.Error) {
  project
  |> build_dir
  |> filesystem.delete
}

fn load_dependency_list(
  base_directory: String,
  toml: dict.Dict(String, tom.Toml),
  toml_path: String,
) -> Result(dict.Dict(String, Package), errors.Error) {
  case filepath.base_name(toml_path) {
    // The manifest is a lockfile generated from gleam.toml by the official
    // tool. A macabre.toml project has no manifest, so read the dependencies
    // straight from the config file.
    "macabre.toml" ->
      parse_gleam_dependencies(toml)
      |> result.map_error(errors.TomlFieldError(toml_path, _))
    _ -> {
      let manifest_path = filepath.join(base_directory, "manifest.toml")
      case simplifile.read(manifest_path) {
        Error(_) ->
          parse_gleam_dependencies(toml)
          |> result.map_error(errors.TomlFieldError(toml_path, _))
        Ok(contents) -> parse_manifest(manifest_path, contents)
      }
    }
  }
}

fn parse_manifest(
  manifest_path: String,
  contents: String,
) -> Result(dict.Dict(String, Package), errors.Error) {
  use parsed_toml <- result.try(
    tom.parse(contents)
    |> result.map_error(errors.TomlParseError(manifest_path, _)),
  )
  use packages <- result.try(
    tom.get_array(parsed_toml, ["packages"])
    |> result.map_error(errors.TomlFieldError(manifest_path, _)),
  )
  packages
  |> list.fold(Ok(dict.new()), fn(state, package) {
    use state_dict <- result.try(state)
    use #(name, parsed_package) <- result.try(
      parse_manifest_package(package)
      |> result.map_error(errors.TomlFieldError(manifest_path, _)),
    )
    Ok(dict.insert(state_dict, name, parsed_package))
  })
}

fn parse_manifest_package(
  package: tom.Toml,
) -> Result(#(String, Package), tom.GetError) {
  use table <- result.try(tom.as_table(package))
  use name <- result.try(tom.get_string(table, ["name"]))
  use version <- result.try(tom.get_string(table, ["version"]))
  use source <- result.try(tom.get_string(table, ["source"]))
  let parsed = case source {
    "hex" -> Ok(HexPackage(version))
    "git" -> {
      use repo <- result.try(tom.get_string(table, ["repo"]))
      use commit <- result.try(tom.get_string(table, ["commit"]))
      let path = case tom.get_string(table, ["path"]) {
        Ok(path) -> option.Some(path)
        Error(_) -> option.None
      }
      Ok(GitPackage(repo, commit, path))
    }
    "local" -> {
      use path <- result.try(tom.get_string(table, ["path"]))
      Ok(LocalPackage(path))
    }
    other -> Error(tom.WrongType(["source"], "hex, git or local", other))
  }
  parsed |> result.map(fn(package) { #(name, package) })
}

fn parse_gleam_dependencies(
  toml: dict.Dict(String, tom.Toml),
) -> Result(dict.Dict(String, Package), tom.GetError) {
  case tom.get_table(toml, ["dependencies"]) {
    Ok(dependencies) -> {
      use state, key, _value <- dict.fold(dependencies, Ok(dict.new()))
      use state_dict <- result.try(state)
      use package <- result.try(parse_dependency(dependencies, key))
      Ok(dict.insert(state_dict, key, package))
    }
    Error(tom.NotFound(_)) -> Ok(dict.new())
    Error(tom.WrongType(..) as error) -> Error(error)
  }
}

fn parse_dependency(
  dependencies: dict.Dict(String, tom.Toml),
  key: String,
) -> Result(Package, tom.GetError) {
  case tom.get(dependencies, [key]) {
    Ok(value) -> {
      case tom.as_string(value) {
        Ok(version) -> Ok(HexPackage(version))
        Error(_) -> {
          use table <- result.try(tom.get_table(dependencies, [key]))
          case tom.get_string(table, ["git"]) {
            Ok(git_url) -> {
              use git_ref <- result.try(tom.get_string(table, ["ref"]))
              let path = case tom.get_string(table, ["path"]) {
                Ok(path) -> option.Some(path)
                Error(_) -> option.None
              }
              Ok(GitPackage(git_url, git_ref, path))
            }
            Error(_) -> {
              use path <- result.try(tom.get_string(table, ["path"]))
              Ok(LocalPackage(path))
            }
          }
        }
      }
    }
    Error(error) -> Error(error)
  }
}

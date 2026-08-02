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
import simplifile
import tom

pub type Project {
  Project(
    name: String,
    packages: dict.Dict(String, Package),
    base_directory: String,
  )
}

/// A git dependency, using the same syntax as the official Gleam build tool.
pub type Package {
  Package(git_url: String, git_ref: String, path: option.Option(String))
}

pub fn load(base_directory: String) -> Result(Project, errors.Error) {
  let toml_path = filepath.join(base_directory, "gleam.toml")
  use toml_contents <- result.try(
    simplifile.read(toml_path)
    |> result.map_error(errors.FileReadError(toml_path, _)),
  )
  use parsed_toml <- result.try(
    tom.parse(toml_contents)
    |> result.map_error(errors.TomlParseError(toml_path, _)),
  )
  use name <- result.try(
    tom.get_string(parsed_toml, ["name"])
    |> result.map_error(errors.TomlFieldError(toml_path, _)),
  )
  use packages <- result.try(
    load_dependency_list(parsed_toml)
    |> result.map_error(errors.TomlFieldError(toml_path, _)),
  )

  Ok(Project(name, packages, base_directory))
}

/// The entry_point for a project, relative to the build src directory.
pub fn entry_point(project: Project) -> String {
  project.name <> ".gleam"
}

pub fn src_dir(project: Project) -> String {
  project.base_directory |> filepath.join("src")
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
  let package_root = case package.path {
    option.Some(subdir) ->
      package_dir(project, package_name) |> filepath.join(subdir)
    option.None -> package_dir(project, package_name)
  }
  package_root |> filepath.join("src")
}

pub fn clone_packages(project: Project) -> Result(Nil, errors.Error) {
  let package_directory = packages_dir(project)
  use _ <- result.try(
    simplifile.create_directory_all(package_directory)
    |> result.map_error(errors.MkdirError(package_directory, _)),
  )
  project.packages
  |> dict.to_list
  |> list.map(fn(tuple) {
    let #(name, package) = tuple
    git.clone(name, package.git_url, package.git_ref, package_directory)
  })
  |> result.all
  |> result.replace(Nil)
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

pub fn clean(project: Project) -> Result(Nil, errors.Error) {
  project
  |> build_dir
  |> filesystem.delete
}

fn load_dependency_list(
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
  use table <- result.try(tom.get_table(dependencies, [key]))
  use git_url <- result.try(tom.get_string(table, ["git"]))
  use git_ref <- result.try(tom.get_string(table, ["ref"]))
  let path = case tom.get_string(table, ["path"]) {
    Ok(path) -> option.Some(path)
    Error(_) -> option.None
  }
  Ok(Package(git_url, git_ref, path))
}

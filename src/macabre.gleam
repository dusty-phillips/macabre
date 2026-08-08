import argv
import compiler
import compiler/package
import compiler/project
import errors
import filepath
import filesystem
import gleam/dict
import gleam/io
import gleam/list
import gleam/result.{try}
import gleam/set
import gleam/string

pub fn main() {
  case argv.load().arguments {
    [] -> usage("Not enough arguments")
    [directory] -> build(directory)
    [_, _, ..] -> usage("Too many arguments")
  }
}

pub fn usage(message: String) -> Nil {
  io.println(
    "Usage: macabre <some_package_folder>\n"
    <> "Reads the package's macabre.toml if present, else its gleam.toml.\n\n"
    <> message,
  )
}

pub fn build(directory: String) -> Nil {
  {
    use gleam_project <- try(project.load(directory))
    use _ <- try(project.clean(gleam_project))
    use _ <- try(project.clone_packages(gleam_project))
    use _ <- try(project.copy_package_srcs(gleam_project))
    use _ <- try(project.copy_project_srcs(gleam_project))
    use gleam_package <- try(package.load(gleam_project))
    let compiled_package = compiler.compile_package(gleam_package)
    use _ <- result.try(write_package(compiled_package))
    Ok(Nil)
  }
  |> result.map_error(filesystem.write_error)
  |> result.unwrap(Nil)
}

pub fn write_package(
  package: package.CompiledPackage,
) -> Result(Nil, errors.Error) {
  let build_directory = project.build_dev_python_dir(package.project)
  let source_directory = project.build_src_dir(package.project)
  filesystem.delete(build_directory)
  |> try(fn(_) { filesystem.create_directory(build_directory) })
  |> try(fn(_) { filesystem.write_prelude_file(build_directory) })
  |> try(fn(_) {
    filesystem.write_py_main(
      package.has_main,
      build_directory,
      package.project.name,
    )
  })
  |> try(fn(_) {
    filesystem.copy_externals(
      build_directory,
      source_directory,
      package.external_import_files |> set.to_list,
    )
  })
  |> try(fn(_) {
    let module_names = dict.keys(package.modules)
    dict.fold(package.modules, Ok(Nil), fn(state, name, module) {
      try(state, fn(_) {
        let has_submodules =
          list.any(module_names, fn(other) {
            other != name && string.starts_with(other, name <> "/")
          })
        let target = case has_submodules {
          True ->
            build_directory
            |> filepath.join(name)
            |> filepath.join("__init__.py")
          False ->
            build_directory
            |> filepath.join(name)
            |> filesystem.replace_extension()
        }
        filesystem.write(module, target)
      })
    })
  })
}

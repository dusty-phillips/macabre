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
import python_prelude
import shellout

pub fn main() {
  case argv.load().arguments {
    [] -> usage("Not enough arguments")
    [directory] -> build(directory)
    ["test", directory] -> run_test(directory)
    [directory, "test"] -> run_test(directory)
    [_, _, ..] -> usage("Too many arguments")
  }
}

pub fn usage(message: String) -> Nil {
  io.println(
    "Usage: macabre <some_package_folder>\n"
    <> "       macabre <some_package_folder> test\n"
    <> "Reads the package's macabre.toml if present, else its gleam.toml.\n"
    <> "The `test` command builds the project and runs its compiled test\n"
    <> "suite with Python.\n\n"
    <> message,
  )
}

pub fn build(directory: String) -> Nil {
  case load_and_compile(directory) {
    Error(error) -> filesystem.write_error(error)
    Ok(_) -> Nil
  }
}

// Compiles a project into build/dev/python, ready for Python to run.
fn load_and_compile(
  directory: String,
) -> Result(package.CompiledPackage, errors.Error) {
  {
    use gleam_project <- try(project.load(directory))
    use _ <- try(project.clean(gleam_project))
    // clone_packages returns the project with its packages expanded to the
    // transitive closure, so the copy step below copies every dependency.
    use gleam_project <- try(project.clone_packages(gleam_project))
    use _ <- try(project.copy_package_srcs(gleam_project))
    use _ <- try(project.copy_project_srcs(gleam_project))
    use _ <- try(project.copy_project_test_srcs(gleam_project))
    use _ <- try(project.copy_project_dev_srcs(gleam_project))
    use gleam_package <- try(package.load(gleam_project))
    let compiled_package = compiler.compile_package(gleam_package)
    use _ <- result.try(write_package(compiled_package))
    Ok(compiled_package)
  }
}

// Builds the project and runs the compiled test suite (the `<name>_test`
// module, which typically calls `gleeunit.main()`). The exit status is the
// test runner's: 0 when all tests pass, non-zero otherwise.
pub fn run_test(directory: String) -> Nil {
  case load_and_compile(directory) {
    Error(error) -> filesystem.write_error(error)
    Ok(compiled_package) -> {
      let test_module = compiled_package.project.name <> "_test.py"
      // The subprocess runs with the project directory as its working
      // directory, so the compiled test module is referenced relative to it.
      let test_path =
        compiled_package.project
        |> project.build_dev_python_dir
        |> string.remove_prefix(compiled_package.project.base_directory <> "/")
        |> filepath.join(test_module)
      case
        shellout.command(run: "python3", with: [test_path], in: directory, opt: [
          shellout.LetBeStdout,
        ])
      {
        Ok(_) -> shellout.exit(0)
        Error(#(status, _)) -> shellout.exit(status)
      }
    }
  }
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
        // Modules with a `main` are runnable as scripts: give them their own
        // `if __name__ == "__main__"` block (e.g. the test entry).
        let contents = case set.contains(package.main_modules, name) {
          True -> string.trim(module) <> "\n\n" <> python_prelude.ifmain
          False -> module
        }
        filesystem.write(contents, target)
      })
    })
  })
}

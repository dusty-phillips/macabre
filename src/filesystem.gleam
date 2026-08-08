//// Mostly a wrapper of simplifile that translates to errors to errors.Error

import errors
import filepath
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import python_prelude
import simplifile

pub fn write(contents: String, filename: String) -> Result(Nil, errors.Error) {
  use _ <- result.try(
    filename
    |> filepath.directory_name
    |> simplifile.create_directory_all
    |> result.map_error(fn(error) {
      errors.MkdirError(filepath.directory_name(filename), error)
    }),
  )
  simplifile.write(filename, contents)
  |> result.map_error(errors.FileWriteError(filename, _))
}

pub fn read(filename: String) -> Result(String, errors.Error) {
  simplifile.read(filename)
  |> result.map_error(errors.FileReadError(filename, _))
}

pub fn replace_extension(filename: String) -> String {
  filename |> filepath.strip_extension <> ".py"
}

pub fn replace_file(path: String, filename: String) -> String {
  path |> filepath.directory_name |> filepath.join(filename)
}

pub fn compile_result(filename: String, result: Result(Nil, String)) -> Nil {
  case result {
    Ok(_) ->
      io.println(
        "Compiled "
        <> filename
        <> " to "
        <> filename |> replace_extension
        <> " successfully",
      )
    Error(error) -> io.println("Error: " <> error)
  }
}

pub fn write_prelude_file(
  build_directory: String,
) -> Result(Nil, errors.Error) {
  build_directory
  |> filepath.join("gleam_builtins.py")
  |> write(python_prelude.gleam_builtins, _)
}

pub fn write_py_main(
  has_main: Bool,
  build_dir: String,
  module: String,
) -> Result(Nil, errors.Error) {
  case has_main {
    True ->
      filepath.join(build_dir, "__main__.py")
      |> write(python_prelude.dunder_main(module), _)
    False -> Ok(Nil)
  }
}

pub fn write_error(error: errors.Error) -> Nil {
  error
  |> errors.format_error
  |> io.println
}

pub fn delete(path: String) -> Result(Nil, errors.Error) {
  simplifile.delete_all([path]) |> result.map_error(errors.DeleteError(path, _))
}

pub fn is_directory(path) -> Result(Bool, errors.Error) {
  simplifile.is_directory(path)
  |> result.map_error(errors.FileOrDirectoryNotFound(path, _))
}

pub fn create_directory(path) -> Result(Nil, errors.Error) {
  simplifile.create_directory_all(path)
  |> result.map_error(errors.MkdirError(path, _))
}

pub fn copy_dir(src: String, dest: String) -> Result(Nil, errors.Error) {
  use files <- result.try(
    simplifile.get_files(src)
    |> result.map_error(errors.FileOrDirectoryNotFound(src, _)),
  )
  list.try_fold(files, Nil, fn(_, file) {
    let relative =
      file
      |> string.remove_prefix(src)
      |> string.remove_prefix("/")
    let target = filepath.join(dest, relative)
    let target_dir = filepath.directory_name(target)
    simplifile.create_directory_all(target_dir)
    |> result.try(fn(_) { simplifile.copy_file(file, target) })
    |> result.map_error(errors.CopyFileError(file, target, _))
  })
}

pub fn copy_externals(
  build_directory: String,
  source_directory: String,
  files: List(String),
) -> Result(Nil, errors.Error) {
  // Copy every python helper found under the source directory in addition to
  // the explicitly referenced externals: bindings may import helper modules
  // (e.g. generated unicode tables) that are never referenced by an
  // `@external(python, ...)` attribute.
  let files =
    simplifile.get_files(source_directory)
    |> result.unwrap([])
    |> list.filter(fn(file) { string.ends_with(file, ".py") })
    |> list.map(fn(file) {
      file
      |> string.remove_prefix(source_directory)
      |> string.remove_prefix("/")
    })
    |> list.append(files)
    |> list.unique
  list.fold(files, Ok(Nil), fn(state, file) {
    case state {
      Ok(Nil) -> {
        let src = filepath.join(source_directory, file)
        let dst = filepath.join(build_directory, file)
        let dst_dir = filepath.directory_name(dst)
        simplifile.create_directory_all(dst_dir)
        |> result.try(fn(__main__) { simplifile.copy_file(src, dst) })
        |> result.map_error(errors.CopyFileError(src, dst, _))
      }
      Error(error) -> Error(error)
    }
  })
}

import compiler
import compiler/package
import filepath
import gleam/dict
import gleam/list
import gleam/option
import gleam/set
import gleam/string
import gleeunit/should
import macabre
import simplifile
import temporary

// These tests have to touch the filesystem, so
// they add measurably to the compile time.
// Tests in other files are pure and require no IO.
// This file should *only* test that stuff is being placed
// in the right directories. 
//
// I tried to bulk all the situations in just one test, but
// it may have to be split out if it becomes too hard to
// maintain.

pub type ProjectFiles {
  ProjectFiles(
    base_dir: String,
    src_dir: String,
    build_dir: String,
    main_path: String,
  )
}

fn init_folders(
  use_function: fn(ProjectFiles) -> a,
) -> Result(a, simplifile.FileError) {
  use dir <- temporary.create(temporary.directory())
  let project_name = filepath.base_name(dir)
  let src = filepath.join(dir, "src")
  let build = filepath.join(dir, "build")
  let main_path = filepath.join(src, project_name <> ".gleam")

  simplifile.create_directory_all(src)
  |> should.be_ok
  let project_files =
    ProjectFiles(
      base_dir: dir,
      src_dir: src,
      build_dir: build,
      main_path: main_path,
    )
  use_function(project_files)
}

pub fn package_compile_test_with_nested_folders_test() {
  // src/<dirname.gleam>
  // src/baz.py
  // src/foo/bar.gleam
  // src/foo/bindings.py
  use project_files <- init_folders()
  simplifile.write(
    to: project_files.main_path,
    contents: "import foo/bar

  @external(python, \"baz\", \"baz\")
  fn baz() -> Nil


  pub fn main() {}",
  )
  |> should.be_ok

  simplifile.write(
    to: filepath.join(project_files.src_dir, "baz.py"),
    contents: "
  fn baz():
      print('baz')",
  )
  |> should.be_ok

  let foo_dir = filepath.join(project_files.src_dir, "foo")
  simplifile.create_directory_all(foo_dir)
  |> should.be_ok
  simplifile.write(
    to: filepath.join(foo_dir, "bar.gleam"),
    contents: "@external(python, \"foo.bindings\", \"bar\")
  fn bar() -> Nil",
  )
  |> should.be_ok

  simplifile.write(
    to: filepath.join(foo_dir, "bindings.py"),
    contents: "def bar():
      pass",
  )
  |> should.be_ok

  let gleam_package =
    package.load_package(project_files.base_dir)
    |> should.be_ok

  // load

  should.equal(gleam_package.base_directory, project_files.base_dir)
  should.equal(
    gleam_package.main_module,
    filepath.base_name(project_files.main_path),
  )
  gleam_package.modules
  |> dict.size
  |> should.equal(2)
  gleam_package.external_import_files |> set.size |> should.equal(2)

  // ---  compile
  let compiled_package = compiler.compile_package(gleam_package)
  should.equal(compiled_package.base_directory, project_files.base_dir)
  should.equal(
    compiled_package.main_module,
    option.Some(
      filepath.base_name(project_files.main_path) |> string.drop_right(6),
    ),
  )
  compiled_package.modules
  |> dict.size
  |> should.equal(2)
  compiled_package.external_import_files |> set.size |> should.equal(2)

  // --- write output
  macabre.write_package(compiled_package) |> should.be_ok

  simplifile.read_directory(project_files.build_dir)
  |> should.be_ok
  |> list.sort(string.compare)
  |> should.equal([
    filepath.base_name(project_files.main_path) |> string.drop_right(6) <> ".py",
    "__main__.py",
    "baz.py",
    "foo",
    "gleam_builtins.py",
  ])

  project_files.build_dir
  |> filepath.join("foo")
  |> simplifile.read_directory
  |> should.be_ok
  |> should.equal(["bindings.py", "bar.py"])
}

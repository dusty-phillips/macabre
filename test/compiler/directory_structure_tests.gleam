import compiler
import compiler/package
import compiler/project
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
    package_src_dir: String,
  )
}

fn init_folders(
  use_function: fn(ProjectFiles) -> a,
) -> Result(a, simplifile.FileError) {
  use dir <- temporary.create(temporary.directory())
  let src = filepath.join(dir, "src")
  let package_src_dir = filepath.join(dir, "build/src")
  let build = filepath.join(dir, "build/dev/python")

  simplifile.create_directory_all(src)
  |> should.be_ok
  simplifile.create_directory_all(build)
  |> should.be_ok
  let project_files =
    ProjectFiles(
      base_dir: dir,
      src_dir: src,
      build_dir: build,
      package_src_dir: package_src_dir,
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
    to: filepath.join(project_files.src_dir, "nested_sample.gleam"),
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

  simplifile.write(
    to: filepath.join(project_files.base_dir, "gleam.toml"),
    contents: "name = \"nested_sample\"",
  )
  |> should.be_ok

  let gleam_project =
    project.load(project_files.base_dir)
    |> should.be_ok

  project.copy_project_srcs(gleam_project)
  |> should.be_ok

  simplifile.read_directory(project_files.package_src_dir)
  |> should.be_ok
  |> list.sort(string.compare)
  |> should.equal(["baz.py", "foo", "nested_sample.gleam"])
  simplifile.read_directory(filepath.join(project_files.package_src_dir, "foo"))
  |> should.be_ok
  |> list.sort(string.compare)
  |> should.equal(["bar.gleam", "bindings.py"])

  let gleam_package =
    package.load(gleam_project)
    |> should.be_ok

  // load

  should.equal(gleam_project.base_directory, project_files.base_dir)
  gleam_package.package.modules
  |> dict.size
  |> should.equal(2)
  gleam_package.external_import_files |> set.size |> should.equal(2)

  // ---  compile
  let compiled_package = compiler.compile_package(gleam_package)
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
    "__main__.py", "baz.py", "foo", "gleam_builtins.py", "nested_sample.py",
  ])

  project_files.build_dir
  |> filepath.join("foo")
  |> simplifile.read_directory
  |> should.be_ok
  |> should.equal(["bindings.py", "bar.py"])
}

pub fn git_dependency_parsing_test() {
  use project_files <- init_folders()
  simplifile.write(
    to: filepath.join(project_files.base_dir, "gleam.toml"),
    contents: "name = \"dependency_parsing\"

[dependencies]
my_library = { git = \"https://example.com/me/my_library\", ref = \"abc123\" }
monorepo = { git = \"https://example.com/me/monorepo\", ref = \"def456\", path = \"packages/thing\" }",
  )
  |> should.be_ok

  let gleam_project =
    project.load(project_files.base_dir)
    |> should.be_ok

  gleam_project.packages
  |> dict.size
  |> should.equal(2)
  gleam_project.packages
  |> dict.get("my_library")
  |> should.equal(
    Ok(project.GitPackage(
      git_url: "https://example.com/me/my_library",
      git_ref: "abc123",
      path: option.None,
    )),
  )
  gleam_project.packages
  |> dict.get("monorepo")
  |> should.equal(
    Ok(project.GitPackage(
      git_url: "https://example.com/me/monorepo",
      git_ref: "def456",
      path: option.Some("packages/thing"),
    )),
  )
}

pub fn hex_dependency_parsing_test() {
  use project_files <- init_folders()
  simplifile.write(
    to: filepath.join(project_files.base_dir, "gleam.toml"),
    contents: "name = \"dependency_parsing\"

[dependencies]
glance = \"7.0.0\"
filepath = \">= 1.0.0 and < 2.0.0\"",
  )
  |> should.be_ok

  let gleam_project =
    project.load(project_files.base_dir)
    |> should.be_ok

  gleam_project.packages
  |> dict.get("glance")
  |> should.equal(Ok(project.HexPackage(version: "7.0.0")))
  gleam_project.packages
  |> dict.get("filepath")
  |> should.equal(Ok(project.HexPackage(version: ">= 1.0.0 and < 2.0.0")))
}

pub fn macabre_toml_preferred_over_gleam_toml_test() {
  use project_files <- init_folders()
  simplifile.write(
    to: filepath.join(project_files.base_dir, "gleam.toml"),
    contents: "name = \"wrong_name\"

[dependencies]
gleam_dep = \"1.0.0\"",
  )
  |> should.be_ok
  simplifile.write(
    to: filepath.join(project_files.base_dir, "macabre.toml"),
    contents: "name = \"right_name\"

[dependencies]
macabre_dep = { git = \"https://example.com/me/macabre_dep\", ref = \"abc123\" }",
  )
  |> should.be_ok

  let gleam_project =
    project.load(project_files.base_dir)
    |> should.be_ok

  should.equal(gleam_project.name, "right_name")
  gleam_project.packages
  |> dict.size
  |> should.equal(1)
  gleam_project.packages
  |> dict.get("macabre_dep")
  |> should.equal(
    Ok(project.GitPackage(
      git_url: "https://example.com/me/macabre_dep",
      git_ref: "abc123",
      path: option.None,
    )),
  )
}

pub fn macabre_toml_without_gleam_toml_test() {
  use project_files <- init_folders()
  simplifile.write(
    to: filepath.join(project_files.base_dir, "macabre.toml"),
    contents: "name = \"macabre_only\"

[dependencies]
macabre_dep = \"1.0.0\"",
  )
  |> should.be_ok

  let gleam_project =
    project.load(project_files.base_dir)
    |> should.be_ok

  should.equal(gleam_project.name, "macabre_only")
  gleam_project.packages
  |> dict.get("macabre_dep")
  |> should.equal(Ok(project.HexPackage(version: "1.0.0")))
}

pub fn macabre_toml_ignores_manifest_test() {
  use project_files <- init_folders()
  simplifile.write(
    to: filepath.join(project_files.base_dir, "macabre.toml"),
    contents: "name = \"macabre_manifest\"

[dependencies]
macabre_dep = \"1.0.0\"",
  )
  |> should.be_ok
  simplifile.write(
    to: filepath.join(project_files.base_dir, "manifest.toml"),
    contents: "packages = [
  { name = \"manifest_dep\", version = \"7.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"ABC\" },
]",
  )
  |> should.be_ok

  let gleam_project =
    project.load(project_files.base_dir)
    |> should.be_ok

  gleam_project.packages
  |> dict.size
  |> should.equal(1)
  gleam_project.packages
  |> dict.get("macabre_dep")
  |> should.equal(Ok(project.HexPackage(version: "1.0.0")))
}

pub fn no_config_file_fails_test() {
  use project_files <- init_folders()
  project.load(project_files.base_dir)
  |> should.be_error
}

pub fn manifest_dependency_parsing_test() {
  use project_files <- init_folders()
  simplifile.write(
    to: filepath.join(project_files.base_dir, "gleam.toml"),
    contents: "name = \"dependency_parsing\"",
  )
  |> should.be_ok
  simplifile.write(
    to: filepath.join(project_files.base_dir, "manifest.toml"),
    contents: "packages = [
  { name = \"glance\", version = \"7.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"ABC\" },
  { name = \"my_library\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"git\", repo = \"https://example.com/me/my_library\", commit = \"abc123\" },
  { name = \"monorepo\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"git\", repo = \"https://example.com/me/monorepo\", commit = \"def456\", path = \"packages/thing\" },
  { name = \"local_thing\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../local_thing\" },
]",
  )
  |> should.be_ok

  let gleam_project =
    project.load(project_files.base_dir)
    |> should.be_ok

  gleam_project.packages
  |> dict.size
  |> should.equal(4)
  gleam_project.packages
  |> dict.get("glance")
  |> should.equal(Ok(project.HexPackage(version: "7.0.0")))
  gleam_project.packages
  |> dict.get("my_library")
  |> should.equal(
    Ok(project.GitPackage(
      git_url: "https://example.com/me/my_library",
      git_ref: "abc123",
      path: option.None,
    )),
  )
  gleam_project.packages
  |> dict.get("monorepo")
  |> should.equal(
    Ok(project.GitPackage(
      git_url: "https://example.com/me/monorepo",
      git_ref: "def456",
      path: option.Some("packages/thing"),
    )),
  )
  gleam_project.packages
  |> dict.get("local_thing")
  |> should.equal(Ok(project.LocalPackage(path: "../local_thing")))
}

pub fn module_with_submodules_written_as_init_test() {
  // src/foo.gleam and src/foo/bar.gleam both exist:
  // foo.gleam must be written as foo/__init__.py so that
  // "from foo import bar" resolves the package, not the module.
  use project_files <- init_folders()
  simplifile.write(
    to: filepath.join(project_files.src_dir, "foo.gleam"),
    contents: "import foo/bar
pub fn foo() -> Int {
  bar.bar()
}",
  )
  |> should.be_ok

  let foo_dir = filepath.join(project_files.src_dir, "foo")
  simplifile.create_directory_all(foo_dir)
  |> should.be_ok
  simplifile.write(
    to: filepath.join(foo_dir, "bar.gleam"),
    contents: "pub fn bar() -> Int {
  2
}",
  )
  |> should.be_ok

  simplifile.write(
    to: filepath.join(project_files.base_dir, "gleam.toml"),
    contents: "name = \"foo\"",
  )
  |> should.be_ok

  let gleam_project =
    project.load(project_files.base_dir)
    |> should.be_ok

  project.copy_project_srcs(gleam_project)
  |> should.be_ok

  let gleam_package =
    package.load(gleam_project)
    |> should.be_ok

  let compiled_package = compiler.compile_package(gleam_package)
  macabre.write_package(compiled_package) |> should.be_ok

  project_files.build_dir
  |> filepath.join("foo")
  |> simplifile.read_directory
  |> should.be_ok
  |> should.equal(["__init__.py", "bar.py"])
}

// Two modules define a variant with the same name but different fields. The
// bare constructor name must resolve to the defining module's own fields when
// compiling it (glance's LabelledField has three fields, python's own
// LabelledField has two — the wrong pick breaks the reordered call).
pub fn bare_constructor_arity_not_shadowed_by_other_module_test() {
  use project_files <- init_folders()
  simplifile.write(
    to: filepath.join(project_files.src_dir, "collision_sample.gleam"),
    contents: "import collision_other

pub type Thing {
  Thing(label: String, location: Int, item: String)
}

pub fn make(name: String, t: String) -> Thing {
  Thing(name, t, location: 1)
}

pub fn main() {}",
  )
  |> should.be_ok

  simplifile.write(
    to: filepath.join(project_files.src_dir, "collision_other.gleam"),
    contents: "pub type Thing {
  Thing(label: String, item: String)
}

pub fn other() -> Thing {
  Thing(label: \"a\", item: \"b\")
}",
  )
  |> should.be_ok

  simplifile.write(
    to: filepath.join(project_files.base_dir, "gleam.toml"),
    contents: "name = \"collision_sample\"",
  )
  |> should.be_ok

  let gleam_project =
    project.load(project_files.base_dir)
    |> should.be_ok

  project.copy_project_srcs(gleam_project)
  |> should.be_ok

  let gleam_package =
    package.load(gleam_project)
    |> should.be_ok

  let compiled_package = compiler.compile_package(gleam_package)
  macabre.write_package(compiled_package) |> should.be_ok

  project_files.build_dir
  |> filepath.join("collision_sample.py")
  |> simplifile.read
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

import collision_other


@dataclasses.dataclass(frozen=True)
class Thing:
    label: str
    location: int
    item: str


def make(name, t):
    return Thing(label=name, location=1, item=t)


def main():
    pass",
  )
}

import compiler
import compiler/package
import compiler/project
import filepath
import gleam/dict
import gleam/list
import gleam/option
import gleam/set
import gleam/string
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

  let assert Ok(_) = simplifile.create_directory_all(src)
  let assert Ok(_) = simplifile.create_directory_all(build)
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
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.src_dir, "nested_sample.gleam"),
      contents: "import foo/bar

  @external(python, \"baz\", \"baz\")
  fn baz() -> Nil


  pub fn main() {}",
    )

  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.src_dir, "baz.py"),
      contents: "
  fn baz():
      print('baz')",
    )

  let foo_dir = filepath.join(project_files.src_dir, "foo")
  let assert Ok(_) = simplifile.create_directory_all(foo_dir)
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(foo_dir, "bar.gleam"),
      contents: "@external(python, \"foo.bindings\", \"bar\")
  fn bar() -> Nil",
    )

  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(foo_dir, "bindings.py"),
      contents: "def bar():
      pass",
    )

  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "gleam.toml"),
      contents: "name = \"nested_sample\"",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  let assert Ok(_) = project.copy_project_srcs(gleam_project)

  let assert Ok(dir_listing) =
    simplifile.read_directory(project_files.package_src_dir)
  assert dir_listing |> list.sort(string.compare)
    == ["baz.py", "foo", "nested_sample.gleam"]
  let assert Ok(foo_listing) =
    simplifile.read_directory(filepath.join(
      project_files.package_src_dir,
      "foo",
    ))
  assert foo_listing |> list.sort(string.compare)
    == ["bar.gleam", "bindings.py"]

  let assert Ok(gleam_package) = package.load(gleam_project)

  // load

  assert gleam_project.base_directory == project_files.base_dir
  assert gleam_package.package.modules |> dict.size == 2
  assert gleam_package.external_import_files |> set.size == 2

  // ---  compile
  let compiled_package = compiler.compile_package(gleam_package)
  assert compiled_package.modules |> dict.size == 2
  assert compiled_package.external_import_files |> set.size == 2

  // --- write output
  let assert Ok(_) = macabre.write_package(compiled_package)

  let assert Ok(output_listing) =
    simplifile.read_directory(project_files.build_dir)
  assert output_listing |> list.sort(string.compare)
    == ["__main__.py", "baz.py", "foo", "gleam_builtins.py", "nested_sample.py"]

  let assert Ok(build_foo_listing) =
    project_files.build_dir
    |> filepath.join("foo")
    |> simplifile.read_directory
  assert build_foo_listing == ["bindings.py", "bar.py"]
}

pub fn git_dependency_parsing_test() {
  use project_files <- init_folders()
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "gleam.toml"),
      contents: "name = \"dependency_parsing\"

[dependencies]
my_library = { git = \"https://example.com/me/my_library\", ref = \"abc123\" }
monorepo = { git = \"https://example.com/me/monorepo\", ref = \"def456\", path = \"packages/thing\" }",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  assert gleam_project.packages |> dict.size == 2
  assert gleam_project.packages
    |> dict.get("my_library")
    == Ok(project.GitPackage(
      git_url: "https://example.com/me/my_library",
      git_ref: "abc123",
      path: option.None,
    ))
  assert gleam_project.packages
    |> dict.get("monorepo")
    == Ok(project.GitPackage(
      git_url: "https://example.com/me/monorepo",
      git_ref: "def456",
      path: option.Some("packages/thing"),
    ))
}

pub fn hex_dependency_parsing_test() {
  use project_files <- init_folders()
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "gleam.toml"),
      contents: "name = \"dependency_parsing\"

[dependencies]
glance = \"7.0.0\"
filepath = \">= 1.0.0 and < 2.0.0\"",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  assert gleam_project.packages
    |> dict.get("glance")
    == Ok(project.HexPackage(version: "7.0.0"))
  assert gleam_project.packages
    |> dict.get("filepath")
    == Ok(project.HexPackage(version: ">= 1.0.0 and < 2.0.0"))
}

pub fn macabre_toml_preferred_over_gleam_toml_test() {
  use project_files <- init_folders()
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "gleam.toml"),
      contents: "name = \"wrong_name\"

[dependencies]
gleam_dep = \"1.0.0\"",
    )
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "macabre.toml"),
      contents: "name = \"right_name\"

[dependencies]
macabre_dep = { git = \"https://example.com/me/macabre_dep\", ref = \"abc123\" }",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  assert gleam_project.name == "right_name"
  assert gleam_project.packages |> dict.size == 1
  assert gleam_project.packages
    |> dict.get("macabre_dep")
    == Ok(project.GitPackage(
      git_url: "https://example.com/me/macabre_dep",
      git_ref: "abc123",
      path: option.None,
    ))
}

pub fn macabre_toml_without_gleam_toml_test() {
  use project_files <- init_folders()
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "macabre.toml"),
      contents: "name = \"macabre_only\"

[dependencies]
macabre_dep = \"1.0.0\"",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  assert gleam_project.name == "macabre_only"
  assert gleam_project.packages
    |> dict.get("macabre_dep")
    == Ok(project.HexPackage(version: "1.0.0"))
}

pub fn macabre_toml_ignores_manifest_test() {
  use project_files <- init_folders()
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "macabre.toml"),
      contents: "name = \"macabre_manifest\"

[dependencies]
macabre_dep = \"1.0.0\"",
    )
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "manifest.toml"),
      contents: "packages = [
  { name = \"manifest_dep\", version = \"7.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"ABC\" },
]",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  assert gleam_project.packages |> dict.size == 1
  assert gleam_project.packages
    |> dict.get("macabre_dep")
    == Ok(project.HexPackage(version: "1.0.0"))
}

pub fn no_config_file_fails_test() {
  use project_files <- init_folders()
  let assert Error(_) = project.load(project_files.base_dir)
}

pub fn manifest_dependency_parsing_test() {
  use project_files <- init_folders()
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "gleam.toml"),
      contents: "name = \"dependency_parsing\"",
    )
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "manifest.toml"),
      contents: "packages = [
  { name = \"glance\", version = \"7.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"hex\", outer_checksum = \"ABC\" },
  { name = \"my_library\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"git\", repo = \"https://example.com/me/my_library\", commit = \"abc123\" },
  { name = \"monorepo\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"git\", repo = \"https://example.com/me/monorepo\", commit = \"def456\", path = \"packages/thing\" },
  { name = \"local_thing\", version = \"1.0.0\", build_tools = [\"gleam\"], requirements = [], source = \"local\", path = \"../local_thing\" },
]",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  assert gleam_project.packages |> dict.size == 4
  assert gleam_project.packages
    |> dict.get("glance")
    == Ok(project.HexPackage(version: "7.0.0"))
  assert gleam_project.packages
    |> dict.get("my_library")
    == Ok(project.GitPackage(
      git_url: "https://example.com/me/my_library",
      git_ref: "abc123",
      path: option.None,
    ))
  assert gleam_project.packages
    |> dict.get("monorepo")
    == Ok(project.GitPackage(
      git_url: "https://example.com/me/monorepo",
      git_ref: "def456",
      path: option.Some("packages/thing"),
    ))
  assert gleam_project.packages
    |> dict.get("local_thing")
    == Ok(project.LocalPackage(path: "../local_thing"))
}

pub fn module_with_submodules_written_as_init_test() {
  // src/foo.gleam and src/foo/bar.gleam both exist:
  // foo.gleam must be written as foo/__init__.py so that
  // "from foo import bar" resolves the package, not the module.
  use project_files <- init_folders()
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.src_dir, "foo.gleam"),
      contents: "import foo/bar
pub fn foo() -> Int {
  bar.bar()
}",
    )

  let foo_dir = filepath.join(project_files.src_dir, "foo")
  let assert Ok(_) = simplifile.create_directory_all(foo_dir)
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(foo_dir, "bar.gleam"),
      contents: "pub fn bar() -> Int {
  2
}",
    )

  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "gleam.toml"),
      contents: "name = \"foo\"",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  let assert Ok(_) = project.copy_project_srcs(gleam_project)

  let assert Ok(gleam_package) = package.load(gleam_project)

  let compiled_package = compiler.compile_package(gleam_package)
  let assert Ok(_) = macabre.write_package(compiled_package)

  let assert Ok(dir_listing) =
    project_files.build_dir
    |> filepath.join("foo")
    |> simplifile.read_directory
  assert dir_listing == ["__init__.py", "bar.py"]
}

// Two modules define a variant with the same name but different fields. The
// bare constructor name must resolve to the defining module's own fields when
// compiling it (glance's LabelledField has three fields, python's own
// LabelledField has two — the wrong pick breaks the reordered call).
pub fn bare_constructor_arity_not_shadowed_by_other_module_test() {
  use project_files <- init_folders()
  let assert Ok(_) =
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

  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.src_dir, "collision_other.gleam"),
      contents: "pub type Thing {
  Thing(label: String, item: String)
}

pub fn other() -> Thing {
  Thing(label: \"a\", item: \"b\")
}",
    )

  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "gleam.toml"),
      contents: "name = \"collision_sample\"",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  let assert Ok(_) = project.copy_project_srcs(gleam_project)

  let assert Ok(gleam_package) = package.load(gleam_project)

  let compiled_package = compiler.compile_package(gleam_package)
  let assert Ok(_) = macabre.write_package(compiled_package)

  let assert Ok(output_listing) =
    project_files.build_dir
    |> filepath.join("collision_sample.py")
    |> simplifile.read
  assert output_listing == "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Thing:
    label: str
    location: int
    item: str


def make(name, t):
    return Thing(label=name, location=1, item=t)


def main():
    pass


import collision_other


"
}

// A module's own nullary constructor must not be resolved against another
// module's same-named non-nullary type. The `Kind.Module` variant would lose
// its `()` and be emitted as the bare `Module` class if the package-wide bare
// arity map overrode the defining module's own entry.
pub fn nullary_constructor_arity_not_shadowed_by_other_module_test() {
  use project_files <- init_folders()
  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.src_dir, "arity_collision.gleam"),
      contents: "import arity_other

pub type Kind {
  Normal
  Doc
  Module
}

pub fn make() -> Kind {
  Module
}

pub fn main() {}",
    )

  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.src_dir, "arity_other.gleam"),
      contents: "pub type Module {
  Module(imports: Int, functions: Int)
}",
    )

  let assert Ok(_) =
    simplifile.write(
      to: filepath.join(project_files.base_dir, "gleam.toml"),
      contents: "name = \"arity_collision\"",
    )

  let assert Ok(gleam_project) = project.load(project_files.base_dir)

  let assert Ok(_) = project.copy_project_srcs(gleam_project)

  let assert Ok(gleam_package) = package.load(gleam_project)

  let compiled_package = compiler.compile_package(gleam_package)
  let assert Ok(_) = macabre.write_package(compiled_package)

  let assert Ok(output_listing) =
    project_files.build_dir
    |> filepath.join("arity_collision.py")
    |> simplifile.read

  assert output_listing == "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Normal:
    pass

@dataclasses.dataclass(frozen=True)
class Doc:
    pass

@dataclasses.dataclass(frozen=True)
class Module:
    pass


def make():
    return Module()


def main():
    pass


import arity_other


"
}

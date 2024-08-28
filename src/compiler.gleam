import compiler/generator
import compiler/package
import compiler/transformer
import glance
import gleam/dict
import gleam/list
import gleam/result

pub fn compile_module(glance_module: glance.Module) -> String {
  glance_module
  |> transformer.transform
  |> generator.generate
}

pub fn compile_package(package: package.GleamPackage) -> package.CompiledPackage {
  package.CompiledPackage(
    project: package.project,
    has_main: dict.get(package.modules, package.project.name <> ".gleam")
      |> result.try(fn(mod) { mod.functions |> has_main_function })
      |> result.is_ok,
    modules: package.modules
      |> dict.map_values(fn(_key, value) { compile_module(value) }),
    external_import_files: package.external_import_files,
  )
}

pub fn has_main_function(
  functions: List(glance.Definition(glance.Function)),
) -> Result(Bool, Nil) {
  functions
  |> list.find(fn(x) {
    case x {
      glance.Definition(
        definition: glance.Function(
          name: "main",
          publicity: glance.Public,
          parameters: [],
          ..,
        ),
        ..,
      ) -> True
      _ -> False
    }
  })
  |> result.replace(True)
}

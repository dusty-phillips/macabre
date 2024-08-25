import compiler/generator
import compiler/program
import compiler/transformer
import glance
import gleam/dict
import gleam/result

// called only by unit tests
// todo: remove
pub fn compile(module_contents: String) -> Result(String, glance.Error) {
  module_contents
  |> glance.module
  |> result.map(transformer.transform)
  |> result.map(generator.generate)
}

pub fn compile_module(glance_module: glance.Module) -> String {
  glance_module
  |> transformer.transform
  |> generator.generate
}

pub fn compile_program(program: program.GleamProgram) -> program.CompiledProgram {
  program.CompiledProgram(
    modules: program.modules
    |> dict.map_values(fn(_key, value) { compile_module(value) }),
  )
}

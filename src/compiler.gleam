import compiler/generator
import compiler/transformer
import glance
import gleam/result

pub fn compile(module_contents: String) -> Result(String, glance.Error) {
  module_contents
  |> glance.module
  |> result.map(transformer.transform)
  |> result.map(generator.generate)
}

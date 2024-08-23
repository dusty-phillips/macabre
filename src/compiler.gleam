import compiler/generator
import compiler/transformer
import glance
import gleam/result
import pprint

pub fn parse(contents: String) -> Result(glance.Module, String) {
  contents
  |> glance.module
  |> result.map_error(fn(x) {
    pprint.debug(x)
    "Unable to parse"
  })
}

pub fn compile(module_contents: String) -> Result(String, String) {
  module_contents
  |> parse
  |> result.try(transformer.transform)
  |> result.try(generator.generate)
}

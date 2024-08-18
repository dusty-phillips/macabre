import glance
import gleam/bool
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import python

pub fn generate(module: python.Module) -> Result(String, String) {
  Ok("print('Hello World')")
}

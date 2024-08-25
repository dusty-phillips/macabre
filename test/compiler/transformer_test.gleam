import compiler/internal/transformer
import gleeunit/should

pub fn transform_last_empty_test() {
  []
  |> transformer.transform_last(fn(a) { a })
  |> should.equal([])
}

pub fn transform_last_single_test() {
  ["a"]
  |> transformer.transform_last(fn(_) { "b" })
  |> should.equal(["b"])
}

pub fn transform_last_two_element_test() {
  ["a", "b"]
  |> transformer.transform_last(fn(_) { "c" })
  |> should.equal(["a", "c"])
}

pub fn transform_last_three_element_test() {
  ["a", "b", "c"]
  |> transformer.transform_last(fn(_) { "d" })
  |> should.equal(["a", "b", "d"])
}

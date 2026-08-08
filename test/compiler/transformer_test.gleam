import compiler/internal/transformer

pub fn transform_last_empty_test() {
  assert [] |> transformer.transform_last(fn(a) { a }) == []
}

pub fn transform_last_single_test() {
  assert ["a"] |> transformer.transform_last(fn(_) { "b" }) == ["b"]
}

pub fn transform_last_two_element_test() {
  assert ["a", "b"] |> transformer.transform_last(fn(_) { "c" }) == ["a", "c"]
}

pub fn transform_last_three_element_test() {
  assert ["a", "b", "c"] |> transformer.transform_last(fn(_) { "d" })
    == [
      "a",
      "b",
      "d",
    ]
}

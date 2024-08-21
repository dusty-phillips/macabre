import gleam/list

pub fn transform_last(elements: List(a), transformer: fn(a) -> a) -> List(a) {
  // This makes three iterations over elements. It may be a candidate for optimization
  // since it happens on all the statements in every function body. I can find ways
  // to do it with only two iterations, or with one iteration but transforming every
  // element and discarding the intermediates, but I didn't have any luck with a solution
  // that could do it in only one iteration.
  let length = list.length(elements)
  let #(head, tail) = list.split(elements, length - 1)
  list.append(head, tail |> list.map(transformer))
}

import gleam/list
import gleam/string_tree

pub fn indent(
  builder: string_tree.StringTree,
  count: Int,
) -> string_tree.StringTree {
  let indent =
    list.repeat(" ", count)
    |> string_tree.from_strings

  let indent_with_newline =
    indent
    |> string_tree.prepend("\n")
    |> string_tree.to_string

  string_tree.replace(builder, "\n", indent_with_newline)
  |> string_tree.prepend_tree(indent)
}

pub fn append_if_not_empty(
  builder: string_tree.StringTree,
  with: String,
) -> string_tree.StringTree {
  case string_tree.is_empty(builder) {
    True -> builder
    False -> string_tree.append(builder, with)
  }
}

pub fn generate_plural(
  elements: List(elem),
  using: fn(elem) -> string_tree.StringTree,
  join_with: String,
) -> string_tree.StringTree {
  elements
  |> list.map(using)
  |> string_tree.join(join_with)
}

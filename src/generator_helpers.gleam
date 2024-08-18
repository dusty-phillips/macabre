import gleam/iterator
import gleam/string_builder

pub fn indent(
  builder: string_builder.StringBuilder,
  count: Int,
) -> string_builder.StringBuilder {
  let indent =
    string_builder.from_string(" ")
    |> iterator.repeat
    |> iterator.take(count)
    |> iterator.to_list
    |> string_builder.join("")

  let indent_with_newline =
    indent
    |> string_builder.prepend("\n")
    |> string_builder.to_string

  string_builder.replace(builder, "\n", indent_with_newline)
  |> string_builder.prepend_builder(indent)
}

pub fn append_if_not_empty(
  builder: string_builder.StringBuilder,
  with: String,
) -> string_builder.StringBuilder {
  case string_builder.is_empty(builder) {
    True -> builder
    False -> string_builder.append(builder, with)
  }
}

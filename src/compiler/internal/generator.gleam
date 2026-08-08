import gleam/list
import gleam/string_tree

// Python keywords that cannot be used as identifiers. Gleam allows many of
// these as function and variable names, so we suffix them with an underscore
// when generating Python.
const python_keywords = [
  "False",
  "None",
  "True",
  "and",
  "as",
  "assert",
  "async",
  "await",
  "break",
  "class",
  "continue",
  "def",
  "del",
  "elif",
  "else",
  "except",
  "finally",
  "for",
  "from",
  "global",
  "if",
  "import",
  "in",
  "is",
  "lambda",
  "nonlocal",
  "not",
  "or",
  "pass",
  "raise",
  "return",
  "try",
  "while",
  "with",
  "yield",
]

pub fn python_name(name: String) -> String {
  case list.contains(python_keywords, name) {
    True -> name <> "_"
    False -> name
  }
}

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

pub fn prepend_if_not_empty(
  builder: string_tree.StringTree,
  with: String,
) -> string_tree.StringTree {
  case string_tree.is_empty(builder) {
    True -> builder
    False -> string_tree.prepend(builder, with)
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

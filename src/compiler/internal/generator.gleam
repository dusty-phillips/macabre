import gleam/list
import gleam/option
import gleam/string
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

/// Renders comment texts as `#` lines, each on its own line, with a trailing
/// newline. Comment texts carry their leading space, so `// note` becomes
/// `# note`.
pub fn generate_comments(comments: List(String)) -> string_tree.StringTree {
  comments
  |> list.map(fn(comment) {
    string_tree.from_string("#")
    |> string_tree.append(comment)
  })
  |> string_tree.join("\n")
  |> append_if_not_empty("\n")
}

/// Renders a docstring as a triple-quoted string, or nothing when absent.
/// Renders a docstring as a triple-quoted string, or nothing when absent.
/// Backslashes and quotes are escaped so Python does not interpret `\u`,
/// `\n`, etc. in the doc comment as escapes, and a trailing `"` in the text
/// cannot merge with the closing `"""`.
pub fn generate_docstring(
  docstring: option.Option(String),
) -> string_tree.StringTree {
  case docstring {
    option.None -> string_tree.new()
    option.Some(text) ->
      string_tree.from_string("\"\"\"")
      |> string_tree.append(
        text
        |> string.to_utf_codepoints
        |> list.map(escape_docstring_codepoint)
        |> string.join(""),
      )
      |> string_tree.append("\"\"\"")
  }
}

fn escape_docstring_codepoint(codepoint) -> String {
  let value = string.utf_codepoint_to_int(codepoint)
  case value {
    92 -> "\\\\"
    34 -> "\\\""
    _ -> string.from_utf_codepoints([codepoint])
  }
}

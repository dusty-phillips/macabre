import compiler/internal/generator as internal
import compiler/internal/generator/expressions
import compiler/python
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleam/string_tree.{type StringTree}
import glexer

pub fn generate_function(function: python.Function) -> StringTree {
  string_tree.new()
  |> string_tree.append_tree(internal.generate_comments(function.comments))
  |> string_tree.append("def ")
  |> string_tree.append(function.name |> internal.python_name)
  |> string_tree.append("(")
  |> string_tree.append_tree(internal.generate_plural(
    function.parameters,
    generate_parameter,
    ", ",
  ))
  |> string_tree.append("):\n")
  |> string_tree.append_tree(
    generate_function_body(function) |> internal.indent(4),
  )
}

// A docstring is emitted as the first statement of the body. A function whose
// body is otherwise empty emits just the docstring, not `pass`.
fn generate_function_body(function: python.Function) -> StringTree {
  case function.docstring, function.body {
    option.None, [] -> string_tree.from_string("pass")
    option.Some(_), [] -> internal.generate_docstring(function.docstring)
    option.None, _ -> generate_block(function.body)
    option.Some(_), _ ->
      internal.generate_docstring(function.docstring)
      |> string_tree.append("\n")
      |> string_tree.append_tree(generate_block(function.body))
  }
}

pub fn generate_module_header(
  docstring: option.Option(String),
  comments: List(String),
) -> StringTree {
  let header =
    internal.generate_comments(comments)
    |> string_tree.append_tree(internal.generate_docstring(docstring))
  case string_tree.is_empty(header) {
    True -> string_tree.new()
    False ->
      header
      |> string_tree.append(case docstring {
        option.None -> "\n"
        option.Some(_) -> "\n\n"
      })
  }
}

fn generate_parameter(param: python.FunctionParameter) -> StringTree {
  case param {
    python.NameParam(name) ->
      string_tree.from_string(name |> internal.python_name)
    python.DiscardParam(index) ->
      string_tree.from_string("_")
      |> string_tree.append(case index {
        0 -> ""
        idx -> idx |> int.to_string
      })
  }
}

pub fn generate_block(statements: List(python.Statement)) -> StringTree {
  case statements {
    [] -> string_tree.from_string("pass")
    multiple_lines ->
      internal.generate_plural(multiple_lines, generate_statement, "\n")
  }
}

pub fn generate_statement(statement: python.Statement) -> StringTree {
  case statement {
    python.Expression(expression) -> expressions.generate_expression(expression)
    python.Return(expression) ->
      string_tree.from_string("return ")
      |> string_tree.append_tree(expressions.generate_expression(expression))
    python.SimpleAssignment(name, value) -> {
      string_tree.new()
      |> string_tree.append(name |> internal.python_name)
      |> string_tree.append(" = ")
      |> string_tree.append_tree(expressions.generate_expression(value))
    }
    python.MultipleAssignment(names, value) -> {
      string_tree.new()
      |> string_tree.append_tree(
        names
        |> list.map(fn(name) {
          name |> internal.python_name |> string_tree.from_string
        })
        |> string_tree.join(", "),
      )
      |> string_tree.append(" = ")
      |> string_tree.append_tree(expressions.generate_expression(value))
    }
    python.Match(subject, cases) ->
      string_tree.new()
      |> string_tree.append("match ")
      |> string_tree.append_tree(expressions.generate_expression(subject))
      |> string_tree.append(":\n")
      |> string_tree.append_tree(generate_cases(cases) |> internal.indent(4))
    python.While(condition, body) ->
      string_tree.new()
      |> string_tree.append("while ")
      |> string_tree.append_tree(expressions.generate_expression(condition))
      |> string_tree.append(":\n")
      |> string_tree.append_tree(generate_block(body) |> internal.indent(4))
    python.FunctionDef(function) -> generate_function(function)
  }
}

pub fn generate_constant(constant: python.Constant) -> StringTree {
  string_tree.new()
  |> string_tree.append_tree(internal.generate_comments(constant.comments))
  |> string_tree.append_tree(
    string_tree.from_string(constant.name |> internal.python_name)
    |> string_tree.append(" = ")
    |> string_tree.append_tree(expressions.generate_expression(constant.value)),
  )
}

fn generate_cases(cases: List(python.MatchCase)) -> StringTree {
  case cases {
    [] -> string_tree.from_string("pass")
    cases -> internal.generate_plural(cases, generate_case, "\n")
  }
}

fn generate_case(case_: python.MatchCase) -> StringTree {
  string_tree.from_string("case ")
  |> string_tree.append_tree(generate_pattern(case_.pattern))
  |> string_tree.append_tree(generate_case_guard(case_.guard))
  |> string_tree.append(":\n")
  |> string_tree.append_tree(generate_block(case_.body) |> internal.indent(4))
}

fn generate_pattern(pattern: python.Pattern) -> StringTree {
  case pattern {
    python.PatternWildcard -> string_tree.from_string("_")
    python.PatternInt(str) | python.PatternFloat(str) ->
      string_tree.from_string(str)
    python.PatternVariable(str) ->
      string_tree.from_string(str |> internal.python_name)
    python.PatternString(str) ->
      case glexer.unescape_string(str) {
        Error(_) -> string_tree.from_strings(["\"", str, "\""])
        Ok(unescaped) ->
          string_tree.from_string(
            "\"" <> expressions.python_escape(unescaped) <> "\"",
          )
      }
    python.PatternAssignment(pattern, name) ->
      generate_pattern(pattern)
      |> string_tree.append(" as ")
      |> string_tree.append(name |> internal.python_name)
    python.PatternTuple(patterns) ->
      patterns
      |> list.map(generate_pattern)
      |> string_tree.join(", ")
      |> string_tree.prepend("(")
      |> string_tree.append(")")
    python.PatternList(elements, rest) -> generate_pattern_list(elements, rest)
    python.PatternAlternate(patterns) ->
      // Python requires every alternative to bind the same names. Named
      // discards (e.g. `_arg`) are rendered as `_`-prefixed variables by the
      // transformer, which would make Python reject the alternatives as
      // binding different names. Discards never bind a usable value, so they
      // are scrubbed to wildcards. Guard-carrying temps like
      // `_nested_subject_0` cannot appear inside an alternate (they force the
      // alternative into its own case), so any `_`-prefixed variable found
      // here is a discard.
      patterns
      |> list.map(fn(pattern) { pattern |> scrub_discards |> generate_pattern })
      |> string_tree.join(" | ")
    python.PatternConstructor(module, constructor, arguments) ->
      case constructor, arguments, module {
        // The Bool and Option constructors are represented in the Python
        // runtime by the Python keywords `True`, `False`, and `None`, so
        // patterns referencing them must not be rendered as constructor
        // calls. This applies even to module qualified references (e.g.
        // `option.None`), since at runtime an option's None value is the
        // literal `None`. The exception is the compiler's own `python.Nil`
        // AST node, which is a real class whose instances need a class
        // pattern.
        "True", [], _ -> string_tree.from_string("True")
        "False", [], _ -> string_tree.from_string("False")
        "None", [], _ -> string_tree.from_string("None")
        "Nil", [], option.None -> string_tree.from_string("None")
        // Nullary constructors are represented at runtime by an instance of
        // the constructor class (e.g. `File()`), so a pattern matches them
        // as a class pattern (isinstance check).
        _, _, _ ->
          module
          |> option.map(fn(mod) { string_tree.from_strings([mod, "."]) })
          |> option.unwrap(string_tree.new())
          |> string_tree.append(constructor)
          |> string_tree.append("(")
          |> string_tree.append_tree(internal.generate_plural(
            arguments,
            generate_pattern_constructor_field,
            ", ",
          ))
          |> string_tree.append(")")
      }
  }
}

fn generate_pattern_constructor_field(
  field: python.Field(python.Pattern),
) -> StringTree {
  case field {
    python.LabelledField(label, pattern) ->
      string_tree.from_strings([label |> internal.python_name, "="])
      |> string_tree.append_tree(generate_pattern(pattern))
    python.UnlabelledField(pattern) -> generate_pattern(pattern)
  }
}

// Replaces discarded variables (rendered as `_`-prefixed names by the
// transformer) with wildcards. Only safe inside a PatternAlternate, where
// guard-carrying temp variables can never appear.
fn scrub_discards(pattern: python.Pattern) -> python.Pattern {
  case pattern {
    python.PatternVariable(name) ->
      case name |> string.starts_with("_") {
        True -> python.PatternWildcard
        False -> python.PatternVariable(name)
      }
    python.PatternAssignment(inner, name) ->
      python.PatternAssignment(scrub_discards(inner), name)
    python.PatternTuple(patterns) ->
      patterns |> list.map(scrub_discards) |> python.PatternTuple
    python.PatternList(elements, rest) ->
      python.PatternList(
        list.map(elements, scrub_discards),
        rest |> option.map(scrub_discards),
      )
    python.PatternConstructor(module, constructor, arguments) ->
      python.PatternConstructor(
        module,
        constructor,
        list.map(arguments, fn(field) {
          case field {
            python.LabelledField(label, inner) ->
              python.LabelledField(label, scrub_discards(inner))
            python.UnlabelledField(inner) ->
              python.UnlabelledField(scrub_discards(inner))
          }
        }),
      )
    other -> other
  }
}

/// Lists are weird. Gleam syntax is like [a, b, c, ..rest]
/// But the pattern in python has to match a linked list.
/// The pattern is essentially GleamList(a, GleamList(b, GleamList(c, rest)))
/// potential optimization: make tail recursive by carrying the number of
/// closing parenns forward
fn generate_pattern_list(elements, rest) -> StringTree {
  case elements, rest {
    [], option.None -> string_tree.from_string("None")
    [], option.Some(pattern) -> generate_pattern(pattern)
    [head, ..others], rest ->
      string_tree.from_string("GleamList(")
      |> string_tree.append_tree(generate_pattern(head))
      |> string_tree.append(", ")
      |> string_tree.append_tree(generate_pattern_list(others, rest))
      |> string_tree.append(")")
  }
}

fn generate_case_guard(guard: option.Option(python.Expression)) -> StringTree {
  case guard {
    option.None -> string_tree.new()
    option.Some(expression) ->
      string_tree.from_string(" if ")
      |> string_tree.append_tree(expressions.generate_expression(expression))
  }
}

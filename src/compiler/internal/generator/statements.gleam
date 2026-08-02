import compiler/internal/generator as internal
import compiler/internal/generator/expressions
import compiler/python
import gleam/int
import gleam/list
import gleam/option
import gleam/string_tree.{type StringTree}

pub fn generate_function(function: python.Function) -> StringTree {
  // TODO: The parameters and return types can have Python type hints
  string_tree.new()
  |> string_tree.append("def ")
  |> string_tree.append(function.name)
  |> string_tree.append("(")
  |> string_tree.append_tree(internal.generate_plural(
    function.parameters,
    generate_parameter,
    ", ",
  ))
  |> string_tree.append("):\n")
  |> string_tree.append_tree(
    generate_block(function.body) |> internal.indent(4),
  )
}

fn generate_parameter(param: python.FunctionParameter) -> StringTree {
  case param {
    python.NameParam(name) -> string_tree.from_string(name)
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
      |> string_tree.append(name)
      |> string_tree.append(" = ")
      |> string_tree.append_tree(expressions.generate_expression(value))
    }
    python.Match(cases) ->
      string_tree.new()
      |> string_tree.append("match _case_subject:\n")
      |> string_tree.append_tree(generate_cases(cases) |> internal.indent(4))
    // TODO: Deal with cases
    python.FunctionDef(function) -> generate_function(function)
  }
}

pub fn generate_constant(constant: python.Constant) -> StringTree {
  string_tree.from_string(constant.name)
  |> string_tree.append(" = ")
  |> string_tree.append_tree(expressions.generate_expression(constant.value))
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
    python.PatternInt(str)
    | python.PatternFloat(str)
    | python.PatternVariable(str) -> string_tree.from_string(str)
    python.PatternString(str) -> string_tree.from_strings(["\"", str, "\""])
    python.PatternAssignment(pattern, name) ->
      generate_pattern(pattern)
      |> string_tree.append(" as ")
      |> string_tree.append(name)
    python.PatternTuple(patterns) ->
      patterns
      |> list.map(generate_pattern)
      |> string_tree.join(", ")
      |> string_tree.prepend("(")
      |> string_tree.append(")")
    python.PatternList(elements, rest) -> generate_pattern_list(elements, rest)
    python.PatternAlternate(patterns) ->
      patterns
      |> list.map(generate_pattern)
      |> string_tree.join(" | ")
    python.PatternConstructor(module, constructor, arguments) ->
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

fn generate_pattern_constructor_field(
  field: python.Field(python.Pattern),
) -> StringTree {
  case field {
    python.LabelledField(label, pattern) ->
      string_tree.from_strings([label, "="])
      |> string_tree.append_tree(generate_pattern(pattern))
    python.UnlabelledField(pattern) -> generate_pattern(pattern)
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

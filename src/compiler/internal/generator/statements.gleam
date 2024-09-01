import compiler/internal/generator as internal
import compiler/internal/generator/expressions
import compiler/python
import gleam/int
import gleam/list
import gleam/option
import gleam/string_builder.{type StringBuilder}

pub fn generate_function(function: python.Function) -> StringBuilder {
  // TODO: The parameters and return types can have Python type hints
  string_builder.new()
  |> string_builder.append("def ")
  |> string_builder.append(function.name)
  |> string_builder.append("(")
  |> string_builder.append_builder(internal.generate_plural(
    function.parameters,
    generate_parameter,
    ", ",
  ))
  |> string_builder.append("):\n")
  |> string_builder.append_builder(
    generate_block(function.body) |> internal.indent(4),
  )
}

fn generate_parameter(param: python.FunctionParameter) -> StringBuilder {
  case param {
    python.NameParam(name) -> string_builder.from_string(name)
    python.DiscardParam(index) ->
      string_builder.from_string("_")
      |> string_builder.append(case index {
        0 -> ""
        idx -> idx |> int.to_string
      })
  }
}

pub fn generate_block(statements: List(python.Statement)) -> StringBuilder {
  case statements {
    [] -> string_builder.from_string("pass")
    multiple_lines ->
      internal.generate_plural(multiple_lines, generate_statement, "\n")
  }
}

pub fn generate_statement(statement: python.Statement) -> StringBuilder {
  case statement {
    python.Expression(expression) -> expressions.generate_expression(expression)
    python.Return(expression) ->
      string_builder.from_string("return ")
      |> string_builder.append_builder(expressions.generate_expression(
        expression,
      ))
    python.SimpleAssignment(name, value) -> {
      string_builder.new()
      |> string_builder.append(name)
      |> string_builder.append(" = ")
      |> string_builder.append_builder(expressions.generate_expression(value))
    }
    python.Match(cases) ->
      string_builder.new()
      |> string_builder.append("match _case_subject:\n")
      |> string_builder.append_builder(
        generate_cases(cases) |> internal.indent(4),
      )
    // TODO: Deal with cases
    python.FunctionDef(function) -> generate_function(function)
  }
}

pub fn generate_constant(constant: python.Constant) -> StringBuilder {
  string_builder.from_string(constant.name)
  |> string_builder.append(" = ")
  |> string_builder.append_builder(expressions.generate_expression(
    constant.value,
  ))
}

fn generate_cases(cases: List(python.MatchCase)) -> StringBuilder {
  case cases {
    [] -> string_builder.from_string("pass")
    cases -> internal.generate_plural(cases, generate_case, "\n")
  }
}

fn generate_case(case_: python.MatchCase) -> StringBuilder {
  string_builder.from_string("case ")
  |> string_builder.append_builder(generate_pattern(case_.pattern))
  |> string_builder.append_builder(generate_case_guard(case_.guard))
  |> string_builder.append(":\n")
  |> string_builder.append_builder(
    generate_block(case_.body) |> internal.indent(4),
  )
}

fn generate_pattern(pattern: python.Pattern) -> StringBuilder {
  case pattern {
    python.PatternWildcard -> string_builder.from_string("_")
    python.PatternInt(str)
    | python.PatternFloat(str)
    | python.PatternVariable(str) -> string_builder.from_string(str)
    python.PatternString(str) -> string_builder.from_strings(["\"", str, "\""])
    python.PatternAssignment(pattern, name) ->
      generate_pattern(pattern)
      |> string_builder.append(" as ")
      |> string_builder.append(name)
    python.PatternTuple(patterns) ->
      patterns
      |> list.map(generate_pattern)
      |> string_builder.join(", ")
      |> string_builder.prepend("(")
      |> string_builder.append(")")
    python.PatternList(elements, rest) -> generate_pattern_list(elements, rest)
    python.PatternAlternate(patterns) ->
      patterns
      |> list.map(generate_pattern)
      |> string_builder.join(" | ")
    python.PatternConstructor(module, constructor, arguments) ->
      module
      |> option.map(fn(mod) { string_builder.from_strings([mod, "."]) })
      |> option.unwrap(string_builder.new())
      |> string_builder.append(constructor)
      |> string_builder.append("(")
      |> string_builder.append_builder(internal.generate_plural(
        arguments,
        generate_pattern_constructor_field,
        ", ",
      ))
      |> string_builder.append(")")
  }
}

fn generate_pattern_constructor_field(
  field: python.Field(python.Pattern),
) -> StringBuilder {
  case field {
    python.LabelledField(label, pattern) ->
      string_builder.from_strings([label, "="])
      |> string_builder.append_builder(generate_pattern(pattern))
    python.UnlabelledField(pattern) -> generate_pattern(pattern)
  }
}

/// Lists are weird. Gleam syntax is like [a, b, c, ..rest]
/// But the pattern in python has to match a linked list.
/// The pattern is essentially GleamList(a, GleamList(b, GleamList(c, rest)))
/// potential optimization: make tail recursive by carrying the number of
/// closing parenns forward
fn generate_pattern_list(elements, rest) -> StringBuilder {
  case elements, rest {
    [], option.None -> string_builder.from_string("None")
    [], option.Some(pattern) -> generate_pattern(pattern)
    [head, ..others], rest ->
      string_builder.from_string("GleamList(")
      |> string_builder.append_builder(generate_pattern(head))
      |> string_builder.append(", ")
      |> string_builder.append_builder(generate_pattern_list(others, rest))
      |> string_builder.append(")")
  }
}

fn generate_case_guard(guard: option.Option(python.Expression)) -> StringBuilder {
  case guard {
    option.None -> string_builder.new()
    option.Some(expression) ->
      string_builder.from_string(" if ")
      |> string_builder.append_builder(expressions.generate_expression(
        expression,
      ))
  }
}

import compiler/internal/generator as internal
import compiler/internal/generator/types
import compiler/python
import gleam/int
import gleam/list
import gleam/option
import gleam/string_builder.{type StringBuilder}
import python_prelude

pub fn generate(module: python.Module) -> Result(String, String) {
  string_builder.new()
  |> string_builder.append(python_prelude.prelude)
  |> string_builder.append_builder(generate_imports(module.imports))
  |> string_builder.append_builder(internal.generate_plural(
    module.custom_types,
    types.generate_custom_type,
    "\n\n\n",
  ))
  |> string_builder.append_builder(internal.generate_plural(
    module.functions,
    generate_function,
    "\n\n\n",
  ))
  |> string_builder.to_string
  |> Ok
}

fn generate_imports(imports: List(python.Import)) -> StringBuilder {
  internal.generate_plural(imports, generate_import, "\n")
  |> internal.append_if_not_empty("\n\n\n")
}

fn generate_import(import_: python.Import) -> StringBuilder {
  case import_ {
    python.UnqualifiedImport(module, name, option.None) ->
      string_builder.new()
      |> string_builder.append("from ")
      |> string_builder.append(module)
      |> string_builder.append(" import ")
      |> string_builder.append(name)
    python.UnqualifiedImport(_module, _name, option.Some(_)) ->
      todo as "Aliased imports not supported yet"
  }
}

fn generate_function(function: python.Function) -> StringBuilder {
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

fn generate_binop(
  name: python.BinaryOperator,
  left: python.Expression,
  right: python.Expression,
) -> StringBuilder {
  let op_string = case name {
    python.And -> " and "
    python.Or -> " or "
    python.Add -> " + "
    python.Subtract -> " - "
    python.Divide -> " / "
    python.DivideInt -> " // "
    python.Multiply -> " * "
    python.Modulo -> " % "
    python.Equal -> " == "
    python.NotEqual -> " != "
    python.LessThan -> " < "
    python.LessThanEqual -> " <= "
    python.GreaterThan -> " > "
    python.GreaterThanEqual -> " >= "
  }

  string_builder.new()
  |> string_builder.append_builder(generate_expression(left))
  |> string_builder.append(op_string)
  |> string_builder.append_builder(generate_expression(right))
}

fn generate_record_update_fields(
  field: python.Field(python.Expression),
) -> StringBuilder {
  case field {
    python.UnlabelledField(_) ->
      panic as "Unlabeled fields are not expected on record updates"
    python.LabelledField(label, expression) ->
      string_builder.new()
      |> string_builder.append(label)
      |> string_builder.append("=")
      |> string_builder.append_builder(generate_expression(expression))
  }
}

fn generate_call_fields(field: python.Field(python.Expression)) -> StringBuilder {
  case field {
    python.UnlabelledField(expression) -> generate_expression(expression)
    python.LabelledField(label, expression) ->
      generate_expression(expression)
      |> string_builder.prepend("=")
      |> string_builder.prepend(label)
  }
}

fn generate_expression(expression: python.Expression) {
  case expression {
    python.String(string) -> string_builder.from_strings(["\"", string, "\""])

    python.Number(number) -> string_builder.from_string(number)

    python.Bool(value) -> string_builder.from_string(value)

    python.Variable(value) -> string_builder.from_string(value)

    python.Negate(expression) ->
      generate_expression(expression) |> string_builder.prepend("-")

    python.Not(expression) ->
      generate_expression(expression) |> string_builder.prepend("not ")

    python.Panic(expression) ->
      generate_expression(expression)
      |> string_builder.prepend("raise GleamPanic(")
      |> string_builder.append(")")

    python.Todo(expression) ->
      generate_expression(expression)
      |> string_builder.prepend("raise NotImplementedError(")
      |> string_builder.append(")")

    python.List(elements) ->
      string_builder.from_string("to_gleam_list([")
      |> string_builder.append_builder(internal.generate_plural(
        elements,
        generate_expression,
        ", ",
      ))
      |> string_builder.append("])")

    python.ListWithRest(elements, rest) ->
      string_builder.from_string("to_gleam_list([")
      |> string_builder.append_builder(internal.generate_plural(
        elements,
        generate_expression,
        ", ",
      ))
      |> string_builder.append("], ")
      |> string_builder.append_builder(generate_expression(rest))
      |> string_builder.append(")")

    python.Tuple(expressions) ->
      string_builder.new()
      |> string_builder.append("(")
      |> string_builder.append_builder(
        expressions
        |> internal.generate_plural(generate_expression, ", "),
      )
      |> string_builder.append(")")

    python.TupleIndex(expression, index) ->
      generate_expression(expression)
      |> string_builder.append("[")
      |> string_builder.append(index |> int.to_string)
      |> string_builder.append("]")

    python.FieldAccess(expression, label) ->
      generate_expression(expression)
      |> string_builder.append(".")
      |> string_builder.append(label)

    python.RecordUpdate(record, fields) ->
      string_builder.new()
      |> string_builder.append("dataclasses.replace(")
      |> string_builder.append_builder(generate_expression(record))
      |> string_builder.append(", ")
      |> string_builder.append_builder(internal.generate_plural(
        fields,
        generate_record_update_fields,
        ", ",
      ))
      |> string_builder.append(")")

    python.Lambda(arguments, body) -> {
      string_builder.from_string("(lambda ")
      |> string_builder.append_builder(internal.generate_plural(
        arguments,
        generate_expression,
        ", ",
      ))
      |> string_builder.append(": ")
      |> string_builder.append_builder(generate_expression(body))
      |> string_builder.append(")")
    }

    python.Call(function, arguments) ->
      string_builder.new()
      |> string_builder.append_builder(generate_expression(function))
      |> string_builder.append("(")
      |> string_builder.append_builder(
        arguments
        |> list.map(generate_call_fields)
        |> string_builder.join(", "),
      )
      |> string_builder.append(")")

    python.BinaryOperator(name, left, right) ->
      generate_binop(name, left, right)
  }
}

fn generate_statement(statement: python.Statement) -> StringBuilder {
  case statement {
    python.Expression(expression) -> generate_expression(expression)
    python.Return(expression) ->
      string_builder.from_string("return ")
      |> string_builder.append_builder(generate_expression(expression))
    python.SimpleAssignment(name, value) -> {
      string_builder.new()
      |> string_builder.append(name)
      |> string_builder.append(" = ")
      |> string_builder.append_builder(generate_expression(value))
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

fn generate_cases(cases: List(python.MatchCase)) -> StringBuilder {
  case cases {
    [] -> string_builder.from_string("pass")
    cases -> internal.generate_plural(cases, generate_case, "\n")
  }
}

fn generate_case(case_: python.MatchCase) -> StringBuilder {
  string_builder.from_string("case ")
  |> string_builder.append_builder(generate_pattern(case_.pattern))
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

fn generate_parameter(param: python.FunctionParameter) -> StringBuilder {
  case param {
    python.NameParam(name) -> string_builder.from_string(name)
  }
}

fn generate_block(statements: List(python.Statement)) -> StringBuilder {
  case statements {
    [] -> string_builder.from_string("pass")
    multiple_lines ->
      internal.generate_plural(multiple_lines, generate_statement, "\n")
  }
}

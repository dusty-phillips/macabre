import compiler/internal/generator as internal
import compiler/python
import gleam/int
import gleam/list
import gleam/string_builder.{type StringBuilder}

pub fn generate_expression(expression: python.Expression) -> StringBuilder {
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

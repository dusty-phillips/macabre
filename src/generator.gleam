import generator_helpers
import gleam/int
import gleam/list
import gleam/option
import gleam/string_builder
import python

fn generate_import(import_: python.Import) -> string_builder.StringBuilder {
  case import_ {
    python.UnqualifiedImport(module, name, option.None) ->
      string_builder.new()
      |> string_builder.append("from ")
      |> string_builder.append(module)
      |> string_builder.append(" import ")
      |> string_builder.append(name)
    python.UnqualifiedImport(module, name, option.Some(_)) ->
      todo as "Aliased imports not supported yet"
  }
}

fn generate_binop(
  name: python.BinaryOperator,
  left: python.Expression,
  right: python.Expression,
) -> string_builder.StringBuilder {
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

fn generate_expression(expression: python.Expression) {
  case expression {
    python.String(string) -> string_builder.from_strings(["\"", string, "\""])
    python.Number(number) -> string_builder.from_string(number)
    python.Bool(value) -> string_builder.from_string(value)
    python.Tuple(expressions) ->
      string_builder.new()
      |> string_builder.append("(")
      |> string_builder.append_builder(
        expressions |> generate_plural(generate_expression, ", "),
      )
      |> string_builder.append(")")
    python.TupleIndex(expression, index) ->
      generate_expression(expression)
      |> string_builder.append("[")
      |> string_builder.append(index |> int.to_string)
      |> string_builder.append("]")
    python.Call(function_name, arguments) ->
      string_builder.new()
      |> string_builder.append(function_name)
      |> string_builder.append("(")
      |> string_builder.append_builder(
        arguments
        |> list.map(generate_expression)
        |> string_builder.join(", "),
      )
      |> string_builder.append(")")
    python.BinaryOperator(name, left, right) ->
      generate_binop(name, left, right)
  }
}

fn generate_statement(
  statement: python.Statement,
) -> string_builder.StringBuilder {
  case statement {
    python.Expression(expression) ->
      generate_expression(expression)
      |> generator_helpers.append_if_not_empty("\n")
  }
}

fn generate_parameter(
  param: python.FunctionParameter,
) -> string_builder.StringBuilder {
  case param {
    python.NameParam(name) -> string_builder.from_string(name)
  }
}

fn generate_function_body(
  statements: List(python.Statement),
) -> string_builder.StringBuilder {
  case statements {
    [] -> string_builder.from_string("pass")
    multiple_lines -> generate_plural(multiple_lines, generate_statement, "\n")
  }
}

fn generate_function(function: python.Function) -> string_builder.StringBuilder {
  // TODO: The parameters and return types can have Python type hints
  string_builder.new()
  |> string_builder.append("def ")
  |> string_builder.append(function.name)
  |> string_builder.append("(")
  |> string_builder.append_builder(generate_plural(
    function.parameters,
    generate_parameter,
    ", ",
  ))
  |> string_builder.append("):\n")
  |> string_builder.append_builder(
    generate_function_body(function.body) |> generator_helpers.indent(4),
  )
}

fn generate_type(type_: python.Type) -> string_builder.StringBuilder {
  case type_ {
    python.NamedType(name: "String", module: option.None) ->
      string_builder.from_string("str")

    python.NamedType(name: "Int", module: option.None) ->
      string_builder.from_string("int")

    python.NamedType(name: name, module: option.None) ->
      string_builder.from_string(name)

    python.NamedType(name: name, module: option.Some(module)) ->
      string_builder.from_strings([module, ".", name])
  }
}

fn generate_type_fields(
  field: python.Field(python.Type),
) -> string_builder.StringBuilder {
  case field {
    python.UnlabelledField(_) ->
      todo as "not handling unlabeled fields in custom types yet"
    python.LabelledField(label, item) ->
      string_builder.new()
      |> string_builder.append(label)
      |> string_builder.append(": ")
      |> string_builder.append_builder(generate_type(item))
  }
}

fn generate_type_variant(
  variant: python.Variant,
) -> string_builder.StringBuilder {
  string_builder.new()
  |> string_builder.append("@dataclass(frozen=True)\n")
  |> string_builder.append("class ")
  |> string_builder.append(variant.name)
  |> string_builder.append(":\n")
  |> string_builder.append_builder(
    generate_plural(variant.fields, generate_type_fields, "\n")
    |> generator_helpers.indent(4),
  )
}

fn generate_variant_reassign(
  namespace: String,
) -> fn(python.Variant) -> string_builder.StringBuilder {
  fn(variant: python.Variant) -> string_builder.StringBuilder {
    string_builder.new()
    |> string_builder.append(variant.name)
    |> string_builder.append(" = ")
    |> string_builder.append(namespace)
    |> string_builder.append(".")
    |> string_builder.append(variant.name)
  }
}

fn generate_custom_type(
  custom_type: python.CustomType,
) -> string_builder.StringBuilder {
  string_builder.new()
  |> string_builder.append("class ")
  |> string_builder.append(custom_type.name)
  |> string_builder.append(":\n")
  |> string_builder.append_builder(
    generate_plural(custom_type.variants, generate_type_variant, "\n\n")
    |> generator_helpers.indent(4)
    |> generator_helpers.append_if_not_empty("\n\n"),
  )
  |> string_builder.append_builder(generate_plural(
    custom_type.variants,
    generate_variant_reassign(custom_type.name),
    "\n",
  ))
  |> string_builder.append("\n\n\n")
}

fn generate_imports(
  imports: List(python.Import),
) -> string_builder.StringBuilder {
  generate_plural(imports, generate_import, "\n")
  |> generator_helpers.append_if_not_empty("\n\n\n")
}

fn generate_plural(
  elements: List(elem),
  using: fn(elem) -> string_builder.StringBuilder,
  join_with: String,
) -> string_builder.StringBuilder {
  elements
  |> list.map(using)
  |> string_builder.join(join_with)
}

pub fn generate(module: python.Module) -> Result(String, String) {
  string_builder.new()
  |> string_builder.append_builder(generate_imports(module.imports))
  |> string_builder.append_builder(generate_plural(
    module.custom_types,
    generate_custom_type,
    "\n\n\n",
  ))
  |> string_builder.append_builder(generate_plural(
    module.functions,
    generate_function,
    "\n\n\n",
  ))
  |> string_builder.to_string
  |> Ok
}

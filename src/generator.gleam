import generator_helpers
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

fn generate_expression(expression: python.Expression) {
  case expression {
    python.String(string) -> string_builder.from_strings(["\"", string, "\""])
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
    module.functions,
    generate_function,
    "\n\n\n",
  ))
  |> string_builder.to_string
  |> Ok
}

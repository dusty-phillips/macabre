import glance
import gleam/list
import gleam/option
import python

type TransformError {
  NotExternal
}

fn maybe_extract_external(
  function_attribute: glance.Attribute,
) -> Result(python.Import, TransformError) {
  case function_attribute {
    glance.Attribute(
      "external",
      [glance.Variable("python"), glance.String(module), glance.String(name)],
    ) -> Ok(python.UnqualifiedImport(module, name, option.None))
    _ -> Error(NotExternal)
  }
}

fn transform_function_parameter(
  function_parameter: glance.FunctionParameter,
) -> python.FunctionParameter {
  case function_parameter {
    glance.FunctionParameter(label: option.Some(_), name: _, type_: _) ->
      todo as "Labelled parameters not supported yet"
    glance.FunctionParameter(
      label: option.None,
      name: glance.Discarded(_),
      type_: _,
    ) -> todo as "Discard parameters not supported in function arguments yet"
    glance.FunctionParameter(
      label: option.None,
      name: glance.Named(name),
      type_: _,
    ) -> python.NameParam(name)
  }
}

fn transform_call_argument(
  argument: glance.Field(glance.Expression),
) -> python.Expression {
  case argument {
    glance.Field(label: option.Some(_), item: _) ->
      todo as "Labelled arguments are not yet supported"
    glance.Field(label: option.None, item: expression) ->
      transform_expression(expression)
  }
}

fn transform_expression(expression: glance.Expression) -> python.Expression {
  case expression {
    glance.Call(glance.Variable(function_name), arguments) -> {
      python.Call(
        function_name,
        arguments: list.map(arguments, transform_call_argument),
      )
    }
    glance.String(string) -> {
      python.String(string)
    }
    _ -> todo as "most expressions aren't handled yet"
  }
}

fn transform_statement(statement: glance.Statement) -> python.Statement {
  case statement {
    glance.Expression(expression) -> {
      python.Expression(transform_expression(expression))
    }
    _ -> todo as "not all statements are defined yet"
  }
}

fn transform_function(function: glance.Function) -> python.Function {
  python.Function(
    name: function.name,
    parameters: list.map(function.parameters, transform_function_parameter),
    body: list.map(function.body, transform_statement),
  )
}

fn transform_function_or_external(
  module: python.Module,
  function: glance.Definition(glance.Function),
) -> python.Module {
  case list.filter_map(function.attributes, maybe_extract_external) {
    [] ->
      python.Module(
        ..module,
        functions: [transform_function(function.definition), ..module.functions],
      )
    [python_import] ->
      python.Module(..module, imports: [python_import, ..module.imports])
    _ -> panic as "Did not expect more than one external for one function"
  }
}

pub fn transform(input: glance.Module) -> Result(python.Module, String) {
  python.empty_module()
  |> list.fold(input.functions, _, transform_function_or_external)
  |> Ok
}

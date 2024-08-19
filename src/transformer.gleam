import glance
import gleam/list
import gleam/option
import gleam/string
import pprint
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

fn transform_binop(
  name: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> python.Expression {
  let op = case name {
    glance.And -> python.And
    glance.Or -> python.Or
    glance.AddInt | glance.AddFloat | glance.Concatenate -> python.Add
    glance.SubInt | glance.SubFloat -> python.Subtract
    glance.DivFloat -> python.Divide
    glance.DivInt -> python.DivideInt
    glance.MultInt | glance.MultFloat -> python.Multiply
    glance.RemainderInt -> python.Modulo
    glance.Eq -> python.Equal
    glance.NotEq -> python.NotEqual
    glance.LtInt | glance.LtFloat -> python.LessThan
    glance.LtEqInt | glance.LtEqFloat -> python.LessThanEqual
    glance.GtInt | glance.GtFloat -> python.GreaterThan
    glance.GtEqInt | glance.GtEqFloat -> python.GreaterThanEqual
    glance.Pipe -> panic as "Pipe should have been translated elsewhere"
  }
  python.BinaryOperator(
    op,
    transform_expression(left),
    transform_expression(right),
  )
}

fn transform_expression(expression: glance.Expression) -> python.Expression {
  case expression {
    glance.Call(glance.Variable(function_name), arguments) -> {
      python.Call(
        function_name,
        arguments: list.map(arguments, transform_call_argument),
      )
    }
    glance.String(string) -> python.String(string)
    glance.Int(string) | glance.Float(string) -> python.Number(string)
    glance.Variable("True") -> python.Bool("True")
    glance.Variable("False") -> python.Bool("False")
    glance.Tuple(expressions) ->
      expressions
      |> list.map(transform_expression)
      |> python.Tuple()
    glance.TupleIndex(tuple, index) ->
      python.TupleIndex(transform_expression(tuple), index)
    glance.BinaryOperator(glance.Pipe, left, glance.Variable(function)) -> {
      // simple pipe left |> foo
      python.Call(function, [transform_expression(left)])
    }
    glance.BinaryOperator(
      glance.Pipe,
      left,
      glance.FnCapture(
        label,
        glance.Variable(function),
        arguments_before,
        arguments_after,
      ),
    ) -> {
      let argument_expressions =
        list.concat([
          arguments_before,
          [glance.Field(label, left)],
          arguments_after,
        ])
        |> list.map(transform_call_argument)
      python.Call(function, argument_expressions)
    }
    glance.BinaryOperator(glance.Pipe, _, right) -> {
      pprint.debug(right)
      panic as "I don't know how to handle this structure of pipe"
    }
    glance.BinaryOperator(name, left, right) ->
      transform_binop(name, left, right)
    _ -> {
      pprint.debug(expression)
      todo as "many expressions aren't handled yet"
    }
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

fn transform_type(type_: glance.Type) -> python.Type {
  case type_ {
    glance.NamedType(name, module, []) -> python.NamedType(name, module)
    _ -> todo as "not able to transform most types yet"
  }
}

fn transform_variant_field(
  field: glance.Field(glance.Type),
) -> python.Field(python.Type) {
  case field {
    glance.Field(label: option.None, item: item) ->
      python.UnlabelledField(transform_type(item))
    glance.Field(label: option.Some(label), item: item) ->
      python.LabelledField(label, transform_type(item))
  }
}

fn transform_type_variant(variant: glance.Variant) -> python.Variant {
  python.Variant(
    name: variant.name,
    fields: list.map(variant.fields, transform_variant_field),
  )
}

fn transform_custom_type(custom_type: glance.CustomType) -> python.CustomType {
  python.CustomType(
    name: custom_type.name,
    variants: list.map(custom_type.variants, transform_type_variant),
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

fn transform_custom_type_in_module(
  module: python.Module,
  custom_type: glance.Definition(glance.CustomType),
) -> python.Module {
  let has_dataclass_import =
    list.find(module.imports, fn(imp) { imp == python.dataclass_import })

  let imports = case has_dataclass_import {
    Ok(_) -> module.imports
    Error(_) -> [python.dataclass_import, ..module.imports]
  }

  python.Module(
    ..module,
    imports: imports,
    custom_types: [
      transform_custom_type(custom_type.definition),
      ..module.custom_types
    ],
  )
}

pub fn transform(input: glance.Module) -> Result(python.Module, String) {
  python.empty_module()
  |> list.fold(input.functions, _, transform_function_or_external)
  |> list.fold(input.custom_types, _, transform_custom_type_in_module)
  |> Ok
}

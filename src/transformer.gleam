import glance
import gleam/list
import gleam/option
import internal/transformer
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

fn add_return_if_returnable_expression(
  statement: python.Statement,
) -> python.Statement {
  case statement {
    python.Expression(python.Panic(_)) -> statement
    python.Expression(python.Todo(_)) -> statement
    python.Expression(expr) -> python.Return(expr)
    statement -> statement
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
) -> python.Field(python.Expression) {
  case argument {
    glance.Field(option.Some(label), expression) ->
      python.LabelledField(label, transform_expression(expression))
    glance.Field(label: option.None, item: expression) ->
      python.UnlabelledField(transform_expression(expression))
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
    glance.Int(string) | glance.Float(string) -> python.Number(string)
    glance.String(string) -> python.String(string)
    glance.Variable("True") -> python.Bool("True")
    glance.Variable("False") -> python.Bool("False")
    glance.Variable(string) -> python.Variable(string)
    glance.NegateInt(expression) ->
      python.Negate(transform_expression(expression))

    glance.Panic(option.None) ->
      python.Panic(python.String("panic expression evaluated"))

    glance.Panic(option.Some(expression)) ->
      python.Panic(transform_expression(expression))

    glance.Todo(option.None) ->
      python.Todo(python.String("This has not yet been implemented"))

    glance.Todo(option.Some(expression)) ->
      python.Todo(transform_expression(expression))

    glance.NegateBool(expression) ->
      python.Not(transform_expression(expression))

    glance.Call(function, arguments) -> {
      python.Call(
        function: transform_expression(function),
        arguments: list.map(arguments, transform_call_argument),
      )
    }

    glance.Tuple(expressions) ->
      expressions
      |> list.map(transform_expression)
      |> python.Tuple()

    glance.TupleIndex(tuple, index) ->
      python.TupleIndex(transform_expression(tuple), index)

    glance.FieldAccess(container: expression, label:) ->
      python.FieldAccess(transform_expression(expression), label)

    glance.BinaryOperator(glance.Pipe, left, glance.Variable(function)) -> {
      // simple pipe left |> foo
      python.Call(python.Variable(function), [
        python.UnlabelledField(transform_expression(left)),
      ])
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
      python.Call(python.Variable(function), argument_expressions)
    }
    glance.BinaryOperator(glance.Pipe, _, right) -> {
      panic as "I don't know how to handle this structure of pipe"
    }
    glance.BinaryOperator(name, left, right) ->
      transform_binop(name, left, right)

    glance.RecordUpdate(record:, fields:, ..) -> {
      python.RecordUpdate(
        record: transform_expression(record),
        fields: fields
          |> list.map(fn(tuple) {
            python.LabelledField(tuple.0, transform_expression(tuple.1))
          }),
      )
    }

    glance.List(head, option.Some(rest)) as expr ->
      python.ListWithRest(
        list.map(head, transform_expression),
        transform_expression(rest),
      )
    glance.List(head, option.None) as expr ->
      python.List(list.map(head, transform_expression))

    glance.BitString(_) as expr
    | glance.Block(_) as expr
    | glance.Case(_, _) as expr
    | glance.Fn(_, _, _) as expr
    | glance.FnCapture(_, _, _, _) as expr -> {
      pprint.debug(expr)
      todo as "Several expressions are not implemented yet"
    }
  }
}

fn transform_statement(statement: glance.Statement) -> python.Statement {
  case statement {
    glance.Expression(expression) -> {
      python.Expression(transform_expression(expression))
    }
    glance.Assignment(
      kind: glance.Let,
      pattern: glance.PatternVariable(variable),
      value: value,
      ..,
    ) -> python.SimpleAssignment(variable, transform_expression(value))
    glance.Assignment(..) ->
      todo as "Non-trivial assignments are not supported yet"
    _ -> {
      pprint.debug(statement)
      todo as "not all statements are defined yet"
    }
  }
}

fn transform_function(function: glance.Function) -> python.Function {
  python.Function(
    name: function.name,
    parameters: list.map(function.parameters, transform_function_parameter),
    body: list.map(function.body, transform_statement)
      |> transformer.transform_last(add_return_if_returnable_expression),
  )
}

fn transform_type(type_: glance.Type) -> python.Type {
  case type_ {
    glance.NamedType(name, module, parameters) ->
      python.NamedType(name, module, list.map(parameters, transform_type))

    glance.TupleType(elements) ->
      python.TupleType(list.map(elements, transform_type))

    glance.FunctionType(..) ->
      todo as "Not able to transform function types yet"

    glance.VariableType(name) -> {
      python.GenericType(name)
    }

    glance.HoleType(..) -> todo as "I don't even know what a hole type is"
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
    parameters: custom_type.parameters,
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
  python.Module(
    ..module,
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

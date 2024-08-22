import glance
import gleam/list
import gleam/option
import internal/transformer
import pprint
import python

type ReversedList(a) =
  List(a)

type TransformError {
  NotExternal
}

type TransformerContext {
  TransformerContext(next_function_id: Int)
}

type ExpressionReturn {
  ExpressionReturn(
    context: TransformerContext,
    statements: List(python.Statement),
    expression: python.Expression,
  )
}

type TransformState(a) {
  TransformState(
    context: TransformerContext,
    statements: List(python.Statement),
    item: a,
  )
}

type StatementReturn {
  StatementReturn(
    context: TransformerContext,
    statements: List(python.Statement),
  )
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

fn fold_call_argument(
  state: TransformState(ReversedList(python.Field(python.Expression))),
  argument: glance.Field(glance.Expression),
) -> TransformState(ReversedList(python.Field(python.Expression))) {
  case argument {
    glance.Field(option.Some(label), expression) -> {
      let result = transform_expression(state.context, expression)
      TransformState(
        result.context,
        list.append(state.statements, result.statements),
        list.prepend(state.item, python.LabelledField(label, result.expression)),
      )
    }
    glance.Field(label: option.None, item: expression) -> {
      let result = transform_expression(state.context, expression)
      TransformState(
        result.context,
        list.append(state.statements, result.statements),
        list.prepend(state.item, python.UnlabelledField(result.expression)),
      )
    }
  }
}

fn transform_binop(
  context: TransformerContext,
  name: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> ExpressionReturn {
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
  let left_result = transform_expression(context, left)
  let right_result = transform_expression(left_result.context, right)
  ExpressionReturn(
    right_result.context,
    list.append(left_result.statements, right_result.statements),
    python.BinaryOperator(op, left_result.expression, right_result.expression),
  )
}

fn transform_expression(
  context: TransformerContext,
  expression: glance.Expression,
) -> ExpressionReturn {
  case expression {
    glance.Int(string) | glance.Float(string) ->
      ExpressionReturn(context, [], python.Number(string))

    glance.String(string) ->
      ExpressionReturn(context, [], python.String(string))

    glance.Variable("True") ->
      ExpressionReturn(context, [], python.Bool("True"))

    glance.Variable("False") ->
      ExpressionReturn(context, [], python.Bool("False"))

    glance.Variable(string) ->
      ExpressionReturn(context, [], python.Variable(string))

    glance.NegateInt(expression) -> {
      let result = transform_expression(context, expression)
      ExpressionReturn(
        result.context,
        result.statements,
        python.Negate(result.expression),
      )
    }

    glance.Panic(option.None) ->
      ExpressionReturn(
        context,
        [],
        python.Panic(python.String("panic expression evaluated")),
      )

    glance.Panic(option.Some(expression)) -> {
      let result = transform_expression(context, expression)
      ExpressionReturn(
        result.context,
        result.statements,
        python.Panic(result.expression),
      )
    }

    glance.Todo(option.None) ->
      ExpressionReturn(
        context,
        [],
        python.Todo(python.String("This has not yet been implemented")),
      )

    glance.Todo(option.Some(expression)) -> {
      let result = transform_expression(context, expression)
      ExpressionReturn(
        result.context,
        result.statements,
        python.Todo(result.expression),
      )
    }

    glance.NegateBool(expression) -> {
      let result = transform_expression(context, expression)
      ExpressionReturn(
        result.context,
        result.statements,
        python.Not(result.expression),
      )
    }
    glance.Call(function, arguments) -> {
      let function_result = transform_expression(context, function)
      let reversed_arguments_result =
        list.fold(
          arguments,
          TransformState(function_result.context, [], []),
          fold_call_argument,
        )
      ExpressionReturn(
        reversed_arguments_result.context,
        list.append(
          function_result.statements,
          reversed_arguments_result.statements,
        ),
        python.Call(
          function: function_result.expression,
          arguments: list.reverse(reversed_arguments_result.item),
        ),
      )
    }

    glance.FnCapture(label, function, arguments_before, arguments_after) -> {
      let function_result = transform_expression(context, function)
      let reversed_arguments_result =
        list.concat([
          arguments_before,
          [glance.Field(label, glance.Variable("fn_capture"))],
          arguments_after,
        ])
        |> list.fold(
          TransformState(function_result.context, [], []),
          fold_call_argument,
        )

      ExpressionReturn(
        reversed_arguments_result.context,
        list.append(
          function_result.statements,
          reversed_arguments_result.statements,
        ),
        python.Lambda(
          [python.Variable("fn_capture")],
          python.Call(
            function_result.expression,
            reversed_arguments_result.item |> list.reverse,
          ),
        ),
      )
    }

    glance.Tuple(expressions) -> {
      let result =
        expressions
        |> list.fold(#(context, [], []), fn(state, expression) {
          let result = transform_expression(state.0, expression)
          #(
            result.context,
            list.append(state.1, result.statements),
            list.prepend(state.2, result.expression),
          )
        })
      ExpressionReturn(result.0, result.1, python.Tuple(list.reverse(result.2)))
    }

    glance.TupleIndex(tuple, index) -> {
      let result = transform_expression(context, tuple)
      ExpressionReturn(
        result.context,
        result.statements,
        python.TupleIndex(result.expression, index),
      )
    }

    glance.FieldAccess(container: expression, label:) -> {
      let result = transform_expression(context, expression)
      ExpressionReturn(
        result.context,
        result.statements,
        python.FieldAccess(result.expression, label),
      )
    }

    glance.BinaryOperator(glance.Pipe, left, right) -> {
      let left_result = transform_expression(context, left)
      let right_result = transform_expression(left_result.context, right)

      ExpressionReturn(
        right_result.context,
        list.append(left_result.statements, right_result.statements),
        python.Call(right_result.expression, [
          python.UnlabelledField(left_result.expression),
        ]),
      )
    }

    glance.BinaryOperator(name, left, right) -> {
      transform_binop(context, name, left, right)
    }

    glance.RecordUpdate(record:, fields:, ..) -> {
      let record_result = transform_expression(context, record)
      let reversed_fields_result =
        fields
        |> list.fold(
          TransformState(record_result.context, [], []),
          fn(state, tuple) {
            let result = transform_expression(state.context, tuple.1)
            TransformState(
              result.context,
              list.append(state.statements, result.statements),
              list.prepend(
                state.item,
                python.LabelledField(tuple.0, result.expression),
              ),
            )
          },
        )

      ExpressionReturn(
        reversed_fields_result.context,
        list.append(record_result.statements, reversed_fields_result.statements),
        python.RecordUpdate(
          record: record_result.expression,
          fields: reversed_fields_result.item |> list.reverse,
        ),
      )
    }

    glance.List(head, option.Some(rest)) -> {
      let reversed_list_result =
        head
        |> list.fold(TransformState(context, [], []), fn(state, elem) {
          let result = transform_expression(state.context, elem)
          TransformState(
            result.context,
            list.append(state.statements, result.statements),
            list.prepend(state.item, result.expression),
          )
        })

      let rest_result = transform_expression(reversed_list_result.context, rest)

      ExpressionReturn(
        rest_result.context,
        list.append(reversed_list_result.statements, rest_result.statements),
        python.ListWithRest(
          reversed_list_result.item |> list.reverse,
          rest_result.expression,
        ),
      )
    }
    glance.List(head, option.None) as expr -> {
      let reversed_list_result =
        head
        |> list.fold(TransformState(context, [], []), fn(state, elem) {
          let result = transform_expression(state.context, elem)
          TransformState(
            result.context,
            list.append(state.statements, result.statements),
            list.prepend(state.item, result.expression),
          )
        })
      ExpressionReturn(
        reversed_list_result.context,
        reversed_list_result.statements,
        python.List(reversed_list_result.item |> list.reverse),
      )
    }

    glance.BitString(_) as expr
    | glance.Block(_) as expr
    | glance.Case(_, _) as expr
    | glance.Fn(_, _, _) as expr -> {
      pprint.debug(expr)
      todo as "Several expressions are not implemented yet"
    }
  }
}

fn transform_statement(
  transform_context: TransformerContext,
  statement: glance.Statement,
) -> StatementReturn {
  case statement {
    glance.Expression(expression) -> {
      let result = transform_expression(transform_context, expression)
      StatementReturn(
        context: result.context,
        statements: list.append(result.statements, [
          python.Expression(result.expression),
        ]),
      )
    }
    glance.Assignment(
      kind: glance.Let,
      pattern: glance.PatternVariable(variable),
      value: value,
      ..,
    ) -> {
      let result = transform_expression(transform_context, value)
      StatementReturn(
        context: result.context,
        statements: list.append(result.statements, [
          python.SimpleAssignment(variable, result.expression),
        ]),
      )
    }
    glance.Assignment(..) ->
      todo as "Non-trivial assignments are not supported yet"
    _ -> {
      pprint.debug(statement)
      todo as "not all statements are defined yet"
    }
  }
}

fn transform_top_level_function(function: glance.Function) -> python.Function {
  python.Function(
    name: function.name,
    parameters: list.map(function.parameters, transform_function_parameter),
    body: {
      let result =
        function.body
        |> list.fold(
          StatementReturn(
            context: TransformerContext(next_function_id: 0),
            statements: [],
          ),
          fn(state, next_statement) {
            let result = transform_statement(state.context, next_statement)
            StatementReturn(
              context: result.context,
              statements: list.append(state.statements, result.statements),
            )
          },
        )
      result.statements
      |> transformer.transform_last(add_return_if_returnable_expression)
    },
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
        functions: [
          transform_top_level_function(function.definition),
          ..module.functions
        ],
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

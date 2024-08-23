import compiler/internal/transformer as internal
import compiler/python
import glance
import gleam/list
import gleam/option
import pprint

pub fn transform_statement(
  transform_context: internal.TransformerContext,
  statement: glance.Statement,
) -> internal.StatementReturn {
  case statement {
    glance.Expression(expression) -> {
      let result = transform_expression(transform_context, expression)
      internal.StatementReturn(
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
      internal.StatementReturn(
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

fn transform_expression(
  context: internal.TransformerContext,
  expression: glance.Expression,
) -> internal.ExpressionReturn {
  case expression {
    glance.Int(string) | glance.Float(string) ->
      internal.empty_return(context, python.Number(string))

    glance.String(string) ->
      internal.empty_return(context, python.String(string))

    glance.Variable("True") ->
      internal.empty_return(context, python.Bool("True"))

    glance.Variable("False") ->
      internal.empty_return(context, python.Bool("False"))

    glance.Variable(string) ->
      internal.empty_return(context, python.Variable(string))

    glance.Tuple(expressions) -> transform_tuple(context, expressions)

    glance.List(head, rest) -> transform_list(context, head, rest)

    glance.NegateInt(expression) ->
      transform_expression(context, expression)
      |> internal.map_return(python.Negate)

    glance.NegateBool(expression) -> {
      transform_expression(context, expression)
      |> internal.map_return(python.Not(_))
    }

    glance.Panic(option.None) ->
      internal.empty_return(
        context,
        python.Panic(python.String("panic expression evaluated")),
      )
    glance.Panic(option.Some(expression)) ->
      transform_expression(context, expression)
      |> internal.map_return(python.Panic)

    glance.Todo(option.None) ->
      internal.empty_return(
        context,
        python.Todo(python.String("This has not yet been implemented")),
      )
    glance.Todo(option.Some(expression)) ->
      transform_expression(context, expression)
      |> internal.map_return(python.Todo(_))

    glance.Call(function, arguments) ->
      transform_call(context, function, arguments)

    glance.FnCapture(label, function, arguments_before, arguments_after) ->
      transform_fn_capture(
        context,
        label,
        function,
        arguments_before,
        arguments_after,
      )

    glance.TupleIndex(tuple, index) -> {
      transform_expression(context, tuple)
      |> internal.map_return(python.TupleIndex(_, index))
    }

    glance.FieldAccess(container: expression, label:) ->
      transform_expression(context, expression)
      |> internal.map_return(python.FieldAccess(_, label))

    glance.BinaryOperator(glance.Pipe, left, right) ->
      transform_pipe(context, left, right)

    glance.BinaryOperator(name, left, right) -> {
      transform_binop(context, name, left, right)
    }

    glance.RecordUpdate(record:, fields:, ..) ->
      transform_record_update(context, record, fields)

    glance.BitString(_) as expr
    | glance.Block(_) as expr
    | glance.Case(_, _) as expr
    | glance.Fn(_, _, _) as expr -> {
      pprint.debug(expr)
      todo as "Several expressions are not implemented yet"
    }
  }
}

fn transform_tuple(
  context: internal.TransformerContext,
  expressions: List(glance.Expression),
) -> internal.ExpressionReturn {
  expressions
  |> list.fold(internal.TransformState(context, [], []), fn(state, expression) {
    internal.merge_state_prepend(
      state,
      transform_expression(state.context, expression),
      fn(a) { a },
    )
  })
  |> internal.reverse_state_to_return(python.Tuple)
}

fn transform_list(
  context: internal.TransformerContext,
  head: List(glance.Expression),
  rest: option.Option(glance.Expression),
) -> internal.ExpressionReturn {
  let reversed_list_result =
    head
    |> list.fold(internal.TransformState(context, [], []), fn(state, elem) {
      internal.merge_state_prepend(
        state,
        transform_expression(state.context, elem),
        fn(a) { a },
      )
    })

  case rest {
    option.None -> {
      internal.reverse_state_to_return(reversed_list_result, python.List(_))
    }
    option.Some(rest) -> {
      let rest_result = transform_expression(reversed_list_result.context, rest)
      internal.ExpressionReturn(
        rest_result.context,
        list.append(reversed_list_result.statements, rest_result.statements),
        python.ListWithRest(
          reversed_list_result.item |> list.reverse,
          rest_result.expression,
        ),
      )
    }
  }
}

fn transform_call(
  context: internal.TransformerContext,
  function: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> internal.ExpressionReturn {
  let function_result = transform_expression(context, function)
  let reversed_arguments_result =
    list.fold(
      arguments,
      internal.TransformState(function_result.context, [], []),
      fold_call_argument,
    )
  internal.ExpressionReturn(
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

fn fold_call_argument(
  state: internal.TransformState(
    internal.ReversedList(python.Field(python.Expression)),
  ),
  argument: glance.Field(glance.Expression),
) -> internal.TransformState(
  internal.ReversedList(python.Field(python.Expression)),
) {
  case argument {
    glance.Field(option.Some(label), expression) -> {
      internal.merge_state_prepend(
        state,
        transform_expression(state.context, expression),
        python.LabelledField(label, _),
      )
    }
    glance.Field(label: option.None, item: expression) -> {
      internal.merge_state_prepend(
        state,
        transform_expression(state.context, expression),
        python.UnlabelledField,
      )
    }
  }
}

fn transform_fn_capture(
  context: internal.TransformerContext,
  label: option.Option(String),
  function: glance.Expression,
  arguments_before: List(glance.Field(glance.Expression)),
  arguments_after: List(glance.Field(glance.Expression)),
) -> internal.ExpressionReturn {
  let function_result = transform_expression(context, function)
  let reversed_arguments_result =
    list.concat([
      arguments_before,
      [glance.Field(label, glance.Variable("fn_capture"))],
      arguments_after,
    ])
    |> list.fold(
      internal.TransformState(function_result.context, [], []),
      fold_call_argument,
    )

  internal.ExpressionReturn(
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

fn transform_pipe(
  context: internal.TransformerContext,
  left: glance.Expression,
  right: glance.Expression,
) -> internal.ExpressionReturn {
  let left_result = transform_expression(context, left)
  let right_result = transform_expression(left_result.context, right)
  internal.merge_return(left_result, right_result, fn(left_ex, right_ex) {
    python.Call(right_ex, [python.UnlabelledField(left_ex)])
  })
}

fn transform_binop(
  context: internal.TransformerContext,
  name: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> internal.ExpressionReturn {
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
  internal.merge_return(left_result, right_result, fn(left_ex, right_ex) {
    python.BinaryOperator(op, left_ex, right_ex)
  })
}

fn transform_record_update(
  context: internal.TransformerContext,
  record: glance.Expression,
  fields: List(#(String, glance.Expression)),
) -> internal.ExpressionReturn {
  let record_result = transform_expression(context, record)
  fields
  |> list.fold(
    internal.TransformState(record_result.context, [], []),
    fn(state, tuple) {
      internal.merge_state_prepend(
        state,
        transform_expression(state.context, tuple.1),
        python.LabelledField(tuple.0, _),
      )
    },
  )
  |> internal.reverse_state_to_return(python.RecordUpdate(
    record: record_result.expression,
    fields: _,
  ))
}

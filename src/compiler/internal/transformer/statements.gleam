import compiler/internal/transformer as internal
import compiler/internal/transformer/patterns
import compiler/python
import glance
import gleam/int
import gleam/list
import gleam/option
import pprint

// a block is a scope, so context can be reset at this level.
//
// Called from 
// * function.transform_top_level_function
// * Todo: fn
// * Todo: block
// * Todo: case
pub fn transform_statement_block(
  statements: List(glance.Statement),
) -> List(python.Statement) {
  transform_statement_block_with_context(
    internal.TransformerContext(
      next_function_id: 0,
      next_block_id: 0,
      next_case_id: 0,
    ),
    statements,
  ).statements
}

pub fn transform_statement_block_with_context(
  context: internal.TransformerContext,
  statements: List(glance.Statement),
) -> internal.StatementReturn {
  let result =
    statements
    |> list.fold(
      internal.StatementReturn(context, statements: []),
      fn(state, next_statement) {
        let result = transform_statement(state.context, next_statement)
        internal.StatementReturn(
          context: result.context,
          statements: list.append(state.statements, result.statements),
        )
      },
    )

  internal.StatementReturn(
    ..result,
    statements: result.statements
      |> internal.transform_last(internal.add_return_if_returnable_expression),
  )
}

fn transform_statement(
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
    glance.Assignment(..) as expr -> {
      pprint.debug(expr)
      todo as "Non-trivial assignments are not supported yet"
    }

    glance.Use(..) -> {
      todo as "Use statements are not supported yet"
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

    glance.Fn(arguments:, return_annotation: _, body:) ->
      transform_fn(context, arguments, body)

    glance.Block(statements) -> transform_block(context, statements)

    glance.Case(subjects, clauses) -> transform_case(context, subjects, clauses)

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

    glance.BitString(segments) -> {
      segments
      |> list.fold(
        internal.TransformState(context, [], []),
        fold_bitstring_segment,
      )
      |> internal.reverse_state_to_return(python.BitString)
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

fn transform_fn(
  context: internal.TransformerContext,
  arguments: List(glance.FnParameter),
  body: List(glance.Statement),
) -> internal.ExpressionReturn {
  let parameters =
    arguments
    |> list.map(fn(argument) {
      // TODO: shouldn't be ignoring type here
      case argument.name {
        glance.Named(name) -> python.NameParam(name)
        glance.Discarded(_) ->
          todo as "discard parameters not supported in function arguments yet"
      }
    })

  let function_name = "_fn_def_" <> int.to_string(context.next_function_id)
  let function =
    python.Function(function_name, parameters, transform_statement_block(body))

  internal.ExpressionReturn(
    context: internal.TransformerContext(
      ..context,
      next_function_id: context.next_function_id + 1,
    ),
    statements: [python.FunctionDef(function)],
    expression: python.Variable(function_name),
  )
}

fn transform_block(
  context: internal.TransformerContext,
  body: List(glance.Statement),
) -> internal.ExpressionReturn {
  let function_name = "_fn_block_" <> int.to_string(context.next_block_id)
  let function =
    python.Function(function_name, [], transform_statement_block(body))
  internal.ExpressionReturn(
    context: internal.TransformerContext(
      ..context,
      next_block_id: context.next_block_id + 1,
    ),
    statements: [python.FunctionDef(function)],
    expression: python.Call(python.Variable(function_name), []),
  )
}

fn transform_case(
  context: internal.TransformerContext,
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
) -> internal.ExpressionReturn {
  let subjects_result = case subjects {
    [] -> panic("No subjects!")
    [subject] -> transform_expression(context, subject)
    multiple -> transform_tuple(context, multiple)
  }
  let clause_result =
    list.fold(
      clauses,
      internal.TransformState(subjects_result.context, [], []),
      fold_case_clause,
    )

  let function_name = "_fn_case_" <> int.to_string(context.next_case_id)
  let function =
    python.Function(function_name, [python.NameParam("_case_subject")], [
      python.Match(clause_result.item |> list.reverse),
    ])

  internal.ExpressionReturn(
    context: internal.TransformerContext(
      ..subjects_result.context,
      next_case_id: context.next_case_id + 1,
    ),
    statements: list.append(subjects_result.statements, [
      python.FunctionDef(function),
    ]),
    expression: python.Call(python.Variable(function_name), [
      python.UnlabelledField(subjects_result.expression),
    ]),
  )
}

fn fold_case_clause(
  state: internal.TransformState(internal.ReversedList(python.MatchCase)),
  clause: glance.Clause,
) -> internal.TransformState(internal.ReversedList(python.MatchCase)) {
  case clause {
    glance.Clause(guard: option.Some(_), ..) ->
      todo as "Case guards not implemented yet"

    glance.Clause(pattern_list, option.None, glance.Block(statements)) -> {
      let python_pattern = patterns.transform_alternative_patterns(pattern_list)
      let statements_result =
        transform_statement_block_with_context(state.context, statements)
      internal.TransformState(
        statements_result.context,
        state.statements,
        state.item
          |> list.prepend(python.MatchCase(
            python_pattern,
            statements_result.statements,
          )),
      )
    }

    glance.Clause(pattern_list, option.None, body) -> {
      let python_pattern = patterns.transform_alternative_patterns(pattern_list)
      let body_result = transform_expression(state.context, body)

      internal.merge_state_prepend(state, body_result, fn(expr) {
        python.MatchCase(python_pattern, [python.Return(expr)])
      })
    }
  }
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
    internal.TransformState(record_result.context, record_result.statements, []),
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

fn fold_bitstring_segment(
  state: internal.TransformState(internal.ReversedList(python.BitStringSegment)),
  segment: #(
    glance.Expression,
    List(glance.BitStringSegmentOption(glance.Expression)),
  ),
) -> internal.TransformState(internal.ReversedList(python.BitStringSegment)) {
  let #(expression, options) = segment
  let expression_result = transform_expression(state.context, expression)
  let options_result =
    options
    |> list.fold(
      internal.TransformState(
        expression_result.context,
        expression_result.statements,
        [],
      ),
      fold_bitsting_segment_option,
    )

  internal.TransformState(
    options_result.context,
    options_result.statements,
    list.prepend(
      state.item,
      python.BitStringSegment(
        expression_result.expression,
        options_result.item |> list.reverse,
      ),
    ),
  )
}

fn fold_bitsting_segment_option(
  state: internal.TransformState(
    internal.ReversedList(python.BitStringSegmentOption),
  ),
  option: glance.BitStringSegmentOption(glance.Expression),
) -> internal.TransformState(
  internal.ReversedList(python.BitStringSegmentOption),
) {
  case option {
    glance.FloatOption -> internal.map_state_prepend(state, python.FloatOption)
    glance.LittleOption ->
      internal.map_state_prepend(state, python.LittleOption)
    glance.BigOption -> internal.map_state_prepend(state, python.BigOption)
    glance.NativeOption ->
      internal.map_state_prepend(state, python.NativeOption)
    glance.BitStringOption ->
      internal.map_state_prepend(state, python.BitStringOption)
    glance.Utf8Option -> internal.map_state_prepend(state, python.Utf8Option)
    glance.Utf16Option -> internal.map_state_prepend(state, python.Utf16Option)
    glance.Utf32Option -> internal.map_state_prepend(state, python.Utf32Option)

    glance.UnitOption(size) ->
      internal.map_state_prepend(state, python.UnitOption(size))
    glance.SizeOption(size) ->
      internal.map_state_prepend(
        state,
        python.SizeValueOption(python.Number(size |> int.to_string)),
      )
    glance.SizeValueOption(expression) -> {
      let expression_result = transform_expression(state.context, expression)
      internal.merge_state_prepend(
        state,
        expression_result,
        python.SizeValueOption,
      )
    }

    glance.SignedOption | glance.UnsignedOption -> {
      panic as "Signed and unsigned are not valid when constructing bitstrings"
    }

    _ -> {
      pprint.debug(option)
      todo as "Some bitstring segment options not supported yet"
    }
  }
}

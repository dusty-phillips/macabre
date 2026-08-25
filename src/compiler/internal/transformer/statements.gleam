import compiler/internal/transformer as internal
import compiler/internal/transformer/desugar
import compiler/internal/transformer/patterns
import compiler/internal/transformer/shadowing
import compiler/python
import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string

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
  transform_statement_block_with_context(internal.empty_context(), statements).statements
}

pub fn transform_statement_block_with_context(
  context: internal.TransformerContext,
  statements: List(glance.Statement),
) -> internal.StatementReturn {
  let result =
    statements
    |> desugar.desugar_use
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

pub fn transform_constant(
  context: internal.TransformerContext,
  module: python.Module,
  constant: glance.Definition(glance.Constant),
  docstring: option.Option(String),
  comments: List(String),
) -> python.Module {
  python.Module(..module, constants: [
    python.Constant(
      name: constant.definition.name,
      value: transform_expression(context, constant.definition.value).expression,
      public: is_public(constant.definition.publicity),
      docstring: docstring,
      comments: comments,
    ),
    ..module.constants
  ])
}

fn is_public(publicity: glance.Publicity) -> Bool {
  case publicity {
    glance.Public -> True
    glance.Private -> False
  }
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
      pattern: glance.PatternVariable(_, variable),
      value: value,
      ..,
    ) -> {
      let result = transform_expression(transform_context, value)
      internal.StatementReturn(
        context: internal.TransformerContext(
          ..result.context,
          local_bindings: list.append(result.context.local_bindings, [
            variable,
          ]),
        ),
        statements: list.append(result.statements, [
          python.SimpleAssignment(variable, result.expression),
        ]),
      )
    }
    glance.Assignment(
      location: location,
      kind: kind,
      pattern: pattern,
      value: value,
      ..,
    ) ->
      transform_destructuring_assignment(
        transform_context,
        location,
        kind,
        pattern,
        value,
      )
    glance.Use(..) -> panic as "Use statements should have been desugared by now"

    glance.Assert(assert_location, expression, message) -> {
      let message_result = case message {
        option.Some(message_expression) -> {
          let result =
            transform_expression(transform_context, message_expression)
          internal.OptionalExpressionReturn(
            result.context,
            result.statements,
            option.Some(result.expression),
          )
        }
        option.None ->
          internal.OptionalExpressionReturn(transform_context, [], option.None)
      }
      transform_assert_statement(
        message_result.context,
        assert_location,
        expression,
        message_result,
      )
    }
  }
}

// A destructuring or `let assert` assignment. These can't be turned into a
// simple Python assignment, so we generate a helper function that matches on
// the value, returning the bound variables as a tuple (or raising on failure
// for `let assert`), and assign the result.
fn transform_destructuring_assignment(
  context: internal.TransformerContext,
  location: glance.Span,
  kind: glance.AssignmentKind,
  pattern: glance.Pattern,
  value: glance.Expression,
) -> internal.StatementReturn {
  let binds = patterns.collect_binds(pattern)
  let message_result = case kind {
    glance.Let -> internal.OptionalExpressionReturn(context, [], option.None)
    glance.LetAssert(message) ->
      message
      |> option.map(fn(expression) {
        let result = transform_expression(context, expression)
        internal.OptionalExpressionReturn(
          result.context,
          result.statements,
          option.Some(result.expression),
        )
      })
      |> option.unwrap(internal.OptionalExpressionReturn(
        context,
        [],
        option.None,
      ))
  }
  let value_result = transform_expression(message_result.context, value)

  let #(statements, fresh_pool) = case tuple_unpack_names(pattern), kind {
    // A `let #(a, b) = expr` where every element is a plain variable or
    // discard: Python unpacks tuples natively, so emit `a, b = expr` directly
    // instead of a helper closure + call + match. This is the most common
    // destructure in the compiler (store/type threading), and each helper
    // closure is a function call plus a match dispatch.
    option.Some(names), glance.Let -> {
      let assignment = case names {
        [] -> [python.Expression(value_result.expression)]
        [single] -> [python.SimpleAssignment(single, value_result.expression)]
        multiple -> [
          python.MultipleAssignment(multiple, value_result.expression),
        ]
      }
      #(
        list.append(
          list.append(message_result.statements, value_result.statements),
          assignment,
        ),
        value_result.context.fresh_pool,
      )
    }
    _, _ -> {
      let #(statements, fresh_pool) = case binds, kind {
        [], glance.Let ->
          // A pattern that binds nothing, e.g. `let _ = foo`. Just evaluate
          // the expression.
          #(
            list.append(
              list.append(message_result.statements, value_result.statements),
              [python.Expression(value_result.expression)],
            ),
            value_result.context.fresh_pool,
          )
        _, _ -> {
          let pattern_result = case
            patterns.transform_alternative_patterns(
              [[pattern]],
              False,
              context.module_bindings,
            )
          {
            [pattern_result] -> pattern_result
            _ -> panic as "Expected a single pattern in destructuring assignment"
          }
          let return_value = case binds {
            [] -> python.Nil
            [single] -> python.Variable(single)
            multiple -> python.Tuple(list.map(multiple, python.Variable))
          }
          let matched_case =
            python.MatchCase(
              pattern_result.pattern,
              pattern_result.guard,
              list.append(pattern_result.body_prepend, [
                python.Return(return_value),
              ]),
            )
          let cases = case kind {
            glance.Let -> [matched_case]
            glance.LetAssert(_) -> [
              matched_case,
              python.MatchCase(python.PatternWildcard, option.None, [
                python.Expression(
                  python.Panic(let_assert_payload(
                    message_result.context,
                    location,
                    pattern,
                    value,
                    option.unwrap(
                      message_result.expression,
                      python.String(
                        "Pattern match failed, no pattern matched the value.",
                      ),
                    ),
                  )),
                ),
              ]),
            ]
          }
          let function_name =
            "_fn_match_" <> int.to_string(context.next_case_id)
          let function =
            python.Function(
              function_name,
              [python.NameParam("_case_subject")],
              [
                python.Match(
                  subject: python.Variable("_case_subject"),
                  cases: cases,
                ),
              ],
              False,
              option.None,
              [],
            )
          let call =
            python.Call(python.Variable(function_name), [
              python.UnlabelledField(value_result.expression),
            ])
          let assignment = case binds {
            [] -> [python.Expression(call)]
            [single] -> [python.SimpleAssignment(single, call)]
            multiple -> [python.MultipleAssignment(multiple, call)]
          }
          #(
            list.append(
              list.append(
                list.append(message_result.statements, value_result.statements),
                [python.FunctionDef(function)],
              ),
              assignment,
            ),
            value_result.context.fresh_pool,
          )
        }
      }
      #(statements, fresh_pool)
    }
  }

  internal.StatementReturn(
    context: internal.TransformerContext(
      ..value_result.context,
      local_bindings: list.append(value_result.context.local_bindings, binds),
      next_case_id: value_result.context.next_case_id + 1,
      fresh_pool: fresh_pool,
    ),
    statements: statements,
  )
}

// The names to bind when destructuring a tuple pattern of only plain variables
// and discards. Returns `None` for any other pattern shape (nested patterns,
// variants, lists, etc.) which still needs the match-helper closure.
fn tuple_unpack_names(pattern: glance.Pattern) -> option.Option(List(String)) {
  case pattern {
    glance.PatternTuple(_, elements) ->
      elements
      |> list.fold(option.Some([]), fn(state, element) {
        case state {
          option.None -> option.None
          option.Some(acc) ->
            case element {
              glance.PatternVariable(_, name) -> option.Some([name, ..acc])
              glance.PatternDiscard(_, "") -> option.Some(["_", ..acc])
              glance.PatternDiscard(_, name) -> option.Some([name, ..acc])
              _ -> option.None
            }
        }
      })
      |> option.map(list.reverse)
    _ -> option.None
  }
}

// The base dict shared by every runtime panic payload:
//   {"gleam_error": <kind>, "message": <msg>, "file": <f>, "module": <m>,
//    "function": <fn>, "line": <n>, ...kind-specific entries}
fn panic_payload(
  context: internal.TransformerContext,
  kind: String,
  message: python.Expression,
  location: glance.Span,
  extra: List(#(String, python.Expression)),
) -> python.Expression {
  python.Dict([
    #("gleam_error", python.String(kind)),
    #("message", message),
    #("file", python.String(context.file_path)),
    #("module", python.String(context.module_name)),
    #("function", python.String(context.function_name)),
    #(
      "line",
      python.Number(
        int.to_string(internal.line_of(context.module_source, location.start)),
      ),
    ),
    ..extra
  ])
}

// The sub-expression dict used for assert operands:
//   {"start": <s>, "end": <e>, "kind": "literal"|"expression"|"unevaluated",
//    "value": <static literal | runtime temp>}
fn asserted_operand_payload(
  expression: glance.Expression,
  temp: String,
) -> python.Expression {
  case compile_time_literal(expression) {
    option.Some(literal) ->
      python.Dict([
        #("start", python.Number(int.to_string(expression.location.start))),
        #("end", python.Number(int.to_string(expression.location.end))),
        #("kind", python.String("literal")),
        #("value", literal),
      ])
    option.None ->
      python.Dict([
        #("start", python.Number(int.to_string(expression.location.start))),
        #("end", python.Number(int.to_string(expression.location.end))),
        #("kind", python.String("expression")),
        #("value", python.Variable(temp)),
      ])
  }
}

fn unevaluated_operand_payload(
  expression: glance.Expression,
) -> python.Expression {
  python.Dict([
    #("start", python.Number(int.to_string(expression.location.start))),
    #("end", python.Number(int.to_string(expression.location.end))),
    #("kind", python.String("unevaluated")),
  ])
}

// Whether a glance expression is a compile-time literal. These get `kind:
// "literal"` with their static value in assert payloads; everything else gets
// `kind: "expression"` with its runtime value.
fn compile_time_literal(
  expression: glance.Expression,
) -> option.Option(python.Expression) {
  case expression {
    glance.Int(_, value) -> option.Some(python.Number(value))
    glance.Float(_, value) -> option.Some(python.Number(value))
    glance.String(_, value) -> option.Some(python.String(value))
    glance.Variable(_, "True") -> option.Some(python.Bool("True"))
    glance.Variable(_, "False") -> option.Some(python.Bool("False"))
    _ -> option.None
  }
}

fn transform_assert_statement(
  context: internal.TransformerContext,
  location: glance.Span,
  subject: glance.Expression,
  message_result: internal.OptionalExpressionReturn,
) -> internal.StatementReturn {
  let message =
    option.unwrap(message_result.expression, python.String("Assertion failed."))
  case subject {
    glance.BinaryOperator(_, glance.And, left, right) ->
      transform_assert_binary_and(
        context,
        location,
        left,
        right,
        message,
        message_result.statements,
      )
    glance.BinaryOperator(_, glance.Or, left, right) ->
      transform_assert_binary_or(
        context,
        location,
        left,
        right,
        message,
        message_result.statements,
      )
    glance.BinaryOperator(_, glance.Pipe, _, _) ->
      transform_assert_expression(
        context,
        location,
        subject,
        message,
        message_result.statements,
      )
    glance.BinaryOperator(_, operator, left, right) ->
      transform_assert_binary_operator(
        context,
        location,
        operator,
        left,
        right,
        message,
        message_result.statements,
      )
    glance.Call(_, _, _) ->
      transform_assert_function_call(
        context,
        location,
        subject,
        message,
        message_result.statements,
      )
    _ ->
      transform_assert_expression(
        context,
        location,
        subject,
        message,
        message_result.statements,
      )
  }
}

// `assert x` where x is a plain expression: kind "expression".
fn transform_assert_expression(
  context: internal.TransformerContext,
  location: glance.Span,
  subject: glance.Expression,
  message: python.Expression,
  message_statements: List(python.Statement),
) -> internal.StatementReturn {
  let subject_result = transform_expression(context, subject)
  let temp = "_assert_" <> int.to_string(subject_result.context.next_assert_id)
  let #(condition, bound_statements) = case compile_time_literal(subject) {
    option.Some(literal) -> #(literal, [])
    option.None -> #(python.Variable(temp), [
      python.SimpleAssignment(temp, subject_result.expression),
    ])
  }
  let payload =
    panic_payload(subject_result.context, "assert", message, location, [
      #("kind", python.String("expression")),
      #("expression", asserted_operand_payload(subject, temp)),
      #("start", python.Number(int.to_string(location.start))),
      #("end", python.Number(int.to_string(subject.location.end))),
      #(
        "expression_start",
        python.Number(int.to_string(subject.location.start)),
      ),
    ])
  internal.StatementReturn(
    context: internal.TransformerContext(
      ..subject_result.context,
      next_assert_id: subject_result.context.next_assert_id + 1,
    ),
    statements: list.append(
      list.append(message_statements, subject_result.statements),
      list.append(bound_statements, [
        python.If(condition: python.Not(condition), body: [
          python.Expression(python.Panic(payload)),
        ]),
      ]),
    ),
  )
}

// `assert a && b`: two error branches matching the erlang nested case. When
// `a` is falsy the right side was never evaluated (kind "unevaluated" with
// spans only); when `b` is falsy both runtime values are reported.
fn transform_assert_binary_and(
  context: internal.TransformerContext,
  location: glance.Span,
  left: glance.Expression,
  right: glance.Expression,
  message: python.Expression,
  message_statements: List(python.Statement),
) -> internal.StatementReturn {
  let left_result = transform_expression(context, left)
  let left_temp =
    "_assert_" <> int.to_string(left_result.context.next_assert_id)
  let #(left_condition, left_binds) = case compile_time_literal(left) {
    option.Some(literal) -> #(literal, [])
    option.None -> #(python.Variable(left_temp), [
      python.SimpleAssignment(left_temp, left_result.expression),
    ])
  }
  let left_context =
    internal.TransformerContext(
      ..left_result.context,
      next_assert_id: left_result.context.next_assert_id + 1,
    )
  let left_payload =
    panic_payload(left_context, "assert", message, location, [
      #("kind", python.String("binary_operator")),
      #("operator", python.String("&&")),
      #("left", asserted_operand_payload(left, left_temp)),
      #("right", unevaluated_operand_payload(right)),
      #("start", python.Number(int.to_string(location.start))),
      #("end", python.Number(int.to_string(right.location.end))),
      #("expression_start", python.Number(int.to_string(left.location.start))),
    ])
  let right_result = transform_expression(left_context, right)
  let right_temp =
    "_assert_" <> int.to_string(right_result.context.next_assert_id)
  let #(right_condition, right_binds) = case compile_time_literal(right) {
    option.Some(literal) -> #(literal, [])
    option.None -> #(python.Variable(right_temp), [
      python.SimpleAssignment(right_temp, right_result.expression),
    ])
  }
  let right_payload =
    panic_payload(right_result.context, "assert", message, location, [
      #("kind", python.String("binary_operator")),
      #("operator", python.String("&&")),
      #("left", asserted_operand_payload(left, left_temp)),
      #("right", asserted_operand_payload(right, right_temp)),
      #("start", python.Number(int.to_string(location.start))),
      #("end", python.Number(int.to_string(right.location.end))),
      #("expression_start", python.Number(int.to_string(left.location.start))),
    ])
  internal.StatementReturn(
    context: internal.TransformerContext(
      ..right_result.context,
      next_assert_id: right_result.context.next_assert_id + 1,
    ),
    statements: list.append(
      list.append(message_statements, left_result.statements),
      list.append(
        left_binds,
        list.append(
          [
            python.If(condition: python.Not(left_condition), body: [
              python.Expression(python.Panic(left_payload)),
            ]),
          ],
          list.append(
            right_result.statements,
            list.append(right_binds, [
              python.If(condition: python.Not(right_condition), body: [
                python.Expression(python.Panic(right_payload)),
              ]),
            ]),
          ),
        ),
      ),
    ),
  )
}

// `assert a || b`: a single error branch reached only when both operands are
// falsy, mirroring erlang's `A orelse B`. The right side is only evaluated
// when the left side is falsy.
fn transform_assert_binary_or(
  context: internal.TransformerContext,
  location: glance.Span,
  left: glance.Expression,
  right: glance.Expression,
  message: python.Expression,
  message_statements: List(python.Statement),
) -> internal.StatementReturn {
  let left_result = transform_expression(context, left)
  let left_temp =
    "_assert_" <> int.to_string(left_result.context.next_assert_id)
  let #(left_condition, left_binds) = case compile_time_literal(left) {
    option.Some(literal) -> #(literal, [])
    option.None -> #(python.Variable(left_temp), [
      python.SimpleAssignment(left_temp, left_result.expression),
    ])
  }
  let left_context =
    internal.TransformerContext(
      ..left_result.context,
      next_assert_id: left_result.context.next_assert_id + 1,
    )
  let right_result = transform_expression(left_context, right)
  let right_temp =
    "_assert_" <> int.to_string(right_result.context.next_assert_id)
  let #(right_condition, right_binds) = case compile_time_literal(right) {
    option.Some(literal) -> #(literal, [])
    option.None -> #(python.Variable(right_temp), [
      python.SimpleAssignment(right_temp, right_result.expression),
    ])
  }
  let payload =
    panic_payload(right_result.context, "assert", message, location, [
      #("kind", python.String("binary_operator")),
      #("operator", python.String("||")),
      #("left", asserted_operand_payload(left, left_temp)),
      #("right", asserted_operand_payload(right, right_temp)),
      #("start", python.Number(int.to_string(location.start))),
      #("end", python.Number(int.to_string(right.location.end))),
      #("expression_start", python.Number(int.to_string(left.location.start))),
    ])
  internal.StatementReturn(
    context: internal.TransformerContext(
      ..right_result.context,
      next_assert_id: right_result.context.next_assert_id + 1,
    ),
    statements: list.append(
      list.append(message_statements, left_result.statements),
      list.append(left_binds, [
        python.If(
          condition: python.Not(left_condition),
          body: list.append(
            right_result.statements,
            list.append(right_binds, [
              python.If(condition: python.Not(right_condition), body: [
                python.Expression(python.Panic(payload)),
              ]),
            ]),
          ),
        ),
      ]),
    ),
  )
}

// `assert a == b` (or any non-&&/|| operator): both operands are always
// evaluated; a single error branch reports them by kind.
fn transform_assert_binary_operator(
  context: internal.TransformerContext,
  location: glance.Span,
  operator: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
  message: python.Expression,
  message_statements: List(python.Statement),
) -> internal.StatementReturn {
  let left_result = transform_expression(context, left)
  let left_temp =
    "_assert_" <> int.to_string(left_result.context.next_assert_id)
  let #(left_condition, left_binds) = case compile_time_literal(left) {
    option.Some(literal) -> #(literal, [])
    option.None -> #(python.Variable(left_temp), [
      python.SimpleAssignment(left_temp, left_result.expression),
    ])
  }
  let left_context =
    internal.TransformerContext(
      ..left_result.context,
      next_assert_id: left_result.context.next_assert_id + 1,
    )
  let right_result = transform_expression(left_context, right)
  let right_temp =
    "_assert_" <> int.to_string(right_result.context.next_assert_id)
  let #(right_condition, right_binds) = case compile_time_literal(right) {
    option.Some(literal) -> #(literal, [])
    option.None -> #(python.Variable(right_temp), [
      python.SimpleAssignment(right_temp, right_result.expression),
    ])
  }
  let payload =
    panic_payload(right_result.context, "assert", message, location, [
      #("kind", python.String("binary_operator")),
      #("operator", python.String(binary_operator_string(operator))),
      #("left", asserted_operand_payload(left, left_temp)),
      #("right", asserted_operand_payload(right, right_temp)),
      #("start", python.Number(int.to_string(location.start))),
      #("end", python.Number(int.to_string(right.location.end))),
      #("expression_start", python.Number(int.to_string(left.location.start))),
    ])
  let condition =
    python.BinaryOperator(
      binary_operator_python(operator),
      left_condition,
      right_condition,
    )
  internal.StatementReturn(
    context: internal.TransformerContext(
      ..right_result.context,
      next_assert_id: right_result.context.next_assert_id + 1,
    ),
    statements: list.append(
      list.append(message_statements, left_result.statements),
      list.append(
        left_binds,
        list.append(
          right_result.statements,
          list.append(right_binds, [
            python.If(condition: python.Not(condition), body: [
              python.Expression(python.Panic(payload)),
            ]),
          ]),
        ),
      ),
    ),
  )
}

fn binary_operator_python(
  operator: glance.BinaryOperator,
) -> python.BinaryOperator {
  case operator {
    glance.And -> python.And
    glance.Or -> python.Or
    glance.Eq -> python.Equal
    glance.NotEq -> python.NotEqual
    glance.LtInt -> python.LessThan
    glance.LtEqInt -> python.LessThanEqual
    glance.LtFloat -> python.LessThan
    glance.LtEqFloat -> python.LessThanEqual
    glance.GtInt -> python.GreaterThan
    glance.GtEqInt -> python.GreaterThanEqual
    glance.GtFloat -> python.GreaterThan
    glance.GtEqFloat -> python.GreaterThanEqual
    glance.AddInt -> python.Add
    glance.AddFloat -> python.Add
    glance.SubInt -> python.Subtract
    glance.SubFloat -> python.Subtract
    glance.MultInt -> python.Multiply
    glance.MultFloat -> python.Multiply
    glance.DivInt -> python.DivideInt
    glance.DivFloat -> python.Divide
    glance.RemainderInt -> python.Modulo
    glance.Concatenate -> python.Add
    glance.Pipe -> panic as "Pipe should have been desugared before asserts"
  }
}

fn binary_operator_string(operator: glance.BinaryOperator) -> String {
  case operator {
    glance.And -> "&&"
    glance.Or -> "||"
    glance.Eq -> "=="
    glance.NotEq -> "!="
    glance.LtInt -> "<"
    glance.LtEqInt -> "<="
    glance.LtFloat -> "<"
    glance.LtEqFloat -> "<="
    glance.GtInt -> ">"
    glance.GtEqInt -> ">="
    glance.GtFloat -> ">"
    glance.GtEqFloat -> ">="
    glance.AddInt -> "+"
    glance.AddFloat -> "+"
    glance.SubInt -> "-"
    glance.SubFloat -> "-"
    glance.MultInt -> "*"
    glance.MultFloat -> "*"
    glance.DivInt -> "/"
    glance.DivFloat -> "/"
    glance.RemainderInt -> "%"
    glance.Concatenate -> "<>"
    glance.Pipe -> "|>"
  }
}

// `assert f(a, b)`: kind "function_call". Non-literal arguments are bound to
// temporaries before the call so their runtime values can be reported.
fn transform_assert_function_call(
  context: internal.TransformerContext,
  location: glance.Span,
  subject: glance.Expression,
  message: python.Expression,
  message_statements: List(python.Statement),
) -> internal.StatementReturn {
  case subject {
    glance.Call(
      location: call_location,
      function: function,
      arguments: arguments,
    ) -> {
      let #(arg_statements, rebuilt_arguments, arg_payloads, context) =
        list.fold(arguments, #([], [], [], context), fold_assert_call_argument)
      let call_result = transform_call(context, function, rebuilt_arguments)
      let temp = "_assert_" <> int.to_string(call_result.context.next_assert_id)
      let payload =
        panic_payload(call_result.context, "assert", message, location, [
          #("kind", python.String("function_call")),
          #("arguments", python.List(arg_payloads)),
          #("start", python.Number(int.to_string(location.start))),
          #("end", python.Number(int.to_string(call_location.end))),
          #(
            "expression_start",
            python.Number(int.to_string(call_location.start)),
          ),
        ])
      internal.StatementReturn(
        context: internal.TransformerContext(
          ..call_result.context,
          next_assert_id: call_result.context.next_assert_id + 1,
        ),
        statements: list.append(
          list.append(message_statements, arg_statements),
          list.append(call_result.statements, [
            python.SimpleAssignment(temp, call_result.expression),
            python.If(condition: python.Not(python.Variable(temp)), body: [
              python.Expression(python.Panic(payload)),
            ]),
          ]),
        ),
      )
    }
    _ -> panic as "Expected a call in transform_assert_function_call"
  }
}

fn let_assert_payload(
  context: internal.TransformerContext,
  location: glance.Span,
  pattern: glance.Pattern,
  value: glance.Expression,
  message: python.Expression,
) -> python.Expression {
  panic_payload(context, "let_assert", message, location, [
    #("value", python.Variable("_case_subject")),
    #("start", python.Number(int.to_string(location.start))),
    #("end", python.Number(int.to_string(value.location.end))),
    #("pattern_start", python.Number(int.to_string(pattern.location.start))),
    #("pattern_end", python.Number(int.to_string(pattern.location.end))),
  ])
}

// Folds a `glance.Field` call argument for an assert: literal arguments are
// kept in place and reported statically; non-literal arguments are bound to a
// temporary before the call so their runtime values can be reported. The
// rebuilt argument list is passed to `transform_call`.
fn fold_assert_call_argument(
  state: #(
    List(python.Statement),
    List(glance.Field(glance.Expression)),
    List(python.Expression),
    internal.TransformerContext,
  ),
  argument: glance.Field(glance.Expression),
) -> #(
  List(python.Statement),
  List(glance.Field(glance.Expression)),
  List(python.Expression),
  internal.TransformerContext,
) {
  let #(statements, rebuilt, payloads, state_context) = state
  case argument {
    glance.UnlabelledField(expression) -> {
      let #(statements, rebuilt, payload, context) =
        fold_assert_call_argument_item(
          statements,
          rebuilt,
          payloads,
          state_context,
          expression,
          glance.UnlabelledField,
        )
      #(statements, rebuilt, payload, context)
    }
    glance.LabelledField(label, location, expression) -> {
      let #(statements, rebuilt, payloads, context) =
        fold_assert_call_argument_item(
          statements,
          rebuilt,
          payloads,
          state_context,
          expression,
          fn(item) { glance.LabelledField(label, location, item) },
        )
      #(statements, rebuilt, payloads, context)
    }
    glance.ShorthandField(label, location) -> {
      let expression = glance.Variable(location, label)
      let #(statements, rebuilt, payloads, context) =
        fold_assert_call_argument_item(
          statements,
          rebuilt,
          payloads,
          state_context,
          expression,
          fn(item) { glance.LabelledField(label, location, item) },
        )
      #(statements, rebuilt, payloads, context)
    }
  }
}

fn fold_assert_call_argument_item(
  statements: List(python.Statement),
  rebuilt: List(glance.Field(glance.Expression)),
  payloads: List(python.Expression),
  state_context: internal.TransformerContext,
  expression: glance.Expression,
  field: fn(glance.Expression) -> glance.Field(glance.Expression),
) -> #(
  List(python.Statement),
  List(glance.Field(glance.Expression)),
  List(python.Expression),
  internal.TransformerContext,
) {
  case compile_time_literal(expression) {
    option.Some(literal) -> #(
      statements,
      list.append(rebuilt, [field(expression)]),
      list.append(payloads, [
        python.Dict([
          #("start", python.Number(int.to_string(expression.location.start))),
          #("end", python.Number(int.to_string(expression.location.end))),
          #("kind", python.String("literal")),
          #("value", literal),
        ]),
      ]),
      state_context,
    )
    option.None -> {
      let result = transform_expression(state_context, expression)
      let temp = "_assert_" <> int.to_string(result.context.next_assert_id)
      #(
        list.append(
          statements,
          list.append(result.statements, [
            python.SimpleAssignment(temp, result.expression),
          ]),
        ),
        list.append(rebuilt, [
          field(glance.Variable(expression.location, temp)),
        ]),
        list.append(payloads, [
          python.Dict([
            #("start", python.Number(int.to_string(expression.location.start))),
            #("end", python.Number(int.to_string(expression.location.end))),
            #("kind", python.String("expression")),
            #("value", python.Variable(temp)),
          ]),
        ]),
        internal.TransformerContext(
          ..result.context,
          next_assert_id: result.context.next_assert_id + 1,
        ),
      )
    }
  }
}

fn transform_expression(
  context: internal.TransformerContext,
  expression: glance.Expression,
) -> internal.ExpressionReturn {
  case expression {
    glance.Int(_, string) | glance.Float(_, string) ->
      internal.empty_return(context, python.Number(string))

    glance.String(_, string) ->
      internal.empty_return(context, python.String(string))

    glance.Variable(_, "True") ->
      internal.empty_return(context, python.Bool("True"))

    glance.Variable(_, "False") ->
      internal.empty_return(context, python.Bool("False"))

    glance.Variable(_, "Nil") -> internal.empty_return(context, python.Nil)

    glance.Variable(_, string) ->
      case is_capitalized(string) {
        True ->
          // A capitalized bare name is either a nullary variant value (e.g.
          // `File`, emitted as an instance `File()`) or a non-nullary
          // constructor used as a function value (e.g. `Some` passed to
          // `list.map`, emitted bare). The constructor arities map
          // disambiguates.
          case constructor_arity(context, string) {
            option.Some(True) ->
              internal.empty_return(
                context,
                python.Call(python.Variable(string), []),
              )
            _ -> internal.empty_return(context, python.Variable(string))
          }
        False -> internal.empty_return(context, python.Variable(string))
      }

    glance.Tuple(_, expressions) -> transform_tuple(context, expressions)

    glance.List(_, head, rest) -> transform_list(context, head, rest)

    glance.NegateInt(_, expression) ->
      transform_expression(context, expression)
      |> internal.map_return(python.Negate)

    glance.NegateBool(_, expression) -> {
      transform_expression(context, expression)
      |> internal.map_return(python.Not)
    }

    glance.Panic(location, option.None) ->
      internal.empty_return(
        context,
        python.Panic(
          panic_payload(
            context,
            "panic",
            python.String("`panic` expression evaluated."),
            location,
            [],
          ),
        ),
      )
    glance.Panic(location, option.Some(expression)) ->
      transform_expression(context, expression)
      |> internal.map_return(fn(message) {
        python.Panic(panic_payload(context, "panic", message, location, []))
      })

    glance.Todo(location, option.None) ->
      internal.empty_return(
        context,
        python.Todo(
          panic_payload(
            context,
            "todo",
            python.String(
              "`todo` expression evaluated. This code has not yet been"
              <> " implemented.",
            ),
            location,
            [],
          ),
        ),
      )
    glance.Todo(location, option.Some(expression)) ->
      transform_expression(context, expression)
      |> internal.map_return(fn(message) {
        python.Todo(panic_payload(context, "todo", message, location, []))
      })

    glance.Call(_, function, arguments) ->
      transform_call(context, function, arguments)

    glance.FnCapture(_, label, function, arguments_before, arguments_after) ->
      transform_fn_capture(
        context,
        label,
        function,
        arguments_before,
        arguments_after,
      )

    glance.Fn(_, arguments, _, body) -> transform_fn(context, arguments, body)

    glance.Block(_, statements) -> transform_block(context, statements)

    glance.Case(_, subjects, clauses) ->
      transform_case(context, subjects, clauses)

    glance.TupleIndex(_, tuple, index) -> {
      transform_expression(context, tuple)
      |> internal.map_return(python.TupleIndex(_, index))
    }

    glance.FieldAccess(_, container: expression, label:) ->
      case expression {
        // A module-qualified variant reference, e.g. `order.Ascending`
        // (a nullary value, emitted as an instance `order.Ascending()`)
        // or `error.LoadError` (a non-nullary constructor used as a
        // function value, emitted bare). The constructor arities map
        // disambiguates.
        glance.Variable(_, alias) ->
          case list.contains(context.module_aliases, alias) {
            True ->
              case is_capitalized(label) {
                // A module-qualified variant reference, e.g.
                // `order.Ascending` (a nullary value, emitted as an
                // instance `order.Ascending()`) or `error.LoadError` (a
                // non-nullary constructor used as a function value,
                // emitted bare). The constructor arities map
                // disambiguates.
                True ->
                  case constructor_arity(context, alias <> "." <> label) {
                    option.Some(True) ->
                      internal.empty_return(
                        context,
                        python.Call(
                          python.FieldAccess(
                            python.ModuleRef(internal.module_binding(
                              context,
                              alias,
                            )),
                            label,
                          ),
                          [],
                        ),
                      )
                    _ ->
                      internal.empty_return(
                        context,
                        python.FieldAccess(
                          python.ModuleRef(internal.module_binding(
                            context,
                            alias,
                          )),
                          label,
                        ),
                      )
                  }
                // A module-qualified function used as a value, e.g.
                // `patterns.collect_binds` passed to `list.map`. The
                // module reference must not be treated as a variable,
                // otherwise it collides with any parameter of the same
                // name. Only emit a module reference when the module
                // actually has this member (checked against the function
                // signatures); otherwise this is a record field access on
                // a local value, which must be renamed with it.
                False ->
                  case is_module_function(context, alias, label) {
                    True ->
                      // Real Gleam resolves `name.label` by typing
                      // `name` as a value and attempting field access
                      // first; only when the value has no such field
                      // does it fall back to module access. So when the
                      // alias is shadowed by a parameter, we check the
                      // parameter's declared type: if it actually has a
                      // field with this label, this is a field access on
                      // the parameter (and must be renamed with it); if
                      // the type is known and has no such field it is the
                      // module-qualified function and stays a module
                      // reference. Without a declared type the package's
                      // field names are a fallback.
                      case type_has_field(context, alias, label) {
                        option.Some(True) ->
                          transform_expression(context, expression)
                          |> internal.map_return(python.FieldAccess(_, label))
                        option.Some(False) ->
                          internal.empty_return(
                            context,
                            python.FieldAccess(
                              python.ModuleRef(internal.module_binding(
                                context,
                                alias,
                              )),
                              label,
                            ),
                          )
                        option.None -> {
                          let shadowed =
                            list.contains(
                              context.module_reserved,
                              alias <> "_0",
                            )
                            || list.contains(context.local_bindings, alias)
                          case is_record_field(context, label) && shadowed {
                            True ->
                              transform_expression(context, expression)
                              |> internal.map_return(python.FieldAccess(
                                _,
                                label,
                              ))
                            False ->
                              internal.empty_return(
                                context,
                                python.FieldAccess(
                                  python.ModuleRef(internal.module_binding(
                                    context,
                                    alias,
                                  )),
                                  label,
                                ),
                              )
                          }
                        }
                      }
                    False ->
                      transform_expression(context, expression)
                      |> internal.map_return(python.FieldAccess(_, label))
                  }
              }
            False ->
              transform_expression(context, expression)
              |> internal.map_return(python.FieldAccess(_, label))
          }
        _ ->
          transform_expression(context, expression)
          |> internal.map_return(python.FieldAccess(_, label))
      }

    glance.BinaryOperator(_, glance.Pipe, left, right) ->
      transform_pipe(context, left, right)

    glance.BinaryOperator(_, name, left, right) -> {
      transform_binop(context, name, left, right)
    }

    glance.RecordUpdate(_, record:, fields:, ..) ->
      transform_record_update(context, record, fields)

    glance.BitString(_, segments) -> {
      segments
      |> list.fold(
        internal.TransformState(context, [], []),
        fold_bitstring_segment,
      )
      |> internal.reverse_state_to_return(python.BitString)
    }

    glance.Echo(_, expression, _) ->
      expression
      |> option.map(fn(expression) { transform_expression(context, expression) })
      |> option.unwrap(internal.empty_return(context, python.String("")))
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
      internal.reverse_state_to_return(reversed_list_result, python.List)
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
  let function_result = case function {
    // A module-qualified call, e.g. `project.build_src_dir(project)`. The
    // module binding is marked with `python.Module` so it is never confused
    // with a variable or parameter of the same name (which may shadow the
    // module binding inside a function).
    glance.FieldAccess(_, glance.Variable(_, alias), name) -> {
      // A local sharing its name with a module alias usually means the call
      // is module-qualified (`resolve_module_shadowing` renames colliding
      // parameters for exactly that reason). But when the local's DECLARED
      // TYPE has a field with this label, real Gleam types the container as
      // a value first: the call is a record-field call on the shadowing
      // local, and emitting a module reference would break at runtime.
      // Known gap: a case-pattern bind has no written annotation, so its
      // type is unknown here; a bind shadowing a module AND calling one of
      // that module's functions as a record field must be renamed in source
      // until pattern-bind types flow through the transformer.
      let shadows_with_field =
        list.contains(context.local_bindings, alias)
        && type_has_field(context, alias, name) == option.Some(True)
      case list.contains(context.module_aliases, alias) && !shadows_with_field {
        True ->
          internal.empty_return(
            context,
            python.FieldAccess(
              python.ModuleRef(internal.module_binding(context, alias)),
              name,
            ),
          )
        False -> transform_expression(context, function)
      }
    }
    // A plain variable or constructor used as a call target, e.g. `Some(x)`
    // or `count_down(n)`. This is a reference to the callee, not a nullary
    // variant *value*, so it must stay a bare variable even when capitalized.
    glance.Variable(_, name) ->
      internal.empty_return(context, python.Variable(name))
    _ -> transform_expression(context, function)
  }
  let reversed_arguments_result =
    arguments
    |> relabel_use_callback(context, function)
    |> list.fold(
      internal.TransformState(function_result.context, [], []),
      fold_call_argument,
    )
  let arguments = list.reverse(reversed_arguments_result.item)
  let arguments = case is_external_callee(context, function) {
    True ->
      // Externals' hand-written python bindings use the parameter names, not
      // the gleam labels, so labelled arguments are emitted as keyword
      // arguments keyed by the binding's parameter name (order independent,
      // which handles piped calls whose argument order differs from the
      // parameter order). When the callee's signature is unknown the labels
      // are simply stripped, emitting the arguments positionally.
      case external_parameter_names(context, function) {
        option.Some(param_names) ->
          // Calls without labelled arguments are already in parameter order
          // (positional arguments in source order always fill the parameters
          // in order), so only calls with labelled arguments need the keyword
          // reassignment. This also keeps non-external functions whose name
          // collides with an external (e.g. `string.append`) positional.
          case list.any(arguments, is_labelled_field) {
            True ->
              case external_keyword_arguments(arguments, param_names) {
                Ok(keyworded) -> keyworded
                Error(_) -> strip_external_labels(arguments)
              }
            False -> strip_external_labels(arguments)
          }
        option.None -> strip_external_labels(arguments)
      }
    False -> arguments
  }
  // A constructor call mixing positional and labelled arguments (e.g.
  // `LabelledField(name, t, label_location: span)`) must be reordered to the
  // dataclass field order, with every argument labelled, so that the
  // positionals land in the right fields.
  let arguments = case constructor_field_names_of(context, function) {
    option.Some(field_names) ->
      case list.any(arguments, is_labelled_field) {
        True ->
          case reorder_constructor_arguments(arguments, field_names) {
            Ok(reordered) -> reordered
            Error(_) -> arguments
          }
        False -> arguments
      }
    option.None -> arguments
  }
  // A regular (non-external, non-constructor) function call mixing positional
  // and labelled arguments must be reordered the same way: labelled arguments
  // bind their parameter by name, and positional arguments fill the first
  // unfilled parameter slot (Gleam's fill order). E.g. the pipe
  // `"Hello" |> write(to: filepath)` for `fn write(to filepath:, contents
  // contents:)` must emit `write(to=filepath, contents="Hello")`, not
  // `write("Hello", to=filepath)` (which would raise a TypeError).
  // The reordered arguments are emitted positionally (in parameter order)
  // rather than as keyword arguments: the generated Python parameters may have
  // been shadow-renamed (e.g. `filepath` -> `filepath_0`) or keyword-escaped,
  // so relabelling positionals with their Gleam label would not match the
  // emitted `def` signature. Positional emission always binds by slot, exactly
  // like the official Gleam compiler.
  let arguments = case is_external_callee(context, function) {
    True -> arguments
    False ->
      case constructor_field_names_of(context, function) {
        option.Some(_) -> arguments
        option.None ->
          // A locally-bound callee (a `let`, parameter, case pattern or fn
          // literal parameter shadowing a module-level function) is a call to
          // that local value, never to the module function, so its labelled
          // arguments must not be reordered using the module function's
          // signature.
          case is_locally_bound(context, function) {
            True -> arguments
            False ->
              case function_parameter_names(context, function) {
                option.None -> arguments
                option.Some(param_names) ->
                  case list.any(arguments, is_labelled_field) {
                    False -> arguments
                    True ->
                      case
                        reorder_constructor_arguments(arguments, param_names)
                      {
                        Ok(reordered) -> strip_external_labels(reordered)
                        Error(_) -> arguments
                      }
                  }
              }
          }
      }
  }
  internal.ExpressionReturn(
    reversed_arguments_result.context,
    list.append(
      function_result.statements,
      reversed_arguments_result.statements,
    ),
    python.Call(function: function_result.expression, arguments: arguments),
  )
}

fn constructor_field_names_of(
  context: internal.TransformerContext,
  function: glance.Expression,
) -> option.Option(List(String)) {
  case function {
    glance.Variable(_, name) -> constructor_field_names(context, name)
    glance.FieldAccess(_, glance.Variable(_, alias), name) ->
      case list.contains(context.module_aliases, alias) {
        True -> constructor_field_names(context, alias <> "." <> name)
        False -> option.None
      }
    _ -> option.None
  }
}

fn is_external_callee(
  context: internal.TransformerContext,
  function: glance.Expression,
) -> Bool {
  case context.external_functions {
    option.None -> False
    option.Some(external_functions) ->
      case function {
        glance.Variable(_, name) -> list.contains(external_functions, name)
        glance.FieldAccess(_, glance.Variable(_, alias), name) ->
          list.contains(context.module_aliases, alias)
          && is_external_qualified(context, alias, name)
        _ -> False
      }
  }
}

fn is_external_qualified(
  context: internal.TransformerContext,
  alias: String,
  name: String,
) -> Bool {
  case context.external_qualified {
    option.None -> False
    option.Some(qualified) -> list.contains(qualified, alias <> "." <> name)
  }
}

fn strip_external_labels(
  arguments: List(python.Field(python.Expression)),
) -> List(python.Field(python.Expression)) {
  list.map(arguments, fn(field) {
    case field {
      python.LabelledField(_, item) -> python.UnlabelledField(item)
      python.UnlabelledField(_) -> field
    }
  })
}

fn external_parameter_names(
  context: internal.TransformerContext,
  function: glance.Expression,
) -> option.Option(List(#(option.Option(String), String))) {
  case context.function_signatures {
    option.None -> option.None
    option.Some(signatures) -> {
      let callee_key = case function {
        glance.Variable(_, name) -> name
        glance.FieldAccess(_, glance.Variable(_, alias), name) ->
          alias <> "." <> name
        _ -> ""
      }
      case dict.get(signatures, callee_key) {
        Ok(params) -> option.Some(params)
        Error(_) -> option.None
      }
    }
  }
}

// The Python parameter names for a regular (non-external) function call, in
// declaration order. The generated `def` uses each parameter's label as its
// name (falling back to the name for unlabelled parameters), so keyword
// arguments in a call must be keyed by those same names.
fn function_parameter_names(
  context: internal.TransformerContext,
  function: glance.Expression,
) -> option.Option(List(String)) {
  case external_parameter_names(context, function) {
    option.None -> option.None
    option.Some(params) ->
      option.Some(
        list.map(params, fn(pair) {
          let #(label, name) = pair
          case label {
            option.Some(label) -> label
            option.None -> name
          }
        }),
      )
  }
}

// Whether a bare callee name refers to a value bound in the current scope
// (a parameter, `let` binding, case pattern or fn literal parameter) rather
// than a module-level function. A locally-bound name shadows any module-level
// function of the same name, so argument reordering for labelled calls must
// not use the module function's signature.
fn is_locally_bound(
  context: internal.TransformerContext,
  function: glance.Expression,
) -> Bool {
  case function {
    glance.Variable(_, name) -> list.contains(context.local_bindings, name)
    glance.FieldAccess(_, glance.Variable(_, alias), _) ->
      list.contains(context.local_bindings, alias)
      && !list.contains(context.module_aliases, alias)
    _ -> False
  }
}

// Emits every argument of an external call as a keyword argument keyed by
// the binding's parameter name. Labelled arguments match their parameter by
// label; unlabelled arguments fill the remaining parameters in order. This
// makes piped calls like `contents |> bit_array.from_string |>
// write_bits(to: filepath)` (where the positional value is the *second*
// parameter) come out correctly ordered.
fn external_keyword_arguments(
  arguments: List(python.Field(python.Expression)),
  params: List(#(option.Option(String), String)),
) -> Result(List(python.Field(python.Expression)), Nil) {
  let names = list.map(params, fn(pair) { pair.1 })
  let labels = list.map(params, fn(pair) { pair.0 })
  let total = list.length(params)
  // Labelled arguments claim their parameter first, then the unlabelled
  // arguments fill the remaining parameters in order. The argument order in
  // the call is irrelevant since every argument is emitted as a keyword.
  use #(used, labelled_keywords) <- result.try(
    list.try_fold(
      arguments,
      #(list.repeat(False, total), []),
      fn(state, argument) {
        let #(used, out) = state
        case argument {
          python.LabelledField(label, item) ->
            case find_label_index(labels, label) {
              option.Some(index) ->
                Ok(#(
                  mark_used(used, index),
                  list.prepend(
                    out,
                    python.LabelledField(name_at(names, index), item),
                  ),
                ))
              option.None -> Error(Nil)
            }
          python.UnlabelledField(_) -> Ok(state)
        }
      },
    ),
  )
  use #(_, positional_keywords) <- result.try(
    list.try_fold(arguments, #(used, []), fn(state, argument) {
      let #(used, out) = state
      case argument {
        python.UnlabelledField(item) ->
          case find_unused_index(used) {
            option.Some(index) ->
              Ok(#(
                mark_used(used, index),
                list.prepend(
                  out,
                  python.LabelledField(name_at(names, index), item),
                ),
              ))
            option.None -> Error(Nil)
          }
        python.LabelledField(_, _) -> Ok(state)
      }
    }),
  )
  Ok(list.append(
    list.reverse(positional_keywords),
    list.reverse(labelled_keywords),
  ))
}

fn mark_used(used: List(Bool), index: Int) -> List(Bool) {
  list.index_map(used, fn(is_used, i) {
    case i == index {
      True -> True
      False -> is_used
    }
  })
}

fn name_at(names: List(String), index: Int) -> String {
  list.index_fold(names, "", fn(found, name, i) {
    case i == index {
      True -> name
      False -> found
    }
  })
}

fn find_label_index(
  labels: List(option.Option(String)),
  label: String,
) -> option.Option(Int) {
  list.index_fold(labels, option.None, fn(found, item, index) {
    case found {
      option.Some(_) -> found
      option.None ->
        case item {
          option.Some(candidate) if candidate == label -> option.Some(index)
          _ -> option.None
        }
    }
  })
}

fn find_unused_index(used: List(Bool)) -> option.Option(Int) {
  list.index_fold(used, option.None, fn(found, is_used, index) {
    case found {
      option.Some(_) -> found
      option.None ->
        case is_used {
          True -> option.None
          False -> option.Some(index)
        }
    }
  })
}

fn constructor_field_names(
  context: internal.TransformerContext,
  name: String,
) -> option.Option(List(String)) {
  case context.constructor_arities {
    option.None -> option.None
    option.Some(arities) ->
      case dict.get(arities, name) {
        Ok(field_names) -> option.Some(field_names)
        Error(_) -> option.None
      }
  }
}

fn is_labelled_field(field: python.Field(python.Expression)) -> Bool {
  case field {
    python.LabelledField(_, _) -> True
    python.UnlabelledField(_) -> False
  }
}

fn is_labelled_glance_field(field: glance.Field(glance.Expression)) -> Bool {
  case field {
    glance.LabelledField(..) -> True
    glance.ShorthandField(..) -> True
    glance.UnlabelledField(_) -> False
  }
}

// Reorders constructor arguments to the dataclass field order: labelled
// arguments are matched by name, and positional arguments fill the remaining
// fields in order. Every argument is relabelled, so the emitted call is
// entirely keyword-based and the positionals land on the correct fields.
fn reorder_constructor_arguments(
  arguments: List(python.Field(python.Expression)),
  field_names: List(String),
) -> Result(List(python.Field(python.Expression)), Nil) {
  let #(_, reordered) =
    list.fold(field_names, #(arguments, []), fn(state, field_name) {
      let #(remaining, acc) = state
      case
        list.find(remaining, fn(field) {
          case field {
            python.LabelledField(label, _) -> label == field_name
            python.UnlabelledField(_) -> False
          }
        })
      {
        Ok(found) -> #(
          list.filter(remaining, fn(field) {
            case field {
              python.LabelledField(label, _) -> label != field_name
              python.UnlabelledField(_) -> True
            }
          }),
          list.append(acc, [found]),
        )
        Error(_) ->
          case remaining {
            [python.UnlabelledField(item), ..rest] -> #(
              rest,
              list.append(acc, [
                python.LabelledField(field_name, item),
              ]),
            )
            _ -> state
          }
      }
    })
  case list.length(reordered) == list.length(arguments) {
    True -> Ok(reordered)
    False -> Error(Nil)
  }
}

// A `use` statement desugars to a call with the callback as the final
// argument. If the call also has labelled arguments the callback would be
// emitted as a positional argument after keyword arguments, which is invalid
// Python. Python requires keyword arguments to come after positional ones, so
// the callback is relabelled with the callee's final parameter name.
fn relabel_use_callback(
  arguments: List(glance.Field(glance.Expression)),
  context: internal.TransformerContext,
  function: glance.Expression,
) -> List(glance.Field(glance.Expression)) {
  case context.function_signatures {
    option.None -> arguments
    option.Some(signatures) -> {
      let callee_key = case function {
        glance.FieldAccess(_, glance.Variable(_, module_alias), name) ->
          module_alias <> "." <> name
        glance.Variable(_, name) -> name
        _ -> ""
      }
      let last_param_label =
        dict.get(signatures, callee_key)
        |> result.map(fn(params) {
          case list.last(params) {
            Ok(pair) -> pair.0
            Error(_) -> option.None
          }
        })
        |> result.unwrap(option.None)
      case last_param_label {
        option.None -> arguments
        option.Some(label) -> relabel_trailing_unlabelled(label, arguments)
      }
    }
  }
}

fn relabel_trailing_unlabelled(
  label: String,
  arguments: List(glance.Field(glance.Expression)),
) -> List(glance.Field(glance.Expression)) {
  let #(_, out) =
    list.fold(arguments, #(False, []), fn(state, argument) {
      let #(seen_labelled, out) = state
      case argument {
        glance.UnlabelledField(expression) ->
          case seen_labelled {
            True -> #(
              True,
              list.prepend(
                out,
                glance.LabelledField(label, glance.Span(0, 0), expression),
              ),
            )
            False -> #(False, list.prepend(out, argument))
          }
        glance.LabelledField(..) -> #(True, list.prepend(out, argument))
        glance.ShorthandField(..) -> #(True, list.prepend(out, argument))
      }
    })
  out |> list.reverse
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
    glance.LabelledField(label, _, expression) -> {
      internal.merge_state_prepend(
        state,
        transform_expression(state.context, expression),
        python.LabelledField(label, _),
      )
    }
    glance.UnlabelledField(expression) -> {
      internal.merge_state_prepend(
        state,
        transform_expression(state.context, expression),
        python.UnlabelledField,
      )
    }
    glance.ShorthandField(label, _) -> {
      internal.merge_state_prepend(
        state,
        internal.empty_return(state.context, python.Variable(label)),
        python.LabelledField(label, _),
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
  let placeholder_for_capture =
    label
    |> option.map(fn(label) {
      [
        glance.LabelledField(
          label,
          glance.Span(0, 0),
          glance.Variable(glance.Span(0, 0), "fn_capture"),
        ),
      ]
    })
    |> option.unwrap([
      glance.UnlabelledField(glance.Variable(glance.Span(0, 0), "fn_capture")),
    ])
  let reversed_arguments_result =
    list.flatten([
      arguments_before,
      placeholder_for_capture,
      arguments_after,
    ])
    |> list.fold(
      internal.TransformState(function_result.context, [], []),
      fold_call_argument,
    )
  let arguments = reversed_arguments_result.item |> list.reverse
  // The partial-application closure calls the same callee as a direct call,
  // so labelled arguments must be reordered the same way transform_call does
  // for a regular function: positional emission binds by parameter slot,
  // which matches the name-based `def` emitted for labelled parameters.
  let arguments = case is_locally_bound(context, function) {
    True -> arguments
    False ->
      case function_parameter_names(context, function) {
        option.None -> arguments
        option.Some(param_names) ->
          case list.any(arguments, is_labelled_field) {
            False -> arguments
            True ->
              case reorder_constructor_arguments(arguments, param_names) {
                Ok(reordered) -> strip_external_labels(reordered)
                Error(_) -> arguments
              }
          }
      }
  }

  internal.ExpressionReturn(
    reversed_arguments_result.context,
    list.append(
      function_result.statements,
      reversed_arguments_result.statements,
    ),
    python.Lambda(
      [python.Variable("fn_capture")],
      python.Call(function_result.expression, arguments),
    ),
  )
}

fn transform_fn(
  context: internal.TransformerContext,
  arguments: List(glance.FnParameter),
  body: List(glance.Statement),
) -> internal.ExpressionReturn {
  let parameters_result =
    list.fold(
      arguments,
      internal.TransformState(context, [], []),
      fold_fn_parameter,
    )

  let function_name = "_fn_def_" <> int.to_string(context.next_function_id)
  let parameters = list.reverse(parameters_result.item)
  let parameter_names =
    list.filter_map(parameters, fn(parameter) {
      case parameter {
        python.NameParam(name) -> Ok(name)
        python.DiscardParam(_) -> Error(Nil)
      }
    })
  let transformed_body =
    transform_statement_block_with_context(
      internal.TransformerContext(
        ..internal.empty_context(),
        function_signatures: context.function_signatures,
        module_aliases: context.module_aliases,
        module_reserved: context.module_reserved,
        constructor_arities: context.constructor_arities,
        module_bindings: context.module_bindings,
        external_functions: context.external_functions,
        external_qualified: context.external_qualified,
        local_bindings: list.append(context.local_bindings, parameter_names),
        fresh_pool: context.fresh_pool,
        module_name: context.module_name,
        function_name: context.function_name,
        file_path: context.file_path,
        module_source: context.module_source,
      ),
      body,
    )
  let #(body_statements, fresh_pool) =
    transformed_body.statements
    |> shadowing.resolve_block_shadowing(
      shadowing.function_parameter_names(parameters),
      context.module_reserved,
      set.from_list(case context.function_signatures {
        option.Some(sigs) -> dict.keys(sigs)
        option.None -> []
      }),
      context.fresh_pool,
    )
  let #(parameters, body_statements, fresh_pool) =
    shadowing.resolve_module_shadowing(
      body_statements,
      parameters,
      context.module_aliases,
      fresh_pool,
    )
  let function =
    python.Function(
      function_name,
      parameters,
      body_statements,
      False,
      option.None,
      [],
    )

  internal.ExpressionReturn(
    context: internal.TransformerContext(
      ..parameters_result.context,
      next_function_id: context.next_function_id + 1,
      fresh_pool: fresh_pool,
    ),
    statements: list.append(parameters_result.statements, [
      python.FunctionDef(function),
    ]),
    expression: python.Variable(function_name),
  )
}

fn fold_fn_parameter(
  state: internal.TransformState(List(python.FunctionParameter)),
  argument: glance.FnParameter,
) -> internal.TransformState(List(python.FunctionParameter)) {
  // TODO: Shouldn't be ignoring type here
  case argument.name {
    glance.Discarded("") ->
      internal.TransformState(
        context: internal.TransformerContext(
          ..state.context,
          next_discard_id: state.context.next_discard_id + 1,
        ),
        statements: state.statements,
        item: list.prepend(
          state.item,
          python.DiscardParam(state.context.next_discard_id),
        ),
      )
    glance.Discarded(name) ->
      internal.map_state_prepend(state, python.NameParam("_" <> name))
    glance.Named(name) ->
      internal.map_state_prepend(state, python.NameParam(name))
  }
}

fn transform_block(
  context: internal.TransformerContext,
  body: List(glance.Statement),
) -> internal.ExpressionReturn {
  let function_name = "_fn_block_" <> int.to_string(context.next_block_id)
  let transformed_body =
    transform_statement_block_with_context(
      internal.TransformerContext(
        ..internal.empty_context(),
        function_signatures: context.function_signatures,
        module_aliases: context.module_aliases,
        module_reserved: context.module_reserved,
        constructor_arities: context.constructor_arities,
        module_bindings: context.module_bindings,
        external_functions: context.external_functions,
        external_qualified: context.external_qualified,
        local_bindings: context.local_bindings,
        fresh_pool: context.fresh_pool,
        module_name: context.module_name,
        function_name: context.function_name,
        file_path: context.file_path,
        module_source: context.module_source,
      ),
      body,
    )
  let #(body_statements, fresh_pool) =
    transformed_body.statements
    |> shadowing.resolve_block_shadowing(
      [],
      context.module_reserved,
      set.from_list(case context.function_signatures {
        option.Some(sigs) -> dict.keys(sigs)
        option.None -> []
      }),
      context.fresh_pool,
    )
  let function =
    python.Function(function_name, [], body_statements, False, option.None, [])
  internal.ExpressionReturn(
    context: internal.TransformerContext(
      ..context,
      next_block_id: context.next_block_id + 1,
      fresh_pool: fresh_pool,
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
    [] -> panic as "No subjects!"
    [subject] -> transform_expression(context, subject)
    multiple -> transform_tuple(context, multiple)
  }
  let is_multi_subject = case subjects {
    [_, _, ..] -> True
    _ -> False
  }
  let clause_result =
    list.fold(
      clauses,
      internal.TransformState(subjects_result.context, [], []),
      fn(state, clause) { fold_case_clause(state, clause, is_multi_subject) },
    )

  let function_name = "_fn_case_" <> int.to_string(context.next_case_id)
  let cases = clause_result.item |> list.reverse
  // Statements hoisted out of clause guards (e.g. a block expression in a
  // guard becomes a `_fn_block_N` call, with the block's function definition
  // hoisted here) are locals of the generated match function: they may
  // reference the pattern captures, which Python scopes to the function
  // containing the match. They are emitted before the match so the guard can
  // call them.
  let function =
    python.Function(
      function_name,
      [python.NameParam("_case_subject")],
      list.append(clause_result.statements, [
        python.Match(subject: python.Variable("_case_subject"), cases: cases),
      ]),
      False,
      option.None,
      [],
    )

  internal.ExpressionReturn(
    context: internal.TransformerContext(
      ..subjects_result.context,
      next_case_id: context.next_case_id + 1,
      fresh_pool: clause_result.context.fresh_pool,
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
  is_multi_subject: Bool,
) -> internal.TransformState(internal.ReversedList(python.MatchCase)) {
  case clause {
    glance.Clause(pattern_list, guard, glance.Block(_, statements)) -> {
      let pattern_results =
        patterns.transform_alternative_patterns(
          pattern_list,
          is_multi_subject,
          state.context.module_bindings,
        )
      let clause_binds =
        pattern_list
        |> list.flat_map(fn(alternative) {
          list.flat_map(alternative, patterns.collect_binds)
        })
        |> list.unique
      let guard_return = transform_optional_expression(state.context, guard)
      let body_context =
        internal.TransformerContext(
          ..guard_return.context,
          local_bindings: list.append(
            state.context.local_bindings,
            clause_binds,
          ),
        )
      let statements_result =
        transform_statement_block_with_context(body_context, statements)
      let match_cases =
        list.map(pattern_results, fn(pattern_result) {
          let rewritten_clause_guard =
            guard_return.expression
            |> option.map(fn(guard) {
              patterns.rewrite_guard_binds(guard, pattern_result.guard_binds)
            })
          let combined_guard =
            combine_guards(pattern_result.guard, rewritten_clause_guard)
          python.MatchCase(
            pattern_result.pattern,
            combined_guard,
            list.append(
              pattern_result.body_prepend,
              statements_result.statements,
            ),
          )
        })
      internal.TransformState(
        internal.TransformerContext(
          ..statements_result.context,
          local_bindings: state.context.local_bindings,
        ),
        list.append(state.statements, guard_return.statements),
        list.fold(match_cases, state.item, fn(item, match_case) {
          list.prepend(item, match_case)
        }),
      )
    }

    glance.Clause(pattern_list, guard, body) -> {
      let pattern_results =
        patterns.transform_alternative_patterns(
          pattern_list,
          is_multi_subject,
          state.context.module_bindings,
        )
      let guard_return = transform_optional_expression(state.context, guard)
      let body_context =
        internal.TransformerContext(
          ..guard_return.context,
          local_bindings: list.append(
            state.context.local_bindings,
            pattern_list
              |> list.flat_map(fn(alternative) {
                list.flat_map(alternative, patterns.collect_binds)
              })
              |> list.unique,
          ),
        )
      let body_result = transform_expression(body_context, body)

      let match_cases =
        list.map(pattern_results, fn(pattern_result) {
          let combined_guard =
            combine_guards(
              pattern_result.guard,
              guard_return.expression
                |> option.map(fn(guard) {
                  patterns.rewrite_guard_binds(
                    guard,
                    pattern_result.guard_binds,
                  )
                }),
            )
          python.MatchCase(
            pattern_result.pattern,
            combined_guard,
            list.append(
              pattern_result.body_prepend,
              list.append(body_result.statements, [
                body_result.expression
                |> python.Expression
                |> internal.add_return_if_returnable_expression,
              ]),
            ),
          )
        })

      internal.TransformState(
        internal.TransformerContext(
          ..body_result.context,
          local_bindings: state.context.local_bindings,
        ),
        list.append(state.statements, guard_return.statements),
        list.fold(match_cases, state.item, fn(item, match_case) {
          list.prepend(item, match_case)
        }),
      )
    }
  }
}

// Combines a guard generated from a pattern (e.g. a concatenation pattern)
// with a guard written in the source. When both exist they are joined with
// `and`, the pattern guard first so its bindings are available.
fn combine_guards(
  pattern_guard: option.Option(python.Expression),
  clause_guard: option.Option(python.Expression),
) -> option.Option(python.Expression) {
  case pattern_guard, clause_guard {
    option.None, option.None -> option.None
    option.None, option.Some(guard) -> option.Some(guard)
    option.Some(guard), option.None -> option.Some(guard)
    option.Some(pattern_guard), option.Some(clause_guard) ->
      option.Some(python.BinaryOperator(python.And, pattern_guard, clause_guard))
  }
}

fn transform_optional_expression(
  context: internal.TransformerContext,
  expression: option.Option(glance.Expression),
) -> internal.OptionalExpressionReturn {
  expression
  |> option.map(fn(expression) {
    let expression_return = transform_expression(context, expression)
    internal.OptionalExpressionReturn(
      expression_return.context,
      expression_return.statements,
      option.Some(expression_return.expression),
    )
  })
  |> option.unwrap(internal.OptionalExpressionReturn(context, [], option.None))
}

fn transform_pipe(
  context: internal.TransformerContext,
  left: glance.Expression,
  right: glance.Expression,
) -> internal.ExpressionReturn {
  let left_result = transform_expression(context, left)
  let right_is_call = case right {
    glance.Call(_, _, _) -> True
    _ -> False
  }
  // Whether the piped value should be applied to the result of the call
  // rather than prepended as its first positional argument. Gleam's
  // (deprecated) pipe-into-result form: `a |> f(b)` where `f(b)` already has
  // every parameter filled becomes `f(b)(a)`. Decided by comparing the number
  // of supplied arguments against the callee's parameter count.
  let piped_into_complete_call = case right {
    glance.Call(_, function, arguments) ->
      case is_locally_bound(context, function) {
        True -> False
        False ->
          case function_parameter_names(context, function) {
            option.Some(params) -> list.length(arguments) >= list.length(params)
            option.None -> False
          }
      }
    _ -> False
  }
  let piped_into_call = case right {
    glance.Call(location, function, arguments) ->
      case is_external_callee(context, function) {
        True -> option.Some(#(location, function, arguments))
        False ->
          // Regular function calls mixing a piped positional with labelled
          // arguments must also be reordered (see `transform_call`), so the
          // piped value is prepended here before the argument keywords are
          // assigned, exactly like externals. Calls without labelled
          // arguments keep the positional merge path below. A locally-bound
          // callee (shadowing a module function) must not be treated this way
          // either: its arguments would be reordered against the module
          // function's signature, and the piped value should simply land
          // positionally on the local's first parameter.
          case is_locally_bound(context, function) {
            True -> option.None
            False ->
              case function_parameter_names(context, function) {
                option.Some(_) ->
                  case list.any(arguments, is_labelled_glance_field) {
                    True -> option.Some(#(location, function, arguments))
                    False -> option.None
                  }
                option.None -> option.None
              }
          }
      }
    _ -> option.None
  }
  let right_result = case piped_into_call {
    option.Some(#(location, function, arguments)) ->
      // The piped value is the first positional argument, so it is prepended
      // here, before the external argument keywords are assigned. Prepending
      // after the keywords were assigned would leave the piped value
      // positional, landing it on the wrong parameter.
      transform_expression(
        left_result.context,
        glance.Call(
          location,
          function,
          list.prepend(arguments, glance.UnlabelledField(left)),
        ),
      )
    option.None -> transform_expression(left_result.context, right)
  }
  internal.merge_return(left_result, right_result, fn(left_ex, right_ex) {
    case right_ex, piped_into_call, right_is_call, piped_into_complete_call {
      // A plain call (no labels to reorder) receives the piped value as its
      // first positional argument, unless the call is already complete, in
      // which case the piped value is applied to its result (see
      // `piped_into_complete_call`).
      python.Call(function, arguments), option.None, True, False ->
        python.Call(
          function,
          list.prepend(arguments, python.UnlabelledField(left_ex)),
        )
      // A call that already had the piped value prepended during its own
      // transformation (labels/externals) is emitted as-is.
      python.Call(_, _), option.Some(_), _, _ -> right_ex
      // Anything else (e.g. a `case` expression, which compiles to a call of
      // its generated match function on the subject) is an expression whose
      // RESULT receives the piped value: `input |> case x { .. }` desugars to
      // `(case x { .. })(input)`.
      _, _, _, _ -> python.Call(right_ex, [python.UnlabelledField(left_ex)])
    }
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
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> internal.ExpressionReturn {
  let record_result = transform_expression(context, record)
  fields
  |> list.fold(
    internal.TransformState(record_result.context, record_result.statements, []),
    fn(state, field) {
      let item_result =
        field.item
        |> option.map(fn(item) { transform_expression(state.context, item) })
        |> option.unwrap(internal.empty_return(
          state.context,
          python.Variable(field.label),
        ))
      internal.merge_state_prepend(state, item_result, python.LabelledField(
        field.label,
        _,
      ))
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
    glance.IntOption -> internal.map_state_prepend(state, python.IntOption)
    glance.FloatOption -> internal.map_state_prepend(state, python.FloatOption)
    glance.LittleOption ->
      internal.map_state_prepend(state, python.LittleOption)
    glance.BigOption -> internal.map_state_prepend(state, python.BigOption)
    glance.NativeOption ->
      internal.map_state_prepend(state, python.NativeOption)
    glance.BytesOption -> internal.map_state_prepend(state, python.BytesOption)
    glance.BitsOption -> internal.map_state_prepend(state, python.BitsOption)
    glance.Utf8Option -> internal.map_state_prepend(state, python.Utf8Option)
    glance.Utf16Option -> internal.map_state_prepend(state, python.Utf16Option)
    glance.Utf32Option -> internal.map_state_prepend(state, python.Utf32Option)

    glance.UnitOption(size) ->
      internal.map_state_prepend(state, python.UnitOption(size))
    glance.SizeOption(size) ->
      internal.map_state_prepend(
        state,
        python.SizeValueOption(python.Number(int.to_string(size))),
      )
    glance.SizeValueOption(expression) -> {
      let expression_result = transform_expression(state.context, expression)
      internal.merge_state_prepend(
        state,
        expression_result,
        python.SizeValueOption,
      )
    }

    glance.Utf8CodepointOption ->
      internal.map_state_prepend(state, python.Utf8CodepointOption)
    glance.Utf16CodepointOption ->
      internal.map_state_prepend(state, python.Utf16CodepointOption)
    glance.Utf32CodepointOption ->
      internal.map_state_prepend(state, python.Utf32CodepointOption)

    glance.SignedOption | glance.UnsignedOption ->
      panic as "Signed, unsigned, and binary are not valid when constructing bitstrings"
  }
}

fn is_capitalized(value: String) -> Bool {
  case string.first(value) {
    Ok(first) -> string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first)
    Error(_) -> False
  }
}

// Looks up whether `name` is a nullary constructor. Returns option.Some(True)
// for nullary variants (values are emitted as instances), option.Some(False)
// for constructors with fields (used as function values they are emitted
// bare), and option.None when the name is not a known constructor.
fn constructor_arity(
  context: internal.TransformerContext,
  name: String,
) -> option.Option(Bool) {
  case context.constructor_arities {
    option.None -> option.None
    option.Some(arities) ->
      case dict.get(arities, name) {
        Ok(field_names) -> option.Some(list.is_empty(field_names))
        Error(_) -> option.None
      }
  }
}

// Whether `alias.label` is a reference to a function of an imported module
// (as opposed to a record field access on a local value). The function
// signatures map keys cross-module functions as `alias.function`, matching
// the import binding name.
fn is_module_function(
  context: internal.TransformerContext,
  alias: String,
  label: String,
) -> Bool {
  case context.function_signatures {
    option.None -> False
    option.Some(signatures) ->
      case dict.get(signatures, alias <> "." <> label) {
        Ok(_) -> True
        Error(_) -> False
      }
  }
}

// Whether the label names a record field somewhere in the package. Used to
// disambiguate `alias.label` when `label` is both a module function and a
// record field name: if the alias is shadowed by a parameter, the access is
// a field access on that parameter (real Gleam types the container as a
// value first), not a module-qualified function reference.
//
// The `type:` keys of the arity map encode whole custom types' unions of
// variant fields (see `type_arities`); they are not "a field somewhere", so
// they are excluded here.
fn is_record_field(
  context: internal.TransformerContext,
  label: String,
) -> Bool {
  case context.constructor_arities {
    option.None -> False
    option.Some(arities) ->
      dict.values(filter_field_arities(arities))
      |> list.any(fn(fields) { list.contains(fields, label) })
  }
}

fn filter_field_arities(
  arities: dict.Dict(String, List(String)),
) -> dict.Dict(String, List(String)) {
  arities
  |> dict.filter(fn(key, _fields) {
    case string.starts_with(key, "type:") {
      True -> False
      False -> True
    }
  })
}

// Whether `alias` (a parameter in scope) has a declared type that carries a
// field named `label`. `Some(True)`/`Some(False)` when the type is known,
// `None` when there is no useful type information, in which case callers fall
// back to the package-wide `is_record_field` heuristic.
fn type_has_field(
  context: internal.TransformerContext,
  alias: String,
  label: String,
) -> option.Option(Bool) {
  case dict.get(context.local_types, alias), context.constructor_arities {
    Error(_), _ -> option.None
    _, option.None -> option.None
    Ok(glance.NamedType(name: name, module: module, ..)), option.Some(arities)
    -> {
      let keys = case module {
        option.Some(binding) -> {
          let prefix = module_prefix(context, binding)
          ["type:" <> prefix <> "." <> name, "type:" <> name]
        }
        option.None -> ["type:" <> name]
      }
      type_fields_of(keys, arities, label)
    }
    Ok(_), option.Some(_) -> option.None
  }
}

// Looks the `label` up in the fields of the first arity key that exists,
// returning `None` when none of the keys are known types.
fn type_fields_of(
  keys: List(String),
  arities: dict.Dict(String, List(String)),
  label: String,
) -> option.Option(Bool) {
  case keys {
    [] -> option.None
    [key, ..rest] ->
      case dict.get(arities, key) {
        Ok(fields) -> option.Some(list.contains(fields, label))
        Error(_) -> type_fields_of(rest, arities, label)
      }
  }
}

// The `<last_segment>` module prefix for a module binding name, e.g. `t` for
// `import rada/testing as t` resolves to `testing`.
fn module_prefix(
  context: internal.TransformerContext,
  binding: String,
) -> String {
  case context.module_paths {
    option.None -> binding
    option.Some(paths) ->
      case dict.get(paths, binding) {
        Ok(path) ->
          path
          |> string.split("/")
          |> list.last
          |> result.unwrap(path)
        Error(_) -> binding
      }
  }
}

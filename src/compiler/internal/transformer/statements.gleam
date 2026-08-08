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
      docstring: docstring,
      comments: comments,
    ),
    ..module.constants
  ])
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
        context: result.context,
        statements: list.append(result.statements, [
          python.SimpleAssignment(variable, result.expression),
        ]),
      )
    }
    glance.Assignment(kind: kind, pattern: pattern, value: value, ..) ->
      transform_destructuring_assignment(
        transform_context,
        kind,
        pattern,
        value,
      )

    glance.Use(..) -> panic as "Use statements should have been desugared by now"

    glance.Assert(_, expression, _) -> {
      let result = transform_expression(transform_context, expression)
      internal.StatementReturn(
        context: result.context,
        statements: list.append(result.statements, [
          python.Expression(result.expression),
        ]),
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
        option.Some(python.String("assertion failed")),
      ))
  }
  let value_result = transform_expression(message_result.context, value)

  let #(statements, fresh_pool) = case binds {
    [] ->
      // A pattern that binds nothing, e.g. `let _ = foo`. Just evaluate the
      // expression.
      #(
        list.append(
          list.append(message_result.statements, value_result.statements),
          [python.Expression(value_result.expression)],
        ),
        value_result.context.fresh_pool,
      )
    _ -> {
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
        [single] -> python.Variable(single)
        multiple -> python.Tuple(list.map(multiple, python.Variable))
      }
      let matched_case =
        python.MatchCase(
          pattern_result.pattern,
          pattern_result.guard,
          list.append(pattern_result.body_prepend, [python.Return(return_value)]),
        )
      let cases = case kind {
        glance.Let -> [matched_case]
        glance.LetAssert(_) -> [
          matched_case,
          python.MatchCase(python.PatternWildcard, option.None, [
            python.Expression(
              python.Panic(option.unwrap(
                message_result.expression,
                python.String("assertion failed"),
              )),
            ),
          ]),
        ]
      }
      let function_name = "_fn_match_" <> int.to_string(context.next_case_id)
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
          option.None,
          [],
        )
      let call =
        python.Call(python.Variable(function_name), [
          python.UnlabelledField(value_result.expression),
        ])
      let assignment = case binds {
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

  internal.StatementReturn(
    context: internal.TransformerContext(
      ..value_result.context,
      next_case_id: value_result.context.next_case_id + 1,
      fresh_pool: fresh_pool,
    ),
    statements: statements,
  )
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

    glance.Variable(_, "None") -> internal.empty_return(context, python.Nil)

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

    glance.Panic(_, option.None) ->
      internal.empty_return(
        context,
        python.Panic(python.String("panic expression evaluated")),
      )
    glance.Panic(_, option.Some(expression)) ->
      transform_expression(context, expression)
      |> internal.map_return(python.Panic)

    glance.Todo(_, option.None) ->
      internal.empty_return(
        context,
        python.Todo(python.String("This has not yet been implemented")),
      )
    glance.Todo(_, option.Some(expression)) ->
      transform_expression(context, expression)
      |> internal.map_return(python.Todo)

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
      case label {
        "None" -> internal.empty_return(context, python.Nil)
        _ ->
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
                          // alias is shadowed by a parameter and the label
                          // is a record field somewhere in the package,
                          // this is a field access on the parameter and
                          // must be emitted as a variable reference so the
                          // shadowing passes rename it with the parameter.
                          // Otherwise it is a module-qualified function
                          // used as a value, which stays a module reference.
                          case is_record_field(context, label) {
                            True ->
                              case
                                list.contains(
                                  context.module_reserved,
                                  alias <> "_0",
                                )
                              {
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
    glance.FieldAccess(_, glance.Variable(_, alias), name) ->
      case list.contains(context.module_aliases, alias) {
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
  let parameters_result =
    list.fold(
      arguments,
      internal.TransformState(context, [], []),
      fold_fn_parameter,
    )

  let function_name = "_fn_def_" <> int.to_string(context.next_function_id)
  let parameters = list.reverse(parameters_result.item)
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
        fresh_pool: context.fresh_pool,
      ),
      body,
    )
  let #(body_statements, fresh_pool) =
    transformed_body.statements
    |> shadowing.resolve_block_shadowing(
      shadowing.function_parameter_names(parameters),
      context.module_reserved,
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
    python.Function(function_name, parameters, body_statements, option.None, [])

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
        fresh_pool: context.fresh_pool,
      ),
      body,
    )
  let #(body_statements, fresh_pool) =
    transformed_body.statements
    |> shadowing.resolve_block_shadowing(
      [],
      context.module_reserved,
      context.fresh_pool,
    )
  let function =
    python.Function(function_name, [], body_statements, option.None, [])
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
  let function =
    python.Function(
      function_name,
      [python.NameParam("_case_subject")],
      [
        python.Match(subject: python.Variable("_case_subject"), cases: cases),
      ],
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
      let guard_return = transform_optional_expression(state.context, guard)
      let statements_result =
        transform_statement_block_with_context(guard_return.context, statements)
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
        statements_result.context,
        state.statements,
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
      let body_result = transform_expression(guard_return.context, body)

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
        body_result.context,
        state.statements,
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
  let piped_into_call = case right {
    glance.Call(location, function, arguments) ->
      case is_external_callee(context, function) {
        True -> option.Some(#(location, function, arguments))
        False -> option.None
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
    case right_ex, piped_into_call {
      python.Call(function, arguments), option.None ->
        python.Call(
          function,
          list.prepend(arguments, python.UnlabelledField(left_ex)),
        )
      python.Call(_, _), option.Some(_) -> right_ex
      _, _ -> python.Call(right_ex, [python.UnlabelledField(left_ex)])
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
    glance.BytesOption ->
      internal.map_state_prepend(state, python.BitStringOption)
    glance.BitsOption ->
      internal.map_state_prepend(state, python.BitStringOption)
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
fn is_record_field(
  context: internal.TransformerContext,
  label: String,
) -> Bool {
  case context.constructor_arities {
    option.None -> False
    option.Some(arities) ->
      dict.values(arities)
      |> list.any(fn(fields) { list.contains(fields, label) })
  }
}

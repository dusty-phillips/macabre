import compiler/internal/transformer as internal
import compiler/internal/transformer/statements
import compiler/python
import glance
import gleam/list
import gleam/option

pub fn transform_top_level_function(
  function: glance.Function,
) -> python.Function {
  python.Function(
    name: function.name,
    parameters: list.map(function.parameters, transform_function_parameter),
    body: {
      let result =
        function.body
        |> list.fold(
          internal.StatementReturn(
            context: internal.TransformerContext(next_function_id: 0),
            statements: [],
          ),
          fn(state, next_statement) {
            let result =
              statements.transform_statement(state.context, next_statement)
            internal.StatementReturn(
              context: result.context,
              statements: list.append(state.statements, result.statements),
            )
          },
        )
      result.statements
      |> internal.transform_last(internal.add_return_if_returnable_expression)
    },
  )
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

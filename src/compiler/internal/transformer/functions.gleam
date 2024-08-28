import compiler/internal/transformer
import compiler/internal/transformer/statements
import compiler/python
import glance
import gleam/list
import gleam/option

type ParamFoldState {
  ParamFoldState(
    discard_idx: Int,
    reversed_params: transformer.ReversedList(python.FunctionParameter),
  )
}

pub fn transform_top_level_function(
  function: glance.Function,
) -> python.Function {
  python.Function(
    name: function.name,
    parameters: list.fold(
      function.parameters,
      ParamFoldState(0, []),
      fold_function_parameter,
    ).reversed_params
      |> list.reverse,
    body: function.body
      |> statements.transform_statement_block,
  )
}

fn fold_function_parameter(
  state: ParamFoldState,
  function_parameter: glance.FunctionParameter,
) -> ParamFoldState {
  case function_parameter {
    glance.FunctionParameter(label: option.Some(_), name: _, type_: _) ->
      todo as "Labelled parameters not supported yet"
    glance.FunctionParameter(
      label: option.None,
      name: glance.Discarded(""),
      type_: _,
    ) ->
      ParamFoldState(
        discard_idx: state.discard_idx + 1,
        reversed_params: list.prepend(
          state.reversed_params,
          python.DiscardParam(state.discard_idx),
        ),
      )
    glance.FunctionParameter(
      label: option.None,
      name: glance.Discarded(name),
      type_: _,
    ) ->
      ParamFoldState(
        ..state,
        reversed_params: list.prepend(
          state.reversed_params,
          python.NameParam("_" <> name),
        ),
      )
    glance.FunctionParameter(
      label: option.None,
      name: glance.Named(name),
      type_: _,
    ) ->
      ParamFoldState(
        ..state,
        reversed_params: list.prepend(
          state.reversed_params,
          python.NameParam(name),
        ),
      )
  }
}

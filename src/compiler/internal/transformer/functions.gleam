import compiler/internal/transformer
import compiler/internal/transformer/shadowing
import compiler/internal/transformer/statements
import compiler/python
import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option

type ParamFoldState {
  ParamFoldState(
    discard_idx: Int,
    reversed_params: transformer.ReversedList(python.FunctionParameter),
    reversed_binds: transformer.ReversedList(python.Statement),
  )
}

/// Builds a forwarding wrapper for an external function whose Python binding
/// has a different name to the Gleam function, e.g.
/// `@external(python, "argv_bindings", "load") fn do() { ... }`. Callers
/// reference the Gleam name, so we emit `def do(): return load()`.
pub fn transform_external_forwarder(
  function: glance.Function,
  binding_name: String,
) -> python.Function {
  let fold_result =
    list.fold(
      function.parameters,
      ParamFoldState(0, [], []),
      fold_function_parameter,
    )
  let parameters = fold_result.reversed_params |> list.reverse
  let args =
    list.map(parameters, fn(parameter) {
      python.UnlabelledField(python.Variable(parameter_name(parameter)))
    })
  python.Function(
    name: function.name,
    parameters: parameters,
    body: list.append(fold_result.reversed_binds |> list.reverse, [
      python.Return(python.Call(python.Variable(binding_name), args)),
    ]),
    docstring: option.None,
    comments: [],
  )
}

fn parameter_name(parameter: python.FunctionParameter) -> String {
  case parameter {
    python.NameParam(name) -> name
    python.DiscardParam(index) ->
      case index {
        0 -> "_"
        _ -> "_" <> int.to_string(index)
      }
  }
}

pub fn transform_top_level_function(
  function: glance.Function,
  function_signatures: option.Option(transformer.FunctionSignatures),
  module_aliases: List(String),
  constructor_arities: option.Option(dict.Dict(String, List(String))),
  module_bindings: option.Option(dict.Dict(String, String)),
  external_functions: option.Option(List(String)),
  external_qualified: option.Option(List(String)),
) -> python.Function {
  let fold_result =
    list.fold(
      function.parameters,
      ParamFoldState(0, [], []),
      fold_function_parameter,
    )
  let context =
    transformer.TransformerContext(
      ..transformer.empty_context(),
      function_signatures: function_signatures,
      module_aliases: module_aliases,
      constructor_arities: constructor_arities,
      external_functions: external_functions,
      external_qualified: external_qualified,
      module_bindings: module_bindings,
    )
  let parameters = fold_result.reversed_params |> list.reverse
  let parameter_names =
    list.filter_map(parameters, fn(parameter) {
      case parameter {
        python.NameParam(name) -> Ok(name)
        python.DiscardParam(_) -> Error(Nil)
      }
    })
  let module_reserved =
    module_aliases
    |> list.filter(fn(alias) { list.contains(parameter_names, alias) })
    |> list.map(fn(alias) { alias <> "_0" })
  let context =
    transformer.TransformerContext(..context, module_reserved: module_reserved)
  let body =
    fold_result.reversed_binds
    |> list.reverse
    |> list.append(
      statements.transform_statement_block_with_context(context, function.body).statements,
    )
  let #(parameters, body, fresh_pool) =
    shadowing.resolve_module_shadowing(
      body,
      parameters,
      module_aliases,
      context.fresh_pool,
    )
  let #(body, _) =
    body
    |> shadowing.resolve_block_shadowing(
      shadowing.function_parameter_names(parameters),
      list.map(module_aliases, fn(alias) { alias <> "_0" }),
      fresh_pool,
    )
  python.Function(
    name: function.name,
    parameters: parameters,
    body: body |> shadowing.resolve_tail_calls(function.name, parameters),
    docstring: option.None,
    comments: [],
  )
}

fn fold_function_parameter(
  state: ParamFoldState,
  function_parameter: glance.FunctionParameter,
) -> ParamFoldState {
  case function_parameter {
    glance.FunctionParameter(
      label: option.Some(label),
      name: glance.Named(name),
      type_: _,
    ) -> {
      let binds = case name == label {
        True -> state.reversed_binds
        False ->
          list.prepend(
            state.reversed_binds,
            python.SimpleAssignment(name, python.Variable(label)),
          )
      }
      ParamFoldState(
        ..state,
        reversed_binds: binds,
        reversed_params: list.prepend(
          state.reversed_params,
          python.NameParam(label),
        ),
      )
    }
    glance.FunctionParameter(label: option.Some(label), name: _, type_: _) ->
      ParamFoldState(
        ..state,
        reversed_params: list.prepend(
          state.reversed_params,
          python.NameParam(label),
        ),
      )
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
        reversed_binds: state.reversed_binds,
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

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

type ForwarderFoldState {
  ForwarderFoldState(
    discard_idx: Int,
    reversed_params: transformer.ReversedList(python.FunctionParameter),
  )
}

/// Builds a forwarding wrapper for an external function whose Python binding
/// has a different name to the Gleam function, e.g.
/// `@external(python, "argv_bindings", "load") fn do() { ... }`. Callers
/// reference the Gleam name, so we emit `def do(): return load()`.
///
/// The wrapper's parameters use the Gleam parameter names (not the labels), as
/// labelled calls to externals are emitted as keyword arguments keyed by those
/// parameter names (see `external_keyword_arguments` in statements.gleam).
pub fn transform_external_forwarder(
  function: glance.Function,
  binding_name: String,
) -> python.Function {
  let parameters = external_forwarder_parameters(function)
  let args =
    list.map(parameters, fn(parameter) {
      python.UnlabelledField(python.Variable(parameter_name(parameter)))
    })
  python.Function(
    name: function.name,
    parameters: parameters,
    body: [
      python.Return(python.Call(python.Variable(binding_name), args)),
    ],
    public: case function.publicity {
      glance.Public -> True
      glance.Private -> False
    },
    docstring: option.None,
    comments: [],
  )
}

// The Python parameter names for a function's parameters, in declaration
// order. Uses the Gleam parameter names (not labels), matching how the
// external forwarder and the compiled function signature name their
// parameters, so labelled calls resolve correctly.
pub fn external_forwarder_parameters(
  function: glance.Function,
) -> List(python.FunctionParameter) {
  let fold_result =
    list.fold(
      function.parameters,
      ForwarderFoldState(0, []),
      fold_forwarder_parameter,
    )
  fold_result.reversed_params |> list.reverse
}

fn fold_forwarder_parameter(
  state: ForwarderFoldState,
  function_parameter: glance.FunctionParameter,
) -> ForwarderFoldState {
  case function_parameter {
    glance.FunctionParameter(label: _, name: glance.Named(name), type_: _) ->
      ForwarderFoldState(
        ..state,
        reversed_params: list.prepend(
          state.reversed_params,
          python.NameParam(name),
        ),
      )
    glance.FunctionParameter(label: _, name: _, type_: _) -> {
      let index = state.discard_idx
      ForwarderFoldState(
        discard_idx: index + 1,
        reversed_params: list.prepend(
          state.reversed_params,
          python.DiscardParam(index),
        ),
      )
    }
  }
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
  module_paths: dict.Dict(String, String),
  constructor_arities: option.Option(dict.Dict(String, List(String))),
  module_bindings: option.Option(dict.Dict(String, String)),
  external_functions: option.Option(List(String)),
  external_qualified: option.Option(List(String)),
  public: Bool,
  module_name: String,
  file_path: String,
  module_source: String,
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
      module_paths: option.Some(module_paths),
      constructor_arities: constructor_arities,
      external_functions: external_functions,
      external_qualified: external_qualified,
      module_bindings: module_bindings,
      local_bindings: list.filter_map(function.parameters, fn(parameter) {
        case parameter {
          glance.FunctionParameter(name: glance.Named(name), ..) -> Ok(name)
          _ -> Error(Nil)
        }
      }),
      module_name: module_name,
      function_name: function.name,
      file_path: file_path,
      module_source: module_source,
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
  let body_result =
    statements.transform_statement_block_with_context(context, function.body)
  let body =
    fold_result.reversed_binds
    |> list.reverse
    |> list.append(body_result.statements)
  let #(parameters, body, fresh_pool) =
    shadowing.resolve_module_shadowing(
      body,
      parameters,
      module_aliases,
      body_result.context.fresh_pool,
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
    body: body
      |> shadowing.resolve_tail_calls(function.name, parameters)
      |> shadowing.inline_case_drivers
      |> shadowing.optimize_list_loops
      |> shadowing.inline_fold_loops(option.Some(module_paths)),
    public: public,
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
      label: option.Some(_label),
      name: glance.Named(name),
      type_: _,
    ) -> {
      ParamFoldState(
        ..state,
        reversed_binds: state.reversed_binds,
        reversed_params: list.prepend(
          state.reversed_params,
          python.NameParam(name),
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

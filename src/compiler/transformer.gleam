import compiler/internal/transformer as internal
import compiler/internal/transformer/functions
import compiler/internal/transformer/types
import compiler/python
import glance
import gleam/list

pub fn transform(input: glance.Module) -> Result(python.Module, String) {
  python.empty_module()
  |> list.fold(input.functions, _, transform_function_or_external)
  |> list.fold(input.custom_types, _, transform_custom_type_in_module)
  |> Ok
}

fn transform_function_or_external(
  module: python.Module,
  function: glance.Definition(glance.Function),
) -> python.Module {
  case list.filter_map(function.attributes, internal.maybe_extract_external) {
    [] ->
      python.Module(
        ..module,
        functions: [
          functions.transform_top_level_function(function.definition),
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
      types.transform_custom_type(custom_type.definition),
      ..module.custom_types
    ],
  )
}

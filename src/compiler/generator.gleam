import compiler/internal/generator as internal
import compiler/internal/generator/imports
import compiler/internal/generator/statements
import compiler/internal/generator/types
import compiler/python
import gleam/string_builder
import python_prelude

pub fn generate(module: python.Module) -> String {
  string_builder.new()
  |> string_builder.append(python_prelude.prelude)
  |> string_builder.append_builder(imports.generate_imports(module.imports))
  |> string_builder.append_builder(
    internal.generate_plural(
      module.constants,
      statements.generate_constant,
      "\n",
    )
    |> internal.append_if_not_empty("\n\n"),
  )
  |> string_builder.append_builder(internal.generate_plural(
    module.custom_types,
    types.generate_custom_type,
    "\n\n\n",
  ))
  |> string_builder.append_builder(internal.generate_plural(
    module.functions,
    statements.generate_function,
    "\n\n\n",
  ))
  |> string_builder.to_string
}

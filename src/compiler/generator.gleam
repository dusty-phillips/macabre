import compiler/internal/generator as internal
import compiler/internal/generator/imports
import compiler/internal/generator/statements
import compiler/internal/generator/types
import compiler/python
import gleam/string_tree
import python_prelude

pub fn generate(module: python.Module) -> String {
  string_tree.new()
  |> string_tree.append(python_prelude.prelude)
  |> string_tree.append_tree(imports.generate_imports(module.imports))
  |> string_tree.append_tree(internal.generate_plural(
    module.custom_types,
    types.generate_custom_type,
    "\n\n\n",
  ))
  |> string_tree.append_tree(internal.generate_plural(
    module.functions,
    statements.generate_function,
    "\n\n\n",
  ))
  |> string_tree.append_tree(
    internal.generate_plural(
      module.constants,
      statements.generate_constant,
      "\n",
    )
    |> internal.append_if_not_empty("\n\n")
    |> internal.prepend_if_not_empty(
      case module.custom_types != [] || module.functions != [] {
        True -> "\n\n\n"
        False -> ""
      },
    ),
  )
  |> string_tree.to_string
}

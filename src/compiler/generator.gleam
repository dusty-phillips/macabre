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
  |> string_tree.append_tree(statements.generate_module_header(
    module.docstring,
    module.comments,
  ))
  |> string_tree.append_tree(internal.generate_plural(
    module.custom_types,
    types.generate_custom_type,
    // Each custom type ends with its own trailing newlines (two blank
    // lines), so consecutive types need no extra separator.
    "",
  ))
  |> string_tree.append_tree(internal.generate_plural(
    module.functions,
    statements.generate_function,
    "\n\n\n",
  ))
  // Imports are emitted after classes and functions: module imports form
  // cycles (e.g. a imports b which imports names from a) that only resolve
  // once the importing module has finished loading. Function and class
  // bodies reference imported names at call time only (annotations are
  // lazy strings thanks to `from __future__ import annotations` in the
  // prelude), so a late import is safe. Constants are emitted last because
  // they are evaluated at module load.
  |> string_tree.append_tree(
    imports.generate_imports(module.imports)
    |> internal.prepend_if_not_empty(
      case module.custom_types != [] || module.functions != [] {
        True -> "\n\n\n"
        False -> ""
      },
    ),
  )
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

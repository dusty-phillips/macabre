import compiler/internal/generator as internal
import compiler/internal/generator/imports
import compiler/internal/generator/statements
import compiler/internal/generator/types
import compiler/python
import gleam/list
import gleam/string_tree.{type StringTree}
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
  |> string_tree.append_tree(generate_all(module))
  |> string_tree.to_string
}

// The public API of the module, for `from module import *`. Gleam's public
// functions, constants, and type constructors map to Python functions,
// module-level values, and variant classes respectively.
fn generate_all(module: python.Module) -> StringTree {
  let names =
    list.filter_map(module.functions, fn(function) {
      case function.public {
        True -> Ok(internal.python_name(function.name))
        False -> Error(Nil)
      }
    })
    |> list.append(
      list.filter_map(module.constants, fn(constant) {
        case constant.public {
          True -> Ok(internal.python_name(constant.name))
          False -> Error(Nil)
        }
      }),
    )
    |> list.append(
      list.flat_map(module.custom_types, fn(custom_type) {
        case custom_type.public {
          True ->
            list.map(custom_type.variants, fn(variant) {
              internal.python_name(variant.name)
            })
          False -> []
        }
      }),
    )
    |> list.unique
  case names {
    [] -> string_tree.new()
    _ ->
      string_tree.new()
      |> string_tree.append("\n\n\n__all__ = [")
      |> string_tree.append_tree(
        names
        |> list.map(fn(name) {
          string_tree.from_string("\"")
          |> string_tree.append(name)
          |> string_tree.append("\"")
        })
        |> internal.generate_plural(fn(tree) { tree }, ", "),
      )
      |> string_tree.append("]\n")
  }
}

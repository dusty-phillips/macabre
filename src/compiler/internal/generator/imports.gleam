import compiler/internal/generator as internal
import compiler/python
import gleam/string_tree.{type StringTree}

pub fn generate_imports(imports: List(python.Import)) -> StringTree {
  internal.generate_plural(imports, generate_import, "\n")
  |> internal.append_if_not_empty("\n\n\n")
}

fn generate_import(import_: python.Import) -> StringTree {
  case import_ {
    python.QualifiedImport(module) ->
      string_tree.from_strings(["import ", module])
    python.AliasedQualifiedImport(module, alias) ->
      string_tree.from_strings(["import ", module, " as ", alias])
    python.UnqualifiedImport(module, name) ->
      string_tree.new()
      |> string_tree.append("from ")
      |> string_tree.append(module)
      |> string_tree.append(" import ")
      |> string_tree.append(name |> internal.python_name)
    python.AliasedUnqualifiedImport(module, name, alias) -> {
      string_tree.new()
      |> string_tree.append("from ")
      |> string_tree.append(module)
      |> string_tree.append(" import ")
      |> string_tree.append(name |> internal.python_name)
      |> string_tree.append(" as ")
      |> string_tree.append(alias |> internal.python_name)
    }
  }
}

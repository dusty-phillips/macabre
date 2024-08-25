import compiler/internal/generator as internal
import compiler/python
import gleam/string_builder.{type StringBuilder}

pub fn generate_imports(imports: List(python.Import)) -> StringBuilder {
  internal.generate_plural(imports, generate_import, "\n")
  |> internal.append_if_not_empty("\n\n\n")
}

fn generate_import(import_: python.Import) -> StringBuilder {
  case import_ {
    python.QualifiedImport(module) ->
      string_builder.from_strings(["import ", module])
    python.AliasedQualifiedImport(module, alias) ->
      string_builder.from_strings(["import ", module, " as ", alias])
    python.UnqualifiedImport(module, name) ->
      string_builder.new()
      |> string_builder.append("from ")
      |> string_builder.append(module)
      |> string_builder.append(" import ")
      |> string_builder.append(name)
    python.AliasedUnqualifiedImport(module, name, alias) -> {
      string_builder.new()
      |> string_builder.append("from ")
      |> string_builder.append(module)
      |> string_builder.append(" import ")
      |> string_builder.append(name)
      |> string_builder.append(" as ")
      |> string_builder.append(alias)
    }
  }
}

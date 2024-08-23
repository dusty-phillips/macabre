import compiler/internal/generator as internal
import compiler/python
import gleam/option
import gleam/string_builder.{type StringBuilder}

pub fn generate_imports(imports: List(python.Import)) -> StringBuilder {
  internal.generate_plural(imports, generate_import, "\n")
  |> internal.append_if_not_empty("\n\n\n")
}

fn generate_import(import_: python.Import) -> StringBuilder {
  case import_ {
    python.UnqualifiedImport(module, name, option.None) ->
      string_builder.new()
      |> string_builder.append("from ")
      |> string_builder.append(module)
      |> string_builder.append(" import ")
      |> string_builder.append(name)
    python.UnqualifiedImport(_module, _name, option.Some(_)) ->
      todo as "Aliased imports not supported yet"
  }
}

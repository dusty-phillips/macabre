import compiler/internal/transformer as internal
import compiler/internal/transformer/functions
import compiler/internal/transformer/statements
import compiler/internal/transformer/types
import compiler/python
import glance
import gleam/list
import gleam/option
import gleam/string

pub fn transform(input: glance.Module) -> python.Module {
  python.empty_module()
  |> list.fold(input.imports, _, transform_import)
  |> list.fold(input.constants, _, statements.transform_constant)
  |> list.fold(input.functions, _, transform_function_or_external)
  |> list.fold(input.custom_types, _, transform_custom_type_in_module)
}

fn transform_function_or_external(
  module: python.Module,
  function: glance.Definition(glance.Function),
) -> python.Module {
  case list.filter_map(function.attributes, maybe_extract_external) {
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

fn transform_import(
  module: python.Module,
  import_: glance.Definition(glance.Import),
) -> python.Module {
  let python_imports = case import_ {
    glance.Definition(attributes: [_head, ..], ..) ->
      todo as "import attributes not supported yet"

    glance.Definition([], glance.Import(_, _, [_head, ..], _)) -> {
      todo as "type alias imports not supported yet"
    }

    glance.Definition([], glance.Import(module, alias, [], unqualified_values)) -> {
      let module_import = transform_module_import(module, alias)
      let module_part =
        module
        |> string.replace("/", ".")

      unqualified_values
      |> list.map(transform_unqualified_description(_, module_part))
      |> list.prepend(module_import)
    }
  }
  python.Module(..module, imports: list.append(module.imports, python_imports))
}

fn transform_module_import(
  module: String,
  alias: option.Option(glance.AssignmentName),
) -> python.Import {
  let #(build_qual, build_unqual) = case alias {
    option.None -> #(python.QualifiedImport, python.UnqualifiedImport)
    option.Some(assignment_name) -> #(
      python.AliasedQualifiedImport(_, transform_import_alias(assignment_name)),
      fn(mod, name) {
        python.AliasedUnqualifiedImport(
          mod,
          name,
          transform_import_alias(assignment_name),
        )
      },
    )
  }

  case module |> string.split("/") |> list.reverse {
    [] -> panic as "Expected at least one module import"
    [module] -> build_qual(module)
    [last_module, ..modules] ->
      build_unqual(modules |> list.reverse |> string.join("."), last_module)
  }
}

fn transform_import_alias(assignment: glance.AssignmentName) -> String {
  // todo: may need some mapping on discarded names
  case assignment {
    glance.Named(string) -> string
    glance.Discarded(string) -> string
  }
}

fn transform_unqualified_description(
  unqual: glance.UnqualifiedImport,
  module: String,
) -> python.Import {
  case unqual.alias {
    option.None -> python.UnqualifiedImport(module, unqual.name)
    option.Some(alias) ->
      python.AliasedUnqualifiedImport(module, unqual.name, alias)
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

fn maybe_extract_external(
  function_attribute: glance.Attribute,
) -> Result(python.Import, internal.TransformError) {
  case function_attribute {
    glance.Attribute(
      "external",
      [glance.Variable("python"), glance.String(module), glance.String(name)],
    ) -> Ok(python.UnqualifiedImport(module, name))
    _ -> Error(internal.NotExternal)
  }
}

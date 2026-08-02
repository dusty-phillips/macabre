import compiler/internal/generator as internal
import compiler/python
import gleam/option
import gleam/string_tree.{type StringTree}

pub fn generate_custom_type(custom_type: python.CustomType) -> StringTree {
  case custom_type.variants {
    // empty types get discarded
    [] -> string_tree.new()

    variants -> {
      internal.generate_plural(
        custom_type.parameters,
        generate_generic_var,
        "\n",
      )
      |> string_tree.append_tree(
        internal.generate_plural(variants, generate_type_variant, "\n\n")
        |> internal.append_if_not_empty("\n\n"),
      )
      |> string_tree.append("\n")
    }
  }
}

fn generate_generic_var(name: String) -> StringTree {
  let upper_name = string_tree.from_string(name) |> string_tree.uppercase
  string_tree.new()
  |> string_tree.append_tree(upper_name)
  |> string_tree.append(" = typing.TypeVar('")
  |> string_tree.append_tree(upper_name)
  |> string_tree.append("')\n")
}

fn generate_type_variant(variant: python.Variant) -> StringTree {
  string_tree.new()
  |> string_tree.append("@dataclasses.dataclass(frozen=True)\n")
  |> string_tree.append("class ")
  |> string_tree.append(variant.name)
  |> string_tree.append(":\n")
  |> string_tree.append_tree(
    case variant.fields {
      [] -> string_tree.from_string("pass")
      fields -> internal.generate_plural(fields, generate_type_field, "\n")
    }
    |> internal.indent(4),
  )
}

fn generate_type_field(field: python.Field(python.Type)) -> StringTree {
  case field {
    python.UnlabelledField(_) ->
      todo as "not handling unlabeled fields in custom types yet"
    python.LabelledField(label, item) ->
      string_tree.new()
      |> string_tree.append(label)
      |> string_tree.append(": ")
      |> string_tree.append_tree(generate_type(item))
  }
}

fn generate_type(type_: python.Type) -> StringTree {
  case type_ {
    python.NamedType(
      name: "String",
      module: option.None,
      generic_parameters: [],
    ) -> string_tree.from_string("str")

    python.NamedType(name: "Int", module: option.None, generic_parameters: []) ->
      string_tree.from_string("int")

    python.NamedType(name: name, module:, generic_parameters:) -> {
      let params = case generic_parameters {
        [] -> string_tree.new()
        params_exist ->
          params_exist
          |> internal.generate_plural(generate_type, ",")
          |> string_tree.prepend("[")
          |> string_tree.append("]")
      }
      module
      |> option.map(fn(mod) { string_tree.from_strings([mod, "."]) })
      |> option.lazy_unwrap(string_tree.new)
      |> string_tree.append(name)
      |> string_tree.append_tree(params)
    }

    python.TupleType(elements) ->
      elements
      |> internal.generate_plural(generate_type, ", ")
      |> string_tree.prepend("typing.Tuple[")
      |> string_tree.append("]")

    python.GenericType(name) ->
      string_tree.from_string(name)
      |> string_tree.uppercase
  }
}

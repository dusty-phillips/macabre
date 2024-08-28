import compiler/internal/generator as internal
import compiler/python
import gleam/option
import gleam/string_builder.{type StringBuilder}

pub fn generate_custom_type(custom_type: python.CustomType) -> StringBuilder {
  case custom_type.variants {
    // empty types get discarded
    [] -> string_builder.new()

    variants -> {
      string_builder.from_string("// pub type " <> custom_type.name)
      internal.generate_plural(
        custom_type.parameters,
        generate_generic_var,
        "\n",
      )
      |> string_builder.append_builder(
        internal.generate_plural(variants, generate_type_variant, "\n\n")
        |> internal.append_if_not_empty("\n\n"),
      )
      |> string_builder.append("\n")
    }
  }
}

fn generate_generic_var(name: String) -> StringBuilder {
  let upper_name = string_builder.from_string(name) |> string_builder.uppercase
  string_builder.new()
  |> string_builder.append_builder(upper_name)
  |> string_builder.append(" = typing.TypeVar('")
  |> string_builder.append_builder(upper_name)
  |> string_builder.append("')\n")
}

fn generate_type_variant(variant: python.Variant) -> StringBuilder {
  string_builder.new()
  |> string_builder.append("@dataclasses.dataclass(frozen=True)\n")
  |> string_builder.append("class ")
  |> string_builder.append(variant.name)
  |> string_builder.append(":\n")
  |> string_builder.append_builder(
    case variant.fields {
      [] -> string_builder.from_string("pass")
      fields -> internal.generate_plural(fields, generate_type_field, "\n")
    }
    |> internal.indent(4),
  )
}

fn generate_type_field(field: python.Field(python.Type)) -> StringBuilder {
  case field {
    python.UnlabelledField(_) ->
      todo as "not handling unlabeled fields in custom types yet"
    python.LabelledField(label, item) ->
      string_builder.new()
      |> string_builder.append(label)
      |> string_builder.append(": ")
      |> string_builder.append_builder(generate_type(item))
  }
}

fn generate_type(type_: python.Type) -> StringBuilder {
  case type_ {
    python.NamedType(
      name: "String",
      module: option.None,
      generic_parameters: [],
    ) -> string_builder.from_string("str")

    python.NamedType(name: "Int", module: option.None, generic_parameters: []) ->
      string_builder.from_string("int")

    python.NamedType(name: name, module:, generic_parameters:) -> {
      let params = case generic_parameters {
        [] -> string_builder.new()
        params_exist ->
          params_exist
          |> internal.generate_plural(generate_type, ",")
          |> string_builder.prepend("[")
          |> string_builder.append("]")
      }
      module
      |> option.map(fn(mod) { string_builder.from_strings([mod, "."]) })
      |> option.lazy_unwrap(string_builder.new)
      |> string_builder.append(name)
      |> string_builder.append_builder(params)
    }

    python.TupleType(elements) ->
      elements
      |> internal.generate_plural(generate_type, ", ")
      |> string_builder.prepend("typing.Tuple[")
      |> string_builder.append("]")

    python.GenericType(name) ->
      string_builder.from_string(name)
      |> string_builder.uppercase
  }
}

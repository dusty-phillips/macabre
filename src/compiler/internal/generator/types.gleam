import compiler/internal/generator as internal
import compiler/python
import gleam/int
import gleam/list
import gleam/option
import gleam/string_tree.{type StringTree}

pub fn generate_custom_type(custom_type: python.CustomType) -> StringTree {
  // The `None` variant of the `Option` type is represented by the Python
  // keyword `None` rather than a class, so it doesn't need a class
  // definition.
  let variants =
    list.filter(custom_type.variants, fn(variant) { variant.name != "None" })
  case variants {
    // empty types get discarded
    [] -> string_tree.new()

    variants -> {
      let type_comments = internal.generate_comments(custom_type.comments)
      internal.generate_plural(
        custom_type.parameters,
        generate_generic_var,
        "\n",
      )
      |> string_tree.append_tree(
        generate_variants(variants, custom_type.docstring)
        |> internal.append_if_not_empty("\n\n"),
      )
      |> string_tree.append("\n")
      |> string_tree.prepend_tree(type_comments)
    }
  }
}

// The docstring documents the whole type, so it becomes the docstring of the
// first generated variant class.
fn generate_variants(
  variants: List(python.Variant),
  docstring: option.Option(String),
) -> StringTree {
  case variants {
    [] -> string_tree.new()
    [first, ..rest] ->
      generate_type_variant(first, docstring)
      |> string_tree.append_tree(
        rest
        |> internal.generate_plural(
          generate_type_variant(_, option.None),
          "\n\n",
        )
        |> internal.prepend_if_not_empty("\n\n"),
      )
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

fn generate_type_variant(
  variant: python.Variant,
  docstring: option.Option(String),
) -> StringTree {
  string_tree.new()
  |> string_tree.append("@dataclasses.dataclass(frozen=True)\n")
  |> string_tree.append("class ")
  |> string_tree.append(variant.name)
  |> string_tree.append(":\n")
  |> string_tree.append_tree(
    generate_type_variant_body(variant, docstring) |> internal.indent(4),
  )
}

fn generate_type_variant_body(
  variant: python.Variant,
  docstring: option.Option(String),
) -> StringTree {
  let docstring = internal.generate_docstring(docstring)
  let fields = case variant.fields, docstring {
    [], _ -> string_tree.new()
    fields, _ -> {
      let fields = generate_type_fields(fields)
      case string_tree.is_empty(docstring) {
        True -> fields
        False ->
          docstring
          |> string_tree.append("\n")
          |> string_tree.append_tree(fields)
      }
    }
  }
  // Hash by value rather than by the frozen dataclass's generated `__hash__`,
  // which cannot hash `Dict` fields. This keeps records usable as dict keys
  // (and in tuples used as keys), matching Erlang where any term is hashable.
  fields
  |> string_tree.append("\n\n")
  |> string_tree.append("def __hash__(self):\n")
  |> string_tree.append("    return gleam_hash(self)\n")
}

fn generate_type_fields(fields: List(python.Field(python.Type))) -> StringTree {
  fields
  |> list.fold(#(string_tree.new(), 0), fn(acc, field) {
    let #(tree, index) = acc
    let field_tree = case field {
      python.UnlabelledField(item) ->
        string_tree.new()
        |> string_tree.append("_")
        |> string_tree.append(int.to_string(index))
        |> string_tree.append(": ")
        |> string_tree.append_tree(generate_type(item))
      python.LabelledField(label, item) ->
        string_tree.new()
        |> string_tree.append(label |> internal.python_name)
        |> string_tree.append(": ")
        |> string_tree.append_tree(generate_type(item))
    }
    let next_index = case field {
      python.UnlabelledField(_) -> index + 1
      python.LabelledField(..) -> index
    }
    #(append_with_newline(tree, field_tree), next_index)
  })
  |> pair_first
}

fn append_with_newline(tree: StringTree, field_tree: StringTree) -> StringTree {
  case string_tree.is_empty(tree) {
    True -> field_tree
    False ->
      string_tree.append(tree, "\n")
      |> string_tree.append_tree(field_tree)
  }
}

fn pair_first(pair: #(StringTree, Int)) -> StringTree {
  pair.0
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

    python.NamedType(name: "Bool", module: option.None, generic_parameters: []) ->
      string_tree.from_string("bool")

    python.NamedType(name: "Float", module: option.None, generic_parameters: []) ->
      string_tree.from_string("float")

    // The BitArray builtin is encoded as a Python bytes object.
    python.NamedType(
      name: "BitArray",
      module: option.None,
      generic_parameters: [],
    ) -> string_tree.from_string("bytes")

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

    python.FunctionType(parameters, return_type) ->
      parameters
      |> internal.generate_plural(generate_type, ", ")
      |> string_tree.prepend("typing.Callable[[")
      |> string_tree.append("], ")
      |> string_tree.append_tree(generate_type(return_type))
      |> string_tree.append("]")

    python.GenericType(name) ->
      string_tree.from_string(name)
      |> string_tree.uppercase
  }
}

import compiler/internal/generator as internal
import compiler/python
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleam/string_tree.{type StringTree}
import glexer

pub fn generate_expression(expression: python.Expression) -> StringTree {
  case expression {
    python.String(string) ->
      case glexer.unescape_string(string) {
        Error(_) -> string_tree.from_strings(["\"", string, "\""])
        Ok(unescaped) ->
          string_tree.from_string("\"" <> python_escape(unescaped) <> "\"")
      }

    python.Number(number) -> string_tree.from_string(number)

    python.Bool(value) -> string_tree.from_string(value)

    python.Nil -> string_tree.from_string("None")

    python.Variable(value) ->
      string_tree.from_string(value |> internal.python_name)

    python.ModuleRef(name) -> string_tree.from_string(name)

    python.Negate(expression) ->
      generate_expression(expression) |> string_tree.prepend("-")

    python.Not(expression) ->
      generate_expression(expression) |> string_tree.prepend("not ")

    python.Panic(expression) ->
      generate_expression(expression)
      |> string_tree.prepend("raise GleamPanic(")
      |> string_tree.append(")")

    python.Todo(expression) ->
      generate_expression(expression)
      |> string_tree.prepend("raise NotImplementedError(")
      |> string_tree.append(")")

    python.List(elements) ->
      string_tree.from_string("to_gleam_list([")
      |> string_tree.append_tree(internal.generate_plural(
        elements,
        generate_expression,
        ", ",
      ))
      |> string_tree.append("])")

    python.ListWithRest(elements, rest) ->
      string_tree.from_string("to_gleam_list([")
      |> string_tree.append_tree(internal.generate_plural(
        elements,
        generate_expression,
        ", ",
      ))
      |> string_tree.append("], ")
      |> string_tree.append_tree(generate_expression(rest))
      |> string_tree.append(")")

    python.Tuple(expressions) ->
      string_tree.new()
      |> string_tree.append("(")
      |> string_tree.append_tree(
        expressions
        |> internal.generate_plural(generate_expression, ", "),
      )
      |> string_tree.append(",)")

    python.TupleIndex(expression, index) ->
      generate_expression(expression)
      |> string_tree.append("[")
      |> string_tree.append(index |> int.to_string)
      |> string_tree.append("]")

    python.FieldAccess(expression, label) ->
      generate_expression(expression)
      |> string_tree.append(".")
      |> string_tree.append(label |> internal.python_name)

    python.RecordUpdate(record, fields) ->
      string_tree.new()
      |> string_tree.append("dataclasses.replace(")
      |> string_tree.append_tree(generate_expression(record))
      |> string_tree.append(", ")
      |> string_tree.append_tree(internal.generate_plural(
        fields,
        generate_record_update_fields,
        ", ",
      ))
      |> string_tree.append(")")

    python.Lambda(arguments, body) -> {
      string_tree.from_string("(lambda ")
      |> string_tree.append_tree(internal.generate_plural(
        arguments,
        generate_expression,
        ", ",
      ))
      |> string_tree.append(": ")
      |> string_tree.append_tree(generate_expression(body))
      |> string_tree.append(")")
    }

    python.Call(function, arguments) ->
      string_tree.new()
      |> string_tree.append_tree(generate_expression(function))
      |> string_tree.append("(")
      |> string_tree.append_tree(
        arguments
        |> list.map(generate_call_fields)
        |> string_tree.join(", "),
      )
      |> string_tree.append(")")

    python.BinaryOperator(name, left, right) ->
      generate_binop(name, left, right)

    python.Slice(container, start, end) ->
      generate_expression(container)
      |> string_tree.append("[")
      |> string_tree.append_tree(generate_expression(start))
      |> string_tree.append(":")
      |> string_tree.append_tree(case end {
        option.None -> string_tree.new()
        option.Some(end) -> generate_expression(end)
      })
      |> string_tree.append("]")

    python.AssignmentExpression(name, value) ->
      string_tree.from_string("(")
      |> string_tree.append(name |> internal.python_name)
      |> string_tree.append(" := ")
      |> string_tree.append_tree(generate_expression(value))
      |> string_tree.append(")")

    python.IsNotNone(expression) ->
      generate_expression(expression)
      |> string_tree.append(" is not None")

    python.BitString(segments) -> generate_bitstring(segments)

    python.Dict(entries) ->
      string_tree.from_string("{")
      |> string_tree.append_tree(internal.generate_plural(
        entries,
        generate_dict_entry,
        ", ",
      ))
      |> string_tree.append("}")
  }
}

fn generate_dict_entry(entry: #(String, python.Expression)) -> StringTree {
  let #(key, value) = entry
  string_tree.from_string("\"" <> key <> "\": ")
  |> string_tree.append_tree(generate_expression(value))
}

fn generate_record_update_fields(
  field: python.Field(python.Expression),
) -> StringTree {
  case field {
    python.UnlabelledField(_) ->
      panic as "Unlabeled fields are not expected on record updates"
    python.LabelledField(label, expression) ->
      string_tree.new()
      |> string_tree.append(label |> internal.python_name)
      |> string_tree.append("=")
      |> string_tree.append_tree(generate_expression(expression))
  }
}

fn generate_call_fields(field: python.Field(python.Expression)) -> StringTree {
  case field {
    python.UnlabelledField(expression) -> generate_expression(expression)
    python.LabelledField(label, expression) ->
      generate_expression(expression)
      |> string_tree.prepend("=")
      |> string_tree.prepend(label |> internal.python_name)
  }
}

fn generate_binop(
  name: python.BinaryOperator,
  left: python.Expression,
  right: python.Expression,
) -> StringTree {
  let op_string = case name {
    python.And -> " and "
    python.Or -> " or "
    python.Add -> " + "
    python.Subtract -> " - "
    python.Divide -> " / "
    python.DivideInt -> " // "
    python.Multiply -> " * "
    python.Modulo -> " % "
    python.Equal -> " == "
    python.NotEqual -> " != "
    python.LessThan -> " < "
    python.LessThanEqual -> " <= "
    python.GreaterThan -> " > "
    python.GreaterThanEqual -> " >= "
  }

  string_tree.new()
  |> string_tree.append_tree(generate_expression(left))
  |> string_tree.append(op_string)
  |> string_tree.append_tree(generate_expression(right))
}

fn generate_bitstring(segments: List(python.BitStringSegment)) -> StringTree {
  string_tree.from_string("gleam_bitstring_segments_to_bytes(")
  |> string_tree.append_tree(internal.generate_plural(
    segments,
    generate_bitstring_segment,
    ", ",
  ))
  |> string_tree.append(")")
}

fn generate_bitstring_segment(segment: python.BitStringSegment) -> StringTree {
  generate_expression(segment.value)
  |> string_tree.prepend("(")
  |> string_tree.append(", [")
  |> string_tree.append_tree(internal.generate_plural(
    segment.options,
    generate_bitstring_segment_option,
    ", ",
  ))
  |> string_tree.append("])")
}

fn generate_bitstring_segment_option(
  option: python.BitStringSegmentOption,
) -> StringTree {
  case option {
    python.SizeValueOption(expression) ->
      generate_expression(expression)
      |> string_tree.prepend("\"SizeValue\", ")

    python.UnitOption(integer) ->
      integer
      |> int.to_string
      |> string_tree.from_string
      |> string_tree.prepend("\"Unit\", ")

    python.FloatOption -> string_tree.from_string("\"Float\", None")
    python.IntOption -> string_tree.from_string("\"Int\", None")
    python.BigOption -> string_tree.from_string("\"Big\", None")
    python.LittleOption -> string_tree.from_string("\"Little\", None")
    python.NativeOption -> string_tree.from_string("\"Native\", None")
    python.BitStringOption -> string_tree.from_string("\"BitString\", None")
    python.Utf8Option -> string_tree.from_string("\"Utf8\", None")
    python.Utf16Option -> string_tree.from_string("\"Utf16\", None")
    python.Utf32Option -> string_tree.from_string("\"Utf32\", None")
    python.Utf8CodepointOption ->
      string_tree.from_string("\"Utf8Codepoint\", None")
    python.Utf16CodepointOption ->
      string_tree.from_string("\"Utf16Codepoint\", None")
    python.Utf32CodepointOption ->
      string_tree.from_string("\"Utf32Codepoint\", None")
  }
  |> string_tree.prepend("(")
  |> string_tree.append(")")
}

pub fn python_escape(content: String) -> String {
  content
  |> string.to_utf_codepoints
  |> list.map(escape_codepoint)
  |> string.join("")
}

fn escape_codepoint(codepoint) -> String {
  let value = string.utf_codepoint_to_int(codepoint)
  case value {
    34 -> "\\\""
    92 -> "\\\\"
    8 -> "\\b"
    9 -> "\\t"
    10 -> "\\n"
    12 -> "\\f"
    13 -> "\\r"
    _ ->
      case value < 32 || value == 127 {
        True -> {
          let hex =
            value
            |> int.to_base16
            |> string.lowercase
            |> zero_pad_hex
          "\\x" <> hex
        }
        False -> string.from_utf_codepoints([codepoint])
      }
  }
}

fn zero_pad_hex(hex: String) -> String {
  case string.length(hex) {
    1 -> "0" <> hex
    _ -> hex
  }
}

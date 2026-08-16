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

    python.Number(number) ->
      string_tree.from_string(python_number_literal(number))

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
      build_gleam_list(elements, string_tree.from_string("EmptyGleamList()"))

    python.ListWithRest(elements, rest) ->
      build_gleam_list(elements, generate_expression(rest))

    python.Tuple(expressions) ->
      case expressions {
        [] ->
          // An empty tuple is written `()` in Python; `(,)` is a syntax
          // error. Emitted for e.g. a zero-argument tail call's GleamTco args.
          string_tree.from_string("()")
        _ ->
          string_tree.new()
          |> string_tree.append("(")
          |> string_tree.append_tree(
            expressions
            |> internal.generate_plural(generate_expression, ", "),
          )
          |> string_tree.append(",)")
      }

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
      |> string_tree.append("gleam_record_replace(")
      |> string_tree.append_tree(generate_expression(record))
      |> string_tree.append(", {")
      |> string_tree.append_tree(internal.generate_plural(
        fields,
        generate_record_update_fields,
        ", ",
      ))
      |> string_tree.append("})")

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
      |> string_tree.append("\"")
      |> string_tree.append(label |> internal.python_name)
      |> string_tree.append("\": ")
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
    python.Multiply -> " * "
    python.Equal -> " == "
    python.NotEqual -> " != "
    python.LessThan -> " < "
    python.LessThanEqual -> " <= "
    python.GreaterThan -> " > "
    python.GreaterThanEqual -> " >= "
    python.Divide -> "gleam_float_div"
    python.DivideInt -> "gleam_int_div"
    python.Modulo -> "gleam_int_rem"
  }

  case name {
    python.Divide | python.DivideInt | python.Modulo ->
      // Erlang's `/`, `div` and `rem` guard against a zero divisor (returning a
      // sign-preserving zero for float division, 0 for int division/rem) and
      // truncate toward zero for integers; Python's `/`, `//` and `%` instead
      // raise on zero and floor. Route through the prelude helpers so negative
      // operands and zero divisors match Gleam semantics.
      string_tree.new()
      |> string_tree.append(op_string)
      |> string_tree.append("(")
      |> string_tree.append_tree(generate_expression(left))
      |> string_tree.append(", ")
      |> string_tree.append_tree(generate_expression(right))
      |> string_tree.append(")")
    _ ->
      string_tree.new()
      |> string_tree.append_tree(generate_expression(left))
      |> string_tree.append(op_string)
      |> string_tree.append_tree(generate_expression(right))
  }
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

/// Python rejects decimal integer literals with leading zeros (e.g. `04` and
/// `0_4` are syntax errors) while Gleam permits them. Floats (`04.5`, `0_4.5`)
/// and base-prefixed integers (`0xFF`, `0b101`, `0o17`) are accepted by both
/// languages and pass through unchanged.
pub fn python_number_literal(literal: String) -> String {
  let is_float =
    string.contains(literal, ".")
    || string.contains(literal, "e")
    || string.contains(literal, "E")
  case is_base_prefixed(literal) {
    True -> literal
    False ->
      case is_float {
        True -> literal
        False -> strip_leading_zeroes(literal)
      }
  }
}

fn is_base_prefixed(literal: String) -> Bool {
  string.starts_with(literal, "0x")
  || string.starts_with(literal, "0X")
  || string.starts_with(literal, "0b")
  || string.starts_with(literal, "0B")
  || string.starts_with(literal, "0o")
  || string.starts_with(literal, "0O")
}

/// Remove leading zero digits (and any underscores separating them) from a
/// decimal integer literal, keeping at least one digit. `04` -> `4`, `0_4` ->
/// `4`, `0` -> `0`, `00` -> `0`, `1_000` -> `1_000`.
fn strip_leading_zeroes(literal: String) -> String {
  let zeroes =
    literal |> string.split("") |> list.drop_while(is_zero_or_underscore)
  case zeroes {
    [] -> "0"
    _ -> string.join(zeroes, "")
  }
}

fn is_zero_or_underscore(grapheme: String) -> Bool {
  grapheme == "0" || grapheme == "_"
}

// Builds a Gleam list literal as directly nested cons cells rather than going
// through `to_gleam_list`. `[a, b, ..rest]` becomes `GleamList(a, GleamList(b,
// rest))`, avoiding the intermediate Python list and the helper call. The tail
// (either `rest` or `EmptyGleamList()` for a non-spliced literal) is the
// innermost cell.
fn build_gleam_list(
  elements: List(python.Expression),
  tail: StringTree,
) -> StringTree {
  elements
  |> list.reverse
  |> list.fold(tail, fn(acc, element) {
    string_tree.from_string("GleamList(")
    |> string_tree.append_tree(generate_expression(element))
    |> string_tree.append(", ")
    |> string_tree.append_tree(acc)
    |> string_tree.append(")")
  })
}

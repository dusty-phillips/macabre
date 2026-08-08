import compiler/python
import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glexer

// A transformed pattern. Some patterns can't be expressed directly as Python
// match patterns (string concatenation and bitstring patterns), so they are
// turned into a wildcard pattern guarded by a boolean expression that binds
// the pattern's variables.
pub type PatternWithGuard {
  PatternWithGuard(
    pattern: python.Pattern,
    guard: option.Option(python.Expression),
    body_prepend: List(python.Statement),
  )
}

const bitstring_binds = "_bitstring_binds"

fn plain(pattern: python.Pattern) -> PatternWithGuard {
  PatternWithGuard(pattern, option.None, [])
}

// alternative patterns are sent to us a a list of list of patters.
// the outer list represents alternatives, so 1 | 2 -> becomes [[1], [2]]
// inner loop represents groupings (see `transform_grouped_pattrns`)
// so 1, 2 | 3, 5 becomes [1, 2], [3, 5]
// is_multi_subject indicates whether this case has more than one subject,
// which means the subject is a tuple and each grouped pattern must bind
// against its own slot of that tuple.
pub fn transform_alternative_patterns(
  patterns: List(List(glance.Pattern)),
  is_multi_subject: Bool,
  module_bindings: option.Option(dict.Dict(String, String)),
) -> List(PatternWithGuard) {
  case patterns {
    [] -> panic as "missing pattern"
    [one_alternative] -> [
      transform_grouped_patterns(
        one_alternative,
        is_multi_subject,
        module_bindings,
      ),
    ]
    multiple_alternatives -> {
      let transformed =
        multiple_alternatives
        |> list.map(fn(patterns) {
          transform_grouped_patterns(
            patterns,
            is_multi_subject,
            module_bindings,
          )
        })
      case
        list.any(transformed, fn(t) {
          t.guard != option.None || t.body_prepend != []
        })
      {
        // Alternative patterns that produce guards (e.g. bitstring or
        // concatenation patterns) can't be combined into a single python
        // pattern, so each alternative becomes its own match case.
        True -> transformed
        False -> [
          PatternWithGuard(
            list.map(transformed, fn(t) { t.pattern })
              |> python.PatternAlternate,
            option.None,
            [],
          ),
        ]
      }
    }
  }
}

// gleam distinguishes between groups of patterns (e.g: case 1, 2 {x, y -> ...})
// and glance sends those to us as a list of patterns. The python pattern
// for a group of patterns will always be a single tuple pattern.
fn transform_grouped_patterns(
  patterns: List(glance.Pattern),
  is_multi_subject: Bool,
  module_bindings: option.Option(dict.Dict(String, String)),
) -> PatternWithGuard {
  case patterns {
    [] -> panic as "missing pattern"
    [one_item] ->
      transform_pattern(
        one_item,
        case is_multi_subject {
          True -> option.Some(0)
          False -> option.None
        },
        module_bindings,
      )
    multiple_items -> {
      let transformed =
        multiple_items
        |> list.index_fold([], fn(acc, item, index) {
          list.prepend(
            acc,
            transform_pattern(item, option.Some(index), module_bindings),
          )
        })
        |> list.reverse
      PatternWithGuard(
        transformed
          |> list.map(fn(t) { t.pattern })
          |> python.PatternTuple,
        combine_pattern_guards(transformed),
        transformed
          |> list.map(fn(t) { t.body_prepend })
          |> list.flatten,
      )
    }
  }
}

fn transform_pattern(
  pattern: glance.Pattern,
  subject_index: option.Option(Int),
  module_bindings: option.Option(dict.Dict(String, String)),
) -> PatternWithGuard {
  case pattern {
    glance.PatternInt(_, str) -> plain(python.PatternInt(str))
    glance.PatternFloat(_, str) -> plain(python.PatternFloat(str))
    glance.PatternString(_, str) -> plain(python.PatternString(str))
    glance.PatternVariable(_, str) -> plain(python.PatternVariable(str))
    glance.PatternDiscard(_, "") -> plain(python.PatternWildcard)
    glance.PatternDiscard(_, str) -> plain(python.PatternVariable("_" <> str))
    glance.PatternTuple(_, patterns) ->
      list.map(patterns, simple_pattern(_, module_bindings))
      |> python.PatternTuple
      |> plain
    glance.PatternList(_, elems, rest) ->
      python.PatternList(
        list.map(elems, simple_pattern(_, module_bindings)),
        option.map(rest, simple_pattern(_, module_bindings)),
      )
      |> plain
    glance.PatternAssignment(_, pattern, name) ->
      python.PatternAssignment(simple_pattern(pattern, module_bindings), name)
      |> plain
    glance.PatternConcatenate(_, prefix, prefix_name, rest_name) ->
      transform_concatenate_pattern(
        prefix,
        prefix_name,
        rest_name,
        subject_index,
      )
    glance.PatternBitString(_, segments) ->
      transform_bitstring_pattern(segments, subject_index)
    glance.PatternVariant(_, module, constructor, arguments, _) ->
      list.map(arguments, transform_pattern_field(_, module_bindings))
      |> python.PatternConstructor(
        option.map(module, fn(module_name) {
          pattern_module_binding(module_bindings, module_name)
        }),
        constructor,
        _,
      )
      |> plain
  }
}

// A pattern's module reference is emitted with the same (possibly renamed)
// binding as module-qualified expressions, so `token.EndOfFile()` keeps
// resolving when the import binding had to be renamed.
fn pattern_module_binding(
  module_bindings: option.Option(dict.Dict(String, String)),
  module_name: String,
) -> String {
  case module_bindings {
    option.None -> module_name
    option.Some(bindings) ->
      case dict.get(bindings, module_name) {
        Ok(binding) -> binding
        Error(_) -> module_name
      }
  }
}

// Converts a nested pattern, which cannot have a guard, into a plain python
// pattern.
fn simple_pattern(
  pattern: glance.Pattern,
  module_bindings: option.Option(dict.Dict(String, String)),
) -> python.Pattern {
  case transform_pattern(pattern, option.None, module_bindings) {
    PatternWithGuard(inner, option.None, []) -> inner
    _ ->
      panic as "Concatenation and bitstring patterns cannot be nested in other patterns"
  }
}

// Combines the guards of several grouped patterns into a single guard,
// joining them with `and`.
fn combine_pattern_guards(
  transformed: List(PatternWithGuard),
) -> option.Option(python.Expression) {
  list.fold(transformed, option.None, fn(acc, t) {
    case acc, t.guard {
      option.None, option.None -> option.None
      option.None, option.Some(guard) -> option.Some(guard)
      option.Some(guard), option.None -> option.Some(guard)
      option.Some(a), option.Some(b) ->
        option.Some(python.BinaryOperator(python.And, a, b))
    }
  })
}

// The subject expression a guard-bearing pattern should be matched against.
// For a single-subject case this is the case subject directly; for a
// multi-subject case the subjects are combined into a tuple so each pattern
// references its own slot of that tuple.
fn subject_expression(subject_index: option.Option(Int)) -> python.Expression {
  case subject_index {
    option.None -> python.Variable("_case_subject")
    option.Some(index) ->
      python.TupleIndex(python.Variable("_case_subject"), index)
  }
}

fn transform_pattern_field(
  field: glance.Field(glance.Pattern),
  module_bindings: option.Option(dict.Dict(String, String)),
) -> python.Field(python.Pattern) {
  case field {
    glance.LabelledField(label, _, item) ->
      python.LabelledField(label, simple_pattern(item, module_bindings))
    glance.UnlabelledField(item) ->
      python.UnlabelledField(simple_pattern(item, module_bindings))
    glance.ShorthandField(label, _) ->
      python.LabelledField(label, python.PatternVariable(label))
  }
}

// A concatenation pattern looks like `"hello" <> rest`, matching strings that
// begin with a literal prefix. There's no way to express this as a Python
// match pattern, so we use a wildcard pattern with a guard that checks the
// prefix and binds the remainder.
fn transform_concatenate_pattern(
  prefix: String,
  prefix_name: option.Option(glance.AssignmentName),
  rest_name: glance.AssignmentName,
  subject_index: option.Option(Int),
) -> PatternWithGuard {
  let subject = subject_expression(subject_index)
  let starts_with =
    python.Call(python.FieldAccess(subject, "startswith"), [
      python.UnlabelledField(python.String(prefix)),
    ])
  // The prefix is stored by glance in its escaped source form (e.g. `\\n`),
  // so it must be unescaped before measuring the number of characters the
  // slice needs to skip.
  let prefix_length =
    prefix
    |> glexer.unescape_string
    |> result.unwrap(prefix)
    |> string.length
  let bind_rest =
    python.IsNotNone(python.AssignmentExpression(
      assignment_name(rest_name),
      python.Slice(
        subject,
        python.Number(int.to_string(prefix_length)),
        option.None,
      ),
    ))
  let guard =
    prefix_name
    |> option.map(fn(name) {
      python.BinaryOperator(
        python.And,
        python.BinaryOperator(
          python.And,
          python.AssignmentExpression(
            assignment_name(name),
            python.String(prefix),
          ),
          starts_with,
        ),
        bind_rest,
      )
    })
    |> option.unwrap(python.BinaryOperator(python.And, starts_with, bind_rest))
  PatternWithGuard(python.PatternWildcard, option.Some(guard), [])
}

// A bitstring pattern like `<<code:8, rest:bit_string>>`. We delegate to a
// runtime helper `gleam_match_bitstring` which returns None when the subject
// doesn't match, or a tuple of the bound variables when it does. The helper
// is guarded by `is not None` and the bindings are unpacked at the top of the
// match case body.
fn transform_bitstring_pattern(
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  subject_index: option.Option(Int),
) -> PatternWithGuard {
  let binds_variable = case subject_index {
    option.None -> bitstring_binds
    option.Some(index) -> bitstring_binds <> "_" <> int.to_string(index)
  }
  let segment_arguments =
    segments
    |> list.map(fn(segment) {
      let #(pattern, options) = segment
      let bind_kind = case pattern {
        glance.PatternVariable(_, name) -> #("variable", python.String(name))
        glance.PatternAssignment(_, _, name) -> #(
          "variable",
          python.String(name),
        )
        glance.PatternDiscard(_, _) -> #("wildcard", python.String(""))
        glance.PatternInt(_, value) -> #("int", python.String(value))
        glance.PatternString(_, value) -> #("string", python.String(value))
        _ -> panic as "Unsupported bitstring pattern"
      }
      let #(kind, payload) = bind_kind
      python.Tuple([
        python.String(kind),
        payload,
        ..list.map(options, transform_bitstring_pattern_option)
      ])
    })

  let guard =
    python.IsNotNone(python.AssignmentExpression(
      binds_variable,
      python.Call(python.Variable("gleam_match_bitstring"), [
        python.UnlabelledField(subject_expression(subject_index)),
        ..list.map(segment_arguments, python.UnlabelledField)
      ]),
    ))

  let binds =
    segments
    |> list.map(fn(segment) { collect_binds(segment.0) })
    |> list.flatten

  let body_prepend = case binds {
    [] -> []
    [single] -> [
      python.SimpleAssignment(
        single,
        python.TupleIndex(python.Variable(binds_variable), 0),
      ),
    ]
    multiple -> [
      python.MultipleAssignment(multiple, python.Variable(binds_variable)),
    ]
  }

  PatternWithGuard(python.PatternWildcard, option.Some(guard), body_prepend)
}

fn transform_bitstring_pattern_option(
  option: glance.BitStringSegmentOption(glance.BitArraySize),
) -> python.Expression {
  let #(name, payload) = case option {
    glance.BytesOption -> #("BitString", python.Nil)
    glance.BitsOption -> #("BitString", python.Nil)
    glance.IntOption -> #("Int", python.Nil)
    glance.FloatOption -> #("Float", python.Nil)
    glance.Utf8Option -> #("Utf8", python.Nil)
    glance.Utf16Option -> #("Utf16", python.Nil)
    glance.Utf32Option -> #("Utf32", python.Nil)
    glance.Utf8CodepointOption -> #("Utf8Codepoint", python.Nil)
    glance.Utf16CodepointOption -> #("Utf16Codepoint", python.Nil)
    glance.Utf32CodepointOption -> #("Utf32Codepoint", python.Nil)
    glance.LittleOption -> #("Little", python.Nil)
    glance.BigOption -> #("Big", python.Nil)
    glance.NativeOption -> #("Native", python.Nil)
    glance.SizeOption(size) -> #(
      "SizeValue",
      python.Number(int.to_string(size)),
    )
    glance.SizeValueOption(bit_array_size) -> #(
      "SizeValue",
      transform_bit_array_size(bit_array_size),
    )
    glance.UnitOption(size) -> #("Unit", python.Number(int.to_string(size)))
    glance.SignedOption | glance.UnsignedOption ->
      panic as "Signed and unsigned options are not supported in bitstring patterns yet"
  }
  python.Tuple([python.String(name), payload])
}

fn transform_bit_array_size(size: glance.BitArraySize) -> python.Expression {
  case size {
    glance.BitArraySizeInt(_, value) -> python.Number(value)
    glance.BitArraySizeVariable(_, name) -> python.Variable(name)
    glance.BitArraySizeBlock(_, inner) -> transform_bit_array_size(inner)
    glance.BitArraySizeBinaryOperator(_, operator, left, right) -> {
      let op = case operator {
        glance.BitArraySizeAdd -> python.Add
        glance.BitArraySizeSubtract -> python.Subtract
        glance.BitArraySizeMultiply -> python.Multiply
        glance.BitArraySizeDivide -> python.DivideInt
        glance.BitArraySizeRemainder -> python.Modulo
      }
      python.BinaryOperator(
        op,
        transform_bit_array_size(left),
        transform_bit_array_size(right),
      )
    }
  }
}

// Collects the variables bound by a pattern, in traversal order. Used to
// unpack the result of destructuring and bitstring matches.
pub fn collect_binds(pattern: glance.Pattern) -> List(String) {
  case pattern {
    glance.PatternVariable(_, name) -> [name]
    glance.PatternDiscard(_, "") -> []
    glance.PatternDiscard(_, name) -> ["_" <> name]
    glance.PatternAssignment(_, inner, name) -> [name, ..collect_binds(inner)]
    glance.PatternTuple(_, patterns) ->
      list.flatten(list.map(patterns, collect_binds))
    glance.PatternList(_, elems, rest) ->
      list.flatten(list.map(elems, collect_binds))
      |> list.append(option.unwrap(option.map(rest, collect_binds), []))
    glance.PatternVariant(_, _, _, fields, _) ->
      list.flatten(
        list.map(fields, fn(field) {
          case field {
            glance.LabelledField(_, _, item) -> collect_binds(item)
            glance.UnlabelledField(item) -> collect_binds(item)
            glance.ShorthandField(label, _) -> [label]
          }
        }),
      )
    glance.PatternConcatenate(_, _, prefix_name, rest_name) ->
      option.unwrap(option.map(prefix_name, collect_assignment_name), [])
      |> list.append([assignment_name(rest_name)])
    glance.PatternBitString(_, segments) ->
      list.flatten(list.map(segments, fn(segment) { collect_binds(segment.0) }))
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..) -> []
  }
}

fn collect_assignment_name(name: glance.AssignmentName) -> List(String) {
  case name {
    glance.Named(str) -> [str]
    glance.Discarded(_) -> []
  }
}

fn assignment_name(name: glance.AssignmentName) -> String {
  case name {
    glance.Named(str) -> str
    glance.Discarded("") -> "_"
    glance.Discarded(str) -> "_" <> str
  }
}

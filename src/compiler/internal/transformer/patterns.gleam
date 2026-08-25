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
    // Names bound by a bitstring pattern through the walrus tuple in the
    // guard. A clause guard (`case <<b, ..>> if b > 5`) references these
    // names, but they only exist as `binds_variable[index]`, so the clause
    // guard must rewrite those references to tuple index accesses. Each
    // entry is #(name, binds_variable, tuple_index).
    guard_binds: List(#(String, String, Int)),
  )
}

const bitstring_binds = "_bitstring_binds"

// Fresh variable names for patterns that can't be expressed directly in
// Python (string concatenation and bitstring patterns) when they appear
// nested inside another pattern. Each match case has its own scope, so the
// counter only needs to be unique within a case.
const nested_subject_binds = "_nested_subject_"

const nested_bitstring_binds = "_nested_bitstring_binds_"

fn plain(pattern: python.Pattern) -> PatternWithGuard {
  PatternWithGuard(pattern, option.None, [], [])
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
      // The counter for fresh variable names is shared across the items in a
      // group, since a group combines into a single match case scope.
      let #(transformed, _) =
        multiple_items
        |> list.index_fold(#([], 0), fn(acc, item, index) {
          let #(items, counter) = acc
          let #(pattern_result, next_counter) =
            transform_pattern_indexed(
              item,
              option.Some(index),
              module_bindings,
              counter,
            )
          #(list.prepend(items, pattern_result), next_counter)
        })
      let transformed = list.reverse(transformed)
      PatternWithGuard(
        transformed
          |> list.map(fn(t) { t.pattern })
          |> python.PatternTuple,
        combine_pattern_guards(transformed),
        transformed
          |> list.map(fn(t) { t.body_prepend })
          |> list.flatten,
        transformed
          |> list.map(fn(t) { t.guard_binds })
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
  let #(result, _) =
    transform_pattern_indexed(pattern, subject_index, module_bindings, 0)
  result
}

// Like `transform_pattern`, but threads a counter through the transformation.
// The counter generates fresh variable names for guarded sub-patterns that
// can't be expressed in Python match patterns; see `transform_nested_pattern`.
fn transform_pattern_indexed(
  pattern: glance.Pattern,
  subject_index: option.Option(Int),
  module_bindings: option.Option(dict.Dict(String, String)),
  index: Int,
) -> #(PatternWithGuard, Int) {
  case pattern {
    glance.PatternInt(_, str) -> #(plain(python.PatternInt(str)), index)
    glance.PatternFloat(_, str) -> #(plain(python.PatternFloat(str)), index)
    glance.PatternString(_, str) -> #(plain(python.PatternString(str)), index)
    glance.PatternVariable(_, str) -> #(
      plain(python.PatternVariable(str)),
      index,
    )
    glance.PatternDiscard(_, "") -> #(plain(python.PatternWildcard), index)
    glance.PatternDiscard(_, _str) ->
      // A `_name` discard binds nothing and is never referenced, so it maps
      // to Python's anonymous `_` wildcard. Emitting `_name` as a named
      // pattern variable would collide when the same discard appears twice
      // in one pattern (Python forbids rebinding a name in a single match).
      #(plain(python.PatternVariable("_")), index)
    glance.PatternTuple(_, patterns) ->
      transform_nested_patterns(patterns, index, module_bindings)
      |> fn(result) {
        let #(sub_patterns, guards, prepends, guard_binds, next_index) = result
        #(
          PatternWithGuard(
            python.PatternTuple(sub_patterns),
            combine_guard_list(guards),
            prepends,
            guard_binds,
          ),
          next_index,
        )
      }
    glance.PatternList(_, elems, rest) ->
      transform_nested_patterns(elems, index, module_bindings)
      |> fn(result) {
        let #(sub_patterns, guards, prepends, guard_binds, next_index) = result
        case rest {
          option.None -> #(
            PatternWithGuard(
              python.PatternList(sub_patterns, option.None),
              combine_guard_list(guards),
              prepends,
              guard_binds,
            ),
            next_index,
          )
          option.Some(rest_pattern) -> {
            let #(rest_sub, rest_guards, rest_prepends, rest_binds, after_rest) =
              transform_nested_pattern(
                rest_pattern,
                next_index,
                module_bindings,
                option.None,
              )
            #(
              PatternWithGuard(
                python.PatternList(sub_patterns, option.Some(rest_sub)),
                combine_guard_list(list.append(guards, rest_guards)),
                list.append(prepends, rest_prepends),
                list.append(guard_binds, rest_binds),
              ),
              after_rest,
            )
          }
        }
      }
    glance.PatternAssignment(_, inner, name) -> {
      let subject = name
      // A discarded name can't be used as a guard subject since the pattern
      // doesn't bind it, so a fresh variable is used instead.
      let preferred_subject = case subject {
        "_" -> option.None
        other -> option.Some(other)
      }
      // Only a bare concatenation or bitstring pattern can bind its subject
      // to the assignment name; for a structured inner pattern the name
      // binds the whole value, so guarded leaves need their own variables.
      let is_leaf = case inner {
        glance.PatternConcatenate(..) | glance.PatternBitString(..) -> True
        _ -> False
      }
      let leaf_subject = case is_leaf {
        True -> preferred_subject
        False -> option.None
      }
      let #(sub, guards, prepends, guard_binds, next_index) =
        transform_nested_pattern(inner, index, module_bindings, leaf_subject)
      let pattern = case guards, prepends {
        [], [] -> python.PatternAssignment(sub, subject)
        _, _ ->
          case sub {
            // A bare leaf already binds its subject to the assignment name,
            // so no extra `as` binding is needed.
            python.PatternVariable(_) -> sub
            _ -> python.PatternAssignment(sub, subject)
          }
      }
      #(
        PatternWithGuard(
          pattern,
          combine_guard_list(guards),
          prepends,
          guard_binds,
        ),
        next_index,
      )
    }
    glance.PatternConcatenate(_, prefix, prefix_name, rest_name) -> #(
      transform_concatenate_pattern(
        prefix,
        prefix_name,
        rest_name,
        subject_index,
      ),
      index,
    )
    glance.PatternBitString(_, segments) -> #(
      transform_bitstring_pattern(segments, subject_index),
      index,
    )
    glance.PatternVariant(_, module, constructor, arguments, _) ->
      transform_variant_fields(arguments, index, module_bindings)
      |> fn(result) {
        let #(fields, guards, prepends, guard_binds, next_index) = result
        #(
          PatternWithGuard(
            python.PatternConstructor(
              option.map(module, fn(module_name) {
                pattern_module_binding(module_bindings, module_name)
              }),
              constructor,
              fields,
            ),
            combine_guard_list(guards),
            prepends,
            guard_binds,
          ),
          next_index,
        )
      }
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

// Transforms a pattern nested inside another pattern (a list element, tuple
// field, constructor argument, or assignment). Nested patterns can't add a
// guard to the case, so patterns that need one (string concatenation and
// bitstring patterns) are bound to a variable in the pattern instead, and
// the guard (and any body statements) they require are returned for the case
// level to combine. `preferred_subject` is the name the pattern position will
// bind (an `as` name) when the nested pattern is a bare concatenation or
// bitstring pattern, so no extra variable is needed.
fn transform_nested_pattern(
  pattern: glance.Pattern,
  index: Int,
  module_bindings: option.Option(dict.Dict(String, String)),
  preferred_subject: option.Option(String),
) -> #(
  python.Pattern,
  List(python.Expression),
  List(python.Statement),
  List(#(String, String, Int)),
  Int,
) {
  case pattern {
    glance.PatternInt(_, str) -> #(python.PatternInt(str), [], [], [], index)
    glance.PatternFloat(_, str) -> #(
      python.PatternFloat(str),
      [],
      [],
      [],
      index,
    )
    glance.PatternString(_, str) -> #(
      python.PatternString(str),
      [],
      [],
      [],
      index,
    )
    glance.PatternVariable(_, str) -> #(
      python.PatternVariable(str),
      [],
      [],
      [],
      index,
    )
    glance.PatternDiscard(_, "") -> #(python.PatternWildcard, [], [], [], index)
    glance.PatternDiscard(_, _str) ->
      // A `_name` discard maps to Python's anonymous `_` wildcard (reusable
      // across one pattern); see the note in `transform_pattern_indexed`.
      #(python.PatternVariable("_"), [], [], [], index)
    glance.PatternTuple(_, patterns) ->
      transform_nested_patterns(patterns, index, module_bindings)
      |> fn(result) {
        let #(sub_patterns, guards, prepends, guard_binds, next_index) = result
        #(
          python.PatternTuple(sub_patterns),
          guards,
          prepends,
          guard_binds,
          next_index,
        )
      }
    glance.PatternList(_, elems, rest) -> {
      let #(sub_patterns, guards, prepends, guard_binds, next_index) =
        transform_nested_patterns(elems, index, module_bindings)
      case rest {
        option.None -> #(
          python.PatternList(sub_patterns, option.None),
          guards,
          prepends,
          guard_binds,
          next_index,
        )
        option.Some(rest_pattern) -> {
          let #(rest_sub, rest_guards, rest_prepends, rest_binds, after_rest) =
            transform_nested_pattern(
              rest_pattern,
              next_index,
              module_bindings,
              option.None,
            )
          #(
            python.PatternList(sub_patterns, option.Some(rest_sub)),
            list.append(guards, rest_guards),
            list.append(prepends, rest_prepends),
            list.append(guard_binds, rest_binds),
            after_rest,
          )
        }
      }
    }
    glance.PatternAssignment(_, inner, name) -> {
      let subject = name
      let preferred = case subject {
        "_" -> option.None
        other -> option.Some(other)
      }
      let leaf = case inner {
        glance.PatternConcatenate(..) | glance.PatternBitString(..) -> True
        _ -> False
      }
      let subject_preference = case leaf {
        True -> preferred
        False -> option.None
      }
      let #(sub, guards, prepends, guard_binds, next_index) =
        transform_nested_pattern(
          inner,
          index,
          module_bindings,
          subject_preference,
        )
      let pattern = case guards, prepends {
        [], [] -> python.PatternAssignment(sub, subject)
        _, _ ->
          case sub {
            python.PatternVariable(_) -> sub
            _ -> python.PatternAssignment(sub, subject)
          }
      }
      #(pattern, guards, prepends, guard_binds, next_index)
    }
    glance.PatternConcatenate(_, prefix, prefix_name, rest_name) -> {
      let #(subject, next_index) = nested_subject(index, preferred_subject)
      let guard =
        concatenate_guard(
          prefix,
          prefix_name,
          rest_name,
          python.Variable(subject),
        )
      #(python.PatternVariable(subject), [guard], [], [], next_index)
    }
    glance.PatternBitString(_, segments) -> {
      let #(subject, next_index) = nested_subject(index, preferred_subject)
      let binds_variable = nested_bitstring_binds <> int.to_string(next_index)
      let guard =
        bitstring_guard(segments, python.Variable(subject), binds_variable)
      let prepends = bitstring_prepends(segments, binds_variable)
      #(
        python.PatternVariable(subject),
        [guard],
        prepends,
        bitstring_guard_binds(segments, binds_variable),
        next_index + 1,
      )
    }
    glance.PatternVariant(_, module, constructor, arguments, _) ->
      transform_variant_fields(arguments, index, module_bindings)
      |> fn(result) {
        let #(fields, guards, prepends, guard_binds, next_index) = result
        #(
          python.PatternConstructor(
            option.map(module, fn(module_name) {
              pattern_module_binding(module_bindings, module_name)
            }),
            constructor,
            fields,
          ),
          guards,
          prepends,
          guard_binds,
          next_index,
        )
      }
  }
}

// The name of the variable that a nested pattern's subject is bound to, or a
// fresh name derived from `index` when the pattern doesn't bind one itself.
fn nested_subject(
  index: Int,
  preferred_subject: option.Option(String),
) -> #(String, Int) {
  case preferred_subject {
    option.Some(subject) -> #(subject, index)
    option.None -> #(nested_subject_binds <> int.to_string(index), index + 1)
  }
}

// Transforms a list of nested patterns, threading the fresh-variable counter
// through each one.
fn transform_nested_patterns(
  patterns: List(glance.Pattern),
  index: Int,
  module_bindings: option.Option(dict.Dict(String, String)),
) -> #(
  List(python.Pattern),
  List(python.Expression),
  List(python.Statement),
  List(#(String, String, Int)),
  Int,
) {
  patterns
  |> list.index_fold(#([], [], [], [], index), fn(acc, item, _index) {
    let #(sub_patterns, guards, prepends, guard_binds, index) = acc
    let #(sub, sub_guards, sub_prepends, sub_binds, next_index) =
      transform_nested_pattern(item, index, module_bindings, option.None)
    #(
      list.append(sub_patterns, [sub]),
      list.append(guards, sub_guards),
      list.append(prepends, sub_prepends),
      list.append(guard_binds, sub_binds),
      next_index,
    )
  })
}

// Transforms the fields of a constructor pattern, threading the
// fresh-variable counter and hoisting guards and body statements.
fn transform_variant_fields(
  fields: List(glance.Field(glance.Pattern)),
  index: Int,
  module_bindings: option.Option(dict.Dict(String, String)),
) -> #(
  List(python.Field(python.Pattern)),
  List(python.Expression),
  List(python.Statement),
  List(#(String, String, Int)),
  Int,
) {
  fields
  |> list.index_fold(#([], [], [], [], index), fn(acc, field, _index) {
    let #(fields, guards, prepends, guard_binds, index) = acc
    case field {
      glance.LabelledField(label, _, item) -> {
        let #(sub, sub_guards, sub_prepends, sub_binds, next_index) =
          transform_nested_pattern(item, index, module_bindings, option.None)
        #(
          list.append(fields, [python.LabelledField(label, sub)]),
          list.append(guards, sub_guards),
          list.append(prepends, sub_prepends),
          list.append(guard_binds, sub_binds),
          next_index,
        )
      }
      glance.UnlabelledField(item) -> {
        let #(sub, sub_guards, sub_prepends, sub_binds, next_index) =
          transform_nested_pattern(item, index, module_bindings, option.None)
        #(
          list.append(fields, [python.UnlabelledField(sub)]),
          list.append(guards, sub_guards),
          list.append(prepends, sub_prepends),
          list.append(guard_binds, sub_binds),
          next_index,
        )
      }
      glance.ShorthandField(label, _) -> #(
        list.append(fields, [
          python.LabelledField(label, python.PatternVariable(label)),
        ]),
        guards,
        prepends,
        guard_binds,
        index,
      )
    }
  })
}

// Combines a list of guard expressions into a single guard, joining them
// with `and`.
fn combine_guard_list(
  guards: List(python.Expression),
) -> option.Option(python.Expression) {
  case guards {
    [] -> option.None
    [first, ..rest] ->
      option.Some(
        list.fold(rest, first, fn(acc, guard) {
          python.BinaryOperator(python.And, acc, guard)
        }),
      )
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
  let guard =
    concatenate_guard(
      prefix,
      prefix_name,
      rest_name,
      subject_expression(subject_index),
    )
  PatternWithGuard(python.PatternWildcard, option.Some(guard), [], [])
}

// The guard for a concatenation pattern, checking that `subject` begins with
// the literal prefix and binding the remainder to `rest_name`. The subject
// can be the case subject or a variable bound by the enclosing pattern.
fn concatenate_guard(
  prefix: String,
  prefix_name: option.Option(glance.AssignmentName),
  rest_name: glance.AssignmentName,
  subject: python.Expression,
) -> python.Expression {
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
  let guard =
    bitstring_guard(segments, subject_expression(subject_index), binds_variable)
  let body_prepend = bitstring_prepends(segments, binds_variable)

  PatternWithGuard(
    python.PatternWildcard,
    option.Some(guard),
    body_prepend,
    bitstring_guard_binds(segments, binds_variable),
  )
}

// The pattern-bound names of a bitstring pattern in tuple order, for
// rewriting clause-guard references (`case <<b, ..>> if b > 5`) to tuple
// index accesses of the walrus variable.
fn bitstring_guard_binds(
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  binds_variable: String,
) -> List(#(String, String, Int)) {
  segments
  |> list.map(fn(segment) { collect_binds(segment.0) })
  |> list.flatten
  |> list.index_map(fn(name, index) { #(name, binds_variable, index) })
}

// The guard for a bitstring pattern: the subject is passed to the
// `gleam_match_bitstring` runtime helper and the resulting tuple of bound
// variables is assigned to `binds_variable`.
fn bitstring_guard(
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  subject: python.Expression,
  binds_variable: String,
) -> python.Expression {
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

  python.IsNotNone(python.AssignmentExpression(
    binds_variable,
    python.Call(python.Variable("gleam_match_bitstring"), [
      python.UnlabelledField(subject),
      ..list.map(segment_arguments, python.UnlabelledField)
    ]),
  ))
}

// The statements that unpack the tuple of bound variables produced by a
// bitstring pattern guard.
fn bitstring_prepends(
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
  binds_variable: String,
) -> List(python.Statement) {
  let binds =
    segments
    |> list.map(fn(segment) { collect_binds(segment.0) })
    |> list.flatten

  case binds {
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
}

fn transform_bitstring_pattern_option(
  option: glance.BitStringSegmentOption(glance.BitArraySize),
) -> python.Expression {
  let #(name, payload) = case option {
    glance.BytesOption -> #("Bytes", python.Nil)
    glance.BitsOption -> #("Bits", python.Nil)
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
    glance.SignedOption -> #("Signed", python.Nil)
    glance.UnsignedOption -> #("Unsigned", python.Nil)
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
    glance.PatternDiscard(_, _name) -> []
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

// Rewrites references to bitstring-bound names in a clause guard. The
// bitstring pattern's guard binds its variables into a tuple via a walrus
// (`_bitstring_binds`); a clause guard like `case <<b, ..>> if b > 5` refers
// to `b` directly, but `b` only exists as `_bitstring_binds[0]`, so the
// reference is rewritten to a tuple index access.
pub fn rewrite_guard_binds(
  expression: python.Expression,
  guard_binds: List(#(String, String, Int)),
) -> python.Expression {
  case expression {
    python.Variable(name) ->
      case
        list.find(guard_binds, fn(bind) {
          let #(bind_name, _, _) = bind
          bind_name == name
        })
      {
        Ok(#(_, binds_variable, index)) ->
          python.TupleIndex(python.Variable(binds_variable), index)
        Error(_) -> expression
      }
    python.String(_)
    | python.Number(_)
    | python.Bool(_)
    | python.Nil
    | python.ModuleRef(_) -> expression
    python.Tuple(elements) ->
      python.Tuple(list.map(elements, rewrite_guard_binds(_, guard_binds)))
    python.Negate(inner) ->
      python.Negate(rewrite_guard_binds(inner, guard_binds))
    python.Not(inner) -> python.Not(rewrite_guard_binds(inner, guard_binds))
    python.Panic(inner) -> python.Panic(rewrite_guard_binds(inner, guard_binds))
    python.Todo(inner) -> python.Todo(rewrite_guard_binds(inner, guard_binds))
    python.Lambda(args, body) ->
      python.Lambda(args, rewrite_guard_binds(body, guard_binds))
    python.List(elements) ->
      python.List(list.map(elements, rewrite_guard_binds(_, guard_binds)))
    python.ListWithRest(elements, rest) ->
      python.ListWithRest(
        list.map(elements, rewrite_guard_binds(_, guard_binds)),
        rewrite_guard_binds(rest, guard_binds),
      )
    python.TupleIndex(tuple, index) ->
      python.TupleIndex(rewrite_guard_binds(tuple, guard_binds), index)
    python.FieldAccess(container, label) ->
      python.FieldAccess(rewrite_guard_binds(container, guard_binds), label)
    python.Call(function, arguments) ->
      python.Call(
        rewrite_guard_binds(function, guard_binds),
        list.map(arguments, fn(field) {
          case field {
            python.LabelledField(label, item) ->
              python.LabelledField(
                label,
                rewrite_guard_binds(item, guard_binds),
              )
            python.UnlabelledField(item) ->
              python.UnlabelledField(rewrite_guard_binds(item, guard_binds))
          }
        }),
      )
    python.RecordUpdate(record, fields) ->
      python.RecordUpdate(
        rewrite_guard_binds(record, guard_binds),
        list.map(fields, fn(field) {
          case field {
            python.LabelledField(label, item) ->
              python.LabelledField(
                label,
                rewrite_guard_binds(item, guard_binds),
              )
            python.UnlabelledField(item) ->
              python.UnlabelledField(rewrite_guard_binds(item, guard_binds))
          }
        }),
      )
    python.BinaryOperator(name, left, right) ->
      python.BinaryOperator(
        name,
        rewrite_guard_binds(left, guard_binds),
        rewrite_guard_binds(right, guard_binds),
      )
    python.Slice(container, start, end) ->
      python.Slice(
        rewrite_guard_binds(container, guard_binds),
        rewrite_guard_binds(start, guard_binds),
        option.map(end, rewrite_guard_binds(_, guard_binds)),
      )
    python.AssignmentExpression(name, value) ->
      python.AssignmentExpression(name, rewrite_guard_binds(value, guard_binds))
    python.IsNotNone(inner) ->
      python.IsNotNone(rewrite_guard_binds(inner, guard_binds))
    python.BitString(segments) ->
      python.BitString(
        list.map(segments, fn(segment) {
          let python.BitStringSegment(value, options) = segment
          python.BitStringSegment(
            rewrite_guard_binds(value, guard_binds),
            options,
          )
        }),
      )
    python.Dict(entries) ->
      python.Dict(
        list.map(entries, fn(entry) {
          let #(key, value) = entry
          #(key, rewrite_guard_binds(value, guard_binds))
        }),
      )
  }
}

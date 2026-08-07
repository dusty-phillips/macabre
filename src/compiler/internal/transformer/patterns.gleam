import compiler/python
import glance
import gleam/list
import gleam/option

// alternative patterns are sent to us a a list of list of patters.
// the outer list represents alternatives, so 1 | 2 -> becomes [[1], [2]]
// inner loop represents groupings (see `transform_grouped_pattrns`)
// so 1, 2 | 3, 5 becomes [1, 2], [3, 5]
pub fn transform_alternative_patterns(
  patterns: List(List(glance.Pattern)),
) -> python.Pattern {
  case patterns {
    [] -> panic as "missing pattern"
    [one_alternative] -> transform_grouped_patterns(one_alternative)
    multiple_alternatives ->
      python.PatternAlternate(list.map(
        multiple_alternatives,
        transform_grouped_patterns,
      ))
  }
}

// gleam distinguishes between groups of patterns (e.g: case 1, 2 {x, y -> ...})
// and glance sends those to us as a list of patterns. The python pattern
// for a group of patterns will always be a single tuple pattern.
fn transform_grouped_patterns(
  patterns: List(glance.Pattern),
) -> python.Pattern {
  case patterns {
    [] -> panic as "missing pattern"
    [one_item] -> transform_pattern(one_item)
    multiple_items ->
      transform_pattern(glance.PatternTuple(glance.Span(0, 0), multiple_items))
  }
}

fn transform_pattern(pattern: glance.Pattern) -> python.Pattern {
  case pattern {
    glance.PatternInt(_, str) -> python.PatternInt(str)
    glance.PatternFloat(_, str) -> python.PatternFloat(str)
    glance.PatternString(_, str) -> python.PatternString(str)
    glance.PatternVariable(_, str) -> python.PatternVariable(str)
    glance.PatternDiscard(_, "") -> python.PatternWildcard
    glance.PatternDiscard(_, str) -> python.PatternVariable("_" <> str)
    glance.PatternTuple(_, patterns) ->
      python.PatternTuple(list.map(patterns, transform_pattern))
    glance.PatternList(_, elems, rest) ->
      python.PatternList(
        list.map(elems, transform_pattern),
        option.map(rest, transform_pattern),
      )
    glance.PatternAssignment(_, pattern, name) ->
      python.PatternAssignment(transform_pattern(pattern), name)
    glance.PatternConcatenate(_, _, _, _) ->
      todo as "concatenate patterns are not supported yet"
    glance.PatternBitString(..) ->
      todo as "bitstring patterns are not supported yet"
    glance.PatternVariant(_, module, constructor, arguments, _) ->
      python.PatternConstructor(
        module,
        constructor,
        list.map(arguments, fn(field) {
          case field {
            glance.LabelledField(label, _, item) ->
              python.LabelledField(label, transform_pattern(item))
            glance.UnlabelledField(item) ->
              python.UnlabelledField(transform_pattern(item))
            glance.ShorthandField(_, _) ->
              todo as "shorthand fields not supported yet"
          }
        }),
      )
  }
}

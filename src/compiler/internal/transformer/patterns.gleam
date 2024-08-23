import compiler/python
import glance
import gleam/list
import pprint

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
fn transform_grouped_patterns(patterns: List(glance.Pattern)) -> python.Pattern {
  case patterns {
    [] -> panic as "missing pattern"
    [one_item] -> transform_pattern(one_item)
    multiple_items -> transform_pattern(glance.PatternTuple(multiple_items))
  }
}

fn transform_pattern(pattern: glance.Pattern) -> python.Pattern {
  case pattern {
    glance.PatternInt(str) -> python.PatternInt(str)
    glance.PatternFloat(str) -> python.PatternFloat(str)
    glance.PatternString(str) -> python.PatternString(str)
    glance.PatternVariable(str) -> python.PatternVariable(str)
    glance.PatternDiscard("") -> python.PatternWildcard
    glance.PatternDiscard(str) -> python.PatternVariable("_" <> str)
    glance.PatternTuple(patterns) ->
      python.PatternTuple(list.map(patterns, transform_pattern))
    glance.PatternList(_, _) -> todo as "list patterns are not supported yet"
    glance.PatternAssignment(pattern, name) ->
      python.PatternAssignment(transform_pattern(pattern), name)
    glance.PatternConcatenate(_, _) ->
      todo as "concatenate patterns are not supported yet"
    glance.PatternBitString(..) ->
      todo as "bitstring patterns are not supported yet"
    glance.PatternConstructor(..) ->
      todo as "record constructor patterns are not supported yet"
  }
}

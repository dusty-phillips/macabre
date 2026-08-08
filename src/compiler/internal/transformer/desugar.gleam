import glance
import gleam/int
import gleam/list
import gleam/option

pub fn desugar_use(block: List(glance.Statement)) -> List(glance.Statement) {
  let #(no_use, starts_with_use) = list.split_while(block, is_not_use_statement)
  case starts_with_use {
    [] -> block
    [
      glance.Use(location, patterns, glance.Call(_, function, arguments)),
      ..tail
    ] -> {
      let #(parameters, destructures) = patterns_to_args(location, patterns)
      list.append(no_use, [
        glance.Expression(glance.Call(
          location,
          function,
          list.append(arguments, [
            glance.UnlabelledField(glance.Fn(
              location,
              parameters,
              // todo: figure out return type
              option.None,
              list.append(destructures, desugar_use(tail)),
            )),
          ]),
        )),
      ])
    }
    [glance.Use(location, patterns, function), ..tail] -> {
      let #(parameters, destructures) = patterns_to_args(location, patterns)
      list.append(no_use, [
        glance.Expression(
          glance.Call(location, function, [
            glance.UnlabelledField(glance.Fn(
              location,
              parameters,
              // todo: figure out return type
              option.None,
              list.append(destructures, desugar_use(tail)),
            )),
          ]),
        ),
      ])
    }
    _ -> panic as "Only expecting use statements in desugar_use case"
  }
}

fn is_not_use_statement(statement: glance.Statement) -> Bool {
  case statement {
    glance.Use(..) -> False
    _ -> True
  }
}

// Turns the patterns of a `use` statement into function parameters, and
// returns any statements that need to be prepended to the desugared body
// to destructure patterns that are more complex than a simple variable.
fn patterns_to_args(
  location: glance.Span,
  patterns: List(glance.UsePattern),
) -> #(List(glance.FnParameter), List(glance.Statement)) {
  patterns
  |> list.index_fold(#([], []), fn(acc, pattern, index) {
    let #(parameters, statements) = acc
    case pattern.pattern {
      glance.PatternVariable(_, name) -> {
        // Todo: can we get types on this?
        #(
          list.append(parameters, [
            glance.FnParameter(glance.Named(name), option.None),
          ]),
          statements,
        )
      }
      glance.PatternDiscard(_, name) -> {
        // Todo: deduplicate discards
        #(
          list.append(parameters, [
            glance.FnParameter(glance.Discarded(name), option.None),
          ]),
          statements,
        )
      }
      destructure_me -> {
        let capture_name = "use_capture_" <> int.to_string(index)
        let capture_value = glance.Variable(glance.Span(0, 0), capture_name)
        #(
          list.append(parameters, [
            glance.FnParameter(glance.Named(capture_name), option.None),
          ]),
          list.append(statements, [
            glance.Assignment(
              location,
              glance.Let,
              destructure_me,
              option.None,
              capture_value,
            ),
          ]),
        )
      }
    }
  })
}

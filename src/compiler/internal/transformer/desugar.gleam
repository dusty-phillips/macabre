import glance
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
      list.append(no_use, [
        glance.Expression(glance.Call(
          location,
          function,
          list.append(arguments, [
            glance.UnlabelledField(glance.Fn(
              location,
              patterns_to_args(patterns),
              // todo: figure out return type
              option.None,
              desugar_use(tail),
            )),
          ]),
        )),
      ])
    }
    [glance.Use(location, patterns, function), ..tail] -> {
      list.append(no_use, [
        glance.Expression(
          glance.Call(location, function, [
            glance.UnlabelledField(glance.Fn(
              location,
              patterns_to_args(patterns),
              // todo: figure out return type
              option.None,
              desugar_use(tail),
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

fn patterns_to_args(
  patterns: List(glance.UsePattern),
) -> List(glance.FnParameter) {
  use pattern <- list.map(patterns)
  case pattern.pattern {
    glance.PatternVariable(_, name) -> {
      // Todo: can we get types on this?
      glance.FnParameter(glance.Named(name), option.None)
    }
    glance.PatternDiscard(_, name) -> {
      // Todo: deduplicate discards
      glance.FnParameter(glance.Discarded(name), option.None)
    }
    _ -> panic as "Only variable and discard patterns are supported in use"
  }
}

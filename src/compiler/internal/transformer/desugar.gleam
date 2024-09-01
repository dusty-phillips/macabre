import glance
import gleam/list
import gleam/option

pub fn desugar_use(block: List(glance.Statement)) -> List(glance.Statement) {
  let #(no_use, starts_with_use) = list.split_while(block, is_not_use_statement)
  case starts_with_use {
    [] -> block
    [glance.Use(patterns, glance.Call(function, arguments)), ..tail] -> {
      list.append(no_use, [
        glance.Expression(glance.Call(
          function,
          list.append(arguments, [
            glance.Field(
              // todo: this won't work if the previous arguments were labelled
              label: option.None,
              item: glance.Fn(
                patterns_to_args(patterns),
                // todo: figure out return type
                option.None,
                desugar_use(tail),
              ),
            ),
          ]),
        )),
      ])
    }
    [glance.Use(patterns, function), ..tail] -> {
      list.append(no_use, [
        glance.Expression(
          glance.Call(function, [
            glance.Field(
              label: option.None,
              item: glance.Fn(
                patterns_to_args(patterns),
                // todo: figure out return type
                option.None,
                desugar_use(tail),
              ),
            ),
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

fn patterns_to_args(patterns: List(glance.Pattern)) -> List(glance.FnParameter) {
  use pattern <- list.map(patterns)
  case pattern {
    glance.PatternVariable(name) -> {
      // Todo: can we get types on this?
      glance.FnParameter(glance.Named(name), option.None)
    }
    glance.PatternDiscard(name) -> {
      // Todo: deduplicate discards
      glance.FnParameter(glance.Discarded(name), option.None)
    }
    _ -> panic as "Only variable and discard patterns are supported in use"
  }
}

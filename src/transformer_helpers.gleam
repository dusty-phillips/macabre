import glance
import gleam/list
import gleam/option
import python

pub type ReversedList(a) =
  List(a)

pub type TransformError {
  NotExternal
}

pub type TransformerContext {
  TransformerContext(next_function_id: Int)
}

pub type ExpressionReturn {
  ExpressionReturn(
    context: TransformerContext,
    statements: List(python.Statement),
    expression: python.Expression,
  )
}

pub type TransformState(a) {
  TransformState(
    context: TransformerContext,
    statements: List(python.Statement),
    item: a,
  )
}

pub type StatementReturn {
  StatementReturn(
    context: TransformerContext,
    statements: List(python.Statement),
  )
}

// Return a new ExpressionReturn with the same context and statements,
// but call a function to generate a new expression
pub fn map_return(
  result: ExpressionReturn,
  mapper: fn(python.Expression) -> python.Expression,
) -> ExpressionReturn {
  ExpressionReturn(..result, expression: mapper(result.expression))
}

// useful when you have two ExpressionReturns where the context of the first
// was passed as the context to the second. Creates a new ExpressionReturn
// with the context from the second, the statements from both of them,
// and the expression the result of calling the mapper on the expressions
// from the two results
pub fn merge_return(
  first: ExpressionReturn,
  second: ExpressionReturn,
  mapper: fn(python.Expression, python.Expression) -> python.Expression,
) {
  ExpressionReturn(
    second.context,
    list.append(first.statements, second.statements),
    mapper(first.expression, second.expression),
  )
}

// useful in folding TransformState objects.
// The merged result will have the context from "current"
// the statements from prev and current concatenated,
// and the item whatever the mapper function returns
pub fn merge_state(
  prev: TransformState(a),
  current: ExpressionReturn,
  next: a,
) -> TransformState(a) {
  TransformState(
    current.context,
    list.append(prev.statements, current.statements),
    next,
  )
}

// useful in folding TransformStates where the item is
// a reversed list of elements that gets a new element prepended
pub fn merge_state_prepend(
  prev: TransformState(ReversedList(a)),
  current: ExpressionReturn,
  map_next: fn(python.Expression) -> a,
) -> TransformState(List(a)) {
  merge_state(
    prev,
    current,
    list.prepend(prev.item, map_next(current.expression)),
  )
}

pub fn reverse_state_to_return(
  state: TransformState(ReversedList(a)),
  mapper: fn(List(a)) -> python.Expression,
) {
  ExpressionReturn(
    state.context,
    state.statements,
    state.item |> list.reverse |> mapper,
  )
}

pub fn maybe_extract_external(
  function_attribute: glance.Attribute,
) -> Result(python.Import, TransformError) {
  case function_attribute {
    glance.Attribute(
      "external",
      [glance.Variable("python"), glance.String(module), glance.String(name)],
    ) -> Ok(python.UnqualifiedImport(module, name, option.None))
    _ -> Error(NotExternal)
  }
}

pub fn add_return_if_returnable_expression(
  statement: python.Statement,
) -> python.Statement {
  case statement {
    python.Expression(python.Panic(_)) -> statement
    python.Expression(python.Todo(_)) -> statement
    python.Expression(expr) -> python.Return(expr)
    statement -> statement
  }
}

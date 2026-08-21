import compiler/python
import gleam/bit_array
import gleam/dict
import gleam/list
import gleam/option
import gleam/string

pub type FunctionSignatures =
  dict.Dict(String, List(#(option.Option(String), String)))

pub type ReversedList(a) =
  List(a)

pub type TransformError {
  NotExternal
}

pub type TransformerContext {
  TransformerContext(
    next_function_id: Int,
    next_block_id: Int,
    next_case_id: Int,
    next_discard_id: Int,
    // Counter for the temporaries an `assert` statement binds its subject
    // (and any sub-expressions it must reference in its panic payload) to.
    next_assert_id: Int,
    function_signatures: option.Option(FunctionSignatures),
    module_aliases: List(String),
    // Maps each module binding name in scope to its full gleam module path
    // (e.g. "list" -> "gleam/list"). Used to recognise stdlib loop calls for
    // inlining. `None` when compiling a module in isolation (tests) where the
    // import table is unknown.
    module_paths: option.Option(dict.Dict(String, String)),
    module_reserved: List(String),
    constructor_arities: option.Option(dict.Dict(String, List(String))),
    module_bindings: option.Option(dict.Dict(String, String)),
    external_functions: option.Option(List(String)),
    external_qualified: option.Option(List(String)),
    // Names bound in the current scope (function parameters, `let`
    // bindings, case patterns, fn literal parameters). A call to a bare
    // name that is locally bound is a call to that local value, never to a
    // module-level function, so argument reordering for labelled calls must
    // not consult the module function's signature.
    local_bindings: List(String),
    // A shared per-base-name counter used to mint fresh names across all
    // shadowing passes. Keeping one pool means a name like `state` is
    // renamed `state_0`, `state_1`, `state_2`... and no two passes can
    // independently choose the same fresh name.
    fresh_pool: dict.Dict(String, Int),
    // Metadata about the source location being compiled, used to build
    // runtime panic payloads (gleam_error maps). Empty strings when unknown
    // (e.g. compiling a module in isolation in the test suite).
    module_name: String,
    function_name: String,
    file_path: String,
    module_source: String,
  )
}

pub fn empty_context() -> TransformerContext {
  TransformerContext(
    next_function_id: 0,
    next_block_id: 0,
    next_case_id: 0,
    next_discard_id: 0,
    next_assert_id: 0,
    function_signatures: option.None,
    module_aliases: [],
    module_paths: option.None,
    module_reserved: [],
    constructor_arities: option.None,
    module_bindings: option.None,
    external_functions: option.None,
    external_qualified: option.None,
    local_bindings: [],
    fresh_pool: dict.new(),
    module_name: "",
    function_name: "",
    file_path: "",
    module_source: "",
  )
}

// The 1-based line number of a byte offset within the module source. Falls
// back to 0 when the source is unknown.
pub fn line_of(module_source: String, offset: Int) -> Int {
  case module_source == "" {
    True -> 0
    False -> {
      let #(count, _) =
        module_source
        |> string.split("\n")
        |> list.fold(#(0, 0), fn(state, line) {
          let #(count, position) = state
          let next_position =
            position + bit_array.byte_size(bit_array.from_string(line)) + 1
          case position <= offset {
            True -> #(count + 1, next_position)
            False -> #(count, next_position)
          }
        })
      count
    }
  }
}

// The name a module binding is emitted under. If a top-level function or
// constant in the module has the same name as an import binding, the import
// binding is renamed (e.g. `token` -> `token_module`) so the Python `def`
// does not override it.
pub fn module_binding(context: TransformerContext, alias: String) -> String {
  case context.module_bindings {
    option.None -> alias
    option.Some(bindings) ->
      case dict.get(bindings, alias) {
        Ok(binding) -> binding
        Error(_) -> alias
      }
  }
}

pub type ExpressionReturn {
  ExpressionReturn(
    context: TransformerContext,
    statements: List(python.Statement),
    expression: python.Expression,
  )
}

pub type OptionalExpressionReturn {
  OptionalExpressionReturn(
    context: TransformerContext,
    statements: List(python.Statement),
    expression: option.Option(python.Expression),
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

// Simple constructor for an ExpressionReturn that doesn't need to
// modify the context or return statements
pub fn empty_return(
  context: TransformerContext,
  expression: python.Expression,
) -> ExpressionReturn {
  ExpressionReturn(context, [], expression)
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
) -> TransformState(ReversedList(a)) {
  merge_state(
    prev,
    current,
    list.prepend(prev.item, map_next(current.expression)),
  )
}

pub fn map_state_prepend(
  prev: TransformState(ReversedList(a)),
  next: a,
) -> TransformState(ReversedList(a)) {
  TransformState(prev.context, prev.statements, prev.item |> list.prepend(next))
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

pub fn transform_last(elements: List(a), transformer: fn(a) -> a) -> List(a) {
  // This makes three iterations over elements. It may be a candidate for optimization
  // since it happens on all the statements in every function body. I can find ways
  // to do it with only two iterations, or with one iteration but transforming every
  // element and discarding the intermediates, but I didn't have any luck with a solution
  // that could do it in only one iteration.
  let length = list.length(elements)
  let #(head, tail) = list.split(elements, length - 1)
  list.append(head, tail |> list.map(transformer))
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

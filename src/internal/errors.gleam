import glance
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder
import glexer
import glexer/token
import glimpse/error as glimpse_error
import internal/bytes

pub fn format_glance_error(
  error: glance.Error,
  filename: String,
  contents: String,
) -> String {
  let error_message = case error {
    glance.UnexpectedEndOfInput -> "Unexpected EOF"
    glance.UnexpectedToken(token, position) ->
      format_unexpected_token(token, position, contents)
  }
  "Unable to compile " <> filename <> ":\n" <> error_message
}

type PositionState {
  PositionState(
    current_line_number: Int,
    current_line_bytes: BytesTree,
    current_line_first_byte_position: Int,
    current_position: Int,
    target_position: Int,
  )
}

pub fn format_unexpected_token(
  token: token.Token,
  position: glexer.Position,
  contents: String,
) -> String {
  let initial =
    PositionState(
      current_line_number: 1,
      current_line_bytes: bytes_tree.new(),
      current_line_first_byte_position: 0,
      current_position: 0,
      // glexer positions start at byte 0, which is character 1 on a line based system
      target_position: position.byte_offset + 1,
    )

  let position_state =
    contents
    |> bytes.iterate
    |> yielder.fold_until(initial, fold_position_to_lines)

  case position_state.current_position {
    pos if pos < position_state.target_position ->
      "\nUnexpected EOF looking for "
      <> format_token(token)
      <> " at position "
      <> int.to_string(position_state.target_position)
    _ -> {
      let column =
        position_state.target_position
        - position_state.current_line_first_byte_position
      "Unexpected Token "
      <> format_token(token)
      <> "\nAt line "
      <> int.to_string(position_state.current_line_number)
      <> " column "
      <> int.to_string(column)
      <> "\n\n"
      <> {
        position_state.current_line_bytes
        |> bytes_tree.to_bit_array
        |> bit_array.to_string
        |> result.unwrap("Unexpected unicode")
      }
      <> "\n"
      <> string.repeat(" ", column - 1)
      <> "^\n"
    }
  }
}

// Given a byte position, return information about the line that contains that
// byte iterates over each bytes, counting lines. Once it finds the target,
// continues iterating until the end of the line and returns that line.
fn fold_position_to_lines(
  state: PositionState,
  byte: Int,
) -> list.ContinueOrStop(PositionState) {
  case byte, state.current_position, state.target_position {
    10, curr, target if curr < target ->
      list.Continue(
        PositionState(
          ..state,
          current_line_first_byte_position: state.current_position + 1,
          current_line_number: state.current_line_number + 1,
          current_line_bytes: bytes_tree.new(),
          current_position: state.current_position + 1,
        ),
      )
    10, _, _ -> list.Stop(state)
    byte, _, _ -> {
      list.Continue(
        PositionState(
          ..state,
          current_line_bytes: bytes_tree.append(state.current_line_bytes, <<
            byte,
          >>),
          current_position: state.current_position + 1,
        ),
      )
    }
  }
}

fn format_token(token: token.Token) -> String {
  token.to_source(token)
}

// Renders a glimpse type-checking error as a friendly, Gleam-style message.
// The `module` is the canonical module name (e.g. `foo/bar`); an empty string
// means the entry module, which is rendered without a path.
pub fn format_glimpse_type_check_error(
  module: String,
  error: glimpse_error.TypeCheckError,
) -> String {
  let message = case error {
    glimpse_error.InvalidReturnType(function_name, got, expected) ->
      "The function `"
      <> function_name
      <> "` has a return type of `"
      <> expected
      <> "` but returns a value of type `"
      <> got
      <> "`."
    glimpse_error.InvalidName(name) ->
      "No variable named `" <> name <> "` has been defined in this scope."
    glimpse_error.InvalidType(got, expected, context) ->
      "This value has type `"
      <> got
      <> "` but `"
      <> expected
      <> "` was expected."
      <> case context {
        "" -> ""
        message -> "\n\n" <> message
      }
    glimpse_error.InvalidBinOp(operator, left_got, right_got, expected) ->
      "The `"
      <> operator
      <> "` operator expects `"
      <> expected
      <> "` on both sides.\n\nLeft side has type `"
      <> left_got
      <> "`.\nRight side has type `"
      <> right_got
      <> "`."
    glimpse_error.UnknownCustomType(name) -> "Unknown type `" <> name <> "`."
    glimpse_error.RecursiveTypeAlias(name) ->
      "The type alias `" <> name <> "` is defined in terms of itself."
    glimpse_error.NotCallable(got) ->
      "This value has type `"
      <> got
      <> "` and so it cannot be called as a function."
    glimpse_error.InvalidArguments(expected, actual_arguments) ->
      "This function was called with the wrong arguments.\n\nExpected: "
      <> expected
      <> "\nGiven: "
      <> actual_arguments
    glimpse_error.InvalidArgumentLabel(expected, got) ->
      "This function does not expect an argument labelled `"
      <> got
      <> "`.\n\nExpected labels: "
      <> expected
    glimpse_error.UnexpectedLabelledArgument(label) ->
      "The `"
      <> label
      <> "` argument was given as a labelled argument, but this call does not accept labelled arguments."
    glimpse_error.DuplicateCustomType(name) ->
      "A type named `" <> name <> "` has already been defined in this module."
    glimpse_error.InvalidFieldAccess(container, label) ->
      "The value of type `"
      <> container
      <> "` has no field named `"
      <> label
      <> "`."
    glimpse_error.UnexpectedType(got, expected) ->
      "Expected a value of type `"
      <> expected
      <> "` but this one has type `"
      <> got
      <> "`."
    glimpse_error.InvalidAnnotation(got, expected, name) ->
      "The annotation for `"
      <> name
      <> "` says it should have the type `"
      <> expected
      <> "` but it actually has the type `"
      <> got
      <> "`."
    glimpse_error.CaseClauseMismatch(got, expected) ->
      "All clauses in a case expression must return the same type.\n\nThe first clause returned `"
      <> expected
      <> "` but this one returns `"
      <> got
      <> "`."
    glimpse_error.PatternMismatch(pattern, expected, got) ->
      "This pattern matches values of type `"
      <> pattern
      <> "` but this value has type `"
      <> got
      <> "` (expected `"
      <> expected
      <> "`)."
    glimpse_error.InvalidGuard(got) ->
      "The guard clause of this case expression must return a `Bool` but it returns a `"
      <> got
      <> "`."
    glimpse_error.InvalidGuardExpression ->
      "This expression is not valid as a case guard. Guards may only use a restricted boolean grammar."
    glimpse_error.LowercaseBoolPattern(name) ->
      "The pattern `"
      <> name
      <> "` is written in lowercase, so it is treated as a variable rather than the `True` or `False` value. Capitalise it to match the boolean value."
    glimpse_error.MissingParameterAnnotation(name) ->
      "The parameter `"
      <> name
      <> "` is missing a type annotation. All function parameters must be annotated."
    glimpse_error.MissingReturnAnnotation(function_name) ->
      "The function `"
      <> function_name
      <> "` is missing a return type annotation."
    glimpse_error.UnexpectedTypeHole(name) ->
      "The type hole `"
      <> name
      <> "` is used where its concrete type must be known, so it cannot be inferred."
    glimpse_error.InvalidUse(subject_count) ->
      "The `use` syntax was used with "
      <> int.to_string(subject_count)
      <> " subject(s), but it must be used with exactly one."
    glimpse_error.InexhaustivePattern(description) ->
      "This case expression does not have a clause for "
      <> description
      <> ".\n\nIf you are sure this is impossible, use `panic` to tell the compiler it will never happen."
    glimpse_error.InvalidBitStringSegment(mismatch) -> mismatch
    glimpse_error.UnsafeRecordUpdate(name) ->
      "This `..` record update is unsafe because the spread value's variant could differ from the one being constructed."
      <> case name {
        "" -> ""
        value -> "\n\nThe spread value is `" <> value <> "`."
      }
    glimpse_error.RecordUpdateOnUnlabelledConstructor(constructor) ->
      "The constructor `"
      <> constructor
      <> "` has no labelled fields, so it cannot be used with `..` record update syntax."
    glimpse_error.DuplicateArgument(field) ->
      "The argument `" <> field <> "` is given more than once."
    glimpse_error.MissingField(message) -> message
    glimpse_error.DuplicateArgumentName(name) ->
      "Two arguments both have the label `"
      <> name
      <> "`. Argument labels must be unique."
    glimpse_error.UnlabelledArgumentAfterLabelled ->
      "An unlabelled argument follows a labelled argument. All arguments after a labelled one must also be labelled."
    glimpse_error.PositionalArgumentAfterLabelled ->
      "A positional argument follows a labelled argument. All arguments after a labelled one must also be labelled."
    glimpse_error.DuplicateConstructor(name) ->
      "The constructor `" <> name <> "` has already been defined in this type."
    glimpse_error.PrivateTypeLeak(name) ->
      "The type `"
      <> name
      <> "` is private, but it appears in a public interface."
    glimpse_error.TodoInConstant ->
      "The `todo` keyword cannot be used in a module constant."
    glimpse_error.InvalidConstantExpression ->
      "This expression is not allowed in a module constant. Constants may only contain literals, constant references, list/tuple/bit-array literals, and record construction and updates."
    glimpse_error.FnInConstant ->
      "A function literal cannot be used in a module constant."
    glimpse_error.UnusedTypeParameter(name) ->
      "The type parameter `"
      <> name
      <> "` is never used. All type parameters must appear in the definition."
    glimpse_error.UnnecessarySpread ->
      "This constructor pattern already lists every field, so the `..` spread is unnecessary."
    glimpse_error.InvalidPatternArity(expected, got) ->
      "This pattern expects "
      <> int.to_string(expected)
      <> " argument(s) but has "
      <> int.to_string(got)
      <> "."
    glimpse_error.DoubleVariableAssignment ->
      "A variable is assigned more than once in this bit-array pattern."
    glimpse_error.DuplicateDefinition(name) ->
      "The name `" <> name <> "` has already been defined in this module."
    glimpse_error.DuplicateTypeParameter(name) ->
      "The type parameter `" <> name <> "` is declared more than once."
    glimpse_error.DuplicateLabel(label) ->
      "The label `" <> label <> "` is used more than once in this constructor."
    glimpse_error.TypeUsedAsConstructor(type_name) ->
      "The type `"
      <> type_name
      <> "` takes no arguments, so it cannot be written with parentheses like `"
      <> type_name
      <> "()`."
    glimpse_error.ExternalTypeWithConstructors(type_name) ->
      "The type `"
      <> type_name
      <> "` has an `@external` annotation but also declares constructors. External types cannot have constructors."
    glimpse_error.IncorrectPatternCount(patterns, subjects) ->
      "This case has "
      <> int.to_string(subjects)
      <> " subject(s) but a clause has "
      <> int.to_string(patterns)
      <> " pattern(s)."
    glimpse_error.DuplicatePatternVariable(name) ->
      "The variable `" <> name <> "` is bound more than once in this pattern."
    glimpse_error.MissingPatternVariable(name) ->
      "The variable `"
      <> name
      <> "` is bound by one alternative but not by all of them."
    glimpse_error.ExtraPatternVariable(name) ->
      "The variable `"
      <> name
      <> "` is bound by an alternative but not by the one before it."
    glimpse_error.RecursiveType -> "This type is defined in terms of itself."
    glimpse_error.FloatOutOfRange(value) ->
      "The float literal `" <> value <> "` is too large to be represented."
    glimpse_error.InvalidEscape(value) ->
      "The escape sequence `" <> value <> "` is not valid in a string literal."
    glimpse_error.UnknownTarget(name) ->
      "The build target `"
      <> name
      <> "` is not recognised. Valid targets are `erlang` and `javascript`."
    glimpse_error.InvalidExternalAttribute ->
      "This `@external` attribute is not valid. It must be of the form `@external(Target, \"module\", \"function\")`."
    glimpse_error.InvalidExternalModule(module) ->
      "The module path `"
      <> module
      <> "` is not a valid `@external` module path."
    glimpse_error.InvalidExternalFunction(name) ->
      "The function name `"
      <> name
      <> "` is not a valid `@external` function name."
    glimpse_error.ExternalAttributePlacement(scope) ->
      "An `@external` attribute cannot be placed on "
      <> scope
      <> ". It is only allowed on functions and custom types."
    glimpse_error.InvalidAttributePlacement(attribute, scope) ->
      "The `" <> attribute <> "` attribute cannot be placed on " <> scope <> "."
    glimpse_error.InvalidTypeName(name) ->
      "The type name `"
      <> name
      <> "` is invalid. Type names must start with an uppercase letter and contain no underscores."
    glimpse_error.InvalidFunctionName(name) ->
      "The function name `"
      <> name
      <> "` is invalid. Function names must be written in snake_case."
    glimpse_error.InvalidConstantName(name) ->
      "The constant name `"
      <> name
      <> "` is invalid. Constant names must be written in snake_case."
    glimpse_error.InvalidArgumentName(name) ->
      "The argument name `"
      <> name
      <> "` is invalid. Argument names must be written in snake_case."
    glimpse_error.InvalidTypeVariableName(name) ->
      "The type variable name `"
      <> name
      <> "` is invalid. Type variable names must be written in snake_case."
    glimpse_error.InvalidVariableName(name) ->
      "The variable name `"
      <> name
      <> "` is invalid. Variable names must be written in snake_case."
    glimpse_error.InvalidVariantName(name) ->
      "The variant name `"
      <> name
      <> "` is invalid. Variant names must start with an uppercase letter and contain no underscores."
    glimpse_error.InvalidTypeAliasName(name) ->
      "The type alias name `"
      <> name
      <> "` is invalid. Type alias names must start with an uppercase letter and contain no underscores."
    glimpse_error.InvalidAttributeShape(attribute) ->
      "The `"
      <> attribute
      <> "` attribute has the wrong shape for its arguments."
    glimpse_error.UnknownAttribute(name) ->
      "The attribute `"
      <> name
      <> "` is not recognised. Valid attributes are `@external`, `@internal`, `@deprecated`, and `@target`."
    glimpse_error.DuplicateAttribute(name) ->
      "The attribute `" <> name <> "` is declared more than once."
    glimpse_error.UnsupportedTarget(name) ->
      "The value `"
      <> name
      <> "` is only implemented for another build target and cannot be used here."
    glimpse_error.MissingImplementation(name) ->
      "The function `"
      <> name
      <> "` has no implementation. Functions must have a body or an `@external` attribute."
    glimpse_error.DuplicateImport(name) ->
      "The module `" <> name <> "` is imported more than once."
  }
  case module {
    "" -> "Type error:\n\n" <> message
    name -> "Type error in " <> name <> ".gleam:\n\n" <> message
  }
}

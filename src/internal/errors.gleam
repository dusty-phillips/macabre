import glance
import gleam/int
import gleam/string
import glexer
import glexer/token
import glimpse/error as glimpse_error

pub fn format_glance_error(
  error: glance.Error,
  filename: String,
  contents: String,
) -> String {
  let file = display_file(filename)
  case error {
    glance.UnexpectedEndOfInput ->
      "error: Unexpected end of input\n"
      <> frame_for_offset(contents, string.byte_size(contents), file, 1)
      <> "\nUnexpected end of input while parsing "
      <> file
      <> ".\nHint: Check for an unclosed block or missing expression."
    glance.UnexpectedToken(tok, position) ->
      format_unexpected_token(tok, position, contents, file)
  }
}

// A module name such as `foo/bar` renders as `foo/bar.gleam`; an empty
// module (the entry point before its name is known) renders as just the
// file it was read from when a path is passed, or `main.gleam` otherwise.
fn display_file(filename: String) -> String {
  case filename {
    "" -> "main.gleam"
    name ->
      case string.ends_with(name, ".gleam") {
        True -> name
        False -> name <> ".gleam"
      }
  }
}

// Renders a Gleam-style code frame for a byte offset into source:
//
//   ┌─ src/main.gleam:2:5
//   │
// 2 │ pub fn main() {
//   │     ^^^
pub fn frame_for_offset(
  source: String,
  byte_offset: Int,
  file: String,
  underline_len: Int,
) -> String {
  let #(line_number, column, line_text) =
    line_col_at_offset(source, byte_offset)
  let line_no = int.to_string(line_number)
  let gutter = string.repeat(" ", string.length(line_no))
  let width = case underline_len < 1 {
    True -> 1
    False -> underline_len
  }
  "  ┌─ "
  <> file
  <> ":"
  <> line_no
  <> ":"
  <> int.to_string(column)
  <> "\n  │\n"
  <> line_no
  <> " │ "
  <> line_text
  <> "\n"
  <> gutter
  <> " │ "
  <> string.repeat(" ", column - 1)
  <> string.repeat("^", width)
  <> "\n"
}

// A header-only frame when no byte offset is known, e.g. `  ┌─ src/foo.gleam`.
pub fn frame_header(file: String) -> String {
  "  ┌─ " <> file <> "\n  │\n"
}

fn line_col_at_offset(source: String, offset: Int) -> #(Int, Int, String) {
  let clamped = case offset < 0 {
    True -> 0
    False ->
      case offset > string.byte_size(source) {
        True -> string.byte_size(source)
        False -> offset
      }
  }
  find_line(string.split(source, "\n"), clamped, 1, 0)
}

fn find_line(
  lines: List(String),
  offset: Int,
  line_number: Int,
  base: Int,
) -> #(Int, Int, String) {
  case lines {
    [] -> #(line_number, 1, "")
    [line, ..rest] -> {
      let line_end = base + string.byte_size(line)
      case offset <= line_end {
        True -> {
          let column = offset - base + 1
          let max_col = string.length(line) + 1
          let col = case column > max_col {
            True -> max_col
            False ->
              case column < 1 {
                True -> 1
                False -> column
              }
          }
          #(line_number, col, line)
        }
        False -> find_line(rest, offset, line_number + 1, line_end + 1)
      }
    }
  }
}

// Byte offset of the first occurrence of `needle` in `source`, so snippets
// point at the offending identifier. Byte-accurate even with unicode,
// since the prefix before the split point is measured in bytes.
pub fn find_needle_offset(source: String, needle: String) -> Result(Int, Nil) {
  case needle {
    "" -> Error(Nil)
    _ ->
      case string.split(source, needle) {
        [before, ..rest] ->
          case rest {
            [] -> Error(Nil)
            _ -> Ok(string.byte_size(before))
          }
        [] -> Error(Nil)
      }
  }
}

pub fn format_unexpected_token(
  token: token.Token,
  position: glexer.Position,
  contents: String,
  file: String,
) -> String {
  let offset = position.byte_offset
  let size = string.byte_size(contents)
  case offset >= size {
    True -> {
      "error: Unexpected end of input\n"
      <> frame_for_offset(contents, size, file, 1)
      <> "\nUnexpected end of input while looking for `"
      <> format_token(token)
      <> "`.\nHint: Check for an unclosed block or missing expression."
    }
    False -> {
      "error: Syntax error\n"
      <> frame_for_offset(
        contents,
        offset,
        file,
        string.length(format_token(token)),
      )
      <> "\nUnexpected token `"
      <> format_token(token)
      <> "`.\nHint: Check the Gleam syntax around this location."
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
  format_glimpse_type_check_error_with_source(module, error, "", "")
}

pub fn format_glimpse_type_check_error_with_source(
  module: String,
  error: glimpse_error.TypeCheckError,
  source: String,
  file: String,
) -> String {
  let title = type_check_title(error)
  let message = type_check_message(error)
  let header = "error: " <> title <> "\n"
  let resolved_file = case file {
    "" ->
      case module {
        "" -> ""
        name -> display_file(name)
      }
    path -> path
  }
  let frame = case resolved_file, source {
    "", _ -> ""
    path, "" -> frame_header(path)
    path, contents ->
      case type_check_needle(error) {
        Error(_) -> frame_header(path)
        Ok(needle) ->
          case find_needle_offset(contents, needle) {
            Error(_) -> frame_header(path)
            Ok(offset) ->
              frame_for_offset(contents, offset, path, string.length(needle))
          }
      }
  }
  let suffix = case type_check_hint(error) {
    Ok(text) -> "\n\nHint: " <> text
    Error(_) -> ""
  }
  header <> frame <> "\n" <> message <> suffix
}

fn type_check_message(error: glimpse_error.TypeCheckError) -> String {
  case error {
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
}

fn type_check_title(error: glimpse_error.TypeCheckError) -> String {
  case error {
    glimpse_error.InvalidReturnType(..) -> "Incorrect return type"
    glimpse_error.InvalidName(..) -> "Unknown variable"
    glimpse_error.InvalidType(..) -> "Type mismatch"
    glimpse_error.InvalidBinOp(..) -> "Type mismatch"
    glimpse_error.UnknownCustomType(..) -> "Unknown type"
    glimpse_error.RecursiveTypeAlias(..) -> "Recursive type alias"
    glimpse_error.NotCallable(..) -> "Not callable"
    glimpse_error.InvalidArguments(..) -> "Wrong arguments"
    glimpse_error.InvalidArgumentLabel(..) -> "Unknown label"
    glimpse_error.UnexpectedLabelledArgument(..) ->
      "Unexpected labelled argument"
    glimpse_error.DuplicateCustomType(..) -> "Duplicate type"
    glimpse_error.InvalidFieldAccess(..) -> "Unknown field"
    glimpse_error.UnexpectedType(..) -> "Type mismatch"
    glimpse_error.InvalidAnnotation(..) -> "Type mismatch"
    glimpse_error.CaseClauseMismatch(..) -> "Type mismatch"
    glimpse_error.PatternMismatch(..) -> "Pattern mismatch"
    glimpse_error.InvalidGuard(..) -> "Type mismatch"
    glimpse_error.InvalidGuardExpression -> "Invalid guard"
    glimpse_error.LowercaseBoolPattern(..) -> "Invalid pattern"
    glimpse_error.MissingParameterAnnotation(..) -> "Missing annotation"
    glimpse_error.MissingReturnAnnotation(..) -> "Missing annotation"
    glimpse_error.UnexpectedTypeHole(..) -> "Unexpected type hole"
    glimpse_error.InvalidUse(..) -> "Invalid use"
    glimpse_error.InexhaustivePattern(..) -> "Inexhaustive pattern"
    glimpse_error.InvalidBitStringSegment(..) -> "Invalid bit array segment"
    glimpse_error.UnsafeRecordUpdate(..) -> "Unsafe record update"
    glimpse_error.RecordUpdateOnUnlabelledConstructor(..) ->
      "Invalid record update"
    glimpse_error.DuplicateArgument(..) -> "Duplicate argument"
    glimpse_error.MissingField(..) -> "Unknown field"
    glimpse_error.DuplicateArgumentName(..) -> "Duplicate argument"
    glimpse_error.UnlabelledArgumentAfterLabelled -> "Invalid argument"
    glimpse_error.PositionalArgumentAfterLabelled -> "Invalid argument"
    glimpse_error.DuplicateConstructor(..) -> "Duplicate constructor"
    glimpse_error.PrivateTypeLeak(..) -> "Private type leak"
    glimpse_error.TodoInConstant -> "Invalid constant"
    glimpse_error.InvalidConstantExpression -> "Invalid constant"
    glimpse_error.FnInConstant -> "Invalid constant"
    glimpse_error.UnusedTypeParameter(..) -> "Unused type parameter"
    glimpse_error.UnnecessarySpread -> "Unnecessary spread"
    glimpse_error.InvalidPatternArity(..) -> "Incorrect arity"
    glimpse_error.DoubleVariableAssignment -> "Duplicate variable"
    glimpse_error.DuplicateDefinition(..) -> "Duplicate definition"
    glimpse_error.DuplicateTypeParameter(..) -> "Duplicate type parameter"
    glimpse_error.DuplicateLabel(..) -> "Duplicate label"
    glimpse_error.TypeUsedAsConstructor(..) -> "Invalid type"
    glimpse_error.ExternalTypeWithConstructors(..) -> "Invalid external type"
    glimpse_error.IncorrectPatternCount(..) -> "Incorrect arity"
    glimpse_error.DuplicatePatternVariable(..) -> "Duplicate variable"
    glimpse_error.MissingPatternVariable(..) -> "Missing variable"
    glimpse_error.ExtraPatternVariable(..) -> "Extra variable"
    glimpse_error.RecursiveType -> "Recursive type"
    glimpse_error.FloatOutOfRange(..) -> "Invalid float"
    glimpse_error.InvalidEscape(..) -> "Invalid escape"
    glimpse_error.UnknownTarget(..) -> "Unknown target"
    glimpse_error.InvalidExternalAttribute -> "Invalid external"
    glimpse_error.InvalidExternalModule(..) -> "Invalid external"
    glimpse_error.InvalidExternalFunction(..) -> "Invalid external"
    glimpse_error.ExternalAttributePlacement(..) -> "Invalid attribute"
    glimpse_error.InvalidAttributePlacement(..) -> "Invalid attribute"
    glimpse_error.InvalidTypeName(..) -> "Invalid name"
    glimpse_error.InvalidFunctionName(..) -> "Invalid name"
    glimpse_error.InvalidConstantName(..) -> "Invalid name"
    glimpse_error.InvalidArgumentName(..) -> "Invalid name"
    glimpse_error.InvalidTypeVariableName(..) -> "Invalid name"
    glimpse_error.InvalidVariableName(..) -> "Invalid name"
    glimpse_error.InvalidVariantName(..) -> "Invalid name"
    glimpse_error.InvalidTypeAliasName(..) -> "Invalid name"
    glimpse_error.InvalidAttributeShape(..) -> "Invalid attribute"
    glimpse_error.UnknownAttribute(..) -> "Unknown attribute"
    glimpse_error.DuplicateAttribute(..) -> "Duplicate attribute"
    glimpse_error.UnsupportedTarget(..) -> "Unsupported target"
    glimpse_error.MissingImplementation(..) -> "Missing implementation"
    glimpse_error.DuplicateImport(..) -> "Duplicate import"
  }
}

fn type_check_needle(
  error: glimpse_error.TypeCheckError,
) -> Result(String, Nil) {
  case error {
    glimpse_error.InvalidReturnType(function_name, ..) -> Ok(function_name)
    glimpse_error.InvalidName(name) -> Ok(name)
    glimpse_error.UnknownCustomType(name) -> Ok(name)
    glimpse_error.RecursiveTypeAlias(name) -> Ok(name)
    glimpse_error.InvalidArgumentLabel(_, got) -> Ok(got)
    glimpse_error.UnexpectedLabelledArgument(label) -> Ok(label)
    glimpse_error.DuplicateCustomType(name) -> Ok(name)
    glimpse_error.InvalidFieldAccess(_, label) -> Ok(label)
    glimpse_error.InvalidAnnotation(_, _, name) -> Ok(name)
    glimpse_error.LowercaseBoolPattern(name) -> Ok(name)
    glimpse_error.MissingParameterAnnotation(name) -> Ok(name)
    glimpse_error.MissingReturnAnnotation(function_name) -> Ok(function_name)
    glimpse_error.UnexpectedTypeHole(name) -> Ok(name)
    glimpse_error.InvalidUse(..) -> Ok("use")
    glimpse_error.InexhaustivePattern(..) -> Ok("case")
    glimpse_error.UnsafeRecordUpdate(name) ->
      case name {
        "" -> Error(Nil)
        value -> Ok(value)
      }
    glimpse_error.RecordUpdateOnUnlabelledConstructor(constructor) ->
      Ok(constructor)
    glimpse_error.DuplicateArgument(field) -> Ok(field)
    glimpse_error.DuplicateArgumentName(name) -> Ok(name)
    glimpse_error.DuplicateConstructor(name) -> Ok(name)
    glimpse_error.PrivateTypeLeak(name) -> Ok(name)
    glimpse_error.TodoInConstant -> Ok("todo")
    glimpse_error.FnInConstant -> Ok("fn")
    glimpse_error.UnusedTypeParameter(name) -> Ok(name)
    glimpse_error.UnnecessarySpread -> Ok("..")
    glimpse_error.DuplicateDefinition(name) -> Ok(name)
    glimpse_error.DuplicateTypeParameter(name) -> Ok(name)
    glimpse_error.DuplicateLabel(label) -> Ok(label)
    glimpse_error.TypeUsedAsConstructor(type_name) -> Ok(type_name)
    glimpse_error.ExternalTypeWithConstructors(type_name) -> Ok(type_name)
    glimpse_error.IncorrectPatternCount(..) -> Ok("case")
    glimpse_error.DuplicatePatternVariable(name) -> Ok(name)
    glimpse_error.MissingPatternVariable(name) -> Ok(name)
    glimpse_error.ExtraPatternVariable(name) -> Ok(name)
    glimpse_error.FloatOutOfRange(value) -> Ok(value)
    glimpse_error.InvalidEscape(value) -> Ok(value)
    glimpse_error.UnknownTarget(name) -> Ok(name)
    glimpse_error.InvalidExternalAttribute -> Ok("external")
    glimpse_error.InvalidExternalModule(module) -> Ok(module)
    glimpse_error.InvalidExternalFunction(name) -> Ok(name)
    glimpse_error.ExternalAttributePlacement(..) -> Ok("external")
    glimpse_error.InvalidAttributePlacement(attribute, ..) -> Ok(attribute)
    glimpse_error.InvalidTypeName(name) -> Ok(name)
    glimpse_error.InvalidFunctionName(name) -> Ok(name)
    glimpse_error.InvalidConstantName(name) -> Ok(name)
    glimpse_error.InvalidArgumentName(name) -> Ok(name)
    glimpse_error.InvalidTypeVariableName(name) -> Ok(name)
    glimpse_error.InvalidVariableName(name) -> Ok(name)
    glimpse_error.InvalidVariantName(name) -> Ok(name)
    glimpse_error.InvalidTypeAliasName(name) -> Ok(name)
    glimpse_error.InvalidAttributeShape(attribute) -> Ok(attribute)
    glimpse_error.UnknownAttribute(name) -> Ok(name)
    glimpse_error.DuplicateAttribute(name) -> Ok(name)
    glimpse_error.UnsupportedTarget(name) -> Ok(name)
    glimpse_error.MissingImplementation(name) -> Ok(name)
    glimpse_error.DuplicateImport(name) -> Ok(name)
    _ -> Error(Nil)
  }
}

fn type_check_hint(error: glimpse_error.TypeCheckError) -> Result(String, Nil) {
  case error {
    glimpse_error.InvalidName(..) ->
      Ok("Check the spelling and that the variable is defined.")
    glimpse_error.UnknownCustomType(..) ->
      Ok("Check the type name and that it is imported.")
    glimpse_error.PrivateTypeLeak(..) ->
      Ok("Make the type public or hide it from the public interface.")
    glimpse_error.UnsupportedTarget(name) ->
      Ok("Use a python-compatible alternative to `" <> name <> "`.")
    glimpse_error.MissingImplementation(..) ->
      Ok("Add a function body or an `@external(python, ...)` implementation.")
    glimpse_error.DuplicateImport(..) ->
      Ok("Remove one of the duplicate imports.")
    glimpse_error.InexhaustivePattern(..) ->
      Ok("Add the missing clause or use `panic` for impossible cases.")
    glimpse_error.InvalidEscape(..) ->
      Ok(
        "Valid escapes are `\\n`, `\\r`, `\\t`, `\\\"`, `\\\\`, and `\\u{...}`.",
      )
    _ -> Error(Nil)
  }
}

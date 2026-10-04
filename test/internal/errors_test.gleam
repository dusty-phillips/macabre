import gleam/list
import gleam/string
import glexer
import glexer/token
import glimpse/error as glimpse_error
import internal/errors

// Reminder: glexer.Position is 0-indexed, but output columns are 1-indexed
pub fn position_at_first_byte_test() {
  assert errors.format_unexpected_token(
      token.Int("5"),
      glexer.Position(0),
      "5bcdefg",
      "src/main.gleam",
    )
    == "error: Syntax error\n  ┌─ src/main.gleam:1:1\n  │\n1 │ 5bcdefg\n  │ ^\n\nUnexpected token `5`.\nHint: Check the Gleam syntax around this location."
}

pub fn position_in_first_line_test() {
  assert errors.format_unexpected_token(
      token.Int("5"),
      glexer.Position(4),
      "abcd5fg",
      "src/main.gleam",
    )
    == "error: Syntax error\n  ┌─ src/main.gleam:1:5\n  │\n1 │ abcd5fg\n  │     ^\n\nUnexpected token `5`.\nHint: Check the Gleam syntax around this location."
}

pub fn position_in_second_line_test() {
  assert errors.format_unexpected_token(
      token.Int("5"),
      glexer.Position(5),
      "abc\nd5fg",
      "src/main.gleam",
    )
    == "error: Syntax error\n  ┌─ src/main.gleam:2:2\n  │\n2 │ d5fg\n  │  ^\n\nUnexpected token `5`.\nHint: Check the Gleam syntax around this location."
}

pub fn position_after_newline_test() {
  assert errors.format_unexpected_token(
      token.Int("5"),
      glexer.Position(6),
      "abc\n\nd5fg",
      "src/main.gleam",
    )
    == "error: Syntax error\n  ┌─ src/main.gleam:3:2\n  │\n3 │ d5fg\n  │  ^\n\nUnexpected token `5`.\nHint: Check the Gleam syntax around this location."
}

pub fn type_check_error_in_module_test() {
  assert errors.format_glimpse_type_check_error(
      "foo/bar",
      glimpse_error.UnknownCustomType("Wibble"),
    )
    == "error: Unknown type\n  ┌─ foo/bar.gleam\n  │\n\nUnknown type `Wibble`.\n\nHint: Check the type name and that it is imported."
}

pub fn type_check_error_in_entry_module_test() {
  assert errors.format_glimpse_type_check_error(
      "",
      glimpse_error.DuplicateDefinition("wibble"),
    )
    == "error: Duplicate definition\n\nThe name `wibble` has already been defined in this module."
}

pub fn type_check_error_invalid_return_type_test() {
  assert errors.format_glimpse_type_check_error(
      "main",
      glimpse_error.InvalidReturnType("main", "Int", "String"),
    )
    == "error: Incorrect return type\n  ┌─ main.gleam\n  │\n\nThe function `main` has a return type of `String` but returns a value of type `Int`."
}

pub fn type_check_error_inexhaustive_test() {
  assert errors.format_glimpse_type_check_error(
      "main",
      glimpse_error.InexhaustivePattern("the `Nil` variant"),
    )
    == "error: Inexhaustive pattern\n  ┌─ main.gleam\n  │\n\nThis case expression does not have a clause for the `Nil` variant.\n\nIf you are sure this is impossible, use `panic` to tell the compiler it will never happen.\n\nHint: Add the missing clause or use `panic` for impossible cases."
}

pub fn type_check_error_lowercase_bool_pattern_test() {
  assert errors.format_glimpse_type_check_error(
      "main",
      glimpse_error.LowercaseBoolPattern("true"),
    )
    == "error: Invalid pattern\n  ┌─ main.gleam\n  │\n\nThe pattern `true` is written in lowercase, so it is treated as a variable rather than the `True` or `False` value. Capitalise it to match the boolean value."
}

pub fn type_check_error_argument_arity_test() {
  assert errors.format_glimpse_type_check_error(
      "main",
      glimpse_error.InvalidPatternArity(2, 1),
    )
    == "error: Incorrect arity\n  ┌─ main.gleam\n  │\n\nThis pattern expects 2 argument(s) but has 1."
}

pub fn type_check_error_with_source_snippet_test() {
  let source = "pub fn main() -> Wibble {\n  todo\n}"
  assert errors.format_glimpse_type_check_error_with_source(
      "main",
      glimpse_error.UnknownCustomType("Wibble"),
      source,
      "src/main.gleam",
    )
    == "error: Unknown type\n  ┌─ src/main.gleam:1:18\n  │\n1 │ pub fn main() -> Wibble {\n  │                  ^^^^^^\n\nUnknown type `Wibble`.\n\nHint: Check the type name and that it is imported."
}

pub fn type_check_error_with_missing_needle_test() {
  // A needle that never appears falls back to the file header.
  assert errors.format_glimpse_type_check_error_with_source(
      "main",
      glimpse_error.UnknownCustomType("Wibble"),
      "pub fn main() -> Int {\n  1\n}",
      "src/main.gleam",
    )
    == "error: Unknown type\n  ┌─ src/main.gleam\n  │\n\nUnknown type `Wibble`.\n\nHint: Check the type name and that it is imported."
}

// Spot-check that the full catalogue of error variants renders without
// panicking (each must produce a non-empty `error:`-prefixed message).
pub fn type_check_error_all_variants_render_test() {
  let module = "m"
  let variants = [
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidName("x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidBinOp("+", "Int", "String", "Int"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.RecursiveTypeAlias("T"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.NotCallable("Int"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidArguments("one argument", "two"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidArgumentLabel("label", "other"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnexpectedLabelledArgument("x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicateCustomType("T"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidFieldAccess("Rec", "field"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnexpectedType("Int", "String"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidAnnotation("Int", "Bool", "x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.CaseClauseMismatch("Int", "String"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.PatternMismatch("Int", "String", "Bool"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidGuard("Int"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidGuardExpression,
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.MissingParameterAnnotation("x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.MissingReturnAnnotation("f"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnexpectedTypeHole("a"),
    ),
    errors.format_glimpse_type_check_error(module, glimpse_error.InvalidUse(2)),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidBitStringSegment("mismatch"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnsafeRecordUpdate(""),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.RecordUpdateOnUnlabelledConstructor("Empty"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicateArgument("x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.MissingField("missing field"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicateArgumentName("x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnlabelledArgumentAfterLabelled,
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.PositionalArgumentAfterLabelled,
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicateConstructor("V"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.PrivateTypeLeak("T"),
    ),
    errors.format_glimpse_type_check_error(module, glimpse_error.TodoInConstant),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidConstantExpression,
    ),
    errors.format_glimpse_type_check_error(module, glimpse_error.FnInConstant),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnusedTypeParameter("a"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnnecessarySpread,
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DoubleVariableAssignment,
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicateDefinition("x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicateTypeParameter("a"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicateLabel("x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.TypeUsedAsConstructor("T"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.ExternalTypeWithConstructors("T"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.IncorrectPatternCount(2, 1),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicatePatternVariable("x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.MissingPatternVariable("x"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.ExtraPatternVariable("x"),
    ),
    errors.format_glimpse_type_check_error(module, glimpse_error.RecursiveType),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.FloatOutOfRange("1e999"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidEscape("\\1"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnknownTarget("python"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidExternalAttribute,
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidExternalModule("bad mod"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidExternalFunction("1bad"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.ExternalAttributePlacement("a constant"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidAttributePlacement("@target", "a constant"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidTypeName("Foo_bar"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidFunctionName("doStuff"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidConstantName("doStuff"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidArgumentName("doStuff"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidTypeVariableName("doStuff"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidVariableName("doStuff"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidVariantName("Bar_"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidTypeAliasName("A_b"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidAttributeShape("@deprecated"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnknownAttribute("@nope"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicateAttribute("@deprecated"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.UnsupportedTarget("wibble"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.MissingImplementation("f"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.DuplicateImport("foo"),
    ),
    errors.format_glimpse_type_check_error(
      module,
      glimpse_error.InvalidType("Int", "String", ""),
    ),
  ]
  assert list.all(variants, fn(message) {
    string.starts_with(message, "error: ")
    && string.length(message) > string.length("error: ")
  })
}

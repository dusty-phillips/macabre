import gleeunit/should
import glexer
import glexer/token
import internal/errors
import pprint

// Reminder: glexer.Position is 0-indexed, but output columns are 1-indexed
pub fn position_at_first_byte_test() {
  errors.format_unexpected_token(token.Int("5"), glexer.Position(0), "5bcdefg")
  |> should.equal("Unexpected Token 5\nAt line 1 column 1\n\n5bcdefg\n^\n")
}

pub fn position_in_first_line_test() {
  errors.format_unexpected_token(token.Int("5"), glexer.Position(4), "abcd5fg")
  |> should.equal("Unexpected Token 5\nAt line 1 column 5\n\nabcd5fg\n    ^\n")
}

pub fn position_in_second_line_test() {
  errors.format_unexpected_token(
    token.Int("5"),
    glexer.Position(5),
    "abc\nd5fg",
  )
  |> should.equal("Unexpected Token 5\nAt line 2 column 2\n\nd5fg\n ^\n")
}

pub fn position_after_newline_test() {
  errors.format_unexpected_token(
    token.Int("5"),
    glexer.Position(6),
    "abc\n\nd5fg",
  )
  |> should.equal("Unexpected Token 5\nAt line 3 column 2\n\nd5fg\n ^\n")
}

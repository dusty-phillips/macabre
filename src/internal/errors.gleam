import glance
import gleam/bit_array
import gleam/bytes_builder.{type BytesBuilder}
import gleam/int
import gleam/iterator
import gleam/list
import gleam/result
import gleam/string
import glexer
import glexer/token
import internal/bytes
import pprint

pub fn format_glance_error(
  error: glance.Error,
  filename: String,
  contents: String,
) -> String {
  pprint.debug(error)
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
    current_line_bytes: BytesBuilder,
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
      current_line_bytes: bytes_builder.new(),
      current_line_first_byte_position: 0,
      current_position: 0,
      // glexer positions start at byte 0, which is character 1 on a line based system
      target_position: position.byte_offset + 1,
    )

  let position_state =
    contents
    |> bytes.iterate
    |> iterator.fold_until(initial, fold_position_to_lines)

  case position_state.current_position {
    pos if pos < position_state.target_position ->
      "\nUnexpected EOF looking for "
      <> format_token(token)
      <> " at position "
      <> int.to_string(position_state.target_position)
    _ ->
      {
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
          |> bytes_builder.to_bit_array
          |> bit_array.to_string
          |> result.unwrap("Unexpected unicode")
        }
        <> "\n"
        <> string.repeat(" ", column - 1)
        <> "^\n"
      }
      |> pprint.debug
  }
}

// Given a byte position, return information about the line that contains that
// byte iterates over each bytes, counting lines. Once it finds the target,
// continues iterating until the end of the line and returns that line.
fn fold_position_to_lines(
  state: PositionState,
  byte: Int,
) -> list.ContinueOrStop(PositionState) {
  pprint.debug(#(
    PositionState(..state, current_line_bytes: bytes_builder.new()),
    byte,
  ))
  case byte, state.current_position, state.target_position {
    10, curr, target if curr < target ->
      list.Continue(
        PositionState(
          ..state,
          current_line_first_byte_position: state.current_position + 1,
          current_line_number: state.current_line_number + 1,
          current_line_bytes: bytes_builder.new(),
          current_position: state.current_position + 1,
        ),
      )
    10, _, _ -> list.Stop(state)
    byte, _, _ -> {
      list.Continue(
        PositionState(
          ..state,
          current_line_bytes: bytes_builder.append(state.current_line_bytes, <<
            byte,
          >>),
          current_position: state.current_position + 1,
        ),
      )
    }
  }
}

fn format_token(token: token.Token) -> String {
  case token {
    token.Int(num_str) -> num_str
    _ -> {
      pprint.debug(token)
      "<TODO Unknown Token>"
    }
  }
}

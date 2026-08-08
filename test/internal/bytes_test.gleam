import gleam/yielder
import internal/bytes

pub fn iterate_ascii_bytes_test() {
  assert bytes.iterate("hello") |> yielder.to_list == [104, 101, 108, 108, 111]
}

pub fn iterate_utf8_bytes_test() {
  assert "🏳️‍🌈" |> bytes.iterate |> yielder.to_list
    == [240, 159, 143, 179, 239, 184, 143, 226, 128, 141, 240, 159, 140, 136]
}

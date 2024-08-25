import gleam/iterator
import gleeunit/should
import internal/bytes

pub fn iterate_ascii_bytes_test() {
  bytes.iterate("hello")
  |> iterator.to_list
  |> should.equal([104, 101, 108, 108, 111])
}

pub fn iterate_utf8_bytes_test() {
  "🏳️‍🌈"
  |> bytes.iterate
  |> iterator.to_list
  |> should.equal([
    240, 159, 143, 179, 239, 184, 143, 226, 128, 141, 240, 159, 140, 136,
  ])
}

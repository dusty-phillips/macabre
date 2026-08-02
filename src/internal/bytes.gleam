import gleam/yielder

pub fn iterate(string: String) -> yielder.Yielder(Int) {
  yielder.unfold(<<string:utf8>>, fn(remaining) {
    case remaining {
      <<>> -> yielder.Done
      <<byte:8, rest:bytes>> -> yielder.Next(byte, rest)
      _ -> panic as "string should always return a byte-aligned bitarray"
    }
  })
}

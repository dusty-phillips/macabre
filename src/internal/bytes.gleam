import gleam/iterator

pub fn iterate(string: String) -> iterator.Iterator(Int) {
  iterator.unfold(<<string:utf8>>, fn(remaining) {
    case remaining {
      <<>> -> iterator.Done
      <<byte:8, rest:bytes>> -> iterator.Next(byte, rest)
      _ -> panic as "string should always return a byte-aligned bitarray"
    }
  })
}

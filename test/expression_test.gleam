import glacier/should
import macabre

pub fn string_expression_test() {
  "fn main() {
      \"bar\"
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "def main():
    \"bar\"
    ",
  )
}

pub fn call_expression_test() {
  "fn main() {
      foo(\"bar\")
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "def main():
    foo(\"bar\")
    ",
  )
}

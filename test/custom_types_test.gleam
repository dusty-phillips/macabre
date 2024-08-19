import glacier/should
import macabre

pub fn single_variant_custom_type_test() {
  "pub type Foo {
  Bar(a: Int)
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from dataclasses import dataclass


class Foo:
    @dataclass(frozen=True)
    class Bar:
        a: int

Bar = Foo.Bar


",
  )
}

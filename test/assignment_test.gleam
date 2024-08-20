import glacier/should
import macabre

pub fn multi_variant_custom_type_test() {
  "pub fn main() {
    let a = \"hello world\"
  }
  "
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "def main():
    a = \"hello world\"
    ",
  )
}

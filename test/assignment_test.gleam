import gleeunit/should
import macabre

pub fn simple_assignment_test() {
  "pub fn main() {
    let a = \"hello world\"
  }
  "
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    a = \"hello world\"",
  )
}

pub fn mulitple_simple_assignment_test() {
  "pub fn main() {
    let a = \"hello world\"
    let b = 42
  }
  "
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    a = \"hello world\"
    b = 42",
  )
}

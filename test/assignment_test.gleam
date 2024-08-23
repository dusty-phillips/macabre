import compiler
import gleeunit/should

pub fn simple_assignment_test() {
  "pub fn main() {
    let a = \"hello world\"
  }
  "
  |> compiler.compile
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
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    a = \"hello world\"
    b = 42",
  )
}

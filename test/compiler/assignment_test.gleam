import compiler
import glance
import gleeunit/should

pub fn simple_assignment_test() {
  "pub fn main() {
    let a = \"hello world\"
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
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
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    a = \"hello world\"
    b = 42",
  )
}

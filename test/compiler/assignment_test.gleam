import compiler
import glance

pub fn simple_assignment_test() {
  let assert Ok(module) =
    "pub fn main() {
    let a = \"hello world\"
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    a = \"hello world\""
}

pub fn mulitple_simple_assignment_test() {
  let assert Ok(module) =
    "pub fn main() {
    let a = \"hello world\"
    let b = 42
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    a = \"hello world\"
    b = 42"
}

pub fn tuple_assignment_test() {
  let assert Ok(module) =
    "pub fn main() {
    let #(a, b) = #(\"one\", \"two\")
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_match_0(_case_subject):
        match _case_subject:
            case (a, b):
                return (a, b,)
    a, b = _fn_match_0((\"one\", \"two\",))"
}

pub fn let_assert_assignment_test() {
  let assert Ok(module) =
    "pub fn main() {
    let assert Some(x) = Some(1)
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_match_0(_case_subject):
        match _case_subject:
            case Some(x):
                return x
            case _:
                raise GleamPanic(\"assertion failed\")
    x = _fn_match_0(Some(1))"
}

pub fn let_assert_custom_message_test() {
  let assert Ok(module) =
    "pub fn main() {
    let assert Some(x) = Some(1) as \"expected Some\"
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_match_0(_case_subject):
        match _case_subject:
            case Some(x):
                return x
            case _:
                raise GleamPanic(\"expected Some\")
    x = _fn_match_0(Some(1))"
}

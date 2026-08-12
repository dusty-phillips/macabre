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
    a = \"hello world\"


__all__ = [\"main\"]
"
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
    b = 42


__all__ = [\"main\"]
"
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
    a, b = _fn_match_0((\"one\", \"two\",))


__all__ = [\"main\"]
"
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
                raise GleamPanic({\"gleam_error\": \"let_assert\", \"message\": \"Pattern match failed, no pattern matched the value.\", \"file\": \"\", \"module\": \"\", \"function\": \"main\", \"line\": 0, \"value\": _case_subject, \"start\": 20, \"end\": 48, \"pattern_start\": 31, \"pattern_end\": 38})
    x = _fn_match_0(Some(1))


__all__ = [\"main\"]
"
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
                raise GleamPanic({\"gleam_error\": \"let_assert\", \"message\": \"expected Some\", \"file\": \"\", \"module\": \"\", \"function\": \"main\", \"line\": 0, \"value\": _case_subject, \"start\": 20, \"end\": 48, \"pattern_start\": 31, \"pattern_end\": 38})
    x = _fn_match_0(Some(1))


__all__ = [\"main\"]
"
}

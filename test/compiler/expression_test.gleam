import compiler
import glance
import gleam/dict
import gleam/option

pub fn string_expression_test() {
  let assert Ok(module) =
    "fn main() {
      \"bar\"
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return \"bar\""
}

pub fn int_expression_test() {
  let assert Ok(module) =
    "fn main() {
      42
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 42"
}

pub fn leading_zero_int_expression_test() {
  let assert Ok(module) =
    "fn main() {
      04
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 4"
}

pub fn leading_zero_underscored_int_expression_test() {
  let assert Ok(module) =
    "fn main() {
      0_4
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 4"
}

pub fn base_prefixed_int_expression_test() {
  let assert Ok(module) =
    "fn main() {
      0xFF
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 0xFF"
}

pub fn zero_int_expression_test() {
  let assert Ok(module) =
    "fn main() {
      0
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 0"
}

pub fn leading_zero_float_expression_test() {
  let assert Ok(module) =
    "fn main() {
      04.5
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 04.5"
}

pub fn float_expression_test() {
  let assert Ok(module) =
    "fn main() {
      12.5
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 12.5"
}

pub fn tuple_expression_test() {
  let assert Ok(module) =
    "fn main() {
  #(42, 12.5, \"foo\")
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return (42, 12.5, \"foo\",)"
}

pub fn empty_list_expression_test() {
  let assert Ok(module) =
    "fn main() {
  []
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return EmptyGleamList()"
}

pub fn list_expression_with_contents_test() {
  let assert Ok(module) =
    "fn main() {
  [1, 2, 3]
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return GleamList(1, GleamList(2, GleamList(3, EmptyGleamList())))"
}

pub fn list_expression_with_tail_test() {
  let assert Ok(module) =
    "fn main() {
  [1, 2, ..[3, 4]]
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return GleamList(1, GleamList(2, GleamList(3, GleamList(4, EmptyGleamList()))))"
}

pub fn true_expression_test() {
  let assert Ok(module) =
    "fn main() {
      True
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return True"
}

pub fn false_expression_test() {
  let assert Ok(module) =
    "fn main() {
      False
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return False"
}

pub fn variable_expression_test() {
  let assert Ok(module) =
    "fn main() {
  println(a)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return println(a)"
}

pub fn negate_int_test() {
  let assert Ok(module) =
    "fn main() {
  let a = -1
  let b = -a
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    a = -1
    b = -a"
}

pub fn negate_bool_test() {
  let assert Ok(module) =
    "fn main() {
  let b = !True
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    b = not True"
}

pub fn empty_panic_test() {
  let assert Ok(module) =
    "fn main() {
  panic
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    raise GleamPanic({\"gleam_error\": \"panic\", \"message\": \"`panic` expression evaluated.\", \"file\": \"\", \"module\": \"\", \"function\": \"main\", \"line\": 0})"
}

pub fn string_panic_test() {
  let assert Ok(module) =
    "fn main() {
  panic as \"my custom panic\"
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    raise GleamPanic({\"gleam_error\": \"panic\", \"message\": \"my custom panic\", \"file\": \"\", \"module\": \"\", \"function\": \"main\", \"line\": 0})"
}

pub fn empty_todo_test() {
  let assert Ok(module) =
    "fn main() {
  todo
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    raise NotImplementedError({\"gleam_error\": \"todo\", \"message\": \"`todo` expression evaluated. This code has not yet been implemented.\", \"file\": \"\", \"module\": \"\", \"function\": \"main\", \"line\": 0})"
}

pub fn case_clause_panic_test() {
  let assert Ok(module) =
    "fn main() {
  case 1 {
    1 -> panic
    _ -> 2
  }
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 1:
                raise GleamPanic({\"gleam_error\": \"panic\", \"message\": \"`panic` expression evaluated.\", \"file\": \"\", \"module\": \"\", \"function\": \"main\", \"line\": 0})
            case _:
                return 2
    return _fn_case_0(1)"
}

pub fn case_clause_todo_test() {
  let assert Ok(module) =
    "fn main() {
  case 1 {
    1 -> todo
    _ -> 2
  }
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 1:
                raise NotImplementedError({\"gleam_error\": \"todo\", \"message\": \"`todo` expression evaluated. This code has not yet been implemented.\", \"file\": \"\", \"module\": \"\", \"function\": \"main\", \"line\": 0})
            case _:
                return 2
    return _fn_case_0(1)"
}

pub fn string_todo_test() {
  let assert Ok(module) =
    "fn main() {
  todo as \"much is yet to be done\"
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    raise NotImplementedError({\"gleam_error\": \"todo\", \"message\": \"much is yet to be done\", \"file\": \"\", \"module\": \"\", \"function\": \"main\", \"line\": 0})"
}

pub fn tuple_index_test() {
  let assert Ok(module) =
    "fn main() {
  #(42, 12.5, \"foo\").1
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return (42, 12.5, \"foo\",)[1]"
}

pub fn field_access_test() {
  let assert Ok(module) =
    "fn main() {
    foo.b
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return foo.b"
}

pub fn binop_int_add_test() {
  let assert Ok(module) =
    "fn main() {
    40 + 2
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 40 + 2"
}

pub fn binop_float_add_test() {
  let assert Ok(module) =
    "fn main() {
    40.2 +. 2.5
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 40.2 + 2.5"
}

pub fn binop_concat_add_test() {
  let assert Ok(module) =
    "fn main() {
    \"hello \" <> \"world\"
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return \"hello \" + \"world\""
}

pub fn binop_int_sub_test() {
  let assert Ok(module) =
    "fn main() {
    40 - 2
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 40 - 2"
}

pub fn binop_float_sub_test() {
  let assert Ok(module) =
    "fn main() {
    40.2 -. 2.5
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 40.2 - 2.5"
}

pub fn binop_int_div_test() {
  let assert Ok(module) =
    "fn main() {
    40 / 2
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_int_div(40, 2)"
}

pub fn binop_float_div_test() {
  let assert Ok(module) =
    "fn main() {
    40.2 /. 2.5
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_float_div(40.2, 2.5)"
}

pub fn binop_int_modulo_test() {
  let assert Ok(module) =
    "fn main() {
    5 % 2
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_int_rem(5, 2)"
}

pub fn equality_test() {
  let assert Ok(module) =
    "fn main() {
    5 == 5
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 5 == 5"
}

pub fn inequality_test() {
  let assert Ok(module) =
    "fn main() {
    5 != 2
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 5 != 2"
}

pub fn lt_int_test() {
  let assert Ok(module) =
    "fn main() {
    5 < 2
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 5 < 2"
}

pub fn lt_float_test() {
  let assert Ok(module) =
    "fn main() {
    5.0 <. 2.0
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 5.0 < 2.0"
}

pub fn lt_eq_int_test() {
  let assert Ok(module) =
    "fn main() {
    5 <= 2
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 5 <= 2"
}

pub fn lt_eq_float_test() {
  let assert Ok(module) =
    "fn main() {
    5.0 <=. 2.0
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return 5.0 <= 2.0"
}

pub fn logical_or_test() {
  let assert Ok(module) =
    "fn main() {
    True || False
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return True or False"
}

pub fn logical_and_test() {
  let assert Ok(module) =
    "fn main() {
    True && False
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return True and False"
}

pub fn simple_pipe_test() {
  let assert Ok(module) =
    "fn main() {
    \"foo\" |> println
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return println(\"foo\")"
}

pub fn capture_pipe_test() {
  let assert Ok(module) =
    "fn main() {
    \"foo\" |> println(\"a\", _, \"b\")
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return (lambda fn_capture: println(\"a\", fn_capture, \"b\"))(\"foo\")"
}

pub fn pipe_into_case_test() {
  let assert Ok(module) =
    "fn add(a: Int, b: Int) -> Int {
    a + b
  }

  fn main() {
    5 |> case 3 {
      3 -> add(_, 10)
      _ -> add(_, 0)
    }
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def add(a, b):
    return a + b


def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 3:
                return (lambda fn_capture: add(fn_capture, 10))
            case _:
                return (lambda fn_capture: add(fn_capture, 0))
    return _fn_case_0(3)(5)"
}

pub fn pipe_into_complete_call_test() {
  let assert Ok(module) =
    "pub fn tag(prefix: String) -> fn(Int) -> String {
    fn(x: Int) -> String { prefix }
  }

  fn main() {
    42 |> tag(\"answer\")
  }"
    |> glance.module
  let signatures = dict.from_list([#("tag", [#(option.None, "prefix")])])
  assert compiler.compile_module_with_signatures(module, signatures)
    == "from __future__ import annotations
from gleam_builtins import *

def tag(prefix):
    def _fn_def_0(x):
        return prefix
    return _fn_def_0


def main():
    return tag(\"answer\")(42)


__all__ = [\"tag\"]
"
}

pub fn pipe_into_incomplete_call_test() {
  let assert Ok(module) =
    "pub fn three(a: Int, b: Int, c: Int) -> Int {
    a + b + c
  }

  fn main() {
    42 |> three(1, 2)
  }"
    |> glance.module
  let signatures =
    dict.from_list([
      #("three", [
        #(option.None, "a"),
        #(option.None, "b"),
        #(option.None, "c"),
      ]),
    ])
  assert compiler.compile_module_with_signatures(module, signatures)
    == "from __future__ import annotations
from gleam_builtins import *

def three(a, b, c):
    return a + b + c


def main():
    return three(42, 1, 2)


__all__ = [\"three\"]
"
}

pub fn simple_call_expression_test() {
  let assert Ok(module) =
    "fn main() {
      foo(\"bar\")
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return foo(\"bar\")"
}

pub fn labelled_argument_call_expression_test() {
  let assert Ok(module) =
    "fn main() {
      foo(\"bar\", baz: \"baz\")
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return foo(\"bar\", baz=\"baz\")"
}

pub fn fn_capture_test() {
  let assert Ok(module) =
    "fn main() {
      let x = foo(\"a\", _, \"b\")
      x(\"c\")
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    x = (lambda fn_capture: foo(\"a\", fn_capture, \"b\"))
    return x(\"c\")"
}

pub fn record_update_test() {
  let assert Ok(module) =
    "pub type Foo {
    Bar(a: Int, b: String)
  }

  pub fn main() {
    let foo = Bar(1, \"who\")
    let bar = Bar(..foo, b: \"you\")
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    a: int
    b: str
    
    def __hash__(self):
        return gleam_hash(self)
    


def main():
    foo = Bar(1, \"who\")
    bar = dataclasses.replace(foo, b=\"you\")


__all__ = [\"main\", \"Bar\"]
"
}

pub fn construct_record_with_label_test() {
  let assert Ok(module) =
    "pub type Foo {
    Bar(a: Int, b: String)
  }

  pub fn main() {
    let foo = Bar(b: \"who\", a: 1)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    a: int
    b: str
    
    def __hash__(self):
        return gleam_hash(self)
    


def main():
    foo = Bar(a=1, b=\"who\")


__all__ = [\"main\", \"Bar\"]
"
}

pub fn simple_fn_test() {
  let assert Ok(module) =
    "pub fn main() {
    let foo = fn(a, b) {}
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_def_0(a, b):
        pass
    foo = _fn_def_0


__all__ = [\"main\"]
"
}

pub fn multiple_fn_test() {
  let assert Ok(module) =
    "pub fn main() {
    let foo = #(fn(a, b) {}, fn(c, d) {})
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_def_0(a, b):
        pass
    def _fn_def_1(c, d):
        pass
    foo = (_fn_def_0, _fn_def_1,)


__all__ = [\"main\"]
"
}

pub fn nested_fn_test() {
  let assert Ok(module) =
    "pub fn main() {
    let foo = fn(a, b) {
      let bar = fn(c, d) {}
    }
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_def_0(a, b):
        def _fn_def_0(c, d):
            pass
        bar = _fn_def_0
    foo = _fn_def_0


__all__ = [\"main\"]
"
}

pub fn simple_block_test() {
  let assert Ok(module) =
    "pub fn main() {
    let foo = {1}
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_block_0():
        return 1
    foo = _fn_block_0()


__all__ = [\"main\"]
"
}

pub fn multiple_block_test() {
  let assert Ok(module) =
    "pub fn main() {
    let foo = {1}
    let bar = {2}
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_block_0():
        return 1
    foo = _fn_block_0()
    def _fn_block_1():
        return 2
    bar = _fn_block_1()


__all__ = [\"main\"]
"
}

pub fn nested_block_test() {
  let assert Ok(module) =
    "pub fn main() {
    let foo = {
      { 1 }
    }
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_block_0():
        def _fn_block_0():
            return 1
        return _fn_block_0()
    foo = _fn_block_0()


__all__ = [\"main\"]
"
}

pub fn const_test() {
  let assert Ok(module) = "const foo = 5" |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

foo = 5

"
}

pub fn const_referencing_function_comes_after_functions_test() {
  let assert Ok(module) =
    "fn identity(x: Int) -> Int {
    x
  }

  const five = identity(5)"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def identity(x):
    return x


five = identity(5)

"
}

pub fn string_escape_control_char_test() {
  let assert Ok(module) =
    "fn main() {
      \"\\u{1b}[\"
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return \"\\x1b[\""
}

pub fn string_escape_quote_and_newline_test() {
  let assert Ok(module) =
    "fn main() {
      \"say \\\"hi\\\"\\n\"
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return \"say \\\"hi\\\"\\n\""
}

pub fn nil_pattern_in_case_test() {
  let assert Ok(module) =
    "fn main() {
  let value = Ok(1)
  case value {
    Error(Nil) -> 0
    Ok(x) -> x
  }
}"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    value = Ok(1)
    def _fn_case_0(_case_subject):
        match _case_subject:
            case Error(None):
                return 0
            case Ok(x):
                return x
    return _fn_case_0(value)"
}

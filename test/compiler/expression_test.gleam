import compiler
import glance
import gleeunit/should

pub fn string_expression_test() {
  "fn main() {
      \"bar\"
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return \"bar\"",
  )
}

pub fn int_expression_test() {
  "fn main() {
      42
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 42",
  )
}

pub fn float_expression_test() {
  "fn main() {
      12.5
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 12.5",
  )
}

pub fn tuple_expression_test() {
  "fn main() {
  #(42, 12.5, \"foo\")
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return (42, 12.5, \"foo\",)",
  )
}

pub fn empty_list_expression_test() {
  "fn main() {
  []
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return to_gleam_list([])",
  )
}

pub fn list_expression_with_contents_test() {
  "fn main() {
  [1, 2, 3]
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return to_gleam_list([1, 2, 3])",
  )
}

pub fn list_expression_with_tail_test() {
  "fn main() {
  [1, 2, ..[3, 4]]
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return to_gleam_list([1, 2], to_gleam_list([3, 4]))",
  )
}

pub fn true_expression_test() {
  "fn main() {
      True
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return True",
  )
}

pub fn false_expression_test() {
  "fn main() {
      False
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return False",
  )
}

pub fn variable_expression_test() {
  "fn main() {
  println(a)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return println(a)",
  )
}

pub fn negate_int_test() {
  "fn main() {
  let a = -1
  let b = -a
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    a = -1
    b = -a",
  )
}

pub fn negate_bool_test() {
  "fn main() {
  let b = !True
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    b = not True",
  )
}

pub fn empty_panic_test() {
  "fn main() {
  panic
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    raise GleamPanic(\"panic expression evaluated\")",
  )
}

pub fn string_panic_test() {
  "fn main() {
  panic as \"my custom panic\"
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    raise GleamPanic(\"my custom panic\")",
  )
}

pub fn empty_todo_test() {
  "fn main() {
  todo
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    raise NotImplementedError(\"This has not yet been implemented\")",
  )
}

pub fn string_todo_test() {
  "fn main() {
  todo as \"much is yet to be done\"
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    raise NotImplementedError(\"much is yet to be done\")",
  )
}

pub fn tuple_index_test() {
  "fn main() {
  #(42, 12.5, \"foo\").1
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return (42, 12.5, \"foo\",)[1]",
  )
}

pub fn field_access_test() {
  "fn main() {
    foo.b
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return foo.b",
  )
}

pub fn binop_int_add_test() {
  "fn main() {
    40 + 2
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 40 + 2",
  )
}

pub fn binop_float_add_test() {
  "fn main() {
    40.2 +. 2.5
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 40.2 + 2.5",
  )
}

pub fn binop_concat_add_test() {
  "fn main() {
    \"hello \" <> \"world\"
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return \"hello \" + \"world\"",
  )
}

pub fn binop_int_sub_test() {
  "fn main() {
    40 - 2
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 40 - 2",
  )
}

pub fn binop_float_sub_test() {
  "fn main() {
    40.2 -. 2.5
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 40.2 - 2.5",
  )
}

pub fn binop_int_div_test() {
  "fn main() {
    40 / 2
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 40 // 2",
  )
}

pub fn binop_float_div_test() {
  "fn main() {
    40.2 /. 2.5
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 40.2 / 2.5",
  )
}

pub fn binop_int_modulo_test() {
  "fn main() {
    5 % 2
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 5 % 2",
  )
}

pub fn equality_test() {
  "fn main() {
    5 == 5
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 5 == 5",
  )
}

pub fn inequality_test() {
  "fn main() {
    5 != 2
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 5 != 2",
  )
}

pub fn lt_int_test() {
  "fn main() {
    5 < 2
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 5 < 2",
  )
}

pub fn lt_float_test() {
  "fn main() {
    5.0 <. 2.0
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 5.0 < 2.0",
  )
}

pub fn lt_eq_int_test() {
  "fn main() {
    5 <= 2
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 5 <= 2",
  )
}

pub fn lt_eq_float_test() {
  "fn main() {
    5.0 <=. 2.0
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return 5.0 <= 2.0",
  )
}

pub fn logical_or_test() {
  "fn main() {
    True || False
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return True or False",
  )
}

pub fn logical_and_test() {
  "fn main() {
    True && False
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return True and False",
  )
}

pub fn simple_pipe_test() {
  "fn main() {
    \"foo\" |> println
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return println(\"foo\")",
  )
}

pub fn capture_pipe_test() {
  "fn main() {
    \"foo\" |> println(\"a\", _, \"b\")
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return (lambda fn_capture: println(\"a\", fn_capture, \"b\"))(\"foo\")",
  )
}

pub fn simple_call_expression_test() {
  "fn main() {
      foo(\"bar\")
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return foo(\"bar\")",
  )
}

pub fn labelled_argument_call_expression_test() {
  "fn main() {
      foo(\"bar\", baz: \"baz\")
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    return foo(\"bar\", baz=\"baz\")",
  )
}

pub fn fn_capture_test() {
  "fn main() {
      let x = foo(\"a\", _, \"b\")
      x(\"c\")
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    x = (lambda fn_capture: foo(\"a\", fn_capture, \"b\"))
    return x(\"c\")",
  )
}

pub fn record_update_test() {
  "pub type Foo {
    Bar(a: Int, b: String)
  }

  pub fn main() {
    let foo = Bar(1, \"who\")
    let bar = Bar(..foo, b: \"you\")
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    a: int
    b: str


def main():
    foo = Bar(1, \"who\")
    bar = dataclasses.replace(foo, b=\"you\")",
  )
}

pub fn construct_record_with_label_test() {
  "pub type Foo {
    Bar(a: Int, b: String)
  }

  pub fn main() {
    let foo = Bar(b: \"who\", a: 1)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    a: int
    b: str


def main():
    foo = Bar(b=\"who\", a=1)",
  )
}

pub fn simple_fn_test() {
  "pub fn main() {
    let foo = fn(a, b) {}
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_def_0(a, b):
        pass
    foo = _fn_def_0",
  )
}

pub fn multiple_fn_test() {
  "pub fn main() {
    let foo = #(fn(a, b) {}, fn(c, d) {})
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_def_0(a, b):
        pass
    def _fn_def_1(c, d):
        pass
    foo = (_fn_def_0, _fn_def_1,)",
  )
}

pub fn nested_fn_test() {
  "pub fn main() {
    let foo = fn(a, b) {
      let bar = fn(c, d) {}
    }
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_def_0(a, b):
        def _fn_def_0(c, d):
            pass
        bar = _fn_def_0
    foo = _fn_def_0",
  )
}

pub fn simple_block_test() {
  "pub fn main() {
    let foo = {1}
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_block_0():
        return 1
    foo = _fn_block_0()",
  )
}

pub fn multiple_block_test() {
  "pub fn main() {
    let foo = {1}
    let bar = {2}
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_block_0():
        return 1
    foo = _fn_block_0()
    def _fn_block_1():
        return 2
    bar = _fn_block_1()",
  )
}

pub fn nested_block_test() {
  "pub fn main() {
    let foo = {
      { 1 }
    }
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_block_0():
        def _fn_block_0():
            return 1
        return _fn_block_0()
    foo = _fn_block_0()",
  )
}

pub fn const_test() {
  "const foo = 5"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

foo = 5

",
  )
}

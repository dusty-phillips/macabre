import gleeunit/should
import macabre

pub fn string_expression_test() {
  "fn main() {
      \"bar\"
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    \"bar\"
    ",
  )
}

pub fn int_expression_test() {
  "fn main() {
      42
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    42
    ",
  )
}

pub fn float_expression_test() {
  "fn main() {
      12.5
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    12.5
    ",
  )
}

pub fn tuple_expression_test() {
  "fn main() {
  #(42, 12.5, \"foo\")
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    (42, 12.5, \"foo\")
    ",
  )
}

pub fn true_expression_test() {
  "fn main() {
      True
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    True
    ",
  )
}

pub fn false_expression_test() {
  "fn main() {
      False
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    False
    ",
  )
}

pub fn variable_expression_test() {
  "fn main() {
  println(a)
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    println(a)
    ",
  )
}

pub fn negate_int_test() {
  "fn main() {
  let a = -1
  let b = -a
  }"
  |> macabre.compile
  |> should.be_ok
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
  |> macabre.compile
  |> should.be_ok
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
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    raise BaseException(\"panic expression evaluated\")
    ",
  )
}

pub fn string_panic_test() {
  "fn main() {
  panic as \"my custom panic\"
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    raise BaseException(\"my custom panic\")
    ",
  )
}

pub fn empty_todo_test() {
  "fn main() {
  todo
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    raise NotImplementedError(\"This has not yet been implemented\")
    ",
  )
}

pub fn string_todo_test() {
  "fn main() {
  todo as \"much is yet to be done\"
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    raise NotImplementedError(\"much is yet to be done\")
    ",
  )
}

pub fn tuple_index_test() {
  "fn main() {
  #(42, 12.5, \"foo\").1
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    (42, 12.5, \"foo\")[1]
    ",
  )
}

pub fn field_access_test() {
  "fn main() {
    foo.b
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    foo.b
    ",
  )
}

pub fn binop_int_add_test() {
  "fn main() {
    40 + 2
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    40 + 2
    ",
  )
}

pub fn binop_float_add_test() {
  "fn main() {
    40.2 +. 2.5
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    40.2 + 2.5
    ",
  )
}

pub fn binop_concat_add_test() {
  "fn main() {
    \"hello \" <> \"world\"
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    \"hello \" + \"world\"
    ",
  )
}

pub fn binop_int_sub_test() {
  "fn main() {
    40 - 2
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    40 - 2
    ",
  )
}

pub fn binop_float_sub_test() {
  "fn main() {
    40.2 -. 2.5
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    40.2 - 2.5
    ",
  )
}

pub fn binop_int_div_test() {
  "fn main() {
    40 / 2
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    40 // 2
    ",
  )
}

pub fn binop_float_div_test() {
  "fn main() {
    40.2 /. 2.5
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    40.2 / 2.5
    ",
  )
}

pub fn binop_int_modulo_test() {
  "fn main() {
    5 % 2
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    5 % 2
    ",
  )
}

pub fn equality_test() {
  "fn main() {
    5 == 5
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    5 == 5
    ",
  )
}

pub fn inequality_test() {
  "fn main() {
    5 != 2
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    5 != 2
    ",
  )
}

pub fn lt_int_test() {
  "fn main() {
    5 < 2
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    5 < 2
    ",
  )
}

pub fn lt_float_test() {
  "fn main() {
    5.0 <. 2.0
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    5.0 < 2.0
    ",
  )
}

pub fn lt_eq_int_test() {
  "fn main() {
    5 <= 2
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    5 <= 2
    ",
  )
}

pub fn lt_eq_float_test() {
  "fn main() {
    5.0 <=. 2.0
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    5.0 <= 2.0
    ",
  )
}

pub fn logical_or_test() {
  "fn main() {
    True || False
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    True or False
    ",
  )
}

pub fn logical_and_test() {
  "fn main() {
    True && False
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    True and False
    ",
  )
}

pub fn simple_pipe_test() {
  "fn main() {
    \"foo\" |> println
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    println(\"foo\")
    ",
  )
}

pub fn capture_pipe_test() {
  "fn main() {
    \"foo\" |> println(\"a\", _, \"b\")
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    println(\"a\", \"foo\", \"b\")
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
    "from gleam_builtins import *

def main():
    foo(\"bar\")
    ",
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
  |> macabre.compile
  |> should.be_ok
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

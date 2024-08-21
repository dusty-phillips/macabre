import gleeunit/should
import macabre

pub fn external_python_test() {
  "@external(python, \"mylib\", \"println\")
  fn println() -> nil"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

from mylib import println\n\n\n",
  )
}

pub fn skip_external_javascript_test() {
  // TODO: I'm not sure if we're supposed to generate an empty function
  // if an external exists for one language but not a body and there is no
  // default body.
  //
  "@external(javascript, \"mylib\", \"println\")
fn println() -> nil"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def println():
    pass",
  )
}

pub fn skip_external_erlang_test() {
  // TODO: I'm not sure if we're supposed to generate an empty function
  // if an external exists for one language but not python there is no
  // default body.
  //
  "@external(erlang, \"mylib\", \"println\")
fn println() -> nil"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def println():
    pass",
  )
}

pub fn empty_body_no_external_test() {
  "fn println() -> nil"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def println():
    pass",
  )
}

pub fn function_with_string_param_test() {
  "fn println(arg: String) -> nil {}"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def println(arg):
    pass",
  )
}

pub fn function_with_two_string_params_test() {
  "fn println(arg: String, other: String) -> nil {}"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def println(arg, other):
    pass",
  )
}

pub fn two_functions_test() {
  "fn func1() -> nil {}

fn func2() -> nil {}
"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def func1():
    pass


def func2():
    pass",
  )
}

pub fn function_with_return_value_test() {
  "fn greet() -> String {
  \"hello world\"
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def greet():
    return \"hello world\"",
  )
}

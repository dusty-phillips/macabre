import compiler
import glance
import gleeunit/should

pub fn use_call_no_params_test() {
  "fn use_thing(func: fn () -> String) -> Nil {
    func(\"thing\")

  }
  pub fn main() {
    use _ <- use_thing() 
    \"hi\"
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def use_thing(func):
    return func(\"thing\")


def main():
    def _fn_def_0(_):
        return \"hi\"
    return use_thing(_fn_def_0)",
  )
}

pub fn use_call_with_params_test() {
  "fn use_thing(x: String, y: String, func: fn () -> String) -> Nil {
    x <> y <> func(\"thing\")

  }
  pub fn main() {
    use x <- use_thing(\"one\", \"two\") 
    \"hi\"
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def use_thing(x, y, func):
    return x + y + func(\"thing\")


def main():
    def _fn_def_0(x):
        return \"hi\"
    return use_thing(\"one\", \"two\", _fn_def_0)",
  )
}

pub fn use_variable_no_params_test() {
  "fn use_thing(func: fn () -> String) -> Nil {
     func(\"thing\")

  }
  pub fn main() {
    let f = use_thing
    use _ <- f 
    \"hi\"
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def use_thing(func):
    return func(\"thing\")


def main():
    f = use_thing
    def _fn_def_0(_):
        return \"hi\"
    return f(_fn_def_0)",
  )
}

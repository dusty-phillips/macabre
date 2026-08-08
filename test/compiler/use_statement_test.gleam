import compiler
import glance
import gleam/dict
import gleam/option
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

pub fn use_tuple_pattern_test() {
  "fn use_thing(func: fn (#(Int, Int)) -> String) -> Nil {
    func(#(1, 2))

  }
  pub fn main() {
    use #(a, b) <- use_thing()
    \"hi\"
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def use_thing(func):
    return func((1, 2,))


def main():
    def _fn_def_0(use_capture_0):
        def _fn_match_0(_case_subject):
            match _case_subject:
                case (a, b):
                    return (a, b,)
        a, b = _fn_match_0(use_capture_0)
        return \"hi\"
    return use_thing(_fn_def_0)",
  )
}

// An assignment inside a case arm of a use callback that shadows an enclosing
// scope's name (and references it in its right hand side) must be renamed,
// e.g. glance's `expression_loop` where `values = to_gleam_list([e], values)`
// shadows the `values` parameter.
pub fn case_arm_assignment_shadowing_enclosing_scope_test() {
  "fn expression_unit() -> Result(Int, Nil) {
    Ok(1)

  }
  fn expression_loop(values: List(Int)) -> List(Int) {
    use expression <- result.try(expression_unit())
    case expression {
      1 -> {
        let values = [expression, ..values]
        values
      }
      _ -> values
    }
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def expression_unit():
    return Ok(1)


def expression_loop(values):
    def _fn_def_0(expression):
        def _fn_case_0(_case_subject):
            match _case_subject:
                case 1:
                    values_0 = to_gleam_list([expression], values)
                    return values_0
                case _:
                    return values
        return _fn_case_0(expression)
    return result.try_(expression_unit(), _fn_def_0)",
  )
}

// Post-binding references nested inside a further match (inside the case arm)
// must also be renamed, like glance's `expression_loop` where the operator
// handling nested inside the arm references the updated `values`.
pub fn case_arm_assignment_shadowing_nested_match_test() {
  "fn expression_unit() -> Result(Int, Nil) {
    Ok(1)

  }
  fn expression_loop(values: List(Int)) -> List(Int) {
    use expression <- result.try(expression_unit())
    case expression {
      1 -> {
        let values = [expression, ..values]
        case handle_operator(Some(1), [], values) {
          #(Some(updated), _, _) -> updated
          _ -> values
        }
      }
      _ -> values
    }
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def expression_unit():
    return Ok(1)


def expression_loop(values):
    def _fn_def_0(expression):
        def _fn_case_0(_case_subject):
            match _case_subject:
                case 1:
                    values_0 = to_gleam_list([expression], values)
                    def _fn_case_0(_case_subject):
                        match _case_subject:
                            case (Some(updated), _, _):
                                return updated
                            case _:
                                return values_0
                    return _fn_case_0(handle_operator(Some(1), to_gleam_list([]), values_0))
                case _:
                    return values
        return _fn_case_0(expression)
    return result.try_(expression_unit(), _fn_def_0)",
  )
}

pub fn use_callback_relabelled_to_last_parameter_test() {
  let signatures =
    dict.from_list([
      #("guard", [
        #(option.Some("when"), "when"),
        #(option.Some("return"), "return"),
        #(option.Some("otherwise"), "otherwise"),
      ]),
    ])
  "pub fn main() {
  use <- guard(when: True, return: \"\")
    \"done\"
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module_with_signatures(signatures)
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_def_0():
        return \"done\"
    return guard(when=True, return_=\"\", otherwise=_fn_def_0)",
  )
}

pub fn use_callback_relabelled_cross_module_test() {
  let signatures =
    dict.from_list([
      #("bool.guard", [
        #(option.Some("when"), "when"),
        #(option.Some("return"), "return"),
        #(option.Some("otherwise"), "otherwise"),
      ]),
    ])
  "import gleam/bool
pub fn main() {
  use <- bool.guard(when: True, return: \"\")
  \"done\"
}
"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module_with_signatures(signatures)
  |> should.equal(
    "from gleam_builtins import *

import gleam.bool
from gleam import bool


def main():
    def _fn_def_0():
        return \"done\"
    return bool.guard(when=True, return_=\"\", otherwise=_fn_def_0)",
  )
}

pub fn use_callback_with_unlabelled_arguments_test() {
  let signatures =
    dict.from_list([
      #("list.try_fold", [
        #(option.Some("over"), "over"),
        #(option.Some("from"), "from"),
        #(option.Some("with"), "with"),
      ]),
    ])
  "pub fn main() {
  use <- list.try_fold(contents, [])
  \"done\"
}
"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module_with_signatures(signatures)
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_def_0():
        return \"done\"
    return list.try_fold(contents, to_gleam_list([]), _fn_def_0)",
  )
}

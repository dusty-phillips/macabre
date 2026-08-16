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
    a, b = (\"one\", \"two\",)


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

pub fn rebind_reference_before_binding_test() {
  let assert Ok(module) =
    "pub fn sequences(from initial: List(Int)) -> List(Int) {
    let growing = [0, ..initial]
    let growing = [1, ..growing]
    growing
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def sequences(initial):
    growing = GleamList(0, initial)
    growing_0 = GleamList(1, growing)
    return growing_0


__all__ = [\"sequences\"]
"
}

pub fn closure_captures_original_parameter_test() {
  let assert Ok(module) =
    "pub fn fold(over dict: List(Int), from initial: Int, with fun: fn(Int, Int, Int) -> Int) -> Int {
    let fun = fn(key: Int, value: Int, acc: Int) -> Int { fun(acc, key, value) }
    do_fold(fun, initial, dict)
  }

  fn do_fold(fun: fn(Int, Int, Int) -> Int, initial: Int, dict: List(Int)) -> Int {
    initial
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def fold(dict, initial, fun):
    def _fn_def_0(key, value, acc):
        return fun(acc, key, value)
    fun_0 = _fn_def_0
    return do_fold(fun_0, initial, dict)


def do_fold(fun, initial, dict):
    return initial


__all__ = [\"fold\"]
"
}

pub fn case_subject_before_rebind_test() {
  let assert Ok(module) =
    "pub fn repeat_loop(times: Int, doubling_acc: String, acc: String) -> String {
    let acc = case times % 2 {
      0 -> acc
      _ -> acc <> doubling_acc
    }
    let times = times / 2
    case times <= 0 {
      True -> acc
      False -> repeat_loop(times, doubling_acc <> doubling_acc, acc)
    }
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def repeat_loop(times, doubling_acc, acc):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 0:
                return acc
            case _:
                return acc + doubling_acc
    def _fn_case_1(_case_subject):
        match _case_subject:
            case True:
                return acc_0
            case False:
                return GleamTco((times_0, doubling_acc + doubling_acc, acc_0,))
    while True:
        acc_0 = _fn_case_0(gleam_int_rem(times, 2))
        times_0 = gleam_int_div(times, 2)
        _result = _fn_case_1(times_0 <= 0)
        match isinstance(_result, GleamTco):
            case True:
                times, doubling_acc, acc = _result.args
            case False:
                return _result


__all__ = [\"repeat_loop\"]
"
}

// A `use` callback that rebinds a name its enclosing case pattern bound gets
// its own fresh name; the case pattern's cross rename must mint a different
// fresh name so the callback's pre-binding RHS reference still resolves to the
// pattern binding (not to the callback's own local).
pub fn use_callback_rebind_of_case_pattern_binding_test() {
  let assert Ok(module) =
    "pub type MyResult(a, e) {
    Ok(a)
    Error(e)
  }

  fn result_try(value: MyResult(a, e)) -> MyResult(a, e) {
    value
  }

  pub fn repro(input: MyResult(String, String)) -> MyResult(String, String) {
    case input {
      Error(error) -> Error(error)
      Ok(environment) -> {
        use first <- result_try(Ok(environment))
        use second <- result_try(Ok(environment))
        let environment = environment
        Ok(environment)
      }
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

A = typing.TypeVar('A')

E = typing.TypeVar('E')
@dataclasses.dataclass(frozen=True)
class Ok:
    _0: A
    
    def __hash__(self):
        return gleam_hash(self)
    

@dataclasses.dataclass(frozen=True)
class Error:
    _0: E
    
    def __hash__(self):
        return gleam_hash(self)
    


def result_try(value):
    return value


def repro(input):
    match input:
        case Error(error):
            return Error(error)
        case Ok(environment_1):
            def _fn_def_0(first):
                def _fn_def_0(second):
                    environment_0 = environment_1
                    return Ok(environment_0)
                return result_try(Ok(environment_1), _fn_def_0)
            return result_try(Ok(environment_1), _fn_def_0)


__all__ = [\"repro\", \"Ok\", \"Error\"]
"
}

// A `let` binding that shadows a parameter, combined with a nested function
// that rebinds the same name while referencing it on its own right hand side,
// must mint distinct Python names for the two bindings. The nested function's
// body resolves its own shadowing first, minting a fresh name from the shared
// pool; the enclosing function's shadowing must then use the pool advanced by
// that mint, or both bindings collapse onto the same name and the nested
// function's RHS reference resolves to its own (unbound) local.
pub fn use_callback_rebind_of_parameter_shadow_test() {
  let assert Ok(module) =
    "pub fn repro(environment: Int) -> Result(Int, Nil) {
    let environment = environment + 1
    let callback = fn(value: Int) -> Result(Int, Nil) {
      let environment = environment + value
      Ok(environment)
    }
    callback(environment)
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def repro(environment):
    environment_1 = environment + 1
    def _fn_def_0(value):
        environment_0 = environment_1 + value
        return Ok(environment_0)
    callback = _fn_def_0
    return callback(environment_1)


__all__ = [\"repro\"]
"
}

import compiler
import glance
import gleam/dict
import gleam/option

pub fn use_call_no_params_test() {
  let assert Ok(module) =
    "fn use_thing(func: fn () -> String) -> Nil {
    func(\"thing\")

  }
  pub fn main() {
    use _ <- use_thing() 
    \"hi\"
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from gleam_builtins import *

def use_thing(func):
    return func(\"thing\")


def main():
    def _fn_def_0(_):
        return \"hi\"
    return use_thing(_fn_def_0)"
}

pub fn use_call_with_params_test() {
  let assert Ok(module) =
    "fn use_thing(x: String, y: String, func: fn () -> String) -> Nil {
    x <> y <> func(\"thing\")

  }
  pub fn main() {
    use x <- use_thing(\"one\", \"two\") 
    \"hi\"
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from gleam_builtins import *

def use_thing(x, y, func):
    return x + y + func(\"thing\")


def main():
    def _fn_def_0(x):
        return \"hi\"
    return use_thing(\"one\", \"two\", _fn_def_0)"
}

pub fn use_variable_no_params_test() {
  let assert Ok(module) =
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
  assert compiler.compile_module(module) == "from gleam_builtins import *

def use_thing(func):
    return func(\"thing\")


def main():
    f = use_thing
    def _fn_def_0(_):
        return \"hi\"
    return f(_fn_def_0)"
}

pub fn use_tuple_pattern_test() {
  let assert Ok(module) =
    "fn use_thing(func: fn (#(Int, Int)) -> String) -> Nil {
    func(#(1, 2))

  }
  pub fn main() {
    use #(a, b) <- use_thing()
    \"hi\"
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from gleam_builtins import *

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
    return use_thing(_fn_def_0)"
}

// An assignment inside a case arm of a use callback that shadows an enclosing
// scope's name (and references it in its right hand side) must be renamed,
// e.g. glance's `expression_loop` where `values = to_gleam_list([e], values)`
// shadows the `values` parameter.
pub fn case_arm_assignment_shadowing_enclosing_scope_test() {
  let assert Ok(module) =
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
  assert compiler.compile_module(module) == "from gleam_builtins import *

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
    return result.try_(expression_unit(), _fn_def_0)"
}

// Post-binding references nested inside a further match (inside the case arm)
// must also be renamed, like glance's `expression_loop` where the operator
// handling nested inside the arm references the updated `values`.
pub fn case_arm_assignment_shadowing_nested_match_test() {
  let assert Ok(module) =
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
  assert compiler.compile_module(module) == "from gleam_builtins import *

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
    return result.try_(expression_unit(), _fn_def_0)"
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
  let assert Ok(module) =
    "pub fn main() {
  use <- guard(when: True, return: \"\")
    \"done\"
  }
  "
    |> glance.module
  assert compiler.compile_module_with_signatures(module, signatures)
    == "from gleam_builtins import *

def main():
    def _fn_def_0():
        return \"done\"
    return guard(when=True, return_=\"\", otherwise=_fn_def_0)"
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
  let assert Ok(module) =
    "import gleam/bool
pub fn main() {
  use <- bool.guard(when: True, return: \"\")
  \"done\"
}
"
    |> glance.module
  assert compiler.compile_module_with_signatures(module, signatures)
    == "from gleam_builtins import *

def main():
    def _fn_def_0():
        return \"done\"
    return bool.guard(when=True, return_=\"\", otherwise=_fn_def_0)


import gleam.bool
from gleam import bool


"
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
  let assert Ok(module) =
    "pub fn main() {
  use <- list.try_fold(contents, [])
  \"done\"
}
"
    |> glance.module
  assert compiler.compile_module_with_signatures(module, signatures)
    == "from gleam_builtins import *

def main():
    def _fn_def_0():
        return \"done\"
    return list.try_fold(contents, to_gleam_list([]), _fn_def_0)"
}

// A use callback destructuring a name that the enclosing case's pattern bound
// must rebind it to a fresh name: the callback's destructure shadows the
// pattern bind (which another arm references), and references after the
// destructure must point at the callback's own binding. This is the
// self-hosting bug in glance's `optional_return_annotation`, where the final
// reference was renamed to the pattern bind's name instead of the callback's.
pub fn use_callback_rebinding_case_pattern_bind_test() {
  let assert Ok(module) =
    "fn do_thing(x: List(Int)) -> Result(#(Int, List(Int)), Nil) {
    case x {
      [] -> Ok(#(0, x))
      _ -> Ok(#(1, x))
    }
  }
  pub fn parse(tokens: List(Int)) -> Result(#(Option(Int), List(Int)), Nil) {
    case tokens {
      [1, ..tokens] -> {
        use #(return_type, tokens) <- do_thing(tokens)
        Ok(#(Some(return_type), tokens))
      }
      _ -> Ok(#(None, tokens))
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from gleam_builtins import *

def do_thing(x):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case None:
                return Ok((0, x,))
            case _:
                return Ok((1, x,))
    return _fn_case_0(x)


def parse(tokens):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case GleamList(1, tokens_0):
                def _fn_def_0(use_capture_0):
                    def _fn_match_0(_case_subject):
                        match _case_subject:
                            case (return_type, tokens):
                                return (return_type, tokens,)
                    return_type, tokens_1 = _fn_match_0(use_capture_0)
                    return Ok((Some(return_type), tokens_1,))
                return do_thing(tokens_0, _fn_def_0)
            case _:
                return Ok((None, tokens,))
    return _fn_case_0(tokens)"
}

// Same scenario when the use callback sits inside a nested case within the
// arm: the enclosing case's renaming must survive the nested case's own
// (empty) renaming so the callback's destructure still rebinds fresh. This is
// the self-hosting bug in glance's `field`, where the labelled field value's
// reference was renamed to the outer pattern bind instead of the callback's.
pub fn use_callback_rebinding_nested_case_pattern_bind_test() {
  let assert Ok(module) =
    "fn do_thing(x: List(Int)) -> Result(#(Int, List(Int)), Nil) {
    case x {
      [] -> Ok(#(0, x))
      _ -> Ok(#(1, x))
    }
  }
  pub fn fields(tokens: List(Int)) -> Result(#(Int, List(Int)), Nil) {
    case tokens {
      [1, 2, ..tokens] -> {
        use #(t, tokens) <- do_thing(tokens)
        Ok(#(t, tokens))
      }
      _ -> case tokens {
        [] -> Error(Nil)
        _ -> {
          use #(t, tokens) <- do_thing(tokens)
          Ok(#(t, tokens))
        }
      }
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from gleam_builtins import *

def do_thing(x):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case None:
                return Ok((0, x,))
            case _:
                return Ok((1, x,))
    return _fn_case_0(x)


def fields(tokens):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case GleamList(1, GleamList(2, tokens_0)):
                def _fn_def_0(use_capture_0):
                    def _fn_match_0(_case_subject):
                        match _case_subject:
                            case (t, tokens):
                                return (t, tokens,)
                    t, tokens_1 = _fn_match_0(use_capture_0)
                    return Ok((t, tokens_1,))
                return do_thing(tokens_0, _fn_def_0)
            case _:
                def _fn_case_0(_case_subject):
                    match _case_subject:
                        case None:
                            return Error(None)
                        case _:
                            def _fn_def_1(use_capture_0):
                                def _fn_match_0(_case_subject):
                                    match _case_subject:
                                        case (t, tokens):
                                            return (t, tokens,)
                                t, tokens = _fn_match_0(use_capture_0)
                                return Ok((t, tokens,))
                            return do_thing(tokens, _fn_def_1)
                return _fn_case_0(tokens)
    return _fn_case_0(tokens)"
}

// A use callback rebinding a name that its own right hand side references
// from the enclosing scope must get a fresh name, leaving the references
// pointing at the earlier binding. This is the arc bug in
// `define_method_property`, where `let prop = case dict.get(...) {...}` inside
// the `heap.update` callback referenced the outer `prop` in the case arms.
pub fn use_callback_rebinding_enclosing_bind_test() {
  let assert Ok(module) =
    "fn update(x: Int) -> Result(Int, Nil) {
    Ok(x)
  }
  fn with_seq(a: Int, b: Int) -> Int {
    a + b
  }
  pub fn rebind(key: Int, val: Int) -> Int {
    let prop = case key {
      1 -> val
      _ -> val
    }
    use slot <- update(slot)
    let prop = case slot {
      Ok(old) -> with_seq(prop, old)
      Error(Nil) -> prop
    }
    with_seq(prop, slot)
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from gleam_builtins import *

def update(x):
    return Ok(x)


def with_seq(a, b):
    return a + b


def rebind(key, val):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 1:
                return val
            case _:
                return val
    prop = _fn_case_0(key)
    def _fn_def_0(slot):
        def _fn_case_0(_case_subject):
            match _case_subject:
                case Ok(old):
                    return with_seq(prop, old)
                case Error(None):
                    return prop
        prop_0 = _fn_case_0(slot)
        return with_seq(prop_0, slot)
    return update(slot, _fn_def_0)"
}

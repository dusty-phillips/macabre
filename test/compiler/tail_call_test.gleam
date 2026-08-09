import compiler
import glance

// Recursion through a `use` callback IS TCO'd: `result.try` returns the
// callback's value unchanged (a transparent callee), so the `GleamTco` marker
// flows straight back to the enclosing `while True` driver. Callees that
// consume the callback result with their own match protocol (like `list.any`)
// are not descended into.
pub fn tail_call_through_use_callback_test() {
  let assert Ok(module) =
    "fn split(tokens: List(Int)) -> Result(#(Int, List(Int)), Nil) {
    case tokens {
      [head, ..rest] -> Ok(#(head, rest))
      [] -> Error(Nil)
    }

  }
  fn process(acc: List(Int), tokens: List(Int)) -> List(Int) {
    use first, rest <- result.try(split(tokens))
    case rest {
      [] -> acc
      _ -> process([first, ..acc], rest)
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def split(tokens):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case GleamList(head, rest):
                return Ok((head, rest,))
            case None:
                return Error(None)
    return _fn_case_0(tokens)


def process(acc, tokens):
    while True:
        def _fn_def_0(first, rest):
            def _fn_case_0(_case_subject):
                match _case_subject:
                    case None:
                        return acc
                    case _:
                        return GleamTco((to_gleam_list([first], acc), rest,))
            return _fn_case_0(rest)
        _result = result.try_(split(tokens), _fn_def_0)
        match isinstance(_result, GleamTco):
            case True:
                acc, tokens = _result.args
            case False:
                return _result"
}

pub fn single_parameter_tail_call_test() {
  let assert Ok(module) =
    "fn countdown(n: Int) -> Int {
    case n {
      0 -> 0
      _ -> countdown(n - 1)
    }
  }

  fn main() {
    countdown(10)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def countdown(n):
    while True:
        def _fn_case_0(_case_subject):
            match _case_subject:
                case 0:
                    return 0
                case _:
                    return GleamTco((n - 1,))
        _result = _fn_case_0(n)
        match isinstance(_result, GleamTco):
            case True:
                n = _result.args[0]
            case False:
                return _result


def main():
    return countdown(10)"
}

pub fn multiple_parameter_tail_call_test() {
  let assert Ok(module) =
    "fn drop_until(n: Int, acc: List(Int)) -> List(Int) {
    case n {
      0 -> acc
      _ -> drop_until(n - 1, [n, ..acc])
    }
  }

  fn main() {
    drop_until(3, [])
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def drop_until(n, acc):
    while True:
        def _fn_case_0(_case_subject):
            match _case_subject:
                case 0:
                    return acc
                case _:
                    return GleamTco((n - 1, to_gleam_list([n], acc),))
        _result = _fn_case_0(n)
        match isinstance(_result, GleamTco):
            case True:
                n, acc = _result.args
            case False:
                return _result


def main():
    return drop_until(3, to_gleam_list([]))"
}

pub fn non_tail_call_not_optimized_test() {
  let assert Ok(module) =
    "fn factorial(n: Int) -> Int {
    case n {
      0 -> 1
      _ -> n * factorial(n - 1)
    }
  }

  fn main() {
    factorial(5)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def factorial(n):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 0:
                return 1
            case _:
                return n * factorial(n - 1)
    return _fn_case_0(n)


def main():
    return factorial(5)"
}

// Recursion nested inside a callback that consumes the callback's result with
// its own match protocol (list.fold) must NOT be rewritten to a GleamTco: the
// fold's own trampoline would swallow the marker. This was the failure behind
// the self-hosted macabre silently failing to compile projects with test/dev
// entries (load_module_recursively recurses through a list.fold callback).
pub fn recursion_inside_fold_callback_not_tco_test() {
  let assert Ok(module) =
    "import gleam/list
  import gleam/result

  fn walk(items: List(String), depth: Int) -> Result(Int, Nil) {
    case items {
      [] -> Ok(depth)
      [item, ..rest] ->
        list.fold(rest, Ok(depth), fn(state, next) {
          use d <- result.try(state)
          walk([next], d + 1)
        })
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def walk(items, depth):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case None:
                return Ok(depth)
            case GleamList(item, rest):
                def _fn_def_0(state, next):
                    def _fn_def_0(d):
                        return walk(to_gleam_list([next]), d + 1)
                    return result.try_(state, _fn_def_0)
                return list.fold(rest, Ok(depth), _fn_def_0)
    return _fn_case_0(items)


import gleam.result
from gleam import result
import gleam.list
from gleam import list


"
}

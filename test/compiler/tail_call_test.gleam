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
            case EmptyGleamList():
                return Error(None)
    return _fn_case_0(tokens)


def process(acc, tokens):
    def _fn_def_0(first, rest):
        def _fn_case_0(_case_subject):
            match _case_subject:
                case EmptyGleamList():
                    return acc
                case _:
                    return GleamTco((GleamList(first, acc), rest,))
        return _fn_case_0(rest)
    while True:
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
        match n:
            case 0:
                return 0
            case _:
                n = n - 1


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
        match n:
            case 0:
                return acc
            case _:
                n, acc = (n - 1, GleamList(n, acc),)


def main():
    return drop_until(3, EmptyGleamList())"
}

// The recursion is inside a nested `case` on the result of a call, which the
// transformer compiles to its own `_fn_case_N` driver. That driver is inlined
// into the outer loop too, so the per-iteration closure call, `GleamTco`
// allocation, and `isinstance` dispatch disappear entirely.
pub fn tail_call_inside_nested_case_test() {
  let assert Ok(module) =
    "fn count_if(list: List(Int), predicate: fn(Int) -> Bool, acc: Int) -> Int {
    case list {
      [] -> acc
      [first, ..rest] ->
        case predicate(first) {
          True -> count_if(rest, predicate, acc + 1)
          False -> count_if(rest, predicate, acc)
        }
    }
  }

  fn main() {
    count_if([1, 2, 3], fn(x) { x > 1 }, 0)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def count_if(list, predicate, acc):
    while True:
        match list:
            case EmptyGleamList():
                return acc
            case GleamList(first, rest_0):
                match predicate(first):
                    case True:
                        list, predicate, acc = (rest_0, predicate, acc + 1,)
                    case False:
                        list, predicate, acc = (rest_0, predicate, acc,)


def main():
    def _fn_def_0(x):
        return x > 1
    return count_if(GleamList(1, GleamList(2, GleamList(3, EmptyGleamList()))), _fn_def_0, 0)"
}

// The nested case's value feeds a later statement rather than the tail call
// directly (`new_acc = _fn_case_0(...)`), so the inlined driver assigns its
// result to that variable.
pub fn nested_case_result_feeds_tail_call_test() {
  let assert Ok(module) =
    "fn filter_loop(list: List(Int), predicate: fn(Int) -> Bool, acc: List(Int)) -> List(Int) {
    case list {
      [] -> list.reverse(acc)
      [first, ..rest] -> {
        let new_acc = case predicate(first) {
          True -> [first, ..acc]
          False -> acc
        }
        filter_loop(rest, predicate, new_acc)
      }
    }
  }

  fn main() {
    filter_loop([1, 2], fn(x) { x > 1 }, [])
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def filter_loop(list, predicate, acc):
    while True:
        match list:
            case EmptyGleamList():
                return list.reverse(acc)
            case GleamList(first_0, rest):
                match predicate(first_0):
                    case True:
                        new_acc = GleamList(first_0, acc)
                    case False:
                        new_acc = acc
                list, predicate, acc = (rest, predicate, new_acc,)


def main():
    def _fn_def_0(x):
        return x > 1
    return filter_loop(GleamList(1, GleamList(2, EmptyGleamList())), _fn_def_0, EmptyGleamList())"
}

// Recursion through a `use` callback (compiled to `result.try_`) still keeps
// the `GleamTco` protocol: the callback returns the marker, which only the
// outer `isinstance` dispatch can unpack. Inlining the driver here would leak
// the marker.
pub fn tail_call_through_use_callback_test_2() {
  let assert Ok(module) =
    "fn parse(token: Int) -> Result(Int, Nil) {
    case token {
      0 -> Error(Nil)
      _ -> Ok(token)
    }
  }

  fn sum_until(tokens: List(Int), acc: Int) -> Int {
    case tokens {
      [] -> acc
      [token, ..rest] -> {
        use value <- result.try(parse(token))
        sum_until(rest, acc + value)
      }
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def parse(token):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 0:
                return Error(None)
            case _:
                return Ok(token)
    return _fn_case_0(token)


def sum_until(tokens, acc):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case EmptyGleamList():
                return acc
            case GleamList(token, rest):
                def _fn_def_0(value):
                    return GleamTco((rest, acc + value,))
                return result.try_(parse(token), _fn_def_0)
    while True:
        _result = _fn_case_0(tokens)
        match isinstance(_result, GleamTco):
            case True:
                tokens, acc = _result.args
            case False:
                return _result"
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
            case EmptyGleamList():
                return Ok(depth)
            case GleamList(item, rest):
                def _fn_def_0(state, next):
                    def _fn_def_0(d):
                        return walk(GleamList(next, EmptyGleamList()), d + 1)
                    return result.try_(state, _fn_def_0)
                return list.fold(rest, Ok(depth), _fn_def_0)
    return _fn_case_0(items)


import gleam.result
from gleam import result
import gleam.list
from gleam import list


"
}

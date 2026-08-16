import compiler
import glance

pub fn option_none_value_and_pattern_test() {
  let assert Ok(module) =
    "
  import gleam/option.{None, Some}
  pub fn main() {
    case Some(1) {
      Some(x) -> x
      None -> 0
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    match Some(1):
        case Some(x):
            return x
        case None:
            return 0


import gleam.option
from gleam import option
from gleam.option import Some





__all__ = [\"main\"]
"
}

pub fn option_none_variant_no_class_test() {
  let assert Ok(module) =
    "
  import gleam/option.{None, Some}
  pub fn main() {
    let value = None
    case value {
      None -> True
      Some(_) -> False
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    value = None
    match value:
        case None:
            return True
        case Some(_):
            return False


import gleam.option
from gleam import option
from gleam.option import Some





__all__ = [\"main\"]
"
}

pub fn option_none_module_qualified_test() {
  let assert Ok(module) =
    "
  import gleam/option
  pub fn main() {
    let value = option.None
    case value {
      None -> True
      Some(_) -> False
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    value = None
    match value:
        case None:
            return True
        case Some(_):
            return False


import gleam.option
from gleam import option





__all__ = [\"main\"]
"
}

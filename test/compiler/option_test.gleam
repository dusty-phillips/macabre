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
    _case_subject = Some(1)
    match _case_subject:
        case Some(x):
            return x
        case None_():
            return 0


import gleam.option
from gleam import option
from gleam.option import None_
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
    value = None_
    match value:
        case None_():
            return True
        case Some(_):
            return False


import gleam.option
from gleam import option
from gleam.option import None_
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
    value = option.None_
    match value:
        case None_():
            return True
        case Some(_):
            return False


import gleam.option
from gleam import option





__all__ = [\"main\"]
"
}

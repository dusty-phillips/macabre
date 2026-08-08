import compiler
import glance
import gleeunit/should

pub fn option_none_value_and_pattern_test() {
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
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import gleam.option
from gleam import option
from gleam.option import Some


def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case Some(x):
                return x
            case None:
                return 0
    return _fn_case_0(Some(1))",
  )
}

pub fn option_none_variant_no_class_test() {
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
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import gleam.option
from gleam import option
from gleam.option import Some


def main():
    value = None
    def _fn_case_0(_case_subject):
        match _case_subject:
            case None:
                return True
            case Some(_):
                return False
    return _fn_case_0(value)",
  )
}

pub fn option_none_module_qualified_test() {
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
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import gleam.option
from gleam import option


def main():
    value = None
    def _fn_case_0(_case_subject):
        match _case_subject:
            case None:
                return True
            case Some(_):
                return False
    return _fn_case_0(value)",
  )
}

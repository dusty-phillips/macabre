import compiler
import glance
import gleam/dict
import gleam/option

pub fn external_python_test() {
  let assert Ok(module) =
    "@external(python, \"mylib\", \"println\")
  fn println() -> nil"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

from mylib import println\n\n\n"
}

pub fn skip_external_javascript_test() {
  let assert Ok(module) =
    "@external(javascript, \"mylib\", \"println\")
fn println() -> nil"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def println():
    raise NotImplementedError(\"The function println has no python binding (its @external annotations target other platforms)\")"
}

pub fn skip_external_erlang_test() {
  let assert Ok(module) =
    "@external(erlang, \"mylib\", \"println\")
fn println() -> nil"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def println():
    raise NotImplementedError(\"The function println has no python binding (its @external annotations target other platforms)\")"
}

pub fn empty_body_no_external_test() {
  let assert Ok(module) = "fn println() -> nil" |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def println():
    pass"
}

pub fn function_with_string_param_test() {
  let assert Ok(module) = "fn println(arg: String) -> nil {}" |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def println(arg):
    pass"
}

pub fn function_with_two_string_params_test() {
  let assert Ok(module) =
    "fn println(arg: String, other: String) -> nil {}" |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def println(arg, other):
    pass"
}

pub fn two_functions_test() {
  let assert Ok(module) =
    "fn func1() -> nil {}

fn func2() -> nil {}
"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def func1():
    pass


def func2():
    pass"
}

pub fn function_with_return_value_test() {
  let assert Ok(module) =
    "fn greet() -> String {
  \"hello world\"
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def greet():
    return \"hello world\""
}

pub fn function_with_discard_params_test() {
  let assert Ok(module) =
    "fn greet(_: String, _: String, _foo: String) -> String {
  \"hello world\"
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def greet(_, _1, _foo):
    return \"hello world\""
}

pub fn fn_with_discard_params_test() {
  let assert Ok(module) =
    "pub fn main() {
    let greet = fn (_ , _, _foo) {
      \"hello world\"
    }
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_def_0(_, _1, _foo):
        return \"hello world\"
    greet = _fn_def_0


__all__ = [\"main\"]
"
}

pub fn labelled_param_same_as_name_test() {
  let assert Ok(module) =
    "fn add(labelled: Int) -> Int {
    labelled
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def add(labelled):
    return labelled"
}

pub fn labelled_param_different_name_test() {
  let assert Ok(module) =
    "fn add(labelled a: Int) -> Int {
    a
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def add(a):
    return a"
}

pub fn labelled_param_call_test() {
  let assert Ok(module) =
    "fn add(labelled: Int) -> Int {
    labelled
  }

  fn main() {
    add(labelled: 1)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def add(labelled):
    return labelled


def main():
    return add(labelled=1)"
}

// Calls to externals are emitted with positional arguments: the hand-written
// python bindings use the parameter names, not the labels a labelled call
// would emit as keywords.
pub fn external_called_with_labels_emits_positional_test() {
  let assert Ok(module) =
    "@external(python, \"bindings\", \"do_replace\")
  fn replace(in builder: String, each pattern: String, with substitute: String) -> String {
    do_replace(builder, pattern, substitute)

  }
  fn main() {
    replace(in: \"a\", each: \"b\", with: \"c\")
  }"
    |> glance.module
  assert compiler.compile_module_with_externals(module, dict.new(), dict.new(), [
      "replace",
    ])
    == "from __future__ import annotations
from gleam_builtins import *

def replace(builder, pattern, substitute):
    return bindings_do_replace(builder, pattern, substitute)


def main():
    return replace(\"a\", \"b\", \"c\")


from bindings import do_replace as bindings_do_replace


"
}

pub fn external_reordered_arguments_emits_keywords_test() {
  let assert Ok(module) =
    "@external(python, \"simplifile_bindings\", \"write_bits\")
  fn write_bits(to filepath: String, bits bits: String) -> Nil

  fn to_bits(input: String) -> String {
    input
  }
  fn main() {
    \"contents\" |> to_bits |> write_bits(to: \"path\")
  }"
    |> glance.module
  assert compiler.compile_module_with_externals(
      module,
      dict.from_list([
        #("write_bits", [
          #(option.Some("to"), "filepath"),
          #(option.Some("bits"), "bits"),
        ]),
      ]),
      dict.new(),
      ["write_bits"],
    )
    == "from __future__ import annotations
from gleam_builtins import *

def to_bits(input):
    return input


def main():
    return write_bits(bits=to_bits(\"contents\"), filepath=\"path\")


from simplifile_bindings import write_bits


"
}

pub fn non_external_call_with_colliding_external_name_test() {
  let assert Ok(module) =
    "import gleam/string

  @external(python, \"bindings\", \"do_append\")
  fn append(first: String, second: String) -> String {
    do_append(first, second)
  }
  fn main() {
    let _ = \"a\" |> string.append(\"/\")
    \"b\" |> string.append(to: \"/\", suffix: \"c\")
  }"
    |> glance.module
  assert compiler.compile_module_with_externals(
      module,
      dict.from_list([
        #("string.append", [
          #(option.Some("to"), "first"),
          #(option.Some("suffix"), "second"),
        ]),
      ]),
      dict.new(),
      ["append"],
    )
    == "from __future__ import annotations
from gleam_builtins import *

def append(first, second):
    return bindings_do_append(first, second)


def main():
    string.append(\"a\", \"/\")
    return string.append(\"b\", to=\"/\", suffix=\"c\")


from bindings import do_append as bindings_do_append
import gleam.string
from gleam import string


"
}

pub fn shorthand_call_field_test() {
  let assert Ok(module) =
    "fn add(labelled: Int) -> Int {
    labelled
  }

  fn main() {
    let labelled = 1
    add(labelled:)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def add(labelled):
    return labelled


def main():
    labelled = 1
    return add(labelled=labelled)"
}

pub fn keyword_named_parameter_test() {
  let assert Ok(module) =
    "fn read(from: String, in: String) -> String {
    from <> in
  }

  fn main() {
    read(from: \"one\", in: \"two\")
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def read(from_, in_):
    return from_ + in_


def main():
    return read(from_=\"one\", in_=\"two\")"
}

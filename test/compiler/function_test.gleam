import compiler
import glance
import gleam/dict
import gleam/option
import gleeunit/should

pub fn external_python_test() {
  "@external(python, \"mylib\", \"println\")
  fn println() -> nil"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

from mylib import println\n\n\n",
  )
}

pub fn skip_external_javascript_test() {
  // TODO: I'm not sure if we're supposed to generate an empty function
  // if an external exists for one language but not a body and there is no
  // default body.
  //
  "@external(javascript, \"mylib\", \"println\")
fn println() -> nil"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def println():
    pass",
  )
}

pub fn skip_external_erlang_test() {
  // TODO: I'm not sure if we're supposed to generate an empty function
  // if an external exists for one language but not python there is no
  // default body.
  //
  "@external(erlang, \"mylib\", \"println\")
fn println() -> nil"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def println():
    pass",
  )
}

pub fn empty_body_no_external_test() {
  "fn println() -> nil"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def println():
    pass",
  )
}

pub fn function_with_string_param_test() {
  "fn println(arg: String) -> nil {}"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def println(arg):
    pass",
  )
}

pub fn function_with_two_string_params_test() {
  "fn println(arg: String, other: String) -> nil {}"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def println(arg, other):
    pass",
  )
}

pub fn two_functions_test() {
  "fn func1() -> nil {}

fn func2() -> nil {}
"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def func1():
    pass


def func2():
    pass",
  )
}

pub fn function_with_return_value_test() {
  "fn greet() -> String {
  \"hello world\"
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def greet():
    return \"hello world\"",
  )
}

pub fn function_with_discard_params_test() {
  "fn greet(_: String, _: String, _foo: String) -> String {
  \"hello world\"
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def greet(_, _1, _foo):
    return \"hello world\"",
  )
}

pub fn fn_with_discard_params_test() {
  "pub fn main() {
    let greet = fn (_ , _, _foo) {
      \"hello world\"
    }
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_def_0(_, _1, _foo):
        return \"hello world\"
    greet = _fn_def_0",
  )
}

pub fn labelled_param_same_as_name_test() {
  "fn add(labelled: Int) -> Int {
    labelled
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def add(labelled):
    return labelled",
  )
}

pub fn labelled_param_different_name_test() {
  "fn add(labelled a: Int) -> Int {
    a
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def add(labelled):
    a = labelled
    return a",
  )
}

pub fn labelled_param_call_test() {
  "fn add(labelled: Int) -> Int {
    labelled
  }

  fn main() {
    add(labelled: 1)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def add(labelled):
    return labelled


def main():
    return add(labelled=1)",
  )
}

// Calls to externals are emitted with positional arguments: the hand-written
// python bindings use the parameter names, not the labels a labelled call
// would emit as keywords.
pub fn external_called_with_labels_emits_positional_test() {
  "@external(python, \"bindings\", \"do_replace\")
  fn replace(in builder: String, each pattern: String, with substitute: String) -> String {
    do_replace(builder, pattern, substitute)

  }
  fn main() {
    replace(in: \"a\", each: \"b\", with: \"c\")
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module_with_externals(dict.new(), dict.new(), ["replace"])
  |> should.equal(
    "from gleam_builtins import *

from bindings import do_replace as bindings_do_replace


def replace(in_, each, with_):
    builder = in_
    pattern = each
    substitute = with_
    return bindings_do_replace(in_, each, with_)


def main():
    return replace(\"a\", \"b\", \"c\")",
  )
}

pub fn external_reordered_arguments_emits_keywords_test() {
  "@external(python, \"simplifile_bindings\", \"write_bits\")
  fn write_bits(to filepath: String, bits bits: String) -> Nil

  fn to_bits(input: String) -> String {
    input
  }
  fn main() {
    \"contents\" |> to_bits |> write_bits(to: \"path\")
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module_with_externals(
    dict.from_list([
      #("write_bits", [
        #(option.Some("to"), "filepath"),
        #(option.Some("bits"), "bits"),
      ]),
    ]),
    dict.new(),
    ["write_bits"],
  )
  |> should.equal(
    "from gleam_builtins import *

from simplifile_bindings import write_bits


def to_bits(input):
    return input


def main():
    return write_bits(bits=to_bits(\"contents\"), filepath=\"path\")",
  )
}

pub fn non_external_call_with_colliding_external_name_test() {
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
  |> should.be_ok
  |> compiler.compile_module_with_externals(
    dict.from_list([
      #("string.append", [
        #(option.Some("to"), "first"),
        #(option.Some("suffix"), "second"),
      ]),
    ]),
    dict.new(),
    ["append"],
  )
  |> should.equal(
    "from gleam_builtins import *

from bindings import do_append as bindings_do_append
import gleam.string
from gleam import string


def append(first, second):
    return bindings_do_append(first, second)


def main():
    string.append(\"a\", \"/\")
    return string.append(\"b\", to=\"/\", suffix=\"c\")",
  )
}

pub fn shorthand_call_field_test() {
  "fn add(labelled: Int) -> Int {
    labelled
  }

  fn main() {
    let labelled = 1
    add(labelled:)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def add(labelled):
    return labelled


def main():
    labelled = 1
    return add(labelled=labelled)",
  )
}

pub fn keyword_named_parameter_test() {
  "fn read(from: String, in: String) -> String {
    from <> in
  }

  fn main() {
    read(from: \"one\", in: \"two\")
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def read(from_, in_):
    return from_ + in_


def main():
    return read(from_=\"one\", in_=\"two\")",
  )
}

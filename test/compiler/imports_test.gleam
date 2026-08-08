import compiler
import glance
import gleam/dict
import gleam/option
import gleeunit/should

pub fn qualified_import_no_namespace_test() {
  "import my_cool_lib"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import my_cool_lib


",
  )
}

pub fn qualified_aliased_import_no_namespace_test() {
  "import my_cool_lib as thing"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import my_cool_lib as thing


",
  )
}

pub fn qualified_import_namespaces_test() {
  "import my/cool/lib"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import my.cool.lib
from my.cool import lib


",
  )
}

pub fn qualified_aliased_import_namespaces_test() {
  "import my/cool/lib as thing"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import my.cool.lib
from my.cool import lib as thing


",
  )
}

pub fn unqualified_import_test() {
  "import my_cool_lib.{hello}"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import my_cool_lib
from my_cool_lib import hello


",
  )
}

pub fn unqualified_import_namespace_test() {
  "import my/cool/lib.{hello}"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import my.cool.lib
from my.cool import lib
from my.cool.lib import hello


",
  )
}

pub fn unqualified_import_aliased_test() {
  "import my/cool/lib.{hello as foo, world as bar}"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import my.cool.lib
from my.cool import lib
from my.cool.lib import hello as foo
from my.cool.lib import world as bar


",
  )
}

pub fn aliased_modules_with_quals_test() {
  "import my/cool/lib.{hello as foo, world} as notlib
  import something.{hello as baz, continent} as nothing
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import something as nothing
from something import hello as baz
from something import continent
import my.cool.lib
from my.cool import lib as notlib
from my.cool.lib import hello as foo
from my.cool.lib import world


",
  )
}

pub fn type_import_test() {
  "import gleam/string_tree.{type StringTree}"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import gleam.string_tree
from gleam import string_tree


",
  )
}

pub fn type_and_value_import_test() {
  "import gleam/list.{type List, map}"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import gleam.list
from gleam import list
from gleam.list import map


",
  )
}

pub fn import_with_attribute_test() {
  "@internal
  import gleam/option"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import gleam.option
from gleam import option


",
  )
}

// A parameter that shares its name with an imported module binding must be
// renamed, so module-qualified calls keep resolving to the module while
// references to the parameter (including record field access on it) are
// distinct.
pub fn parameter_shadowing_imported_module_test() {
  "import compiler/project

  fn load(project: project.Project) -> String {
    project.build_src_dir(project.name)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import compiler.project
from compiler import project


def load(project_0):
    return project.build_src_dir(project_0.name)",
  )
}

pub fn module_function_value_with_shadowing_parameter_test() {
  let signatures =
    dict.from_list([
      #("list.fold", [
        #(option.Some("over"), "over"),
        #(option.Some("from"), "from"),
      ]),
      #("list.append", [
        #(option.Some("to"), "to"),
        #(option.Some("suffix"), "suffix"),
      ]),
    ])
  "import gleam/list

  fn count(list: List(Int)) -> Int {
    list.fold(list, 0, list.append)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module_with_signatures(signatures)
  |> should.equal(
    "from gleam_builtins import *

import gleam.list
from gleam import list


def count(list_0):
    return list.fold(list_0, 0, list.append)",
  )
}

// A private top-level function colliding with a submodule import binding is
// renamed (the import binding is left alone), so the emitted `def` does not
// clobber the `glexer.token` package attribute that other modules import the
// submodule from.
pub fn module_binding_colliding_with_function_test() {
  "import glexer/token

  fn token(lexer: Int, tok: String, source: String, offset: Int) -> String {
    tok
  }

  fn main() -> String {
    token(1, token.Name(\"x\"), \"\", 0)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import glexer.token
from glexer import token


def token_0(lexer, tok, source, offset):
    return tok


def main():
    return token_0(1, token.Name(\"x\"), \"\", 0)",
  )
}

// A public top-level function colliding with a submodule import binding
// cannot be renamed (other modules may import it), so the import binding is
// renamed instead.
pub fn module_binding_colliding_with_public_function_test() {
  "import glexer/token

  pub fn token(lexer: Int, tok: String, source: String, offset: Int) -> String {
    tok
  }

  fn main() -> String {
    token(1, token.Name(\"x\"), \"\", 0)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import glexer.token
from glexer import token as token_module


def token(lexer, tok, source, offset):
    return tok


def main():
    return token(1, token_module.Name(\"x\"), \"\", 0)",
  )
}

// A function parameter named like the colliding value shadows it within the
// body, so references to the parameter must not be renamed to the fresh name.
pub fn module_binding_colliding_parameter_shadowing_test() {
  "import glexer/token

  fn token(lexer: Int, tok: String, source: String, offset: Int) -> String {
    tok
  }

  fn use_token(token: Int) -> Int {
    token + 1
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import glexer.token
from glexer import token


def token_0(lexer, tok, source, offset):
    return tok


def use_token(token_0):
    return token_0 + 1",
  )
}

// A private constant colliding with a submodule import binding is renamed
// like a private function would be.
pub fn module_binding_colliding_with_constant_test() {
  "import glexer/token

  const token = \"glexer\"

  fn main() -> String {
    token
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import glexer.token
from glexer import token


def main():
    return token_0


token_0 = \"glexer\"

",
  )
}

// Module-qualified patterns must also use the (un)renamed binding correctly,
// e.g. the `token.EndOfFile()` pattern in glexer's lexer.
pub fn module_binding_colliding_with_function_pattern_test() {
  "import glexer/token

  fn token(lexer: Int, tok: String, source: String, offset: Int) -> String {
    tok
  }

  fn main() -> String {
    case Some(token.Name(\"x\")) {
      Some(token.Name(name)) -> name
    }
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

import glexer.token
from glexer import token


def token_0(lexer, tok, source, offset):
    return tok


def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case Some(token.Name(name)):
                return name
    return _fn_case_0(Some(token.Name(\"x\")))",
  )
}

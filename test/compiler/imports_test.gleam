import compiler
import glance
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
from my.cool import lib as notlib
from my.cool.lib import hello as foo
from my.cool.lib import world


",
  )
}

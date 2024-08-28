import compiler
import glance
import gleeunit/should

pub fn no_variant_custom_type_test() {
  "pub type Foo {
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

",
  )
}

pub fn single_variant_custom_type_test() {
  "pub type Foo {
  Bar(a: Int)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    a: int


",
  )
}

pub fn multi_variant_custom_type_test() {
  "pub type Foo {
  Bar(a: Int)
  Baz(a: String)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    a: int

@dataclasses.dataclass(frozen=True)
class Baz:
    a: str


",
  )
}

pub fn single_variant_with_no_fields_test() {
  "pub type Foo {
  Bar
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    pass


",
  )
}

pub fn multi_variant_with_no_fields_test() {
  "pub type Foo {
  Bar
  Baz
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    pass

@dataclasses.dataclass(frozen=True)
class Baz:
    pass


",
  )
}

pub fn tuple_type_test() {
  "pub type Foo {
    Foo(point: #(Int, Int))
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Foo:
    point: typing.Tuple[int, int]


",
  )
}

pub fn variant_generic_test() {
  "pub type Foo(elem) {
    Foo(item: elem)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

ELEM = typing.TypeVar('ELEM')
@dataclasses.dataclass(frozen=True)
class Foo:
    item: ELEM


",
  )
}

pub fn multi_variant_generic_test() {
  "pub type Foo(elem) {
    Bar(item: elem)
    Baz(elem: elem)
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

ELEM = typing.TypeVar('ELEM')
@dataclasses.dataclass(frozen=True)
class Bar:
    item: ELEM

@dataclasses.dataclass(frozen=True)
class Baz:
    elem: ELEM


",
  )
}

// TODO: The extra whitespace after the class Foo has me puzzled
pub fn generic_field_type_test() {
  "pub type Foo(elem) {
    Foo(item: elem)
  }

  pub type Bar {
    Bar(foo: Foo(String))
  }"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

ELEM = typing.TypeVar('ELEM')
@dataclasses.dataclass(frozen=True)
class Foo:
    item: ELEM





@dataclasses.dataclass(frozen=True)
class Bar:
    foo: Foo[str]


",
  )
}

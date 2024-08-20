import gleeunit/should
import macabre

pub fn no_variant_custom_type_test() {
  "pub type Foo {
  }"
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

",
  )
}

pub fn single_variant_custom_type_test() {
  "pub type Foo {
  Bar(a: Int)
  }"
  |> macabre.compile
  |> should.be_ok
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
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

class Foo:
    @dataclasses.dataclass(frozen=True)
    class Bar:
        a: int
    
    @dataclasses.dataclass(frozen=True)
    class Baz:
        a: str

Bar = Foo.Bar
Baz = Foo.Baz


",
  )
}

pub fn single_variant_with_no_fields_test() {
  "pub type Foo {
  Bar
  }"
  |> macabre.compile
  |> should.be_ok
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
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

class Foo:
    @dataclasses.dataclass(frozen=True)
    class Bar:
        pass
    
    @dataclasses.dataclass(frozen=True)
    class Baz:
        pass

Bar = Foo.Bar
Baz = Foo.Baz


",
  )
}

pub fn tuple_type_test() {
  "pub type Foo {
    Foo(point: #(Int, Int))
  }"
  |> macabre.compile
  |> should.be_ok
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
  |> macabre.compile
  |> should.be_ok
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
  |> macabre.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

ELEM = typing.TypeVar('ELEM')
class Foo:
    @dataclasses.dataclass(frozen=True)
    class Bar:
        item: ELEM
    
    @dataclasses.dataclass(frozen=True)
    class Baz:
        elem: ELEM

Bar = Foo.Bar
Baz = Foo.Baz


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
  |> macabre.compile
  |> should.be_ok
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

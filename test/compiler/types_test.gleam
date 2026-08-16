import compiler
import glance

pub fn no_variant_custom_type_test() {
  let assert Ok(module) =
    "pub type Foo {
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

"
}

pub fn single_variant_custom_type_test() {
  let assert Ok(module) =
    "pub type Foo {
  Bar(a: Int)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    a: int
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Bar\"]
"
}

pub fn multi_variant_custom_type_test() {
  let assert Ok(module) =
    "pub type Foo {
  Bar(a: Int)
  Baz(a: String)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    a: int
    
    def __hash__(self):
        return gleam_hash(self)
    

@dataclasses.dataclass(frozen=True)
class Baz:
    a: str
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Bar\", \"Baz\"]
"
}

pub fn single_variant_with_no_fields_test() {
  let assert Ok(module) =
    "pub type Foo {
  Bar
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Bar\"]
"
}

pub fn multi_variant_with_no_fields_test() {
  let assert Ok(module) =
    "pub type Foo {
  Bar
  Baz
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Bar:
    
    
    def __hash__(self):
        return gleam_hash(self)
    

@dataclasses.dataclass(frozen=True)
class Baz:
    
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Bar\", \"Baz\"]
"
}

pub fn tuple_type_test() {
  let assert Ok(module) =
    "pub type Foo {
    Foo(point: #(Int, Int))
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Foo:
    point: typing.Tuple[int, int]
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Foo\"]
"
}

pub fn variant_generic_test() {
  let assert Ok(module) =
    "pub type Foo(elem) {
    Foo(item: elem)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

ELEM = typing.TypeVar('ELEM')
@dataclasses.dataclass(frozen=True)
class Foo:
    item: ELEM
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Foo\"]
"
}

pub fn multi_variant_generic_test() {
  let assert Ok(module) =
    "pub type Foo(elem) {
    Bar(item: elem)
    Baz(elem: elem)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

ELEM = typing.TypeVar('ELEM')
@dataclasses.dataclass(frozen=True)
class Bar:
    item: ELEM
    
    def __hash__(self):
        return gleam_hash(self)
    

@dataclasses.dataclass(frozen=True)
class Baz:
    elem: ELEM
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Bar\", \"Baz\"]
"
}

pub fn generic_field_type_test() {
  let assert Ok(module) =
    "pub type Foo(elem) {
    Foo(item: elem)
  }

  pub type Bar {
    Bar(foo: Foo(String))
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

ELEM = typing.TypeVar('ELEM')
@dataclasses.dataclass(frozen=True)
class Foo:
    item: ELEM
    
    def __hash__(self):
        return gleam_hash(self)
    


@dataclasses.dataclass(frozen=True)
class Bar:
    foo: Foo[str]
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Foo\", \"Bar\"]
"
}

pub fn unlabelled_fields_test() {
  let assert Ok(module) =
    "pub type Foo {
    Foo(Int, String)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Foo:
    _0: int
    _1: str
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Foo\"]
"
}

pub fn mixed_labelled_unlabelled_fields_test() {
  let assert Ok(module) =
    "pub type Foo {
    Foo(a: Int, String)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Foo:
    a: int
    _0: str
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Foo\"]
"
}

pub fn function_type_field_test() {
  let assert Ok(module) =
    "pub type Foo {
    Foo(callback: fn(Int) -> Int)
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Foo:
    callback: typing.Callable[[int], int]
    
    def __hash__(self):
        return gleam_hash(self)
    





__all__ = [\"Foo\"]
"
}

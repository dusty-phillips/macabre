import compiler
import glance
import gleam/dict

pub fn non_nullary_constructor_as_function_value_test() {
  let assert Ok(module) =
    "pub type Wrap {
  Wrap(Int)
}

fn f() {
  use_thing(Wrap)
}
"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Wrap:
    _0: int
    
    def __hash__(self):
        return gleam_hash(self)
    


def f():
    return use_thing(Wrap)


__all__ = [\"Wrap\"]
"
}

pub fn nullary_value_emitted_as_instance_test() {
  let assert Ok(module) =
    "pub type State {
  Idle
  Active
}

fn f() {
  let state = Idle
  state
}
"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Idle:
    
    
    def __hash__(self):
        return gleam_hash(self)
    

@dataclasses.dataclass(frozen=True)
class Active:
    
    
    def __hash__(self):
        return gleam_hash(self)
    


def f():
    state = Idle()
    return state


__all__ = [\"Idle\", \"Active\"]
"
}

pub fn module_qualified_non_nullary_function_value_test() {
  let arities = dict.from_list([#("option.Some", ["_0"])])
  let assert Ok(module) =
    "import gleam/option

fn f() {
  let mapper = option.Some
  mapper
}
"
    |> glance.module
  assert compiler.compile_module_with_arities(module, dict.new(), arities)
    == "from __future__ import annotations
from gleam_builtins import *

def f():
    mapper = option.Some
    return mapper


import gleam.option
from gleam import option


"
}

pub fn module_qualified_nullary_value_emitted_as_instance_test() {
  let arities = dict.from_list([#("order.Lt", [])])
  let assert Ok(module) =
    "import gleam/order

fn f() {
  let ordering = order.Lt
  ordering
}
"
    |> glance.module
  assert compiler.compile_module_with_arities(module, dict.new(), arities)
    == "from __future__ import annotations
from gleam_builtins import *

def f():
    ordering = order.Lt()
    return ordering


import gleam.order
from gleam import order


"
}

// A constructor call mixing positional and labelled arguments must be
// reordered to the dataclass field order with every argument labelled, so
// the positionals land on the correct fields (e.g. glance's
// `LabelledField(name, t, label_location: span)`).
pub fn mixed_positional_and_labelled_arguments_test() {
  let arities = dict.from_list([#("Thing", ["label", "location", "item"])])
  let assert Ok(module) =
    "pub type Thing {
    Thing(label: String, location: Int, item: String)

  }
  pub fn main() {
    let t = Thing(\"a\", \"x\", location: 1)
    t
  }
  "
    |> glance.module
  assert compiler.compile_module_with_arities(module, dict.new(), arities)
    == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Thing:
    label: str
    location: int
    item: str
    
    def __hash__(self):
        return gleam_hash(self)
    


def main():
    t = Thing(label=\"a\", location=1, item=\"x\")
    return t


__all__ = [\"main\", \"Thing\"]
"
}

// A nullary constructor of an ALIASED import must also emit as an instance:
// the arity lookup is keyed by the alias (e.g. `o.Lt` for
// `import gleam/order as o`), not the module's last path segment.
pub fn aliased_import_nullary_value_emitted_as_instance_test() {
  let arities = dict.from_list([#("o.Lt", [])])
  let assert Ok(module) =
    "import gleam/order as o

fn f() {
  let ordering = o.Lt
  ordering
}
"
    |> glance.module
  assert compiler.compile_module_with_arities(module, dict.new(), arities)
    == "from __future__ import annotations
from gleam_builtins import *

def f():
    ordering = o.Lt()
    return ordering


import gleam.order
from gleam import order as o


"
}

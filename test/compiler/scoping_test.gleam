import compiler
import glance
import gleam/dict

// Guard-walrus captures in an inlinable case driver: the arm patterns rebind
// the same name the subject references. Python would turn the walrus into a
// function-local and break the subject evaluation (UnboundLocalError), so the
// inliner/refactor passes must keep them apart.
pub fn guard_walrus_driver_inline_test() {
  let assert Ok(module) =
    "pub fn main() {
  let exponent = \"e5\"
  let kind = case exponent {
    \"\" -> \"empty\"
    \"e\" <> exponent -> exponent
    _ -> \"other\"
  }
  kind
}
"
    |> glance.module
  assert compiler.compile_module(module)
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\ndef main():\n    exponent = \"e5\"\n    def _fn_case_0(_case_subject):\n        match _case_subject:\n            case \"\":\n                return \"empty\"\n            case _ if _case_subject.startswith(\"e\") and (exponent := _case_subject[1:]) is not None:\n                return exponent\n            case _:\n                return \"other\"\n    kind = _fn_case_0(exponent)\n    return kind\n\n\n__all__ = [\"main\"]\n"
}

// A nested case whose arm body rebinds a name referenced earlier in the same
// generated helper: after inlining, the bind would make the earlier reference
// an UnboundLocalError (the xmlm parse_element_end_signal shape).
pub fn nested_case_arm_rebind_test() {
  let assert Ok(module) =
    "fn step(n: Int) -> Result(Int, String) {
  Ok(n + 1)
}

pub fn run(input: Int) -> Int {
  case input > 0 {
    True -> {
      let out = case step(input) {
        Error(_) -> 0
        Ok(input) -> input * 2
      }
      out
    }
    False -> 0
  }
}
"
    |> glance.module
  assert compiler.compile_module(module)
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\ndef step(n):\n    return Ok(n + 1)\n\n\ndef run(input):\n    _case_subject = input > 0\n    if _case_subject:\n        def _fn_case_0(_case_subject):\n            if type(_case_subject) is Error:\n                return 0\n            elif type(_case_subject) is Ok:\n                input = _case_subject.value\n                return input * 2\n        out = _fn_case_0(step(input))\n        return out\n    else:\n        return 0\n\n\n__all__ = [\"run\"]\n"
}

// Match-subject reference colliding with an arm's concatenation-pattern
// capture: the capture must be renamed so the subject still reads the outer
// binding.
pub fn match_subject_capture_collision_test() {
  let assert Ok(module) =
    "pub fn main() {
  let exponent = \"e5\"
  case exponent {
    \"\" -> \"empty\"
    \"e\" <> exponent -> exponent
    _ -> \"other\"
  }
}
"
    |> glance.module
  assert compiler.compile_module(module)
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\ndef main():\n    exponent = \"e5\"\n    def _fn_case_0(_case_subject):\n        match _case_subject:\n            case \"\":\n                return \"empty\"\n            case _ if _case_subject.startswith(\"e\") and (exponent := _case_subject[1:]) is not None:\n                return exponent\n            case _:\n                return \"other\"\n    return _fn_case_0(exponent)\n\n\n__all__ = [\"main\"]\n"
}

// A local shadowing an imported module calls a field of an OPAQUE type:
// fields are not accessible, so the call falls back to the module function.
pub fn opaque_type_shadowing_local_falls_back_to_module_call_test() {
  let assert Ok(module) =
    "import boxm.{type Box}

pub fn unwrap(boxm: Box) -> Int {
  boxm.value(boxm)
}
"
    |> glance.module
  let arities =
    dict.new()
    |> dict.insert("type:boxm.Box", ["value"])
    |> dict.insert("type:Box", ["value"])
    |> dict.insert("opaque:type:boxm.Box", ["value"])
    |> dict.insert("opaque:type:Box", ["value"])
  assert compiler.compile_module_with_arities(module, dict.new(), arities)
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\ndef unwrap(boxm_0):\n    return boxm.value(boxm_0)\n\n\nimport boxm\n\n\n\n\n\n__all__ = [\"unwrap\"]\n"
}

// Same shape, PUBLIC type: the field is accessible, so the call stays a
// record-field call even though the local shadows a module function.
pub fn public_type_shadowing_local_keeps_field_call_test() {
  let assert Ok(module) =
    "import boxm.{type Wrap}

pub fn unwrap(boxm: Wrap) -> Int {
  boxm.value(boxm)
}
"
    |> glance.module
  let arities =
    dict.new()
    |> dict.insert("type:boxm.Wrap", ["value"])
    |> dict.insert("type:Wrap", ["value"])
  assert compiler.compile_module_with_arities(module, dict.new(), arities)
    == "from __future__ import annotations\nfrom gleam_builtins import *\n\ndef unwrap(boxm_0):\n    return boxm_0.value(boxm_0)\n\n\nimport boxm\n\n\n\n\n\n__all__ = [\"unwrap\"]\n"
}

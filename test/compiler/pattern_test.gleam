import compiler
import glance
import gleeunit/should

pub fn multiple_subjects_bitstring_test() {
  "pub fn main() {
    case <<1>>, <<2>> {
      <<x>>, <<y>> -> x
      _, _ -> 0
    }
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case (_, _) if (_bitstring_binds_0 := gleam_match_bitstring(_case_subject[0], (\"variable\", \"x\",))) is not None and (_bitstring_binds_1 := gleam_match_bitstring(_case_subject[1], (\"variable\", \"y\",))) is not None:
                x = _bitstring_binds_0[0]
                y = _bitstring_binds_1[0]
                return x
            case (_, _):
                return 0
    return _fn_case_0((gleam_bitstring_segments_to_bytes((1, [])), gleam_bitstring_segments_to_bytes((2, [])),))",
  )
}

pub fn multiple_subjects_concatenate_test() {
  "pub fn main() {
    case \"hello world\", \"foo\" {
      \"hello\" <> rest, other -> rest
      _, _ -> \"\"
    }
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case (_, other) if _case_subject[0].startswith(\"hello\") and (rest := _case_subject[0][5:]) is not None:
                return rest
            case (_, _):
                return \"\"
    return _fn_case_0((\"hello world\", \"foo\",))",
  )
}

pub fn concatenate_assignment_test() {
  "pub fn main() {
    let \"hello\" <> rest = \"hello world\"
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_match_0(_case_subject):
        match _case_subject:
            case _ if _case_subject.startswith(\"hello\") and (rest := _case_subject[5:]) is not None:
                return rest
    rest = _fn_match_0(\"hello world\")",
  )
}

// Escaped prefixes (e.g. `"\n" <> rest`) are stored by glance in their raw
// source form, so the slice length must be computed from the unescaped
// prefix or the generated `[2:]` would skip an extra character.
pub fn escaped_prefix_concat_pattern_test() {
  "pub fn main() {
    case \"\nworld\" {
      \"\\n\" <> rest -> rest
      _ -> \"\"
    }
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case _ if _case_subject.startswith(\"\\n\") and (rest := _case_subject[1:]) is not None:
                return rest
            case _:
                return \"\"
    return _fn_case_0(\"\\nworld\")",
  )
}

// A concatenation pattern whose remainder is the empty string must still
// match: the guard `(rest := _case_subject[1:])` would be falsy when the rest
// is `""`, so it is wrapped in `is not None`.
pub fn concatenate_pattern_with_empty_rest_test() {
  "pub fn main() {
    case \"x\" {
      \"x\" <> rest -> rest
      _ -> \"\"
    }
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case _ if _case_subject.startswith(\"x\") and (rest := _case_subject[1:]) is not None:
                return rest
            case _:
                return \"\"
    return _fn_case_0(\"x\")",
  )
}

pub fn concatenate_case_test() {
  "pub fn main() {
    case \"hello world\" {
      \"hello\" as prefix <> rest -> prefix
    }
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case _ if (prefix := \"hello\") and _case_subject.startswith(\"hello\") and (rest := _case_subject[5:]) is not None:
                return prefix
    return _fn_case_0(\"hello world\")",
  )
}

pub fn bitstring_pattern_case_test() {
  "pub fn main() {
    case <<1>> {
      <<x>> -> x
    }
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case _ if (_bitstring_binds := gleam_match_bitstring(_case_subject, (\"variable\", \"x\",))) is not None:
                x = _bitstring_binds[0]
                return x
    return _fn_case_0(gleam_bitstring_segments_to_bytes((1, [])))",
  )
}

pub fn shorthand_pattern_field_test() {
  "pub type Box {
    Box(value: Int)
  }

fn main() {
  let Box(value:) = Box(5)
}
"
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Box:
    value: int


def main():
    def _fn_match_0(_case_subject):
        match _case_subject:
            case Box(value=value):
                return value
    value = _fn_match_0(Box(5))",
  )
}

pub fn bitstring_pattern_assignment_test() {
  "pub fn main() {
    let <<x:8, y:8>> = <<1:8, 2:8>>
  }
  "
  |> glance.module
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_match_0(_case_subject):
        match _case_subject:
            case _ if (_bitstring_binds := gleam_match_bitstring(_case_subject, (\"variable\", \"x\", (\"SizeValue\", 8,),), (\"variable\", \"y\", (\"SizeValue\", 8,),))) is not None:
                x, y = _bitstring_binds
                return (x, y,)
    x, y = _fn_match_0(gleam_bitstring_segments_to_bytes((1, [(\"SizeValue\", 8)]), (2, [(\"SizeValue\", 8)])))",
  )
}

import compiler
import glance

pub fn single_int_case_test() {
  let assert Ok(module) =
    "pub fn main() {
    case 1 {
      1 -> \"one\"
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 1:
                return \"one\"
    return _fn_case_0(1)"
}

pub fn single_float_case_test() {
  let assert Ok(module) =
    "pub fn main() {
    case 1.0 {
      1.0 -> \"one\"
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 1.0:
                return \"one\"
    return _fn_case_0(1.0)"
}

pub fn single_string_case_test() {
  let assert Ok(module) =
    "pub fn main() {
    case \"hello\" {
      \"hello\" -> \"one\"
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case \"hello\":
                return \"one\"
    return _fn_case_0(\"hello\")"
}

pub fn variable_case_test() {
  let assert Ok(module) =
    "pub fn main() {
    case \"hello\" {
      greet -> greet <> \" world\"
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case greet:
                return greet + \" world\"
    return _fn_case_0(\"hello\")"
}

pub fn tuple_case_test() {
  let assert Ok(module) =
    "pub fn main() {
    case #(1, 2) {
      #(1, 2) -> \"one\"
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case (1, 2):
                return \"one\"
    return _fn_case_0((1, 2,))"
}

pub fn pattern_assignment_test() {
  let assert Ok(module) =
    "pub fn main() {
    case 1 {
      1 as x -> 2 + x
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 1 as x:
                return 2 + x
    return _fn_case_0(1)"
}

pub fn grouped_pattern_test() {
  let assert Ok(module) =
    "pub fn main() {
    case 1, 2 {
      1, x -> x + 50
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case (1, x):
                return x + 50
    return _fn_case_0((1, 2,))"
}

pub fn alternate_pattern_test() {
  let assert Ok(module) =
    "pub fn main() {
    case 1 {
      1 | 2 -> 5
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 1 | 2:
                return 5
    return _fn_case_0(1)"
}

pub fn alternate_grouped_pattern_test() {
  let assert Ok(module) =
    "pub fn main() {
    case 1, 2 {
      1, 2 | 2, 3 -> 5
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case (1, 2) | (2, 3):
                return 5
    return _fn_case_0((1, 2,))"
}

pub fn alternate_bitstring_pattern_test() {
  let assert Ok(module) =
    "pub fn main() {
    case <<1>> {
      <<1>> | <<2>> -> 5
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case _ if (_bitstring_binds := gleam_match_bitstring(_case_subject, (\"int\", \"1\",))) is not None:
                return 5
            case _ if (_bitstring_binds := gleam_match_bitstring(_case_subject, (\"int\", \"2\",))) is not None:
                return 5
    return _fn_case_0(gleam_bitstring_segments_to_bytes((1, [])))"
}

pub fn case_block_test() {
  let assert Ok(module) =
    "pub fn main() {
    case 1 {
      1 -> {
        let x = 1
        let y = 2
        x + y
      }
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 1:
                x = 1
                y = 2
                return x + y
    return _fn_case_0(1)"
}

pub fn case_empty_list_test() {
  let assert Ok(module) =
    "pub fn main() {
    case [] {
      [] -> 1
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case None:
                return 1
    return _fn_case_0(to_gleam_list([]))"
}

pub fn case_single_element_list_test() {
  let assert Ok(module) =
    "pub fn main() {
    case [1] {
      [1] -> 1
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case GleamList(1, None):
                return 1
    return _fn_case_0(to_gleam_list([1]))"
}

pub fn case_multi_element_list_test() {
  let assert Ok(module) =
    "pub fn main() {
    case [1, 2, 3] {
      [1, 2, 3] -> 1
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case GleamList(1, GleamList(2, GleamList(3, None))):
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))"
}

// The gleam formatter doesn't permit this scenario, but it is encountered
// during recursion
pub fn case_empty_rest_case_test() {
  let assert Ok(module) =
    "pub fn main() {
    case [1, 2, 3] {
      rest -> 1
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case rest:
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))"
}

pub fn single_element_with_rest_case_test() {
  let assert Ok(module) =
    "pub fn main() {
    case [1, 2, 3] {
      [1, ..rest] -> 1
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case GleamList(1, rest):
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))"
}

pub fn multi_element_with_rest_case_test() {
  let assert Ok(module) =
    "pub fn main() {
    case [1, 2, 3] {
      [1, 2, ..rest] -> 1
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case GleamList(1, GleamList(2, rest)):
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))"
}

pub fn unnamed_rest_test() {
  let assert Ok(module) =
    "pub fn main() {
    case [1, 2, 3] {
      [1, 2, ..] -> 1
    }
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case GleamList(1, GleamList(2, _)):
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))"
}

pub fn case_guard_test() {
  let assert Ok(module) =
    "pub fn main() -> Nil {
    case num {
      0 -> \"Just zero\"
      x if x < 0 -> \"So negative\"
      x if x % 2 == 0 -> \"Positively even\"
      _ -> \"Somewhat odd\"
    }
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 0:
                return \"Just zero\"
            case x if x < 0:
                return \"So negative\"
            case x if x % 2 == 0:
                return \"Positively even\"
            case _:
                return \"Somewhat odd\"
    return _fn_case_0(num)"
}

// Nullary constructors are represented at runtime by the constructor class
// object itself, so a pattern matching one must be an equality match
// (`case Idle:`) rather than a class pattern (`case Idle():`).
pub fn nullary_constructor_pattern_test() {
  let assert Ok(module) =
    "pub type State { Idle Active }

  fn check(state: State) -> Bool {
    case state {
      Idle -> True
      Active -> False
    }
  }"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Idle:
    pass

@dataclasses.dataclass(frozen=True)
class Active:
    pass


def check(state):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case Idle():
                return True
            case Active():
                return False
    return _fn_case_0(state)"
}

pub fn arm_binding_shadowing_reference_before_binding_test() {
  let assert Ok(module) =
    "fn next(lexer: Int) -> Int {
  case lexer {
    _ if lexer > 0 -> {
      let before = lexer
      let #(lexer, name) = tuple(lexer, 1)
      before + lexer
    }
    _ -> lexer
  }
}
"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def next(lexer):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case _ if lexer > 0:
                before = lexer
                def _fn_match_0(_case_subject):
                    match _case_subject:
                        case (lexer, name):
                            return (lexer, name,)
                lexer_0, name = _fn_match_0(tuple(lexer, 1))
                return before + lexer_0
            case _:
                return lexer
    return _fn_case_0(lexer)"
}

// A pattern capture colliding with a module-qualified constructor pattern in
// another arm must be renamed: Python match captures are scoped to the whole
// function, so the capture would otherwise shadow the module binding used in
// the other arm's pattern (e.g. glexer's `do_lex` matching
// `Some((token.EndOfFile(), _))` while another arm captures `token`).
pub fn pattern_capture_colliding_with_module_pattern_test() {
  let assert Ok(module) =
    "import glexer/token

  fn do_lex() {
    case #(1, Some(2)) {
      #(lexer, None) -> 0
      #(_lexer, Some(token.EndOfFile())) -> 1
      #(lexer, Some(token)) -> token
    }
  }
"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def do_lex():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case (lexer, None):
                return 0
            case (_lexer, Some(token.EndOfFile())):
                return 1
            case (lexer, Some(token_0)):
                return token_0
    return _fn_case_0((1, Some(2),))


import glexer.token
from glexer import token


"
}

// A local binding whose name collides with a module binding is renamed, while
// references to the module binding in the local's own right hand side (e.g. a
// case initializer) keep pointing at the module, like glexer's `comment`.
// Without this the generated Python binds the module name as an unbound local
// of the enclosing function.
pub fn local_colliding_with_module_binding_in_case_test() {
  let assert Ok(module) =
    "import glexer/token

fn comment(kind: Int) -> #(String, Int) {
  let token = case kind {
    0 -> token.CommentModule(\"x\")
    _ -> token.CommentNormal(\"y\")
  }
  #(token, kind)
}
"
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def comment(kind):
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 0:
                return token.CommentModule(\"x\")
            case _:
                return token.CommentNormal(\"y\")
    token_1 = _fn_case_0(kind)
    return (token_1, kind,)


import glexer.token
from glexer import token


"
}

// A case pattern capture in one arm must not collide with another arm's
// reference to the enclosing scope, even when that reference is renamed by the
// enclosing scope after the collision check. Here `tokens` is rebound by each
// `use` (so the subject is `tokens_0_0` by the case), and the first arm's
// `..tokens` capture must get a fresh name rather than reusing `tokens_0_0`.
pub fn case_arm_capture_renamed_away_from_enclosing_subject_test() {
  let assert Ok(module) =
    "pub type Kind {
    Let
    LetAssert(Option(String))
  }

  fn assignment(kind: Kind, tokens: List(Int), start: Int) {
    use #(pattern, tokens) <- result.try(Ok(#(1, tokens)))
    use #(annotation, tokens) <- result.try(Ok(#(Nil, tokens)))
    use _, tokens <- result.try(Ok(#(Nil, tokens)))
    use #(value, tokens) <- result.try(Ok(#(0, tokens)))
    use #(new_kind, tokens, end) <- result.try(case kind, tokens {
      LetAssert(None), [0, ..tokens] -> Ok(#(LetAssert(Some(\"x\")), tokens, start + 1))
      LetAssert(_), _ | Let, _ -> Ok(#(kind, tokens, start))
    })
    #(new_kind, tokens, end)
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

@dataclasses.dataclass(frozen=True)
class Let:
    pass

@dataclasses.dataclass(frozen=True)
class LetAssert:
    _0: Option[str]


def assignment(kind, tokens, start):
    def _fn_def_0(use_capture_0):
        def _fn_match_0(_case_subject):
            match _case_subject:
                case (pattern, tokens):
                    return (pattern, tokens,)
        pattern, tokens = _fn_match_0(use_capture_0)
        def _fn_def_0(use_capture_0):
            def _fn_match_0(_case_subject):
                match _case_subject:
                    case (annotation, tokens):
                        return (annotation, tokens,)
            annotation, tokens_0 = _fn_match_0(use_capture_0)
            def _fn_def_0(_, tokens_0):
                def _fn_def_0(use_capture_0):
                    def _fn_match_0(_case_subject):
                        match _case_subject:
                            case (value, tokens):
                                return (value, tokens,)
                    value, tokens_0_0 = _fn_match_0(use_capture_0)
                    def _fn_case_1(_case_subject):
                        match _case_subject:
                            case (LetAssert(None), GleamList(0, tokens_0_0_0)):
                                return Ok((LetAssert(Some(\"x\")), tokens_0_0_0, start + 1,))
                            case (LetAssert(_), _) | (Let(), _):
                                return Ok((kind, tokens_0_0, start,))
                    def _fn_def_0(use_capture_0):
                        def _fn_match_0(_case_subject):
                            match _case_subject:
                                case (new_kind, tokens, end):
                                    return (new_kind, tokens, end,)
                        new_kind, tokens_1, end = _fn_match_0(use_capture_0)
                        return (new_kind, tokens_1, end,)
                    return result.try_(_fn_case_1((kind, tokens_0_0,)), _fn_def_0)
                return result.try_(Ok((0, tokens_0,)), _fn_def_0)
            return result.try_(Ok((None, tokens_0,)), _fn_def_0)
        return result.try_(Ok((None, tokens,)), _fn_def_0)
    return result.try_(Ok((1, tokens,)), _fn_def_0)"
}

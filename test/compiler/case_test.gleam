import compiler
import glance
import gleeunit/should

pub fn single_int_case_test() {
  "pub fn main() {
    case 1 {
      1 -> \"one\"
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
            case 1:
                return \"one\"
    return _fn_case_0(1)",
  )
}

pub fn single_float_case_test() {
  "pub fn main() {
    case 1.0 {
      1.0 -> \"one\"
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
            case 1.0:
                return \"one\"
    return _fn_case_0(1.0)",
  )
}

pub fn single_string_case_test() {
  "pub fn main() {
    case \"hello\" {
      \"hello\" -> \"one\"
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
            case \"hello\":
                return \"one\"
    return _fn_case_0(\"hello\")",
  )
}

pub fn variable_case_test() {
  "pub fn main() {
    case \"hello\" {
      greet -> greet <> \" world\"
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
            case greet:
                return greet + \" world\"
    return _fn_case_0(\"hello\")",
  )
}

pub fn tuple_case_test() {
  "pub fn main() {
    case #(1, 2) {
      #(1, 2) -> \"one\"
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
            case (1, 2):
                return \"one\"
    return _fn_case_0((1, 2))",
  )
}

pub fn pattern_assignment_test() {
  "pub fn main() {
    case 1 {
      1 as x -> 2 + x
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
            case 1 as x:
                return 2 + x
    return _fn_case_0(1)",
  )
}

pub fn grouped_pattern_test() {
  "pub fn main() {
    case 1, 2 {
      1, x -> x + 50
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
            case (1, x):
                return x + 50
    return _fn_case_0((1, 2))",
  )
}

pub fn alternate_pattern_test() {
  "pub fn main() {
    case 1 {
      1 | 2 -> 5
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
            case 1 | 2:
                return 5
    return _fn_case_0(1)",
  )
}

pub fn alternate_grouped_pattern_test() {
  "pub fn main() {
    case 1, 2 {
      1, 2 | 2, 3 -> 5
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
            case (1, 2) | (2, 3):
                return 5
    return _fn_case_0((1, 2))",
  )
}

pub fn case_block_test() {
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
  |> should.be_ok
  |> compiler.compile_module
  |> should.equal(
    "from gleam_builtins import *

def main():
    def _fn_case_0(_case_subject):
        match _case_subject:
            case 1:
                x = 1
                y = 2
                return x + y
    return _fn_case_0(1)",
  )
}

pub fn case_empty_list_test() {
  "pub fn main() {
    case [] {
      [] -> 1
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
            case None:
                return 1
    return _fn_case_0(to_gleam_list([]))",
  )
}

pub fn case_single_element_list_test() {
  "pub fn main() {
    case [1] {
      [1] -> 1
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
            case GleamList(1, None):
                return 1
    return _fn_case_0(to_gleam_list([1]))",
  )
}

pub fn case_multi_element_list_test() {
  "pub fn main() {
    case [1, 2, 3] {
      [1, 2, 3] -> 1
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
            case GleamList(1, GleamList(2, GleamList(3, None))):
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))",
  )
}

// The gleam formatter doesn't permit this scenario, but it is encountered
// during recursion
pub fn case_empty_rest_case_test() {
  "pub fn main() {
    case [1, 2, 3] {
      rest -> 1
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
            case rest:
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))",
  )
}

pub fn single_element_with_rest_case_test() {
  "pub fn main() {
    case [1, 2, 3] {
      [1, ..rest] -> 1
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
            case GleamList(1, rest):
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))",
  )
}

pub fn multi_element_with_rest_case_test() {
  "pub fn main() {
    case [1, 2, 3] {
      [1, 2, ..rest] -> 1
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
            case GleamList(1, GleamList(2, rest)):
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))",
  )
}

pub fn unnamed_rest_test() {
  "pub fn main() {
    case [1, 2, 3] {
      [1, 2, ..] -> 1
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
            case GleamList(1, GleamList(2, _)):
                return 1
    return _fn_case_0(to_gleam_list([1, 2, 3]))",
  )
}

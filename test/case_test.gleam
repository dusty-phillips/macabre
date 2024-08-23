import compiler
import gleeunit/should

pub fn single_int_case_test() {
  "pub fn main() {
    case 1 {
      1 -> \"one\"
    }
  }
  "
  |> compiler.compile
  |> should.be_ok
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
  |> compiler.compile
  |> should.be_ok
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
  |> compiler.compile
  |> should.be_ok
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
  |> compiler.compile
  |> should.be_ok
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
  |> compiler.compile
  |> should.be_ok
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
  |> compiler.compile
  |> should.be_ok
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
  |> compiler.compile
  |> should.be_ok
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
  |> compiler.compile
  |> should.be_ok
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
  |> compiler.compile
  |> should.be_ok
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

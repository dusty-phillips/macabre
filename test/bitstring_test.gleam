import compiler
import gleeunit/should

pub fn single_byte_case_test() {
  "pub fn main() {
      <<16>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((16, []))",
  )
}

pub fn multiple_bytes_case_test() {
  "pub fn main() {
      <<16, 42, 255>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((16, []), (42, []), (255, []))",
  )
}

pub fn two_byte_integers_test() {
  "pub fn main() {
      <<62_000:16, 63_000:16>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((62_000, [(\"SizeValue\", 16)]), (63_000, [(\"SizeValue\", 16)]))",
  )
}

pub fn size_expression_test() {
  "pub fn main() {
      let x = 16
      <<62_000:size(x)>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    x = 16
    return gleam_bitstring_segments_to_bytes((62_000, [(\"SizeValue\", x)]))",
  )
}

pub fn little_endian_test() {
  "pub fn main() {
      <<4_666_000:32-little>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((4_666_000, [(\"SizeValue\", 32), (\"Little\", None)]))",
  )
}

pub fn big_endian_test() {
  "pub fn main() {
      <<4_666_000:32-big>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((4_666_000, [(\"SizeValue\", 32), (\"Big\", None)]))",
  )
}

pub fn native_endian_test() {
  "pub fn main() {
      <<4_666_000:32-native>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((4_666_000, [(\"SizeValue\", 32), (\"Native\", None)]))",
  )
}

pub fn size_unit_test() {
  "pub fn main() {
      <<64_003:2-unit(8)>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64_003, [(\"SizeValue\", 2), (\"Unit\", 8)]))",
  )
}

pub fn float_default_double_test() {
  "pub fn main() {
      <<64.888889:float>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64.888889, [(\"Float\", None)]))",
  )
}

pub fn float_explicit_double_test() {
  "pub fn main() {
      <<64.888889:64-float>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64.888889, [(\"SizeValue\", 64), (\"Float\", None)]))",
  )
}

pub fn float_explicit_single_test() {
  "pub fn main() {
      <<64.888889:32-float>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64.888889, [(\"SizeValue\", 32), (\"Float\", None)]))",
  )
}

pub fn float_single_little_test() {
  "pub fn main() {
      <<64.888889:32-float>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64.888889, [(\"SizeValue\", 32), (\"Float\", None)]))",
  )
}

pub fn bitstring_test() {
  // TODO: Pretty sure this should be :bits, not :bit_string,
  // but glance has a bug:
  // https://github.com/lpil/glance/issues/22
  "pub fn main() {
      <<<<3>>:bit_string>>
  }
  "
  |> compiler.compile
  |> should.be_ok
  |> should.equal(
    "from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((gleam_bitstring_segments_to_bytes((3, [])), [(\"BitString\", None)]))",
  )
}

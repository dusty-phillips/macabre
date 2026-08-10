import compiler
import glance

pub fn single_byte_case_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<16>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((16, []))


__all__ = [\"main\"]
"
}

pub fn multiple_bytes_case_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<16, 42, 255>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((16, []), (42, []), (255, []))


__all__ = [\"main\"]
"
}

pub fn two_byte_integers_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<62_000:16, 63_000:16>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((62_000, [(\"SizeValue\", 16)]), (63_000, [(\"SizeValue\", 16)]))


__all__ = [\"main\"]
"
}

pub fn size_expression_test() {
  let assert Ok(module) =
    "pub fn main() {
      let x = 16
      <<62_000:size(x)>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    x = 16
    return gleam_bitstring_segments_to_bytes((62_000, [(\"SizeValue\", x)]))


__all__ = [\"main\"]
"
}

pub fn little_endian_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<4_666_000:32-little>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((4_666_000, [(\"SizeValue\", 32), (\"Little\", None)]))


__all__ = [\"main\"]
"
}

pub fn big_endian_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<4_666_000:32-big>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((4_666_000, [(\"SizeValue\", 32), (\"Big\", None)]))


__all__ = [\"main\"]
"
}

pub fn native_endian_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<4_666_000:32-native>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((4_666_000, [(\"SizeValue\", 32), (\"Native\", None)]))


__all__ = [\"main\"]
"
}

pub fn size_unit_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<64_003:2-unit(8)>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64_003, [(\"SizeValue\", 2), (\"Unit\", 8)]))


__all__ = [\"main\"]
"
}

pub fn float_default_double_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<64.888889:float>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64.888889, [(\"Float\", None)]))


__all__ = [\"main\"]
"
}

pub fn float_explicit_double_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<64.888889:64-float>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64.888889, [(\"SizeValue\", 64), (\"Float\", None)]))


__all__ = [\"main\"]
"
}

pub fn float_explicit_single_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<64.888889:32-float>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64.888889, [(\"SizeValue\", 32), (\"Float\", None)]))


__all__ = [\"main\"]
"
}

pub fn float_single_little_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<64.888889:32-float>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((64.888889, [(\"SizeValue\", 32), (\"Float\", None)]))


__all__ = [\"main\"]
"
}

pub fn explicit_int_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<42:int>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((42, [(\"Int\", None)]))


__all__ = [\"main\"]
"
}

pub fn bitstring_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<<<3>>:bits>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((gleam_bitstring_segments_to_bytes((3, [])), [(\"BitString\", None)]))


__all__ = [\"main\"]
"
}

pub fn u8_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<\"hello\":utf8>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((\"hello\", [(\"Utf8\", None)]))


__all__ = [\"main\"]
"
}

pub fn u16_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<\"hello\":utf16>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((\"hello\", [(\"Utf16\", None)]))


__all__ = [\"main\"]
"
}

pub fn u32_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<\"hello\":utf32>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((\"hello\", [(\"Utf32\", None)]))


__all__ = [\"main\"]
"
}

pub fn u32_little_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<\"hello\":utf32-little>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((\"hello\", [(\"Utf32\", None), (\"Little\", None)]))


__all__ = [\"main\"]
"
}

pub fn utf8_codepoint_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<1_000_000:utf8_codepoint>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((1_000_000, [(\"Utf8Codepoint\", None)]))


__all__ = [\"main\"]
"
}

pub fn utf16_codepoint_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<1_000_000:utf16_codepoint>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((1_000_000, [(\"Utf16Codepoint\", None)]))


__all__ = [\"main\"]
"
}

pub fn utf32_codepoint_test() {
  let assert Ok(module) =
    "pub fn main() {
      <<1_000_000:utf32_codepoint>>
  }
  "
    |> glance.module
  assert compiler.compile_module(module) == "from __future__ import annotations
from gleam_builtins import *

def main():
    return gleam_bitstring_segments_to_bytes((1_000_000, [(\"Utf32Codepoint\", None)]))


__all__ = [\"main\"]
"
}

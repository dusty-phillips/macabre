pub const gleam_builtins = "
import dataclasses

class GleamPanic(BaseException):
    pass
"

pub const prelude = "from gleam_builtins import *\n\n"

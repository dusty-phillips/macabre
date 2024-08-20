pub const gleam_builtins = "
import dataclasses
import typing

class GleamPanic(BaseException):
    pass
"

pub const prelude = "from gleam_builtins import *\n\n"

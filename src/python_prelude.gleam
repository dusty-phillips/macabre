pub const gleam_builtins = "
import dataclasses
import typing

class GleamPanic(BaseException):
    pass


GleamListElem = typing.TypeVar(\"GleamListElem\")


class GleamList(typing.Generic[GleamListElem]):
    def __str__(self):
        strs = []
        head = self

        while not head.is_empty:
            strs.append(head.value)
            head = head.tail

        return  \"GleamList([\" + \", \".join(strs) + \"])\"


class NonEmptyGleamList(GleamList[GleamListElem]):
    __slots__ = [\"value\", \"tail\"]
    is_empty = False

    def __init__(self, value: GleamListElem, tail: GleamList[GleamListElem]):
        self.value = value
        self.tail = tail


class EmptyGleamList(GleamList):
    __slots__ = []
    is_empty = True



def to_gleam_list(elements: list[GleamListElem], tail: GleamList = EmptyGleamList()):
    head = tail
    for element in reversed(elements):
        head = NonEmptyGleamList(element, head)
    return head
"

pub const prelude = "from gleam_builtins import *\n\n"

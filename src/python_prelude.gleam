pub const gleam_builtins = "
from __future__ import annotations
import dataclasses
import sys
import typing
import struct

class GleamPanic(BaseException):
    pass


GleamListElem = typing.TypeVar('GleamListElem')


@dataclasses.dataclass(frozen=True)
class Ok:
    value: typing.Any


@dataclasses.dataclass(frozen=True)
class Error:
    value: typing.Any


Nil = None


class GleamTco:
    __slots__ = [\"args\"]

    def __init__(self, args: tuple):
        self.args = args


class GleamList(typing.Generic[GleamListElem]):
    __slots__ = [\"value\", \"tail\"]
    __match_args__ = (\"value\", \"tail\")

    def __init__(self, value: GleamListElem, tail: GleamList[GleamListElem] | None):
        self.value = value
        self.tail = tail

    def __str__(self):
        strs = []
        head = self

        while head is not None:
            strs.append(str(head.value))
            head = head.tail

        return \"GleamList([\" + \", \".join(strs) + \"])\"

    def __eq__(self, other):
        if not isinstance(other, GleamList):
            return False
        left = self
        right = other
        while left is not None and right is not None:
            if left.value != right.value:
                return False
            left = left.tail
            right = right.tail
        return left is None and right is None

    def __hash__(self):
        result = 0
        head = self
        while head is not None:
            result = result * 31 + hash(head.value)
            head = head.tail
        return result



def to_gleam_list(elements: list[GleamListElem], tail: GleamList | None=None):
    head = tail
    for element in reversed(elements):
        head = GleamList(element, head)
    return head

def gleam_bitstring_segments_to_bytes(*segments):
    result = bytearray()
    for segment in segments:
        result.extend(gleam_bitstring_segment_to_bytes(segment))
    return bytes(result)
    

def gleam_bitstring_segment_to_bytes(segment) -> bytes:
    value, options = segment

    size = None
    unit = None
    type = None
    bitsize = None
    endianness = 'big'
    for option in options:
        match option:
            case ('SizeValue', size):
                size = size
            case ('Unit', unit):
                unit = unit
            case ('Little', None):
                endianness = 'little'
            case ('Big', None):
                endianness = 'big'
            case ('Native', None):
                endianness = sys.byteorder
            case ('Float', None):
                type = 'float'
            case ('Int', None):
                type = 'int'
            case ('BitString', None):
                type = 'bitstring'
            case ('Utf8', None):
                type = 'utf8'
            case ('Utf16', None):
                type = 'utf16'
            case ('Utf32', None):
                type = 'utf32'
            case _:
                raise Exception(f'Unexpected bitstring option {option}')

    # Defaults from https://www.erlang.org/doc/system/bit_syntax.html
    if type == None:
        type = 'int'

    if size == None:
        match type:
            case 'int':
                size = 8
            case 'float':
                size = 64

    if unit == None:
        match type:
            case 'int' | 'float':
                unit = 1
                bitsize = unit * size
            case 'bitstring' | 'utf8' | 'utf16' | 'utf32':
                unit = 8
                # For string-like types the size is implied by the value,
                # so bitsize is only needed when a size was given.
                if size != None:
                    bitsize = unit * size

    if bitsize != None and bitsize % 8:
        raise Exception(f'Python bitstrings must be byte aligned, but got {bitsize}')

    match type:
        case 'int':
            return value.to_bytes(bitsize // 8, endianness, signed=value < 0)
        case 'float':
            match endianness: 
                case 'big':
                    order = '>'
                case 'little':
                    order = '<'
            match bitsize:
                case 32:
                    fmt = 'f'
                case  64:
                    fmt = 'd'
                case _:
                    raise Exception('bitstring floats must be 32 or 64 bits')
            return struct.pack(f'{order}{fmt}', value)
        case 'bitstring':
            return value
        case 'utf8':
            return value.encode('utf8')
        case 'utf16':
            match endianness:
                case 'little':
                    return value.encode('utf-16-le')
                case 'big':
                    return value.encode('utf-16-be')
        case 'utf32':
            match endianness:
                case 'little':
                    return value.encode('utf-32-le')
                case 'big':
                    return value.encode('utf-32-be')
            

    raise Exception('Unexpected bitstring encountered')

def gleam_match_bitstring(subject, *segments):
    cursor = 0
    bindings = []

    for segment in segments:
        kind, payload = segment[0], segment[1]
        options = segment[2:]

        size = None
        unit = None
        type = None
        bitsize = None
        endianness = 'big'
        for option in options:
            match option:
                case ('SizeValue', size):
                    size = size
                case ('Unit', unit):
                    unit = unit
                case ('Little', _):
                    endianness = 'little'
                case ('Big', _):
                    endianness = 'big'
                case ('Native', _):
                    endianness = sys.byteorder
                case ('Float', _):
                    type = 'float'
                case ('Int', _):
                    type = 'int'
                case ('BitString', _):
                    type = 'bitstring'
                case ('Utf8', _):
                    type = 'utf8'
                case ('Utf16', _):
                    type = 'utf16'
                case ('Utf32', _):
                    type = 'utf32'
                case _:
                    raise Exception(f'Unexpected bitstring option {option}')

        if type == None:
            type = 'int'

        if type == 'bitstring':
            value = subject[cursor:]
            cursor = len(subject)
        else:
            if size == None:
                match type:
                    case 'int':
                        size = 8
                    case 'float':
                        size = 64
                    case _:
                        raise Exception('bitstring pattern needs an explicit size')
            if unit == None:
                match type:
                    case 'int' | 'float':
                        unit = 1
                    case 'utf8' | 'utf16' | 'utf32':
                        unit = 8
            bitsize = unit * size
            if bitsize % 8:
                raise Exception(f'Python bitstrings must be byte aligned, but got {bitsize}')
            # A segment that needs more bytes than remain cannot match: the
            # subject is exhausted (the pattern extends past the end). Without
            # this check `int.from_bytes(b'')` yields a phantom 0 and the
            # pattern falsely matches, which can send scanners into an
            # infinite loop.
            if cursor + bitsize // 8 > len(subject):
                return None
            match type:
                case 'int':
                    value = int.from_bytes(
                        subject[cursor:cursor + bitsize // 8], endianness)
                case 'float':
                    order = '>' if endianness == 'big' else '<'
                    fmt = 'f' if bitsize == 32 else 'd'
                    value = struct.unpack(
                        f'{order}{fmt}', subject[cursor:cursor + bitsize // 8])[0]
                case 'utf8':
                    value = subject[cursor:cursor + bitsize // 8].decode('utf8')
                case 'utf16':
                    value = subject[cursor:cursor + bitsize // 8].decode(
                        'utf-16-le' if endianness == 'little' else 'utf-16-be')
                case 'utf32':
                    value = subject[cursor:cursor + bitsize // 8].decode(
                        'utf-32-le' if endianness == 'little' else 'utf-32-be')
            cursor += bitsize // 8

        match kind:
            case 'variable':
                bindings.append(value)
            case 'wildcard':
                pass
            case 'int':
                if value != int(payload, 0):
                    return None
            case 'string':
                if value != payload:
                    return None

    if cursor != len(subject):
        return None

    return tuple(bindings)
"

pub const prelude = "from gleam_builtins import *\n\n"

pub fn dunder_main(module: String) -> String {
  "from " <> module <> " import main

if __name__ == \"__main__\":
    main()"
}

// Appended to any compiled module that defines a top-level `main` function, so
// it can be run directly as a script (e.g. `python3 build/dev/python/foo_test.py`).
pub const ifmain = "if __name__ == \"__main__\":
    main()"

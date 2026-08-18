pub const gleam_builtins = "
from __future__ import annotations
import dataclasses
import sys
import typing
import struct

# Compiled Gleam programs can recurse much deeper than Python's default
# recursion limit (1000 frames): a deeply nested `use <- result.try(...)`
# chain alone costs several frames per nesting level. Raise the limit so
# programs that are well-formed for Erlang (which has a growable stack) also
# run under CPython.
sys.setrecursionlimit(20000)

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


def gleam_int_div(a, b):
    # Erlang's `div` truncates toward zero and returns 0 on a zero divisor.
    if b == 0:
        return 0
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def gleam_int_rem(a, b):
    # Erlang's `rem` truncates toward zero and returns 0 on a zero divisor.
    if b == 0:
        return 0
    return a - b * gleam_int_div(a, b)


def gleam_float_div(a, b):
    # Erlang float division guards a zero divisor, returning a zero with the
    # DIVISOR's sign: dividing by +0.0 gives +0.0 and by -0.0 gives -0.0.
    # Python raises ZeroDivisionError, so guard explicitly.
    import math
    if b == 0.0:
        return math.copysign(0.0, b)
    return a / b


class GleamList(typing.Generic[GleamListElem]):
    __slots__ = [\"value\", \"tail\"]
    __match_args__ = (\"value\", \"tail\")

    def __init__(self, value: GleamListElem, tail: GleamList[GleamListElem] | None):
        self.value = value
        self.tail = tail

    def __str__(self):
        strs = []
        head = self

        while isinstance(head, GleamList):
            strs.append(str(head.value))
            head = head.tail

        return \"GleamList([\" + \", \".join(strs) + \"])\"

    def __eq__(self, other):
        left = self
        right = other
        while isinstance(left, GleamList) and isinstance(right, GleamList):
            if left.value != right.value:
                return False
            left = left.tail
            right = right.tail
        return isinstance(left, EmptyGleamList) and isinstance(right, EmptyGleamList)

    def __hash__(self):
        result = 0
        head = self
        while isinstance(head, GleamList):
            result = result * 31 + hash(head.value)
            head = head.tail
        return result


class EmptyGleamList:
    __slots__ = []

    def __str__(self):
        return \"GleamList([])\"

    def __eq__(self, other):
        return isinstance(other, EmptyGleamList)

    def __hash__(self):
        return 0


# Gleam values are all hashable (like Erlang terms), but Python's `dict` is
# not, so a record or tuple containing a `Dict` cannot be hashed by the
# generated dataclass alone. `gleam_hash` hashes any value by a canonical,
# value-based form: dicts become frozensets of items, lists/tuples become
# tuples, and records become `(class, fields...)`. Equal values (including
# dicts with different insertion orders) always hash the same.
def _gleam_hash_key(value):
    if value is None or isinstance(value, (bool, int, float, str, bytes)):
        return value
    if isinstance(value, dict):
        return frozenset(
            (_gleam_hash_key(k), _gleam_hash_key(v)) for k, v in value.items())
    if isinstance(value, (list, tuple)):
        return tuple(_gleam_hash_key(v) for v in value)
    if isinstance(value, GleamList):
        items = []
        while isinstance(value, GleamList):
            items.append(_gleam_hash_key(value.value))
            value = value.tail
        return (\"GleamList\", tuple(items))
    fields = getattr(type(value), \"__dataclass_fields__\", None)
    if fields is not None:
        return (type(value),) + tuple(
            _gleam_hash_key(getattr(value, name)) for name in fields)
    return (type(value), value)


def gleam_hash(value):
    return hash(_gleam_hash_key(value))


# A record update. `dataclasses.replace` is far slower: it builds a kwargs
# dict for every field and calls `__init__`. Bypassing the constructor with a
# `__dict__` copy (mutated directly, which the frozen dataclass `__setattr__`
# cannot intercept) is equivalent for the plain dataclasses the compiler
# generates, which have no custom `__init__`.
def gleam_record_replace(record, changes):
    new = type(record).__new__(type(record))
    object.__setattr__(new, \"__dict__\", record.__dict__.copy())
    new.__dict__.update(changes)
    return new


def to_gleam_list(elements: list[GleamListElem], tail: GleamList | None=None):
    head = tail if tail is not None else EmptyGleamList()
    for element in reversed(elements):
        head = GleamList(element, head)
    return head

def gleam_bitstring_segments_to_bytes(*segments):
    total_bits = 0
    parts = []
    for segment in segments:
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
            # A bare string literal in a bitstring segment (for example a
            # two-char string in `body, rest`) is encoded as latin-1 bytes,
            # matching erlang. Int values default to int.
            type = 'utf8' if isinstance(value, str) else 'int'

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
                case 'bitstring' | 'utf8' | 'utf16' | 'utf32':
                    unit = 8

        segment_bits = []
        if type == 'int':
            bitsize = unit * size
            if endianness == 'little':
                value_bytes = value.to_bytes(max(1, (bitsize + 7) // 8), 'little', signed=value < 0)
                byte_count = len(value_bytes)
                segment_bits = _bits_of(value_bytes, len(value_bytes) * 8)
                if bitsize % 8 == 0:
                    segment_bits = segment_bits[:bitsize]
                else:
                    segment_bits = segment_bits[:8 * (byte_count - 1)] + segment_bits[len(segment_bits) - (bitsize % 8):]
            else:
                value_bytes = value.to_bytes(max(1, (bitsize + 7) // 8), 'big', signed=value < 0)
                segment_bits = _bits_of(value_bytes, len(value_bytes) * 8)
                if len(segment_bits) > bitsize:
                    segment_bits = segment_bits[len(segment_bits) - bitsize:]
        elif type == 'float':
            bitsize = unit * size
            if endianness == 'little':
                order = '<'
            else:
                order = '>'
            match bitsize:
                case 32:
                    fmt = 'f'
                case 64:
                    fmt = 'd'
                case _:
                    raise Exception('bitstring floats must be 32 or 64 bits')
            segment_bits = _bits_of(struct.pack(f'{order}{fmt}', value), bitsize)
        elif type == 'bitstring':
            if isinstance(value, GleamBitArray):
                segment_bits = _bits_of(value.data, value.bits)
            else:
                segment_bits = _bits_of(value, len(value) * 8)
            if size != None and size * unit < len(segment_bits):
                segment_bits = segment_bits[: size * unit]
        else:
            match type:
                case 'utf8':
                    value_bytes = value.encode('utf8')
                case 'utf16':
                    if endianness == 'little':
                        value_bytes = value.encode('utf-16-le')
                    else:
                        value_bytes = value.encode('utf-16-be')
                case 'utf32':
                    if endianness == 'little':
                        value_bytes = value.encode('utf-32-le')
                    else:
                        value_bytes = value.encode('utf-32-be')
            segment_bits = _bits_of(value_bytes, len(value_bytes) * 8)
            if size != None and size * unit < len(segment_bits):
                segment_bits = segment_bits[: size * unit]

        parts.append(segment_bits)
        total_bits += len(segment_bits)

    result = _pack_bits(parts, total_bits)
    if total_bits % 8 == 0:
        return bytes(result)
    return GleamBitArray(bytes(result), total_bits)


def _bits_of(data: bytes, count: int) -> list:
    bits = []
    for byte in data:
        for shift in range(7, -1, -1):
            bits.append((byte >> shift) & 1)
    if count < len(bits):
        return bits[:count]
    return bits


def _pack_bits(parts: list, total_bits: int) -> bytearray:
    result = bytearray((total_bits + 7) // 8)
    bit_index = 0
    for bits in parts:
        for bit in bits:
            if bit:
                result[bit_index // 8] |= 1 << (7 - (bit_index % 8))
            bit_index += 1
    return result


def gleam_bitstring_segment_to_bytes(segment) -> bytes:
    return gleam_bitstring_segments_to_bytes(segment)


class GleamBitArray:
    __slots__ = ['data', 'bits']

    def __init__(self, data: bytes, bits: int):
        self.data = data
        self.bits = bits

    def __str__(self):
        return f'GleamBitArray({self.data!r}, {self.bits})'

    def __eq__(self, other):
        if isinstance(other, bytes):
            return self.bits == len(other) * 8 and self.data == other
        if isinstance(other, GleamBitArray):
            return self.bits == other.bits and self.data == other.data
        return False

    def __hash__(self):
        return hash((self.data, self.bits))

    def __len__(self):
        return len(self.data)

def gleam_match_bitstring(subject, *segments):
    if isinstance(subject, GleamBitArray):
        total_bits = subject.bits
        subject_bytes = subject.data
    else:
        total_bits = len(subject) * 8
        subject_bytes = subject
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
        signed = False
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
                case ('Signed', _):
                    signed = True
                case ('Unsigned', _):
                    signed = False
                case _:
                    raise Exception(f'Unexpected bitstring option {option}')

        if type == None:
            # A bare string literal in a bitstring pattern is matched as its
            # byte sequence (erlang semantics). The payload is a python str.
            if kind == 'string' and isinstance(payload, str):
                type = 'utf8'
                if size == None:
                    size = len(payload.encode('utf-8'))
            else:
                type = 'int'

        if type == 'bitstring':
            if size == None:
                value = _bitstring_slice(
                    subject_bytes, cursor, total_bits - cursor,
                )
                cursor = total_bits
            else:
                if unit == None:
                    unit = 8
                bitsize = unit * size
                if cursor + bitsize > total_bits:
                    return None
                value = _bitstring_slice(subject_bytes, cursor, bitsize)
                cursor += bitsize
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
            # A segment that needs more bits than remain cannot match: the
            # subject is exhausted (the pattern extends past the end).
            if cursor + bitsize > total_bits:
                return None
            start_byte = cursor // 8
            start_bit = cursor % 8
            end_byte = (cursor + bitsize + 7) // 8
            data = subject_bytes[start_byte:end_byte]
            match type:
                case 'int':
                    value = _bits_to_int(data, start_bit, bitsize, endianness)
                    if signed and bitsize > 0:
                        value = _to_signed(value, bitsize)
                case 'float':
                    value = _bits_to_float(data, start_bit, bitsize, endianness)
                case 'utf8':
                    value = _bits_to_utf8(data, start_bit, bitsize, 'utf-8')
                case 'utf16':
                    value = _bits_to_utf8(
                        data, start_bit, bitsize,
                        'utf-16-le' if endianness == 'little' else 'utf-16-be')
                case 'utf32':
                    value = _bits_to_utf8(
                        data, start_bit, bitsize,
                        'utf-32-le' if endianness == 'little' else 'utf-32-be')
            cursor += bitsize

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

    if cursor != total_bits:
        return None

    return tuple(bindings)


def _bitstring_slice(data: bytes, start_bit: int, count: int) -> bytes | GleamBitArray:
    if count % 8 == 0:
        return _bits_to_bytes(data, start_bit, count)
    return GleamBitArray(_bits_to_bytes(data, start_bit, count), count)


def _bits_to_bytes(data: bytes, start_bit: int, count: int) -> bytes:
    result = bytearray((count + 7) // 8)
    for i in range(count):
        byte_index = (start_bit + i) // 8
        bit_index = 7 - ((start_bit + i) % 8)
        if byte_index < len(data) and (data[byte_index] >> bit_index) & 1:
            result[i // 8] |= 1 << (7 - (i % 8))
    return bytes(result)


def _bits_to_int(data: bytes, start_bit: int, count: int, endianness: str) -> int:
    byte_count = (count + 7) // 8
    if start_bit == 0 and count % 8 == 0:
        value = int.from_bytes(data[:byte_count], endianness)
    elif endianness == 'little':
        extracted = _bits_to_bytes(data, start_bit, count)
        if count % 8 == 0:
            value = int.from_bytes(extracted, 'little')
        else:
            partial = extracted[-1] >> (8 - (count % 8))
            value = int.from_bytes(extracted[:-1], 'little')
            value |= partial << (8 * (len(extracted) - 1))
    else:
        extracted = _bits_to_bytes(data, start_bit, count)
        value = int.from_bytes(extracted, 'big')
        value >>= byte_count * 8 - count
    return value


def _to_signed(value: int, bitsize: int) -> int:
    sign_bit = 1 << (bitsize - 1)
    if value & sign_bit:
        return value - (1 << bitsize)
    return value


def _bits_to_float(data: bytes, start_bit: int, count: int, endianness: str) -> float:
    byte_count = count // 8
    value_bytes = _bits_to_bytes(data, start_bit, count)
    order = '<' if endianness == 'little' else '>'
    fmt = 'f' if count == 32 else 'd'
    return struct.unpack(f'{order}{fmt}', value_bytes)[0]


def _bits_to_utf8(data: bytes, start_bit: int, count: int, encoding: str) -> str:
    return _bits_to_bytes(data, start_bit, count).decode(encoding)
"

pub const prelude = "from __future__ import annotations\nfrom gleam_builtins import *\n\n"

pub fn dunder_main(module: String) -> String {
  "from " <> module <> " import main

if __name__ == \"__main__\":
    main()"
}

// Appended to any compiled module that defines a top-level `main` function, so
// it can be run directly as a script (e.g. `python3 build/dev/python/foo_test.py`).
pub const ifmain = "if __name__ == \"__main__\":
    main()"

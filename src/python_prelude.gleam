pub const gleam_builtins = "
from __future__ import annotations
import dataclasses
import sys
import typing
import struct

class GleamPanic(BaseException):
    pass


GleamListElem = typing.TypeVar('GleamListElem')


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
            case 'bitstring' | 'utf8' | 'utf16' | 'utf8':
                unit = 8
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
"

pub const prelude = "from gleam_builtins import *\n\n"

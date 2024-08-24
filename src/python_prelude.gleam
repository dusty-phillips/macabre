pub const gleam_builtins = "
import dataclasses
import sys
import typing
import struct

class GleamPanic(BaseException):
    pass


GleamListElem = typing.TypeVar('GleamListElem')


class GleamList(typing.Generic[GleamListElem]):
    def __str__(self):
        strs = []
        head = self

        while not head.is_empty:
            strs.append(head.value)
            head = head.tail

        return  'GleamList([' + ', '.join(strs) + '])'


class NonEmptyGleamList(GleamList[GleamListElem]):
    __slots__ = ['value', 'tail']
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
    endianness = 'big'
    for option in options:
        match option:
            case ('SizeValue', size):
                size = size
            case('Unit', unit):
                unit = unit
            case('Little', None):
                endianness = 'little'
            case('Big', None):
                endianness = 'big'
            case('Native', None):
                endianness = sys.byteorder
            case('Float', None):
                type = 'float'
            case('Integer', None):
                type = 'int'
            case('BitString', None):
                type = 'bitstring'
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
            case 'bitstring':
                size = len(value)

    if unit == None:
        match type:
            case 'int' | 'float':
                unit = 1
            case 'bitstring':
                unit = 8

    bitsize = unit * size
    if bitsize % 8:
        raise Exception(f'Python bitstrings must be byte aligned, but got {bitsize}')

    bytesize = bitsize // 8

    match type:
        case 'int':
            return value.to_bytes(bitsize // 8, endianness, signed=value < 0)
        case 'float':
            match endianness: 
                case 'big':
                    order = '>'
                case 'little':
                    order = '<'
                case 'native':
                    onder = '='
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

    raise Exception('Unexpected bitstring encountered')
"

pub const prelude = "from gleam_builtins import *\n\n"

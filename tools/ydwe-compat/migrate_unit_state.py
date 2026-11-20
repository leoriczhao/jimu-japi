#!/usr/bin/env python3
"""Offline YDWE unit-state source migration for JASS maps.

Background
==========
YDWE hooks GetUnitState/SetUnitState and reads/writes a set of extended unit
states (0x10..0x61). This project does not hook game natives. Instead it
already exposes the same behaviour through the EXGetUnitState /
EXSetUnitState bridge handlers. This tool rewrites *call sites* in JASS source
so those handlers are used only for the extended states they implement:

    GetUnitState(u, 0x20)          -> EXGetUnitState(GetHandleId(u), 0x20)
    SetUnitState(u, ConvertUnitState(0x25), 1.0)
                                   -> EXSetUnitState(GetHandleId(u), 0x25, 1.0)

Safety rules
============
* The tokenizer is byte oriented. Comments, string literals, rawcodes and
  non-ASCII source bytes are never rewritten; files keep their encoding and
  line endings.
* Vanilla states 0..3 are left untouched (EXSetUnitState has a special
  MAX_LIFE/MAX_MANA path, so routing them would change vanilla semantics).
* Unknown states, UjAPI-only states 4..7, runtime expressions and unresolvable
  constants are left untouched and reported.
* SetUnitState is not rewritten for states where EXSetUnitState is a no-op
  (attack damage min/max 0x14/0x15/0x42/0x43).
* GetUnitStateSwap(state, unit) is rewritten too, because YDWE's GUI emits it.

The EX functions are UnitId bridge wrappers, not engine natives. Pack the map
with tools/pack.ps1 -WithJassWrappers, or use --emit-compat to write the two
wrapper functions plus optional dynamic-state helpers.

Usage
=====
    python tools/ydwe-compat/migrate_unit_state.py --check war3map.j
    python tools/ydwe-compat/migrate_unit_state.py --in-place path/to/jass
    python tools/ydwe-compat/migrate_unit_state.py --out build/migrated path/
    python tools/ydwe-compat/migrate_unit_state.py --report-json r.json \
        --emit-compat build/ydwe-unit-state.j path/

Exit status: 0 success/no changes, 1 error or --check found pending rewrites.
Standard library only; no game, MPQ, DLL or network access.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional

TRIVIA_KINDS = {"ws", "newline", "comment"}
TARGET_GET = b"GetUnitState"
TARGET_SET = b"SetUnitState"
TARGET_SWAP = b"GetUnitStateSwap"
TARGET_PERCENT = b"GetUnitStatePercent"
TARGETS = {TARGET_GET, TARGET_SET, TARGET_SWAP, TARGET_PERCENT}

WRAPPER_GET = b"EXGetUnitState"
WRAPPER_SET = b"EXSetUnitState"
HELPER_GET = b"YDWEGetUnitState"
HELPER_SET = b"YDWESetUnitState"
HELPER_PERCENT = b"YDWEGetUnitStatePercent"

# Standard names from common.j. They let the tool resolve the usual
# GetUnitStatePercent(..., UNIT_STATE_MAX_LIFE) argument without scanning
# Scripts\common.j. UjAPI-only values 4..7 are listed so they are reported
# explicitly instead of looking like a garbled custom constant.
BUILTIN_CONSTANTS = {
    b"UNIT_STATE_LIFE": (b"unitstate", 0),
    b"UNIT_STATE_MAX_LIFE": (b"unitstate", 1),
    b"UNIT_STATE_MANA": (b"unitstate", 2),
    b"UNIT_STATE_MAX_MANA": (b"unitstate", 3),
    b"UNIT_STATE_REGEN_LIFE": (b"unitstate", 4),
    b"UNIT_STATE_REGEN_MANA": (b"unitstate", 5),
    b"UNIT_STATE_BONUS_LIFE": (b"unitstate", 6),
    b"UNIT_STATE_BONUS_MANA": (b"unitstate", 7),
}


# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------

@dataclass
class Token:
    kind: str
    start: int
    end: int
    line: int
    col: int
    text: bytes


def _advance_position(text: bytes, line: int, col: int) -> tuple[int, int]:
    i = 0
    while i < len(text):
        byte = text[i]
        if byte == 0x0D and i + 1 < len(text) and text[i + 1] == 0x0A:
            line += 1
            col = 1
            i += 2
            continue
        if byte in (0x0A, 0x0D):
            line += 1
            col = 1
        else:
            col += 1
        i += 1
    return line, col


def tokenize(data: bytes) -> list[Token]:
    tokens: list[Token] = []
    n = len(data)
    i = 0
    line = 1
    col = 1

    def emit(kind: str, start: int, end: int) -> None:
        nonlocal line, col
        text = data[start:end]
        tokens.append(Token(kind, start, end, line, col, text))
        line, col = _advance_position(text, line, col)

    while i < n:
        byte = data[i]
        start = i
        if byte in (0x20, 0x09, 0x0B, 0x0C):
            i += 1
            while i < n and data[i] in (0x20, 0x09, 0x0B, 0x0C):
                i += 1
            emit("ws", start, i)
        elif byte in (0x0A, 0x0D):
            if byte == 0x0D and i + 1 < n and data[i + 1] == 0x0A:
                i += 2
            else:
                i += 1
            emit("newline", start, i)
        elif byte == 0x2F and i + 1 < n and data[i + 1] == 0x2F:  # //
            i += 2
            while i < n and data[i] not in (0x0A, 0x0D):
                i += 1
            emit("comment", start, i)
        elif byte == 0x2F and i + 1 < n and data[i + 1] == 0x2A:  # /*
            i += 2
            while i + 1 < n and not (data[i] == 0x2A and data[i + 1] == 0x2F):
                i += 1
            i = min(n, i + 2 if i + 1 < n else n)
            emit("comment", start, i)
        elif byte == 0x22:  # "
            i += 1
            while i < n:
                if data[i] == 0x5C and i + 1 < n:  # backslash escape
                    i += 2
                    continue
                if data[i] == 0x22:
                    i += 1
                    break
                i += 1
            emit("string", start, i)
        elif byte == 0x27:  # '
            i += 1
            while i < n:
                if data[i] == 0x5C and i + 1 < n:
                    i += 2
                    continue
                if data[i] == 0x27:
                    i += 1
                    break
                i += 1
            emit("rawcode", start, i)
        elif _is_ident_start(byte):
            i += 1
            while i < n and _is_ident_continue(data[i]):
                i += 1
            emit("ident", start, i)
        elif byte == 0x30 and i + 1 < n and data[i + 1] in (0x78, 0x58):  # 0x
            i += 2
            while i < n and _is_hex(data[i]):
                i += 1
            emit("int", start, i)
        elif byte == 0x24:  # $
            i += 1
            while i < n and _is_hex(data[i]):
                i += 1
            emit("int" if i > start + 1 else "punct", start, i)
        elif _is_digit(byte):
            i += 1
            while i < n and _is_digit(data[i]):
                i += 1
            if i < n and data[i] == 0x2E:  # .
                i += 1
                while i < n and _is_digit(data[i]):
                    i += 1
                emit("real", start, i)
            else:
                emit("int", start, i)
        elif byte == 0x2E and i + 1 < n and _is_digit(data[i + 1]):  # .5
            i += 2
            while i < n and _is_digit(data[i]):
                i += 1
            emit("real", start, i)
        else:
            two = data[i:i + 2]
            if two in (b"==", b"!=", b"<=", b">="):
                i += 2
                emit("punct", start, i)
            else:
                i += 1
                kind = "punct" if byte < 0x80 else "other"
                emit(kind, start, i)

    return tokens


def _is_ident_start(byte: int) -> bool:
    return (0x41 <= byte <= 0x5A) or (0x61 <= byte <= 0x7A) or byte == 0x5F


def _is_ident_continue(byte: int) -> bool:
    return _is_ident_start(byte) or _is_digit(byte)


def _is_digit(byte: int) -> bool:
    return 0x30 <= byte <= 0x39


def _is_hex(byte: int) -> bool:
    return _is_digit(byte) or (0x41 <= byte <= 0x46) or (0x61 <= byte <= 0x66)


def _is_trivia(token: Token) -> bool:
    return token.kind in TRIVIA_KINDS


def _next_nontrivia(tokens: list[Token], index: int) -> Optional[int]:
    while index < len(tokens) and _is_trivia(tokens[index]):
        index += 1
    return index if index < len(tokens) else None


def _prev_nontrivia(tokens: list[Token], index: int) -> Optional[int]:
    index -= 1
    while index >= 0 and _is_trivia(tokens[index]):
        index -= 1
    return index if index >= 0 else None


def _core_bounds(tokens: list[Token], start: int, end: int) -> Optional[tuple[int, int]]:
    while start < end and _is_trivia(tokens[start]):
        start += 1
    while end > start and _is_trivia(tokens[end - 1]):
        end -= 1
    if start >= end:
        return None
    return start, end


def _matching_paren(tokens: list[Token], open_index: int) -> Optional[int]:
    depth = 0
    for index in range(open_index, len(tokens)):
        text = tokens[index].text
        if tokens[index].kind != "punct":
            continue
        if text == b"(":
            depth += 1
        elif text == b")":
            depth -= 1
            if depth == 0:
                return index
    return None


def _split_args(tokens: list[Token], start: int, end: int) -> list[tuple[int, int]]:
    args: list[tuple[int, int]] = []
    depth = 0
    arg_start = start
    for index in range(start, end):
        token = tokens[index]
        if token.kind != "punct":
            continue
        if token.text in (b"(", b"["):
            depth += 1
        elif token.text in (b")", b"]"):
            depth -= 1
            if depth < 0:
                return []
        elif token.text == b"," and depth == 0:
            args.append((arg_start, index))
            arg_start = index + 1
    args.append((arg_start, end))
    return args


# ---------------------------------------------------------------------------
# Integer literals and constants
# ---------------------------------------------------------------------------

def parse_int_literal(text: bytes) -> Optional[int]:
    try:
        if text.startswith((b"0x", b"0X")):
            value = int(text[2:], 16)
        elif text.startswith(b"$"):
            value = int(text[1:], 16)
        elif len(text) > 1 and text.startswith(b"0"):
            # pjass parses a leading-zero literal with base 8 and rejects 8/9
            # in it; mirror that instead of silently treating 0208 as decimal.
            if not all(0x30 <= b <= 0x37 for b in text[1:]):
                return None
            value = int(text, 8)
        else:
            value = int(text, 10)
    except ValueError:
        return None
    if value < 0 or value > 0xFFFFFFFF:
        return None
    return value


def canonical_int_literal(text: bytes) -> bytes:
    # tools/pjass.exe (the gate pack.ps1 uses) rejects 0X20 even though
    # token.l lists 0X. Emit the lowercase form.
    if text.startswith(b"0X"):
        return b"0x" + text[2:]
    return text


@dataclass
class Constant:
    name: bytes
    kind: bytes  # b"integer" or b"unitstate"
    value: Optional[int] = None
    literal: Optional[bytes] = None
    ref: Optional[bytes] = None
    file: str = ""
    line: int = 0


def collect_constants(tokens: list[Token], file: str) -> dict[bytes, Constant]:
    constants: dict[bytes, Constant] = {}
    in_globals = False
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "ident" and token.text == b"globals":
            in_globals = True
            index += 1
            continue
        if token.kind == "ident" and token.text == b"endglobals":
            in_globals = False
            index += 1
            continue
        if not in_globals or token.kind != "ident" or token.text != b"constant":
            index += 1
            continue

        type_index = _next_nontrivia(tokens, index + 1)
        if type_index is None or tokens[type_index].kind != "ident":
            index += 1
            continue
        if tokens[type_index].text not in (b"integer", b"unitstate"):
            index += 1
            continue
        name_index = _next_nontrivia(tokens, type_index + 1)
        if name_index is None or tokens[name_index].kind != "ident":
            index += 1
            continue
        equals_index = _next_nontrivia(tokens, name_index + 1)
        if equals_index is None or tokens[equals_index].text != b"=":
            index += 1
            continue

        expression: list[Token] = []
        depth = 0
        cursor = equals_index + 1
        while cursor < len(tokens):
            current = tokens[cursor]
            if current.kind == "punct" and current.text in (b"(", b"["):
                depth += 1
            elif current.kind == "punct" and current.text in (b")", b"]"):
                depth = max(0, depth - 1)
            if current.kind == "newline" and depth == 0:
                break
            expression.append(current)
            cursor += 1

        constant = Constant(
            name=tokens[name_index].text,
            kind=tokens[type_index].text,
            file=file,
            line=tokens[name_index].line,
        )
        core = [t for t in expression if not _is_trivia(t)]
        if len(core) == 1 and core[0].kind == "int":
            value = parse_int_literal(core[0].text)
            if value is not None:
                constant.value = value
                constant.literal = canonical_int_literal(core[0].text)
        elif _is_convert_call(core):
            value = parse_int_literal(core[2].text)
            if value is not None:
                constant.value = value
                constant.literal = canonical_int_literal(core[2].text)
        elif len(core) == 1 and core[0].kind == "ident":
            constant.ref = core[0].text
        constants[constant.name] = constant
        index = max(index + 1, cursor)
    return constants


def _is_convert_call(core: list[Token]) -> bool:
    return (len(core) == 4
            and core[0].kind == "ident"
            and core[0].text == b"ConvertUnitState"
            and core[1].text == b"("
            and core[2].kind == "int"
            and core[3].text == b")")


def resolve_constants(constants: dict[bytes, Constant]) -> None:
    def resolve(constant: Constant, visiting: set[bytes]) -> None:
        if constant.value is not None or not constant.ref:
            return
        if constant.name in visiting:
            return
        visiting.add(constant.name)
        target = constants.get(constant.ref)
        if target is not None:
            resolve(target, visiting)
            if target.value is not None:
                constant.value = target.value
                if target.kind == b"integer":
                    constant.literal = target.name
                else:
                    constant.literal = target.literal
        visiting.discard(constant.name)

    for constant in constants.values():
        resolve(constant, set())


@dataclass
class StateResolution:
    value: int
    replacement: bytes
    kind: str


def lookup_constant(constants: dict[bytes, Constant], name: bytes) -> Optional[Constant]:
    constant = constants.get(name)
    if constant is not None:
        return constant
    builtin = BUILTIN_CONSTANTS.get(name)
    if builtin is None:
        return None
    kind, value = builtin
    return Constant(name=name, kind=kind, value=value,
                    literal=str(value).encode("ascii"))


def resolve_state(tokens: list[Token], start: int, end: int,
                  constants: dict[bytes, Constant]) -> Optional[StateResolution]:
    bounds = _core_bounds(tokens, start, end)
    if bounds is None:
        return None
    core = [t for t in tokens[bounds[0]:bounds[1]] if not _is_trivia(t)]
    if not core:
        return None
    if len(core) == 1 and core[0].kind == "int":
        value = parse_int_literal(core[0].text)
        if value is None:
            return None
        return StateResolution(value, canonical_int_literal(core[0].text), "literal")
    if _is_convert_call(core):
        value = parse_int_literal(core[2].text)
        if value is None:
            return None
        # The EX wrapper takes an integer, so unwrap ConvertUnitState.
        return StateResolution(value, canonical_int_literal(core[2].text),
                               "convert-literal")
    if len(core) == 1 and core[0].kind == "ident":
        constant = lookup_constant(constants, core[0].text)
        if constant is None or constant.value is None:
            return None
        if constant.kind == b"integer":
            return StateResolution(constant.value, core[0].text, "integer-constant")
        literal = constant.literal or str(constant.value).encode("ascii")
        return StateResolution(constant.value, literal, "unitstate-constant")
    if (len(core) == 4 and core[0].kind == "ident"
            and core[0].text == b"ConvertUnitState"
            and core[1].text == b"(" and core[3].text == b")"
            and core[2].kind == "ident"):
        constant = lookup_constant(constants, core[2].text)
        if constant is None or constant.value is None or constant.kind != b"integer":
            return None
        return StateResolution(constant.value, core[2].text, "convert-integer-constant")
    return None


# ---------------------------------------------------------------------------
# Migration
# ---------------------------------------------------------------------------

@dataclass
class Rewrite:
    file: str
    line: int
    col: int
    function: str
    state_value: int
    state_name: str
    state_old: str
    state_new: str
    unit_wrapped: bool


@dataclass
class Skip:
    file: str
    line: int
    col: int
    function: str
    reason: str
    state_expr: str


@dataclass
class FileResult:
    path: str
    changed: bool = False
    output: bytes = b""
    rewrites: list[Rewrite] = field(default_factory=list)
    skips: list[Skip] = field(default_factory=list)


class StateTable:
    def __init__(self, document: dict):
        self.by_value = {int(s["value"]): s for s in document["states"]}
        self.vanilla = set(int(v) for v in document.get("vanilla", [0, 1, 2, 3]))
        self.ujapi_only = {int(s["value"]): s for s in document.get("ujapi_only", [])}

    @classmethod
    def load(cls, path: Path) -> "StateTable":
        with path.open("r", encoding="utf-8") as stream:
            return cls(json.load(stream))

    def classify(self, value: int, is_set: bool) -> tuple[Optional[dict], Optional[str]]:
        if value in self.vanilla:
            return None, "vanilla-state"
        if value in self.ujapi_only:
            return None, "ujapi-only-state"
        state = self.by_value.get(value)
        if state is None:
            return None, "unknown-state"
        if is_set and not state.get("set", False):
            return None, "set-noop-state"
        if not is_set and not state.get("get", False):
            return None, "get-unsupported-state"
        return state, None


def _core_bounds_and_text(data: bytes, tokens: list[Token],
                          start: int, end: int) -> Optional[tuple[int, int, bytes]]:
    bounds = _core_bounds(tokens, start, end)
    if bounds is None:
        return None
    return (bounds[0], bounds[1],
            data[tokens[bounds[0]].start:tokens[bounds[1] - 1].end])


def state_identifier(tokens: list[Token], start: int, end: int) -> Optional[bytes]:
    """Identifier used by a state expression, if it is a simple one."""
    bounds = _core_bounds(tokens, start, end)
    if bounds is None:
        return None
    core = [t for t in tokens[bounds[0]:bounds[1]] if not _is_trivia(t)]
    if len(core) == 1 and core[0].kind == "ident":
        return core[0].text
    if _is_convert_call(core) and core[2].kind == "ident":
        return core[2].text
    return None


def containing_function(functions: list[FunctionInfo],
                        index: int) -> Optional[FunctionInfo]:
    for function in functions:
        if function.start < index < function.end:
            return function
    return None


def shadowed_names(function: Optional[FunctionInfo]) -> set[bytes]:
    if function is None:
        return set()
    return function.parameters | function.locals


def _migrate_percent(data: bytes, file: str, tokens: list[Token],
                     args: list[tuple[int, int]], call_token: Token,
                     constants: dict[bytes, Constant], table: StateTable,
                     shadowed: set[bytes]):
    unit_bounds = _core_bounds_and_text(data, tokens, *args[0])
    state_bounds = _core_bounds_and_text(data, tokens, *args[1])
    max_bounds = _core_bounds_and_text(data, tokens, *args[2])
    if unit_bounds is None or state_bounds is None or max_bounds is None:
        return None, Skip(file, call_token.line, call_token.col,
                          "GetUnitStatePercent", "empty-argument", ""), None

    state_ident = state_identifier(tokens, *args[1])
    max_ident = state_identifier(tokens, *args[2])
    if (state_ident is not None and state_ident in shadowed) or (
            max_ident is not None and max_ident in shadowed):
        combined = (state_bounds[2].decode("latin-1") + ", "
                    + max_bounds[2].decode("latin-1"))
        return None, Skip(file, call_token.line, call_token.col,
                          "GetUnitStatePercent", "shadowed-state", combined[:80]), None

    state_res = resolve_state(tokens, args[1][0], args[1][1], constants)
    max_res = resolve_state(tokens, args[2][0], args[2][1], constants)
    combined = (state_bounds[2].decode("latin-1") + ", "
                + max_bounds[2].decode("latin-1"))
    if state_res is None or max_res is None:
        return None, Skip(file, call_token.line, call_token.col,
                          "GetUnitStatePercent", "unresolved-state", combined[:80]), None

    state_state, state_reason = table.classify(state_res.value, False)
    max_state, max_reason = table.classify(max_res.value, False)
    for reason in (state_reason, max_reason):
        if reason is not None and reason != "vanilla-state":
            return None, Skip(file, call_token.line, call_token.col,
                              "GetUnitStatePercent", reason, combined[:80]), None
    if state_reason == "vanilla-state" and max_reason == "vanilla-state":
        return None, Skip(file, call_token.line, call_token.col,
                          "GetUnitStatePercent", "percent-vanilla", combined[:80]), None

    replacement = (b"YDWEGetUnitStatePercent(" + unit_bounds[2] + b", "
                   + state_res.replacement + b", " + max_res.replacement + b")")
    state_name = (state_state or {}).get("short") or f"0x{state_res.value:X}"
    max_name = (max_state or {}).get("short") or f"0x{max_res.value:X}"
    value = state_res.value if state_state is not None else max_res.value
    rewrite = Rewrite(
        file=file,
        line=call_token.line,
        col=call_token.col,
        function="GetUnitStatePercent",
        state_value=value,
        state_name=f"{state_name}/{max_name}",
        state_old=combined[:80],
        state_new=replacement.decode("latin-1")[:80],
        unit_wrapped=False,
    )
    edits = [
        (call_token.start, call_token.end, HELPER_PERCENT),
        (tokens[state_bounds[0]].start, tokens[state_bounds[1] - 1].end,
         state_res.replacement),
        (tokens[max_bounds[0]].start, tokens[max_bounds[1] - 1].end,
         max_res.replacement),
    ]
    return rewrite, None, edits


@dataclass
class FunctionInfo:
    name: bytes
    start: int
    end: int
    constant: bool
    initialize_plugin_index: Optional[int]
    parameters: set[bytes] = field(default_factory=set)
    locals: set[bytes] = field(default_factory=set)


def _parse_parameters(tokens: list[Token], start: int, end: int) -> set[bytes]:
    names: set[bytes] = set()
    cursor = start
    while cursor < end:
        cursor = _next_nontrivia(tokens, cursor) or end
        if cursor >= end:
            break
        if tokens[cursor].kind == "ident" and tokens[cursor].text == b"nothing":
            break
        if tokens[cursor].kind != "ident":
            break
        name_index = _next_nontrivia(tokens, cursor + 1)
        if name_index is None or name_index >= end or tokens[name_index].kind != "ident":
            break
        names.add(tokens[name_index].text)
        cursor = name_index + 1
        comma = _next_nontrivia(tokens, cursor)
        if comma is None or comma >= end or tokens[comma].text != b",":
            break
        cursor = comma + 1
    return names


def _parse_locals(tokens: list[Token], start: int, end: int) -> set[bytes]:
    names: set[bytes] = set()
    for index in range(start, end):
        if not (tokens[index].kind == "ident" and tokens[index].text == b"local"):
            continue
        cursor = _next_nontrivia(tokens, index + 1)
        if cursor is None or cursor >= end:
            continue
        if tokens[cursor].kind == "ident" and tokens[cursor].text == b"constant":
            cursor = _next_nontrivia(tokens, cursor + 1)
        if cursor is None or cursor >= end or tokens[cursor].kind != "ident":
            continue
        cursor = _next_nontrivia(tokens, cursor + 1)
        if cursor is None or cursor >= end:
            continue
        if tokens[cursor].kind == "ident" and tokens[cursor].text == b"array":
            cursor = _next_nontrivia(tokens, cursor + 1)
        if cursor is None or cursor >= end or tokens[cursor].kind != "ident":
            continue
        names.add(tokens[cursor].text)
    return names


def analyze_context(tokens: list[Token]) -> tuple[list[tuple[int, int]],
                                                  list[FunctionInfo]]:
    globals_ranges: list[tuple[int, int]] = []
    index = 0
    while index < len(tokens):
        if tokens[index].kind == "ident" and tokens[index].text == b"globals":
            end = index + 1
            while end < len(tokens) and not (
                    tokens[end].kind == "ident" and tokens[end].text == b"endglobals"):
                end += 1
            globals_ranges.append((index, min(end, len(tokens) - 1)))
            index = end + 1
            continue
        index += 1

    functions: list[FunctionInfo] = []
    index = 0
    while index < len(tokens):
        if not (tokens[index].kind == "ident" and tokens[index].text == b"function"):
            index += 1
            continue
        name_index = _next_nontrivia(tokens, index + 1)
        if name_index is None or tokens[name_index].kind != "ident":
            index += 1
            continue
        end = index + 1
        while end < len(tokens) and not (
                tokens[end].kind == "ident" and tokens[end].text == b"endfunction"):
            end += 1
        previous = _prev_nontrivia(tokens, index)
        constant = (previous is not None
                    and tokens[previous].kind == "ident"
                    and tokens[previous].text == b"constant")
        initialize_plugin = None
        for cursor in range(index, min(end + 1, len(tokens))):
            if (tokens[cursor].kind == "ident"
                    and tokens[cursor].text == b"initializePlugin"):
                initialize_plugin = cursor
                break
        takes_index = None
        returns_index = None
        for cursor in range(name_index + 1, min(end + 1, len(tokens))):
            if tokens[cursor].kind != "ident":
                continue
            if tokens[cursor].text == b"takes" and takes_index is None:
                takes_index = cursor
            elif tokens[cursor].text == b"returns":
                returns_index = cursor
                break
        parameters = set()
        if takes_index is not None and returns_index is not None:
            parameters = _parse_parameters(tokens, takes_index + 1, returns_index)
        functions.append(FunctionInfo(
            name=tokens[name_index].text,
            start=index,
            end=min(end, len(tokens) - 1),
            constant=constant,
            initialize_plugin_index=initialize_plugin,
            parameters=parameters,
            locals=_parse_locals(tokens, name_index + 1, end)))
        index = end + 1
    return globals_ranges, functions


def context_skip_reason(call_index: int,
                        globals_ranges: list[tuple[int, int]],
                        functions: list[FunctionInfo]) -> Optional[str]:
    for start, end in globals_ranges:
        if start < call_index < end:
            return "global-initializer"
    for function in functions:
        if not (function.start < call_index < function.end):
            continue
        if function.constant:
            return "constant-function"
        if function.name == b"config":
            return "early-config"
        if function.name == b"main":
            if (function.initialize_plugin_index is None
                    or call_index < function.initialize_plugin_index):
                return "early-main"
        return None
    return None


def migrate_bytes(data: bytes, file: str, constants: dict[bytes, Constant],
                  table: StateTable) -> FileResult:
    tokens = tokenize(data)
    globals_ranges, functions = analyze_context(tokens)
    result = FileResult(path=file, output=data)
    edits: list[tuple[int, int, bytes]] = []

    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token.kind != "ident" or token.text not in TARGETS:
            index += 1
            continue
        # JASS has no line continuation in an expression list. Only spaces/tabs
        # may sit between the callee and '('; a comment or newline here means
        # the source is not valid JASS, so leave it alone.
        open_index = index + 1
        while open_index < len(tokens) and tokens[open_index].kind == "ws":
            open_index += 1
        if open_index >= len(tokens) or tokens[open_index].text != b"(":
            index += 1
            continue
        close_index = _matching_paren(tokens, open_index)
        if close_index is None:
            result.skips.append(Skip(file, token.line, token.col,
                                     token.text.decode("ascii"), "malformed-call", ""))
            index += 1
            continue
        if any(t.kind == "newline" for t in tokens[open_index + 1:close_index]):
            result.skips.append(Skip(file, token.line, token.col,
                                     token.text.decode("ascii"), "multiline-call",
                                     data[open_index + 1:close_index]
                                     .decode("latin-1")[:80]))
            index = close_index + 1
            continue
        args = _split_args(tokens, open_index + 1, close_index)
        is_set = token.text == TARGET_SET
        is_percent = token.text == TARGET_PERCENT
        expected = 3 if (is_set or is_percent) else 2
        if len(args) != expected:
            result.skips.append(Skip(file, token.line, token.col,
                                     token.text.decode("ascii"), "malformed-call",
                                     data[open_index + 1:close_index]
                                     .decode("latin-1")[:80]))
            index = close_index + 1
            continue

        context_reason = context_skip_reason(index, globals_ranges, functions)
        if context_reason is not None:
            result.skips.append(Skip(file, token.line, token.col,
                                     token.text.decode("ascii"), context_reason,
                                     data[open_index + 1:close_index]
                                     .decode("latin-1")[:80]))
            index = close_index + 1
            continue

        # Scan the arguments as well. A stock call can contain an extended
        # state read, and the unit or value expression can contain one too.
        function = containing_function(functions, index)
        shadowed = shadowed_names(function)
        index = open_index + 1
        if is_percent:
            rewrite, skip, percent_edits = _migrate_percent(
                data, file, tokens, args, token, constants, table, shadowed)
            if rewrite is not None:
                edits.extend(percent_edits)
                result.rewrites.append(rewrite)
            if skip is not None:
                result.skips.append(skip)
            continue

        if token.text == TARGET_SWAP:
            state_start, state_end = args[0]
            unit_start, unit_end = args[1]
            is_swap = True
        else:
            unit_start, unit_end = args[0]
            state_start, state_end = args[1]
            is_swap = False

        unit_bounds = _core_bounds(tokens, unit_start, unit_end)
        state_bounds = _core_bounds(tokens, state_start, state_end)
        if unit_bounds is None or state_bounds is None:
            result.skips.append(Skip(file, token.line, token.col,
                                     token.text.decode("ascii"), "empty-argument", ""))
            continue

        state_ident = state_identifier(tokens, state_start, state_end)
        if state_ident is not None and state_ident in shadowed:
            state_text = data[tokens[state_bounds[0]].start:
                              tokens[state_bounds[1] - 1].end]
            result.skips.append(Skip(file, token.line, token.col,
                                     token.text.decode("ascii"), "shadowed-state",
                                     state_text.decode("latin-1")[:80]))
            continue

        resolution = resolve_state(tokens, state_start, state_end, constants)
        if resolution is None:
            state_text = data[tokens[state_bounds[0]].start:
                              tokens[state_bounds[1] - 1].end]
            result.skips.append(Skip(file, token.line, token.col,
                                     token.text.decode("ascii"), "unresolved-state",
                                     state_text.decode("latin-1")[:80]))
            continue

        state, reason = table.classify(resolution.value, is_set)
        state_text = data[tokens[state_bounds[0]].start:
                          tokens[state_bounds[1] - 1].end].decode("latin-1")
        if state is None:
            result.skips.append(Skip(file, token.line, token.col,
                                     token.text.decode("ascii"), reason or "unsupported",
                                     state_text[:80]))
            continue

        new_name = WRAPPER_SET if is_set else WRAPPER_GET
        unit_first = tokens[unit_bounds[0]].start
        unit_end = tokens[unit_bounds[1] - 1].end
        state_new = resolution.replacement

        if is_swap:
            # Move the state argument to the end without replacing the unit
            # expression, which can contain edits of its own.
            edits.append((token.start, unit_first, b"EXGetUnitState(GetHandleId("))
            edits.append((unit_end, tokens[close_index].start, b"), " + state_new))
        else:
            edits.append((token.start, token.end, new_name))
            edits.append((unit_first, unit_first, b"GetHandleId("))
            edits.append((unit_end, unit_end, b")"))
            if state_new != data[tokens[state_bounds[0]].start:
                              tokens[state_bounds[1] - 1].end]:
                edits.append((tokens[state_bounds[0]].start,
                              tokens[state_bounds[1] - 1].end, state_new))

        state_name = state.get("short") or state.get("name", "")
        result.rewrites.append(Rewrite(
            file=file,
            line=token.line,
            col=token.col,
            function=token.text.decode("ascii"),
            state_value=resolution.value,
            state_name=str(state_name),
            state_old=state_text[:80],
            state_new=state_new.decode("latin-1")[:80],
            unit_wrapped=True,
        ))

    result.changed = bool(edits)
    if not edits:
        return result

    edits.sort(key=lambda edit: (edit[0], edit[1]), reverse=True)
    output = bytearray(data)
    previous_start = len(data)
    for start, end, replacement in edits:
        if end > previous_start:
            raise ValueError(f"{file}: internal edit overlap at byte {start}")
        output[start:end] = replacement
        previous_start = start
    result.output = bytes(output)
    return result


# ---------------------------------------------------------------------------
# Definitions and compat block
# ---------------------------------------------------------------------------

def collect_definitions(tokens: list[Token]) -> tuple[set[bytes], set[bytes]]:
    functions: set[bytes] = set()
    natives: set[bytes] = set()
    for index, token in enumerate(tokens):
        if token.kind != "ident" or token.text not in (b"function", b"native"):
            continue
        name_index = _next_nontrivia(tokens, index + 1)
        if name_index is None or tokens[name_index].kind != "ident":
            continue
        takes_index = _next_nontrivia(tokens, name_index + 1)
        if takes_index is None or tokens[takes_index].text != b"takes":
            continue
        if token.text == b"function":
            functions.add(tokens[name_index].text)
        else:
            natives.add(tokens[name_index].text)
    return functions, natives


WRAPPER_GET_TEXT = """function EXGetUnitState takes integer arg1, integer arg2 returns real
    call SaveStr(japi_ht, japi__key, 0, "(II)R")
    call SaveInteger(japi_ht, japi__key, 1, arg1)
    call SaveInteger(japi_ht, japi__key, 2, arg2)
    call UnitId("EXGetUnitState")
    return LoadReal(japi_ht, japi__key, 0)
endfunction
"""

WRAPPER_SET_TEXT = """function EXSetUnitState takes integer arg1, integer arg2, real arg3 returns nothing
    call SaveStr(japi_ht, japi__key, 0, "(IIR)V")
    call SaveInteger(japi_ht, japi__key, 1, arg1)
    call SaveInteger(japi_ht, japi__key, 2, arg2)
    call SaveReal(japi_ht, japi__key, 3, arg3)
    call UnitId("EXSetUnitState")
endfunction
"""

HELPER_GET_TEXT = """function YDWEGetUnitState takes unit whichUnit, unitstate whichState returns real
    local integer state = GetHandleId(whichState)
    if state >= 0 and state <= 3 then
        return GetUnitState(whichUnit, whichState)
    endif
    return EXGetUnitState(GetHandleId(whichUnit), state)
endfunction
"""

HELPER_SET_TEXT = """function YDWESetUnitState takes unit whichUnit, unitstate whichState, real value returns nothing
    local integer state = GetHandleId(whichState)
    if state >= 0 and state <= 3 then
        call SetUnitState(whichUnit, whichState, value)
    else
        call EXSetUnitState(GetHandleId(whichUnit), state, value)
    endif
endfunction
"""

HELPER_PERCENT_TEXT = """function YDWEGetUnitStatePercent takes unit whichUnit, integer whichState, integer whichMaxState returns real
    local real value
    local real maxValue
    if whichState >= 0 and whichState <= 3 then
        set value = GetUnitState(whichUnit, ConvertUnitState(whichState))
    else
        set value = EXGetUnitState(GetHandleId(whichUnit), whichState)
    endif
    if whichMaxState >= 0 and whichMaxState <= 3 then
        set maxValue = GetUnitState(whichUnit, ConvertUnitState(whichMaxState))
    else
        set maxValue = EXGetUnitState(GetHandleId(whichUnit), whichMaxState)
    endif
    if maxValue == 0.0 then
        return 0.0
    endif
    if value <= 0.0 then
        return 0.0
    endif
    if value >= maxValue then
        return 100.0
    endif
    return value / maxValue * 100.0
endfunction
"""

COMPAT_HEADER = """// ============================================================================
// YDWE unit-state compatibility block (map-inject tools/ydwe-compat).
//
// Insert this block after `endglobals` and before the first function that
// calls EXGetUnitState / EXSetUnitState / YDWEGetUnitState / YDWESetUnitState.
//
// EXGetUnitState and EXSetUnitState are UnitId bridge wrappers with the same
// shape tools/gen-jass-wrappers.ps1 emits. If the map is packed with
// `pack.ps1 -WithJassWrappers`, that generator emits them itself and skips
// names the map already defines; do not add this block twice.
//
// The YDWE* helpers accept runtime unitstate values. They cast unitstate with
// GetHandleId(state), the only typed cast vanilla JASS has. Direct call-site
// migration resolves known constants to integer literals and does not use
// this cast; the helper path is therefore not covered by the offline
// compile-only tests beyond pjass type checking.
// ============================================================================
"""


def build_compat_block(functions: set[bytes], natives: set[bytes],
                       include_wrappers: bool = True) -> bytes:
    chunks: list[str] = [COMPAT_HEADER]
    defined = functions | natives
    if include_wrappers:
        if WRAPPER_GET not in defined:
            chunks.append(WRAPPER_GET_TEXT)
        if WRAPPER_SET not in defined:
            chunks.append(WRAPPER_SET_TEXT)
    if HELPER_GET not in defined:
        chunks.append(HELPER_GET_TEXT)
    if HELPER_SET not in defined:
        chunks.append(HELPER_SET_TEXT)
    if HELPER_PERCENT not in defined:
        chunks.append(HELPER_PERCENT_TEXT)
    return ("\n".join(chunks)).encode("utf-8")


# ---------------------------------------------------------------------------
# CLI plumbing
# ---------------------------------------------------------------------------

def iter_jass_files(paths: Iterable[Path], excludes: set[str]) -> Iterable[Path]:
    default_excludes = {".git", "__pycache__", "build", ".agents", "node_modules"}
    for path in paths:
        if path.is_file():
            yield path
            continue
        for root, dirs, files in os.walk(path, followlinks=False):
            dirs[:] = [d for d in dirs
                       if d not in excludes and d not in default_excludes]
            for name in sorted(files):
                if name.lower().endswith(".j"):
                    yield Path(root) / name


def print_summary(results: list[FileResult], quiet: bool) -> None:
    changed = [r for r in results if r.changed]
    rewrites = sum(len(r.rewrites) for r in results)
    skips = sum(len(r.skips) for r in results)
    if not quiet:
        for result in results:
            if not result.changed:
                continue
            print(f"{result.path}: {len(result.rewrites)} rewrite(s)")
            for rewrite in result.rewrites:
                print(f"  {rewrite.line}:{rewrite.col} {rewrite.function} "
                      f"state=0x{rewrite.state_value:X} ({rewrite.state_name})"
                      f" {rewrite.state_old} -> {rewrite.state_new}")
            for skip in result.skips:
                print(f"  {skip.line}:{skip.col} skipped {skip.function}: "
                      f"{skip.reason} ({skip.state_expr})")
        for result in results:
            if result.changed or not result.skips:
                continue
            for skip in result.skips:
                print(f"{result.path}:{skip.line}:{skip.col} skipped "
                      f"{skip.function}: {skip.reason} ({skip.state_expr})")
    print(f"migrate-unit-state: files={len(results)} changed={len(changed)} "
          f"rewrites={rewrites} skipped={skips}")


def write_report(path: Path, results: list[FileResult],
                 functions: set[bytes], natives: set[bytes]) -> None:
    document = {
        "format": 1,
        "files": [
            {
                "path": result.path,
                "changed": result.changed,
                "rewrites": [rewrite.__dict__ for rewrite in result.rewrites],
                "skips": [skip.__dict__ for skip in result.skips],
            }
            for result in results
        ],
        "definitions": {
            "functions": sorted(name.decode("latin-1") for name in functions),
            "natives": sorted(name.decode("latin-1") for name in natives),
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def default_states_path() -> Path:
    return Path(__file__).resolve().parent / "unit_states.json"


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Offline YDWE unit-state JASS source migration.")
    parser.add_argument("paths", nargs="+", type=Path,
                        help="JASS files or directories containing .j files")
    parser.add_argument("--in-place", action="store_true",
                        help="rewrite the input files")
    parser.add_argument("--out", type=Path,
                        help="write rewritten files below this directory")
    parser.add_argument("--check", action="store_true",
                        help="do not write; exit 1 if any file would change")
    parser.add_argument("--report-json", type=Path,
                        help="write a machine-readable report")
    parser.add_argument("--emit-compat", type=Path,
                        help="write the EX wrappers + YDWE helpers block")
    parser.add_argument("--no-wrappers", action="store_true",
                        help="do not put EXGetUnitState/EXSetUnitState in the "
                             "compat block (pack.ps1 -WithJassWrappers provides them)")
    parser.add_argument("--require-wrappers", action="store_true",
                        help="fail if EXGetUnitState/EXSetUnitState are not "
                             "defined in the scanned files and --emit-compat is absent")
    parser.add_argument("--states", type=Path, default=default_states_path(),
                        help="state table JSON (default: unit_states.json next to this tool)")
    parser.add_argument("--exclude", action="append", default=[],
                        help="directory name to skip (repeatable; build, .agents, "
                             ".git, __pycache__ and node_modules are always skipped)")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    if args.in_place and args.out:
        parser.error("--in-place and --out are mutually exclusive")
    if args.check and (args.in_place or args.out):
        parser.error("--check cannot be combined with --in-place/--out")

    table = StateTable.load(args.states)
    files = list(iter_jass_files(args.paths, set(args.exclude)))
    if not files:
        print("migrate-unit-state: no .j files found", file=sys.stderr)
        return 1

    file_data: list[tuple[Path, bytes]] = []
    constants: dict[bytes, Constant] = {}
    functions: set[bytes] = set()
    natives: set[bytes] = set()
    for path in files:
        try:
            data = path.read_bytes()
        except OSError as error:
            print(f"migrate-unit-state: cannot read {path}: {error}", file=sys.stderr)
            return 1
        tokens = tokenize(data)
        file_data.append((path, data))
        constants.update(collect_constants(tokens, str(path)))
        defs, native_defs = collect_definitions(tokens)
        functions |= defs
        natives |= native_defs
    resolve_constants(constants)

    results: list[FileResult] = []
    for path, data in file_data:
        try:
            result = migrate_bytes(data, str(path), constants, table)
        except ValueError as error:
            print(f"migrate-unit-state: {error}", file=sys.stderr)
            return 1
        results.append(result)

    if args.check:
        print_summary(results, args.quiet)
        return 1 if any(result.changed for result in results) else 0

    if args.in_place or args.out:
        roots = [path for path in args.paths if path.is_dir()]
        for result in results:
            if not result.changed:
                continue
            source = Path(result.path)
            if args.in_place:
                target = source
            else:
                relative = source.name
                for root in roots:
                    try:
                        relative = str(source.relative_to(root))
                        break
                    except ValueError:
                        continue
                target = args.out / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(result.output)

    if args.emit_compat:
        compat = build_compat_block(functions, natives,
                                    include_wrappers=not args.no_wrappers)
        args.emit_compat.parent.mkdir(parents=True, exist_ok=True)
        args.emit_compat.write_bytes(compat)
    elif args.require_wrappers:
        missing = [name.decode() for name in (WRAPPER_GET, WRAPPER_SET)
                   if name not in functions and name not in natives]
        needs_percent = any(
            rewrite.function == "GetUnitStatePercent"
            for result in results for rewrite in result.rewrites)
        if needs_percent and HELPER_PERCENT not in functions:
            missing.append(HELPER_PERCENT.decode())
        if missing:
            print("migrate-unit-state: missing compatibility functions (use "
                  "--emit-compat or pack.ps1 -WithJassWrappers): "
                  + ", ".join(missing), file=sys.stderr)
            return 1

    declared_natives = sorted(name.decode() for name in (WRAPPER_GET, WRAPPER_SET)
                              if name in natives)
    if declared_natives and not args.quiet:
        print("migrate-unit-state: warning: "
              + ", ".join(declared_natives)
              + " are declared as JASS natives; callback-mode maps cannot "
                "declare runtime natives. Use function wrappers instead.",
              file=sys.stderr)

    if not args.emit_compat:
        missing = [name.decode() for name in (WRAPPER_GET, WRAPPER_SET)
                   if name not in functions and name not in natives]
        needs_percent = any(
            rewrite.function == "GetUnitStatePercent"
            for result in results for rewrite in result.rewrites)
        if needs_percent and HELPER_PERCENT not in functions:
            missing.append(HELPER_PERCENT.decode())
        if missing and (args.in_place or args.out) and not args.quiet:
            print("migrate-unit-state: warning: migrated call sites need "
                  + ", ".join(missing)
                  + "; pack with -WithJassWrappers for the EX wrappers and use "
                    "--emit-compat for the YDWE percent helper",
                  file=sys.stderr)

    if args.report_json:
        write_report(args.report_json, results, functions, natives)

    print_summary(results, args.quiet)
    return 0


if __name__ == "__main__":
    sys.exit(main())

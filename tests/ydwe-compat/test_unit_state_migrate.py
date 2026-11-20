#!/usr/bin/env python3
"""Offline tests for tools/ydwe-compat/migrate_unit_state.py.

Run from the repository root:
    python -B tests/ydwe-compat/test_unit_state_migrate.py

No War3 process, MPQ, DLL, pack or deploy step is involved.
"""

from __future__ import annotations

import contextlib
import io
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL_DIR = ROOT / "tools" / "ydwe-compat"
sys.path.insert(0, str(TOOL_DIR))

import migrate_unit_state as migrate  # noqa: E402

TABLE = migrate.StateTable.load(TOOL_DIR / "unit_states.json")


def run_migration(source: bytes, constants_source: bytes | None = None):
    tokens = migrate.tokenize(source)
    constants = migrate.collect_constants(tokens, "fixture.j")
    if constants_source is not None:
        constants.update(migrate.collect_constants(
            migrate.tokenize(constants_source), "constants.j"))
    migrate.resolve_constants(constants)
    return migrate.migrate_bytes(source, "fixture.j", constants, TABLE)


class MigrationTests(unittest.TestCase):
    def test_extended_get_set(self):
        source = (b"function T takes unit u, real v returns nothing\n"
                  b"    local real a = GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"    local real b = GetUnitState(u, ConvertUnitState(0x25))\n"
                  b"    call SetUnitState(u, ConvertUnitState(0x10), v)\n"
                  b"endfunction\n")
        result = run_migration(source)
        self.assertTrue(result.changed)
        self.assertEqual(
            result.output,
            b"function T takes unit u, real v returns nothing\n"
            b"    local real a = EXGetUnitState(GetHandleId(u), 0x20)\n"
            b"    local real b = EXGetUnitState(GetHandleId(u), 0x25)\n"
            b"    call EXSetUnitState(GetHandleId(u), 0x10, v)\n"
            b"endfunction\n")
        self.assertEqual(len(result.rewrites), 3)

    def test_shadowed_state_names_are_not_resolved(self):
        constants = (b"globals\n"
                     b"    constant unitstate MY_ARMOR = ConvertUnitState(0x20)\n"
                     b"endglobals\n")
        parameter_shadow = (b"function T takes unit u, integer MY_ARMOR returns real\n"
                            b"    return GetUnitState(u, MY_ARMOR)\n"
                            b"endfunction\n")
        result = run_migration(parameter_shadow, constants)
        self.assertFalse(result.changed)
        self.assertEqual(result.skips[0].reason, "shadowed-state")

        local_shadow = (b"function T takes unit u returns real\n"
                        b"    local integer MY_ARMOR = 0\n"
                        b"    return GetUnitState(u, MY_ARMOR)\n"
                        b"endfunction\n")
        result = run_migration(local_shadow, constants)
        self.assertFalse(result.changed)
        self.assertEqual(result.skips[0].reason, "shadowed-state")

        not_shadowed = (b"function T takes unit u returns real\n"
                        b"    return GetUnitState(u, MY_ARMOR)\n"
                        b"endfunction\n")
        result = run_migration(not_shadowed, constants)
        self.assertTrue(result.changed)

    def test_nested_state_calls(self):
        source = (b"function T takes unit u returns nothing\n"
                  b"    call SetUnitState(u, UNIT_STATE_LIFE, GetUnitState(u, ConvertUnitState(0x20)))\n"
                  b"    call SetUnitState(u, ConvertUnitState(0x25), GetUnitState(u, ConvertUnitState(0x20)))\n"
                  b"endfunction\n")
        result = run_migration(source)
        read_armor = b"EXGetUnitState(GetHandleId(u), 0x20)"
        self.assertIn(b"SetUnitState(u, UNIT_STATE_LIFE, " + read_armor + b")", result.output)
        self.assertIn(b"EXSetUnitState(GetHandleId(u), 0x25, " + read_armor + b")", result.output)
        self.assertEqual(len(result.rewrites), 3)
        self.assertFalse(run_migration(result.output).changed)

    def test_comments_strings_rawcodes_and_boundaries(self):
        source = (b"globals\n"
                  b"    constant integer MyGetUnitState = 0\n"
                  b"endglobals\n"
                  b"function T takes unit u returns nothing\n"
                  b"    // GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"    local string s = \"GetUnitState(u, ConvertUnitState(0x20))\"\n"
                  b"    local integer raw = 'GetU'\n"
                  b"    local integer x = MyGetUnitState\n"
                  b"    local real y = GetUnitStateSwapExtra(u)\n"
                  b"    local real z = GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"endfunction\n")
        result = run_migration(source)
        self.assertTrue(result.changed)
        self.assertIn(b"// GetUnitState(u, ConvertUnitState(0x20))", result.output)
        self.assertIn(b'"GetUnitState(u, ConvertUnitState(0x20))"', result.output)
        self.assertIn(b"'GetU'", result.output)
        self.assertIn(b"MyGetUnitState", result.output)
        self.assertIn(b"GetUnitStateSwapExtra(u)", result.output)
        self.assertIn(b"EXGetUnitState(GetHandleId(u), 0x20)", result.output)
        self.assertEqual(len(result.rewrites), 1)

    def test_vanilla_unknown_ujapi_and_set_noop_are_untouched(self):
        source = (b"function T takes unit u returns nothing\n"
                  b"    local real a = GetUnitState(u, UNIT_STATE_LIFE)\n"
                  b"    local real b = GetUnitState(u, UNIT_STATE_MAX_LIFE)\n"
                  b"    local real c = GetUnitState(u, ConvertUnitState(0x62))\n"
                  b"    local real d = GetUnitState(u, ConvertUnitState(4))\n"
                  b"    call SetUnitState(u, ConvertUnitState(0x14), 1.0)\n"
                  b"endfunction\n")
        result = run_migration(source)
        self.assertFalse(result.changed)
        self.assertEqual(result.output, source)
        reasons = {skip.reason for skip in result.skips}
        self.assertIn("vanilla-state", reasons)
        self.assertIn("unknown-state", reasons)
        self.assertIn("ujapi-only-state", reasons)
        self.assertIn("set-noop-state", reasons)

    def test_swap_reorders_arguments(self):
        source = (b"function T takes unit u returns real\n"
                  b"    return GetUnitStateSwap(ConvertUnitState(0x51), FirstOfGroup(g))\n"
                  b"endfunction\n")
        result = run_migration(source)
        self.assertIn(
            b"EXGetUnitState(GetHandleId(FirstOfGroup(g)), 0x51)",
            result.output)
        self.assertNotIn(b"GetUnitStateSwap", result.output)

    def test_percent(self):
        source = (b"function T takes unit u returns real\n"
                  b"    local real a = GetUnitStatePercent(u, ConvertUnitState(0x20), UNIT_STATE_MAX_LIFE)\n"
                  b"    local real b = GetUnitStatePercent(u, UNIT_STATE_LIFE, UNIT_STATE_MAX_LIFE)\n"
                  b"    local real c = GetUnitStatePercent(u, ConvertUnitState(0x51), ConvertUnitState(0x62))\n"
                  b"    return a + b + c\n"
                  b"endfunction\n")
        result = run_migration(source)
        self.assertIn(b"YDWEGetUnitStatePercent(u, 0x20, 1)", result.output)
        self.assertIn(b"GetUnitStatePercent(u, UNIT_STATE_LIFE, UNIT_STATE_MAX_LIFE)",
                      result.output)
        self.assertIn(b"GetUnitStatePercent(u, ConvertUnitState(0x51), ConvertUnitState(0x62))",
                      result.output)
        reasons = [skip.reason for skip in result.skips]
        self.assertIn("percent-vanilla", reasons)
        self.assertIn("unknown-state", reasons)

    def test_named_constants(self):
        constants = (b"globals\n"
                     b"    constant unitstate MY_ARMOR = ConvertUnitState(0x20)\n"
                     b"    constant integer MY_ATK = 0x25\n"
                     b"endglobals\n")
        source = (b"function T takes unit u returns real\n"
                  b"    local real a = GetUnitState(u, MY_ARMOR)\n"
                  b"    local real b = GetUnitState(u, MY_ATK)\n"
                  b"    local real c = GetUnitState(u, ConvertUnitState(MY_ATK))\n"
                  b"    return a + b + c\n"
                  b"endfunction\n")
        result = run_migration(source, constants)
        self.assertIn(b"EXGetUnitState(GetHandleId(u), 0x20)", result.output)
        self.assertIn(b"EXGetUnitState(GetHandleId(u), MY_ATK)", result.output)
        self.assertEqual(result.output.count(b"MY_ATK"), 2)

    def test_byte_preservation_bom_crlf_and_gbk(self):
        gbk = "测试".encode("gbk")
        source = (b"\xef\xbb\xbfglobals\r\n"
                  b"endglobals\r\n"
                  b"function T takes unit u returns real\r\n"
                  b"    // " + gbk + b" GetUnitState(u, ConvertUnitState(0x20))\r\n"
                  b"    local string s = \"GetUnitState\\\"(u)\"\r\n"
                  b"    return GetUnitState(u, ConvertUnitState(0x20))\r\n"
                  b"endfunction\r\n")
        result = run_migration(source)
        expected = source.replace(
            b"return GetUnitState(u, ConvertUnitState(0x20))",
            b"return EXGetUnitState(GetHandleId(u), 0x20)")
        self.assertEqual(result.output, expected)
        self.assertTrue(result.output.startswith(b"\xef\xbb\xbf"))
        self.assertIn(gbk, result.output)
        self.assertIn(b"\r\n", result.output)

    def test_idempotent(self):
        source = (b"function T takes unit u returns real\n"
                  b"    return GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"endfunction\n")
        first = run_migration(source)
        second = run_migration(first.output)
        self.assertTrue(first.changed)
        self.assertFalse(second.changed)
        self.assertEqual(second.output, first.output)

    def test_invalid_octal_literal_is_not_rewritten(self):
        source = (b"function T takes unit u returns real\n"
                  b"    return GetUnitState(u, ConvertUnitState(0208))\n"
                  b"endfunction\n")
        result = run_migration(source)
        self.assertFalse(result.changed)
        self.assertEqual(result.output, source)
        self.assertEqual(result.skips[0].reason, "unresolved-state")

    def test_canonicalizes_uppercase_hex(self):
        source = (b"function T takes unit u returns real\n"
                  b"    return GetUnitState(u, ConvertUnitState(0X20))\n"
                  b"endfunction\n")
        result = run_migration(source)
        self.assertIn(b"EXGetUnitState(GetHandleId(u), 0x20)", result.output)
        self.assertNotIn(b"0X20", result.output)

    def test_multiline_or_commented_calls_are_skipped(self):
        source = (b"function T takes unit u returns real\n"
                  b"    local real a = GetUnitState(u,\n"
                  b"        ConvertUnitState(0x20))\n"
                  b"    local real b = GetUnitState /* not jass */ (u, ConvertUnitState(0x20))\n"
                  b"    return a + b\n"
                  b"endfunction\n")
        result = run_migration(source)
        self.assertFalse(result.changed)
        self.assertEqual(result.output, source)
        reasons = [skip.reason for skip in result.skips]
        self.assertIn("multiline-call", reasons)
        # The block-comment form is not a call because only whitespace may
        # separate the callee from '('.
        self.assertEqual(reasons.count("multiline-call"), 1)

    def test_unsafe_call_contexts_are_skipped(self):
        source = (b"globals\n"
                  b"    constant real GLOBAL_VALUE = GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"endglobals\n"
                  b"constant function ConstFn takes unit u returns real\n"
                  b"    return GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"endfunction\n"
                  b"function config takes nothing returns nothing\n"
                  b"    set x = GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"endfunction\n"
                  b"function main takes nothing returns nothing\n"
                  b"    set x = GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"    call initializePlugin()\n"
                  b"    set x = GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"endfunction\n")
        result = run_migration(source)
        reasons = [skip.reason for skip in result.skips]
        self.assertIn("global-initializer", reasons)
        self.assertIn("constant-function", reasons)
        self.assertIn("early-config", reasons)
        self.assertIn("early-main", reasons)
        self.assertEqual(len(result.rewrites), 1)
        self.assertIn(b"call initializePlugin()\n    set x = EXGetUnitState",
                      result.output)

    def test_cli_check_in_place_and_out(self):
        source = (b"function T takes unit u returns real\n"
                  b"    return GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"endfunction\n")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "war3map.j"
            path.write_bytes(source)
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(migrate.main(["--check", str(path)]), 1)
            self.assertEqual(path.read_bytes(), source)

            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(migrate.main(["--in-place", str(path)]), 0)
            migrated = path.read_bytes()
            self.assertIn(b"EXGetUnitState", migrated)

            out_root = root / "out"
            path.write_bytes(source)
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(
                    migrate.main(["--out", str(out_root), str(path)]), 0)
            self.assertIn(b"EXGetUnitState", (out_root / "war3map.j").read_bytes())

    def test_emit_compat_and_duplicate_detection(self):
        source = (b"globals\n"
                  b"    hashtable japi_ht = null\n"
                  b"    integer japi__key = 0\n"
                  b"endglobals\n"
                  b"function T takes unit u returns real\n"
                  b"    return GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"endfunction\n")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "war3map.j"
            path.write_bytes(source)
            compat = root / "compat.j"
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(
                    migrate.main(["--emit-compat", str(compat), str(path)]), 0)
            text = compat.read_text(encoding="utf-8")
            self.assertIn("function EXGetUnitState takes integer arg1, integer arg2 returns real", text)
            self.assertIn("function EXSetUnitState takes integer arg1, integer arg2, real arg3 returns nothing", text)
            self.assertIn("function YDWEGetUnitState takes unit whichUnit", text)
            self.assertIn("function YDWESetUnitState takes unit whichUnit", text)
            self.assertIn("function YDWEGetUnitStatePercent takes unit whichUnit", text)

            defined = source + b"\nfunction EXGetUnitState takes integer a, integer b returns real\n    return 0.0\nendfunction\n"
            path.write_bytes(defined)
            compat2 = root / "compat2.j"
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(
                    migrate.main(["--emit-compat", str(compat2), str(path)]), 0)
            text2 = compat2.read_text(encoding="utf-8")
            self.assertNotIn("function EXGetUnitState takes", text2)
            self.assertIn("function EXSetUnitState takes", text2)

    def test_pjass_compiles_migrated_output_with_compat(self):
        fixture = (b"globals\n"
                   b"    hashtable japi_ht = null\n"
                   b"    integer japi__key = 0\n"
                   b"    constant unitstate MY_ARMOR = ConvertUnitState(0x20)\n"
                   b"    constant integer MY_ATK = 0x25\n"
                   b"endglobals\n"
                   b"\n"
                   b"function Probe takes unit u returns real\n"
                   b"    local real a = GetUnitState(u, ConvertUnitState(0x20))\n"
                   b"    local real b = GetUnitState(u, MY_ARMOR)\n"
                   b"    local real c = GetUnitState(u, MY_ATK)\n"
                   b"    local real d = GetUnitStateSwap(ConvertUnitState(0x51), u)\n"
                   b"    local real e = GetUnitStatePercent(u, ConvertUnitState(0x20), UNIT_STATE_MAX_LIFE)\n"
                   b"    call SetUnitState(u, ConvertUnitState(0x10), 5.0)\n"
                   b"    call SetUnitState(u, UNIT_STATE_MANA, 5.0)\n"
                   b"    return a + b + c + d + e\n"
                   b"endfunction\n"
                   b"\n"
                   b"function RuntimeHelper takes unit u, unitstate s returns real\n"
                   b"    return YDWEGetUnitState(u, s)\n"
                   b"endfunction\n")
        result = run_migration(fixture)
        functions, natives = migrate.collect_definitions(migrate.tokenize(result.output))
        compat = migrate.build_compat_block(functions, natives)
        self.assertIn(b"function EXGetUnitState takes", compat)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "migrated.j"
            path.write_bytes(result.output.replace(
                b"endglobals", b"endglobals\n\n" + compat, 1))
            common = ROOT / "reference" / "YDWE" / "Development" / "Component" / "compiler" / "jass" / "24" / "common.j"
            blizzard = common.with_name("blizzard.j")
            pjass = ROOT / "tools" / "pjass.exe"
            completed = subprocess.run(
                [str(pjass), str(common), str(blizzard), str(path)],
                capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0,
                             completed.stdout + completed.stderr)

            # Without the wrappers pjass must reject the migrated calls.
            path.write_bytes(result.output)
            completed = subprocess.run(
                [str(pjass), str(common), str(blizzard), str(path)],
                capture_output=True, text=True)
            self.assertNotEqual(completed.returncode, 0)

    def test_require_wrappers_accounts_for_percent_helper(self):
        source = (b"function T takes unit u returns real\n"
                  b"    return GetUnitStatePercent(u, ConvertUnitState(0x20), UNIT_STATE_MAX_LIFE)\n"
                  b"endfunction\n")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "war3map.j"
            path.write_bytes(source)
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(
                    migrate.main(["--require-wrappers", str(path)]), 1)
            compat = root / "compat.j"
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(
                    migrate.main(["--emit-compat", str(compat),
                                  "--require-wrappers", str(path)]), 0)
            self.assertIn("YDWEGetUnitStatePercent",
                          compat.read_text(encoding="utf-8"))

    def test_report_json(self):
        source = (b"function T takes unit u returns real\n"
                  b"    local real bad = GetUnitState(u, ConvertUnitState(0x62))\n"
                  b"    return GetUnitState(u, ConvertUnitState(0x20))\n"
                  b"endfunction\n")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "war3map.j"
            path.write_bytes(source)
            report = root / "report.json"
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(
                    migrate.main(["--report-json", str(report), str(path)]), 0)
            document = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(document["files"][0]["path"], str(path))
            self.assertEqual(len(document["files"][0]["rewrites"]), 1)
            self.assertEqual(document["files"][0]["skips"][0]["reason"],
                             "unknown-state")


class StaticConsistencyTests(unittest.TestCase):
    def test_state_table_matches_cpp(self):
        source = (ROOT / "src" / "src" / "extensions" / "ex_natives" /
                  "UnitState.cpp").read_text(encoding="utf-8", errors="replace")
        enum = {name: int(value, 0) for name, value in re.findall(
            r"(UNIT_STATE_[A-Z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)", source)}
        self.assertTrue(enum)
        for state in TABLE.by_value.values():
            self.assertIn(state["name"], enum)
            self.assertEqual(enum[state["name"]], int(state["value"]))

        def body(name):
            match = re.search(
                r"(?:uint32_t|void)\s+__cdecl\s+" + name + r"\s*\(", source)
            self.assertIsNotNone(match, name)
            brace = source.index("{", match.end())
            depth = 0
            for index in range(brace, len(source)):
                if source[index] == "{":
                    depth += 1
                elif source[index] == "}":
                    depth -= 1
                    if depth == 0:
                        return source[brace:index + 1]
            raise AssertionError("unterminated " + name)

        get_body = body("FakeGetUnitState")
        set_body = body("FakeSetUnitState")
        for state in TABLE.by_value.values():
            self.assertIn("case " + state["name"] + ":", get_body)
            self.assertIn("case " + state["name"] + ":", set_body)

        # The only extended states EXSetUnitState accepts but does not write
        # are the four derived attack-damage aggregates.
        noop = {state["name"] for state in TABLE.by_value.values()
                if not state["set"]}
        self.assertEqual(noop, {
            "UNIT_STATE_ATTACK1_DAMAGE_MIN",
            "UNIT_STATE_ATTACK1_DAMAGE_MAX",
            "UNIT_STATE_ATTACK2_DAMAGE_MIN",
            "UNIT_STATE_ATTACK2_DAMAGE_MAX",
        })
        for name in noop:
            self.assertIn("case " + name + ":", set_body)

        # Vanilla states stay out of the migration table.
        self.assertNotIn(1, TABLE.by_value)
        self.assertNotIn(3, TABLE.by_value)
        self.assertEqual(TABLE.vanilla, {0, 1, 2, 3})
        self.assertEqual(set(TABLE.ujapi_only), {4, 5, 6, 7})
        self.assertEqual(len(TABLE.by_value), 47)
        self.assertEqual(sum(1 for state in TABLE.by_value.values() if state["set"]), 43)

    def test_initialize_registrations(self):
        text = (ROOT / "src" / "src" / "extensions" / "ex_natives" /
                "Initialize.cpp").read_text(encoding="utf-8", errors="replace")
        self.assertRegex(text, r'register_cpp_handler\("EXGetUnitState"\s*,\s*"\(II\)R"')
        self.assertRegex(text, r'register_cpp_handler\("EXSetUnitState"\s*,\s*"\(IIR\)V"')
        self.assertRegex(text, r'register_cpp_handler\("EXDclareButtonIcon"\s*,\s*"\(S\)V"')
        self.assertRegex(text, r'register_cpp_handler\("EXBlendButtonIcon"\s*,\s*"\(SSS\)B"')

    def test_lua_table_matches_json(self):
        text = (ROOT / "src" / "src" / "lua_engine" / "lua_engine" /
                "libs_ydwe_lua.h").read_text(encoding="utf-8", errors="replace")
        entries = {int(value, 16): name for value, name in re.findall(
            r"\[0x([0-9A-Fa-f]+)\]\s*=\s*\"([A-Z0-9_]+)\"", text)}
        expected = {int(state["value"]): state["short"]
                    for state in TABLE.by_value.values()}
        self.assertEqual(entries, expected)

    def test_lua_module_registered_and_built(self):
        engine = (ROOT / "src" / "src" / "lua_engine" / "lua_engine" /
                  "open_lua_engine.cpp").read_text(encoding="utf-8", errors="replace")
        self.assertIn('"jass.ydwe"', engine)
        self.assertIn("ydwe::open", engine)
        cmake = (ROOT / "src" / "CMakeLists.txt").read_text(
            encoding="utf-8", errors="replace")
        self.assertIn("libs_ydwe.cpp", cmake)
        self.assertIn("ButtonIcon.cpp", cmake)
        self.assertIn("japi_image", cmake)

    def test_pas_button_copy_matches_ydwe_reference(self):
        reference = (ROOT / "reference" / "YDWE" / "Development" / "Plugin" /
                     "Warcraft3" / "yd_jass_api" / "PasButton.h")
        copied = (ROOT / "src" / "src" / "image" / "pas_button_data.h")
        self.assertEqual(
            migrate_pas_values(reference), migrate_pas_values(copied))

    def test_no_forbidden_mechanisms_in_new_runtime_code(self):
        files = [
            ROOT / "src" / "src" / "extensions" / "ex_natives" / "ButtonIcon.cpp",
            ROOT / "src" / "src" / "image" / "button_icon.cpp",
            ROOT / "src" / "src" / "image" / "blp_codec.cpp",
            ROOT / "src" / "src" / "image" / "wic_decode.cpp",
            ROOT / "src" / "src" / "lua_engine" / "lua_engine" / "libs_ydwe.cpp",
        ]
        forbidden = [
            "SFileLoadFile", "iat(", "VirtualProtect", "japi_add",
            "inline_hook", "get_vfn_ptr", "war3_searcher",
            "handle_to_object", "0x1E4", "0x3BC",
        ]
        for path in files:
            text = path.read_text(encoding="utf-8", errors="replace")
            # Explanatory comments are allowed to name the mechanism that is
            # deliberately not used; only executable code is checked.
            code = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
            code = re.sub(r"//[^\n]*", "", code)
            for needle in forbidden:
                self.assertNotIn(needle, code,
                                 f"{path.name} contains forbidden mechanism {needle}")
        button_icon = files[0].read_text(encoding="utf-8", errors="replace")
        self.assertIn("storm.load_file", button_icon)
        self.assertIn("japi-button-icons", button_icon)


def migrate_pas_values(path: Path) -> list[int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return [int(value, 16) for value in re.findall(r"0x([0-9A-Fa-f]{8})", text)]


if __name__ == "__main__":
    unittest.main(verbosity=2)

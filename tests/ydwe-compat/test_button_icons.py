#!/usr/bin/env python3
"""End-to-end offline tests for src/build/bin/Release/ydwe_button_icon.exe.

The Python side has its own BLP1 writer/reader and YDWE formula, so the
compiled C++ module is checked from the outside. No War3, MPQ, DLL injection,
pack or deploy step is involved.

Run from the repository root after src\\build.bat:
    python -B tests/ydwe-compat/test_button_icons.py
"""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import blp_fixture

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "src" / "build" / "bin" / "Release" / "ydwe_button_icon.exe"
PAS_REFERENCE = (ROOT / "reference" / "YDWE" / "Development" / "Plugin" /
                 "Warcraft3" / "yd_jass_api" / "PasButton.h")
MAP_PREVIEW = ROOT / "reference" / "empty-map" / "war3mapMap.blp"


def run_cli(*arguments: str | Path) -> subprocess.CompletedProcess:
    command = [str(CLI)] + [str(argument) for argument in arguments]
    return subprocess.run(command, capture_output=True, text=True)


class IconToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CLI.exists():
            raise unittest.SkipTest(
                f"{CLI} is missing; run src\\build.bat first")
        cls.pas = blp_fixture.pas_button_values(PAS_REFERENCE)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.a = self.root / "BTNFixtureA.blp"
        self.b = self.root / "BTNFixtureB.blp"
        blp_fixture.write_blp1_palette(
            self.a, 64, 64, blp_fixture.make_low_color_pattern(0))
        blp_fixture.write_blp1_palette(
            self.b, 64, 64, blp_fixture.make_low_color_pattern(1))

    def tearDown(self):
        self.temp.cleanup()

    def test_probe_existing_blp1_jpeg(self):
        completed = run_cli("probe", MAP_PREVIEW)
        self.assertEqual(completed.returncode, 0,
                         completed.stdout + completed.stderr)
        self.assertEqual(completed.stdout.strip(), "OK 256x256")

    def test_probe_rejects_non_blp(self):
        junk = self.root / "junk.bin"
        junk.write_bytes(b"not a blp")
        completed = run_cli("probe", junk)
        self.assertNotEqual(completed.returncode, 0)

    def test_disable_raw_matches_ydwe_formula_exactly(self):
        raw = self.root / "disabled.raw"
        completed = run_cli("raw-disable", self.a, raw)
        self.assertEqual(completed.returncode, 0,
                         completed.stdout + completed.stderr)
        width, height, actual = blp_fixture.read_raw(raw)
        self.assertEqual((width, height), (64, 64))
        expected = blp_fixture.reference_disabled(
            blp_fixture.make_low_color_pattern(0), self.pas)
        self.assertEqual(actual, expected)

    def test_blend_raw_matches_ydwe_formula_exactly(self):
        raw = self.root / "blended.raw"
        completed = run_cli("raw-blend", self.a, self.b, raw)
        self.assertEqual(completed.returncode, 0,
                         completed.stdout + completed.stderr)
        width, height, actual = blp_fixture.read_raw(raw)
        self.assertEqual((width, height), (64, 64))
        expected = blp_fixture.reference_blend(
            blp_fixture.make_low_color_pattern(0),
            blp_fixture.make_low_color_pattern(1))
        self.assertEqual(actual, expected)

    def test_disable_writes_standard_path_and_listfile(self):
        out_root = self.root / "base-map"
        completed = run_cli("disable", self.a, out_root)
        self.assertEqual(completed.returncode, 0,
                         completed.stdout + completed.stderr)
        target = (out_root / "ReplaceableTextures" / "CommandButtonsDisabled" /
                  "DISBTNFixtureA.blp")
        self.assertTrue(target.is_file())
        _width, _height, actual = blp_fixture.read_blp1_palette(target)
        expected = blp_fixture.reference_disabled(
            blp_fixture.make_low_color_pattern(0), self.pas)
        self.assertEqual([p[3] for p in actual], [p[3] for p in expected])
        max_error = blp_fixture.max_rgb_error(actual, expected)
        self.assertLessEqual(max_error, 40, f"max RGB error {max_error}")
        listfile = (out_root / "(listfile)").read_text(encoding="utf-8")
        self.assertIn(
            "ReplaceableTextures\\CommandButtonsDisabled\\DISBTNFixtureA.blp",
            listfile)
        # A second run must not duplicate the listfile entry.
        completed = run_cli("disable", self.a, out_root)
        self.assertEqual(completed.returncode, 0)
        listfile = (out_root / "(listfile)").read_text(encoding="utf-8")
        self.assertEqual(listfile.count("DISBTNFixtureA.blp"), 1)

    def test_disable_uses_archive_argument_for_output_name(self):
        out_root = self.root / "base-map"
        completed = run_cli(
            "disable", self.a, out_root,
            "ReplaceableTextures/CommandButtons/BTNOther.blp")
        self.assertEqual(completed.returncode, 0,
                         completed.stdout + completed.stderr)
        self.assertTrue(
            (out_root / "ReplaceableTextures" / "CommandButtonsDisabled" /
             "DISBTNOther.blp").is_file())

    def test_blend_writes_archive_relative_file(self):
        out_root = self.root / "base-map"
        completed = run_cli(
            "blend", self.a, self.b,
            out_root / "ReplaceableTextures" / "CommandButtons" / "BTNMerged.blp")
        self.assertEqual(completed.returncode, 0,
                         completed.stdout + completed.stderr)
        target = (out_root / "ReplaceableTextures" / "CommandButtons" /
                  "BTNMerged.blp")
        _width, _height, actual = blp_fixture.read_blp1_palette(target)
        expected = blp_fixture.reference_blend(
            blp_fixture.make_low_color_pattern(0),
            blp_fixture.make_low_color_pattern(1))
        self.assertEqual([p[3] for p in actual], [p[3] for p in expected])
        max_error = blp_fixture.max_rgb_error(actual, expected)
        self.assertLessEqual(max_error, 40, f"max RGB error {max_error}")

    def test_manifest_runs_both_operations(self):
        manifest = self.root / "icons.txt"
        manifest.write_text(
            "# generated fixture\n"
            f"disable {self.a.name}\n"
            "blend BTNFixtureA.blp BTNFixtureB.blp ReplaceableTextures\\CommandButtons\\BTNManifest.blp\n",
            encoding="utf-8")
        out_root = self.root / "base-map"
        completed = run_cli("run", manifest, out_root)
        self.assertEqual(completed.returncode, 0,
                         completed.stdout + completed.stderr)
        self.assertTrue(
            (out_root / "ReplaceableTextures" / "CommandButtonsDisabled" /
             "DISBTNFixtureA.blp").is_file())
        self.assertTrue(
            (out_root / "ReplaceableTextures" / "CommandButtons" /
             "BTNManifest.blp").is_file())

    def test_manifest_rejects_path_traversal(self):
        manifest = self.root / "bad.txt"
        manifest.write_text(
            "blend BTNFixtureA.blp BTNFixtureB.blp ..\\evil.blp\n",
            encoding="utf-8")
        completed = run_cli("run", manifest, self.root / "base-map")
        self.assertNotEqual(completed.returncode, 0)
        self.assertFalse((self.root / "evil.blp").exists())

    def test_non_64x64_is_rejected(self):
        small = self.root / "small.blp"
        blp_fixture.write_blp1_palette(
            small, 64, 64, blp_fixture.make_low_color_pattern(0))
        # Rewrite the header dimensions to 32x32 without changing the body;
        # the tool must reject the size before touching pixels.
        data = bytearray(small.read_bytes())
        data[12:16] = (32).to_bytes(4, "little")
        data[16:20] = (32).to_bytes(4, "little")
        small.write_bytes(bytes(data))
        completed = run_cli("raw-disable", small, self.root / "out.raw")
        self.assertNotEqual(completed.returncode, 0)

    def test_missing_input_fails(self):
        completed = run_cli("disable", self.root / "nope.blp", self.root / "out")
        self.assertNotEqual(completed.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

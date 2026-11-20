"""Independent BLP/pixel helpers for tests/ydwe-compat.

Nothing here imports project C++ code. The BLP1 palette writer/reader and the
YDWE disable/blend formulas are a second implementation used to verify the
compiled module and the offline CLI from the outside.
"""

from __future__ import annotations

import struct
from pathlib import Path
from typing import Iterable, Sequence

BLP1_HEADER = struct.Struct("<4sIIIIII16I16I")
RAW_MAGIC = b"JAPIRAW1"
RAW_HEADER = struct.Struct("<8sII")
PALETTE_OFFSET = BLP1_HEADER.size + 256 * 4


def clamp_channel(value: int) -> int:
    if value > 255:
        return 255
    if value < 0:
        return 0
    return value


def make_pattern(seed: int) -> list[tuple[int, int, int, int]]:
    """Same 64x64 BGRA patterns as src/tests/button_icon_test.cpp."""
    pixels: list[tuple[int, int, int, int]] = []
    for y in range(64):
        for x in range(64):
            if seed == 0:
                pixels.append(((x * 4 + y) & 0xFF,
                               (x * 3 + y * 2) & 0xFF,
                               (x + y * 5) & 0xFF,
                               (x + y) & 0xFF))
            else:
                pixels.append(((x * 7 + y * 3) & 0xFF,
                               (x * 2 + y * 11) & 0xFF,
                               (x * 13 + y * 5) & 0xFF,
                               (x * 4 + y * 6) & 0xFF))
    return pixels


def make_low_color_pattern(seed: int) -> list[tuple[int, int, int, int]]:
    """64x64 with 16 exact RGB colours and an alpha gradient."""
    pixels: list[tuple[int, int, int, int]] = []
    for y in range(64):
        for x in range(64):
            index = (x // 16) + (y // 16) * 4
            if seed == 0:
                color = ((index * 11) & 0xFF, (index * 7) & 0xFF,
                         (index * 3) & 0xFF)
            else:
                color = ((255 - index * 9) & 0xFF, (index * 13) & 0xFF,
                         (index * 5) & 0xFF)
            alpha = (x * 3 + y * 5) & 0xFF
            pixels.append((color[0], color[1], color[2], alpha))
    return pixels


def write_blp1_palette(path: Path, width: int, height: int,
                       pixels: Sequence[tuple[int, int, int, int]]) -> None:
    if width != 64 or height != 64:
        raise ValueError("fixtures are 64x64")
    if len(pixels) != width * height:
        raise ValueError("pixel count does not match dimensions")
    colors: list[tuple[int, int, int]] = []
    index_of: dict[tuple[int, int, int], int] = {}
    indices = bytearray()
    for b, g, r, _a in pixels:
        rgb = (r, g, b)
        if rgb not in index_of:
            if len(colors) >= 256:
                raise ValueError("fixture has more than 256 colours")
            index_of[rgb] = len(colors)
            colors.append(rgb)
        indices.append(index_of[rgb])
    alpha = bytes(pixel[3] for pixel in pixels)

    offsets = [0] * 16
    sizes = [0] * 16
    offsets[0] = PALETTE_OFFSET
    sizes[0] = len(indices) + len(alpha)
    header = BLP1_HEADER.pack(
        b"BLP1", 1, 8, width, height, 5, 0,
        *offsets, *sizes)
    palette = bytearray(256 * 4)
    for i, (r, g, b) in enumerate(colors):
        palette[i * 4 + 0] = b
        palette[i * 4 + 1] = g
        palette[i * 4 + 2] = r
        palette[i * 4 + 3] = 255
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(header) + bytes(palette) + bytes(indices) + alpha)


def read_blp1_palette(path: Path) -> tuple[int, int,
                                          list[tuple[int, int, int, int]]]:
    data = path.read_bytes()
    if len(data) < BLP1_HEADER.size + 1024:
        raise ValueError("BLP file is too short")
    fields = BLP1_HEADER.unpack_from(data, 0)
    magic, compression, alpha_bits, width, height, _ptype, _psub = fields[:7]
    offsets = list(fields[7:23])
    sizes = list(fields[23:39])
    if magic != b"BLP1":
        raise ValueError("not BLP1")
    if compression != 1 or alpha_bits != 8:
        raise ValueError(f"unexpected BLP1 mode: compression={compression} "
                         f"alpha_bits={alpha_bits}")
    if width != 64 or height != 64:
        raise ValueError(f"unexpected fixture dimensions {width}x{height}")
    count = width * height
    if sizes[0] < count * 2:
        raise ValueError("mip 0 is truncated")
    palette = data[BLP1_HEADER.size:BLP1_HEADER.size + 1024]
    mip = data[offsets[0]:offsets[0] + sizes[0]]
    indices = mip[:count]
    alpha = mip[count:count + count]
    pixels: list[tuple[int, int, int, int]] = []
    for i in range(count):
        entry = indices[i] * 4
        pixels.append((palette[entry + 0], palette[entry + 1],
                       palette[entry + 2], alpha[i]))
    return width, height, pixels


def read_raw(path: Path) -> tuple[int, int,
                                  list[tuple[int, int, int, int]]]:
    data = path.read_bytes()
    if len(data) < RAW_HEADER.size:
        raise ValueError("raw dump is too short")
    magic, width, height = RAW_HEADER.unpack_from(data, 0)
    if magic != RAW_MAGIC:
        raise ValueError("not a JAPIRAW1 dump")
    count = width * height
    body = data[RAW_HEADER.size:]
    if len(body) != count * 4:
        raise ValueError("raw dump body length mismatch")
    return width, height, [tuple(body[i * 4:i * 4 + 4]) for i in range(count)]


def pas_button_values(reference_header: Path) -> list[int]:
    import re
    text = reference_header.read_text(encoding="utf-8", errors="replace")
    values = [int(value, 16) for value in re.findall(r"0x([0-9A-Fa-f]{8})", text)]
    if len(values) != 4096:
        raise ValueError(f"expected 4096 PasButton values, got {len(values)}")
    return values


def reference_disabled(pixels: Sequence[tuple[int, int, int, int]],
                       pas: Sequence[int]):
    if len(pixels) != 4096 or len(pas) != 4096:
        raise ValueError("disable requires 64x64 input")
    output: list[tuple[int, int, int, int]] = []
    enable = False
    for (b, g, r, a), overlay in zip(pixels, pas):
        overlay_b = overlay & 0xFF
        overlay_g = (overlay >> 8) & 0xFF
        overlay_r = (overlay >> 16) & 0xFF
        overlay_a = (overlay >> 24) & 0xFF
        out_b = clamp_channel(((255 - overlay_a) * b + overlay_b) // (255 * 2))
        out_g = clamp_channel(((255 - overlay_a) * g + overlay_g) // (255 * 2))
        out_r = clamp_channel(((255 - overlay_a) * r + overlay_r) // (255 * 2))
        out_a = clamp_channel(255 - (255 - overlay_a) * (255 - a) // 255)
        if out_b > 63 or out_g > 63 or out_r > 63:
            enable = True
        output.append((out_b, out_g, out_r, out_a))
    if not enable:
        output = [(clamp_channel(b * 2), clamp_channel(g * 2),
                   clamp_channel(r * 2), a) for b, g, r, a in output]
    return output


def reference_blend(a: Sequence[tuple[int, int, int, int]],
                    b: Sequence[tuple[int, int, int, int]]):
    if len(a) != 4096 or len(b) != 4096:
        raise ValueError("blend requires 64x64 inputs")
    output: list[tuple[int, int, int, int]] = []
    for (ab, ag, ar, aa), (bb, bg, br, ba) in zip(a, b):
        output.append((
            clamp_channel(((255 - aa) * bb + aa * ab) // 255),
            clamp_channel(((255 - aa) * bg + aa * ag) // 255),
            clamp_channel(((255 - aa) * br + aa * ar) // 255),
            clamp_channel(255 - (255 - aa) * (255 - ba) // 255),
        ))
    return output


def max_rgb_error(actual: Iterable[tuple[int, int, int, int]],
                  expected: Iterable[tuple[int, int, int, int]]) -> int:
    worst = 0
    for a, e in zip(actual, expected):
        for channel in range(3):
            worst = max(worst, abs(a[channel] - e[channel]))
    return worst

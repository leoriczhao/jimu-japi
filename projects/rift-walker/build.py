"""Build Rift Walker as a standard Warcraft III TFT map archive."""
from __future__ import annotations

import argparse
from collections import deque
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
from tempfile import TemporaryDirectory

from map_data import make_members

PROJECT = Path(__file__).resolve().parent
REPO = PROJECT.parents[1]
MODULES = ('10-combat.j', '20-encounters.j', '30-game.j')
VENDOR = REPO / 'tools/w3x2lni'
ARCHIVE_TOOL = PROJECT / 'archive.lua'
DEFAULT_OUTPUT = REPO / 'build/RiftWalker.w3x'
EXPECTED_MEMBERS = {
    'war3map.j', 'war3map.w3i', 'war3map.w3e', 'war3map.wpm', 'war3map.shd',
    'war3map.doo', 'war3mapUnits.doo', 'war3map.w3u', 'war3map.w3a', 'war3mapMap.blp',
}
GLOBALS = re.compile(r'^globals\s*$\n(.*?)^endglobals\s*$\n', re.M | re.S)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def game_source() -> tuple[bytes, dict[str, str]]:
    declarations = []
    definitions = []
    hashes = {}
    for name in MODULES:
        path = PROJECT / 'src' / name
        data = path.read_text(encoding='utf-8-sig')
        hashes[name] = digest(data.encode('utf-8'))
        blocks = list(GLOBALS.finditer(data))
        if len(blocks) != 1:
            raise ValueError(f'{name} requires exactly one globals block')
        section = blocks[0]
        declarations.append(section[1].strip('\n'))
        definitions.append((data[:section.start()] + data[section.end():]).strip())
    source = ('globals\n' + '\n'.join(declarations) + '\nendglobals\n\n' +
              '\n\n'.join(definitions) + '\n')
    return source.encode('utf-8'), hashes


def inspect_layout(path_map: bytes) -> None:
    """Check connectivity and clear widths of the actual WPM data shipped."""
    _, _, width, height = struct.unpack_from('<4siii', path_map)
    flags = path_map[16:]
    assert len(flags) == width * height

    def cell(x: int, y: int) -> tuple[int, int]:
        return (x + 6144) // 32, (y + 4096) // 32

    def can_walk(position: tuple[int, int]) -> bool:
        x, y = position
        return 0 <= x < width and 0 <= y < height and not flags[y * width + x] & 2

    hero = cell(-2950, 0)
    visited = {hero}
    queue = deque(visited)
    while queue:
        x, y = queue.popleft()
        for next_cell in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if next_cell not in visited and can_walk(next_cell):
                visited.add(next_cell)
                queue.append(next_cell)
    assert can_walk(hero)
    for x, y in [(-2200, 0), (-1100, 0), (-300, 0), (0, 480), (0, -480),
                 (600, 0), (1100, 0), (2200, 0), (2700, 500)]:
        assert cell(x, y) in visited, (x, y)
    assert not can_walk(cell(0, 0)) and not can_walk(cell(0, 2000))
    for gate_x in (-1100, 1100):
        assert all(can_walk(cell(gate_x, y)) for y in range(-160, 161, 32))
        assert not can_walk(cell(gate_x, 320))


def run(*args: str | Path) -> None:
    subprocess.run([str(arg) for arg in args], cwd=REPO, check=True)


def build(output: Path) -> dict:
    output.parent.mkdir(parents=True, exist_ok=True)
    source, sources = game_source()
    members = make_members()
    members['war3map.j'] = source
    assert set(members) == EXPECTED_MEMBERS
    inspect_layout(members['war3map.wpm'])
    scripts = VENDOR / 'data/enUS-1.27.1/mpq/Scripts'
    lua = VENDOR / 'bin/w3x2lni-lua.exe'
    pjass = REPO / 'tools/pjass-std.exe'
    with TemporaryDirectory(prefix='rift-map-', dir=output.parent) as temp:
        scratch = Path(temp)
        for name, content in members.items():
            (scratch / name).write_bytes(content)
        run(pjass, scripts / 'Common.j', scripts / 'Blizzard.j', scratch / 'war3map.j')
        candidate = scratch / 'RiftWalker.w3x'
        run(lua, '-E', ARCHIVE_TOOL, VENDOR, scratch, candidate, *sorted(members))
        assert candidate.read_bytes().startswith(b'HM3W')
        info = {
            'design': 'V2 / 2026-11-18',
            'runtime': 'Warcraft III: The Frozen Throne 1.27a, native JASS',
            'map': output.name,
            'map_bytes': candidate.stat().st_size,
            'map_sha256': digest(candidate.read_bytes()),
            'members': {name: digest(content) for name, content in sorted(members.items())},
            'jass_modules': sources,
            'as_built_toolchain': {
                'pjass-std.exe': digest(pjass.read_bytes()),
                'stormlib.dll': digest((VENDOR / 'bin/stormlib.dll').read_bytes()),
                'Common.j': digest((scripts / 'Common.j').read_bytes()),
                'Blizzard.j': digest((scripts / 'Blizzard.j').read_bytes()),
            },
        }
        assert info['map_bytes'] <= 20 * 1024 * 1024
        candidate.replace(output)
    return info


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    output = args.out.resolve()
    info = build(output)
    manifest = output.with_suffix('.manifest.json')
    manifest.write_text(json.dumps(info, indent=2) + '\n', encoding='utf-8')
    print(f'Built {output} ({info["map_bytes"]} bytes)')
    print(f'SHA-256 {info["map_sha256"]}')
    print(f'Manifest {manifest}')


if __name__ == '__main__':
    main()

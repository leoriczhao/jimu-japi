# Build-only unit and ability declarations

Place `objects.lua` beside your project's `war3map.lua`. `tools/pack.ps1 -MapDir <project>` discovers it automatically. Projects without it take the existing pipeline. The root declaration is excluded from the runtime module map; do not `require "objects"`. The compiler lives in `tools/object-data`, outside the project source tree, and is never bundled.

```lua
unit {
    id = 'u001', parent = 'hfoo',
    fields = { unam = 'My Footman', uhpm = 725, umvs = 300 },
}
ability {
    id = 'A001', parent = 'AHbz',
    fields = { anam = 'My Blizzard', alev = 2, aher = 0,
        acdn = { 9.0, 5.0 }, amcs = { 30, 50 } },
}
```

Declarations execute at build time in a Lua environment exposing only `unit` and `ability`. Locals, arithmetic and literal tables work. No `require`, filesystem, OS, game natives or Lua standard-library globals are exposed. This is a declaration environment, not a resource-limited sandbox for untrusted programs.

Each declaration requires explicit `id`, `parent` and `fields`. The compiler snapshots the options and level values when `unit(...)` or `ability(...)` is called; reusing a Lua table and mutating it later does not change previously declared objects. IDs are exactly four ASCII letters/digits/underscores, case sensitive. New IDs must be unique across both declaration kinds, must not collide with standard objects of their kind, and must not collide with original/custom records in the affected base-map object file. Repeated declarations fail even when identical. Parents must be standard objects of the correct kind; inheriting from custom objects is not supported.

Supported fields use **raw object editor field IDs**, not LNI/SLK names. The compiler reads the actual shipped `tools/w3x2lni/data/enUS-1.27.1/prebuilt/metadata.ini` and standard-parent indexes under `prebuilt/Custom`. This metadata target is fixed to Warcraft III 1.27.1, independent of w3x2lni's configured UI language. No converter source is embedded or copied.

| Kind | Scalar fields | Level-table fields |
| --- | --- | --- |
| unit | `unam` name (string), `uhpm` max HP (int), `umpi` initial mana (int), `umvs` speed (int), `usca` model scale (real), `uabi` comma-separated ability IDs (string) | none |
| ability | `anam` name (string), `alev` number of levels (int), `aher` hero flag (int), `aite` item flag (int) | `acdn` cooldown (real), `amcs` mana cost (int), `aran` range (real), `aare` area (real), `adur` duration (real), `ahdu` hero duration (real), `atp1` tooltip (string), `aub1` extended tooltip (string) |

Every ability explicitly supplies `alev` in 1..100. Each supplied level table must have exactly that many entries with dense integer keys 1..alev. No automatic scalar repetition, sparse tables or default filling. Scalars reject tables. Integer fields accept only int32; real fields require finite float32-range numbers. Strings reject embedded NUL and are written as UTF-8 bytes. Additional semantic limits (flags being 0/1, valid ability-list members, positive HP, parent-specific mechanics) are the author's responsibility. Omitted fields and mechanics inherit from the standard parent; changing the level count does not synthesize unspecified parent data levels. Ability-specific DataA/DataB fields, aliases and other object kinds are not supported.

The compiler emits real version-2 `war3map.w3u` / `war3map.w3a` files. It appends custom records to existing version-1/2 files while retaining all original and existing custom record bytes, order and header version. Both kinds are validated before output files are opened. Malformed/unsupported existing binary files and unresolved LNI sources for an affected kind fail rather than being replaced. Pack's existing base-map LNI compilation runs first, so its `war3map.w3u.ini` objects are retained. This does not provide transactional recovery from disk-write failures; only pack scratch files are written, never the base map or declarations.

Run offline validation from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/object-data/run.ps1
```

The tests use unique directories under `build/` and clean them in `finally`. They cover deterministic bytes, binary parsing, validation errors, collision rejection, preservation, real w3x2lni binary-to-LNI decoding and pack integration. They require the fetched w3x2lni data/runtime and the existing build DLL for pack integration. They do not start Warcraft III.

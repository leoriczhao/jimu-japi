# 11 — Code-defined unit and multilevel ability

`objects.lua` is a build-only declaration. It adds unit `uO11` (parent `hfoo`, name Code Footman, 725 HP) and ability `AO11` (parent `AHbz`, three levels with cooldown 9/7/5 and mana cost 30/40/50). The runtime script creates the custom unit, adds the ability with `UnitAddAbility`, cycles its levels, checks custom data through `jass.slk`, then removes the unit.

From the repository root:

```powershell
.\tools\pack.ps1 -MapDir examples\11-object-data -WorkDir build\example11-work -OutFile build\example11.w3x -StrictRequires
```

No feature switches are required. The presence of root `objects.lua` opts into compilation; it is excluded from runtime Lua bundling. The example uses the usual default base map and existing DLL. It has no local module dependencies or external assets.

Expected live output: four `[PASS]` lines and `Results: 4 passed, 0 failed, 4 total`. The checks cover custom CreateUnit/name/max life, UnitAddAbility and levels 1–3, SLK unit name/HP/inherited race, and SLK ability parent code/level count/cooldown levels 1 and 3. Verified on 2026-11-18 in Warcraft III 1.27a: `Results: 4 passed, 0 failed, 4 total`. Offline compiler checks passed 21/21, with independent converter decoding, packaging, and existing Hrif byte preservation. This validates object data and level selection; it does not benchmark spell effects or multiplayer behavior.

Run the offline regression with `powershell -NoProfile -ExecutionPolicy Bypass -File tests/object-data/run.ps1`. API support and limits are documented in `tools/object-data/README.md`: only listed raw metadata field IDs are accepted, parents must be standard objects, and every specified level field must provide a dense table matching explicit `alev`.

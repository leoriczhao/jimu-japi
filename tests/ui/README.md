# UI component tests (OFFLINE MOCK)

These tests exercise `map/lib/ui.lua` and the private copy in
`examples/12-ui-components/lib/ui.lua` with a fake `jass.d3d` adapter. They
**do not** start Warcraft III, load the native D3D proxy, render anything, or
send real input.

| File | Kind | Purpose |
| --- | --- | --- |
| `fake_d3d.lua` | mock | Models the documented public surface: Font/Text/Texture lifetime, visible + hit_test + z hit stack, pointer capture, 6 px click rule, hover enter/leave, subscription ownership, resize events, injected allocation/destroy failures. |
| `test_ui.lua` | mock | Layout/padding/spacing, hidden and disabled clicks, hover/pressed colors, zero ARGB/z, idempotent destroy, resize cancellation, reentrant destroy, callback error containment, creation rollback, failed native destroy retry. |
| `run_suite.lua` | runner | Runs `test_ui.lua` against both library copies and fails if they differ byte-for-byte. |
| `run.lua` | mock smoke | Focused nested-layout / input / rollback loop, including adapters that omit `Font:get_height`. |
| `example_contract.lua` | mock replay | Executes the real `examples/12-ui-components/war3map.lua` with fake timers and hit-testing, checks the READY/ENABLED/WAIT_RESIZE/RELAYOUT protocol, timeout behavior, and resource baseline. |
| `run-offline.ps1` | runner | Runs the three Lua scripts with the vendored `w3x2lni-lua.exe`; exits non-zero on failure. |

## Run

From the repository root:

```powershell
.\tests\ui\run-offline.ps1
```

or each script directly:

```powershell
.\tools\w3x2lni\bin\w3x2lni-lua.exe tests/ui/run_suite.lua
.\tools\w3x2lni\bin\w3x2lni-lua.exe tests/ui/run.lua
.\tools\w3x2lni\bin\w3x2lni-lua.exe tests/ui/example_contract.lua
```

A passing offline run ends with lines such as:

```text
OFFLINE MOCK SUITE: 33 passed, 0 failed across 2 library copies; ...
OFFLINE MOCK: 5 passed; no live input or rendering validated
[PASS mock] actual example READY / disabled / enabled / resize / relayout / cleanup protocol
OFFLINE MOCK TOTAL: 3/3 scripts passed; no War3 process or native D3D SDK was started.
```

## What is NOT covered here

- Native D3D rendering, device reset/loss, MPQ asset loading, font rendering.
- Win32 mouse/keyboard delivery, foreground focus, client-to-screen mapping.
- The live example's real click/resize sequence. That is a **game test**:
  pack `examples/12-ui-components` with a D3D-enabled deployment, then use the
  parent-owned Windows driver against the `UI12` markers. See that example's
  README.
- Reentrant destroy inside a real native click callback. The mocked suite covers
  the library logic; the live example cleans up from its own timer after the
  input sequence, so a native dispatcher bug in that path would not be caught by
  the game run described above.

The fake adapter intentionally copies the documented SDK behavior that the
library relies on. It is not a reimplementation of the SDK and cannot prove
native correctness.

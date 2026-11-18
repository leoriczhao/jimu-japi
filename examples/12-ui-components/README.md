# Local pixel UI components

This self-contained example uses its own `lib/ui.lua` copy. It requires the existing D3D proxy and public `jass.d3d` SDK. It does not require a C++ change, map assets, or an external UI framework. The default button texture is the built-in Footman icon; text and state tint are drawn over it.

## API

```lua
local ui = require "lib.ui"
local ctx = assert(ui.new())
local root = assert(ctx:column {
    position = function(w, h) return w - 320, h - 180 end,
    padding = 12, spacing = 8,
})
local row = assert(root:row {spacing = 10})
local button = assert(row:button {
    text = "Click", width = 160, height = 40,
    on_click = function(self, event) self:set_text("Clicked locally") end,
})
button:set_enabled(false)
button:set_hidden(true)
local x, y, width, height = button:get_rect()
assert(ctx:destroy())
assert(ctx:destroy())
```

`ui.new(d3d)` accepts a native adapter for offline tests. `ui.new {d3d=adapter, on_error=function(ctx,message) ... end}` also accepts a local error handler. Contexts and containers expose `row`, `column`, and `button`; buttons cannot contain children. Contexts expose `reflow`, `set_on_error`, `is_destroyed`, and `destroy`.

All coordinates are War3 client pixels from the top-left. Root `x`/`y` are fixed, or `position(window_width, window_height)` can re-anchor a root on resize. Nested children follow their container's padding and spacing. Rows sum child widths and take maximum height; columns sum heights and take maximum width. Containers include padding on both sides. Hidden children occupy no flow space. Explicit container width/height change the reported size; they do not stretch children or clip them.

Buttons default to 160x40 and accept `source`, `z`, `font_size`, `text_padding`, `enabled`, `hidden`, `colors`, `text_colors`, `on_click(button,event)`, and optional `on_blocked_click(button,event)`. Color tables use `normal`, `hover`, `pressed`, and `disabled` ARGB values. Nodes expose `get_rect`, `set_enabled`, `set_hidden`, `set_visible`, `get_state`, `is_destroyed`, and `destroy`; labeled buttons also expose `get_text` and `set_text`. Buttons expose `get_colors` and `get_blocked_clicks` for diagnostics.

Enabled/hidden state inherits from containers. Disabled buttons retain hit-testing and consume input while suppressing `on_click`. Hidden buttons disable native visibility and hit-testing. Pointer capture and click qualification come from the native dispatcher. Click handlers execute locally and may destroy their button or context. Callback errors go to the context's local error handler. Do not perform unsynchronized gameplay changes in these callbacks.

Destroy the context explicitly. It cancels resize and button subscriptions and releases Text, Texture, then Font resources. Destroy is idempotent; a failed native release returns `nil,error` and a later destroy retries remaining handles. Constructor failures roll back partial allocations. The library does not shut down the shared D3D session.

## Live automation contract

Run this directory with the normal map packer and D3D-enabled game deployment. Manifest, driver integration, and live deployment are owned by the parent task. The example self-times out after 90 seconds, so a 120-second external harness is enough. Wait for each marker before sending input.

Each marker is a single machine-readable line:

```text
UI12 READY phase=disabled x=680 y=544 width=200 height=48 client_width=1024 client_height=768
```

The rectangle is in client coordinates. Convert its center to screen coordinates before sending a real left-button down/up pair. Wait for the next marker before each action:

| Marker | Required next action |
| --- | --- |
| `UI12 READY phase=disabled ...` | Click the disabled rectangle once. Its native click observer must fire while the component callback remains suppressed. |
| `UI12 ENABLED phase=enabled ...` | Click the enabled rectangle once. |
| `UI12 WAIT_RESIZE phase=resize ...` | Change the real client size substantially, e.g. by 160x100 pixels. Moving the window alone does not qualify. |
| `UI12 RELAYOUT phase=relayout ...` | Click the newly reported rectangle once. |

The library's resize subscription must move the button before RELAYOUT appears. The example prints one summary only after the last click and cleanup, or after an error/timeout:

```text
UI12 CLEANUP fonts=0/0 texts=0/0 textures=0/0 subscriptions=0/0
 Results: 3 passed, 0 failed, 3 total
```

`UI12 CLEANUP` reports `current/baseline` native counts. The three checks are: the disabled click was observed natively but did not invoke the component callback; both enabled clicks arrived around a real client resize and the button moved; and explicit idempotent cleanup returned fonts/texts/textures/subscriptions to the pre-creation baseline. The example self-times out after 1800 timer ticks of 0.05 seconds (90 s). A no-input timeout reports failures and still checks cleanup. The shared asset byte cache is outside this component's resource ownership.

## Verified live result — earlier revision (2026-11-18)

`tools/verify-examples.ps1 -Filter '11|12' -Live -Timeout 160` completed with exit 0. This example reported `Results: 3 passed, 0 failed, 3 total`: disabled input suppressed the component callback, two enabled clicks were separated by a real window resize, and fonts/texts/textures/subscriptions returned to their initial counts after destruction. The driver used real Win32 pointer down/up events and resized the actual HWND; it did not invoke Lua callbacks directly.

Logs: `build/verify-examples/12-ui-components.log` and `12-ui-components-input.log`. Full D3D device-loss and multiplayer tests were not repeated for this component library.

> **Current revision: offline mock only.** The live record above predates the changes that added the `UI12 CLEANUP` diagnostic, the 90 s self-timeout, and the library's option-validation/destroy-retry hardening. The marker protocol and the three checks are unchanged, but the current revision has not been re-run in the game; treat it as mocked-verified until the parent re-runs `verify-examples.ps1 -Filter '12' -Live`.

## Offline verification

From the repository root:

```powershell
.\tests\ui\run-offline.ps1
```

This runs three mocked scripts and starts no Warcraft III process:

- `tests/ui/run_suite.lua` runs `tests/ui/test_ui.lua` against both `map/lib/ui.lua` and this example's copy, then checks the copies are byte-identical.
- `tests/ui/run.lua` is a focused mock smoke test with a simpler adapter (including one that omits `Font:get_height`).
- `tests/ui/example_contract.lua` executes this actual example with fake timers and hit-testing, checks the READY/ENABLED/WAIT_RESIZE/RELAYOUT protocol and the timeout path.

`tests/ui/fake_d3d.lua` models the documented public resource/event surface for those replays. These are **OFFLINE MOCK** tests: they do not prove rendering, Win32 input, device reset, or multiplayer synchronization. The live example contains no fake-input path. Layouts are fixed-size flows without wrapping, clipping, scrolling, text measurement, or keyboard focus.

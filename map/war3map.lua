-- ============================================================
-- japi game entry point (war3map.lua)
-- Edit this file to write your game logic.
--
-- NOTE: tools/pack.ps1 inlines require "module" calls, and its pattern only
-- matches a require that starts at column 0. Keep every require at the top
-- level of this file, unindented.
-- ============================================================

-- Built-in C modules (registered by japi.dll)
local jass    = require "jass.common"
local message = require "jass.message"
local runtime = require "jass.runtime"
local japi    = require "jass.japi"
local hook    = require "jass.hook"
local util    = require "lib.util"
local scene   = require "lib.scene"
local demo    = require "game.demo"
local bridge_preflight = require "tests.bridge_preflight"
local test_mod = require "tests.test_suite"

-- Packed with -Demo, the map runs the playable vertical slice instead of the
-- regression suite. Both modes share the scene, debugger and entry timing.
local demo_mode = _G.__JAPI_DEMO == true

-- Establish a deterministic empty scene after JASS main() has completed:
-- flat map, no melee base, and exactly one rifleman.
local scene_timer = jass.CreateTimer()
jass.TimerStart(scene_timer, 0.0, false, function()
    jass.DestroyTimer(scene_timer)
    local ok, err = pcall(scene.reset)
    if not ok then
        print("[japi-lua] scene initialization failed: " .. tostring(err))
    end
end)

-- Start the DAP debugger via runtime config (VS Code: attach to 127.0.0.1:4278).
-- Requires the map packed with -WithDebugger; failure is non-fatal.
local debugger = require "jass.debugger"
local dbg_port = nil
for _, p in ipairs({4278, 4279, 4280}) do
    runtime.debugger = p
    if debugger.connected() then
        dbg_port = p
        break
    end
end

if dbg_port then
    print("[japi-lua] debugger listening on 127.0.0.1:" .. dbg_port)
else
    print("[japi-lua] debugger not started")
end

if demo_mode then
    -- Playable slice: hero + skill + input + HUD, self-verified at the end.
    demo.run()
else
    -- Run the JASS<->Lua bridge preflight before the synchronous suite:
    -- real UnitId callbacks, error routing, and a JASS-timer sleep/resume.
    -- runtime.sleep is enabled while the preflight owns its timers. The suite is
    -- started by a separate fixed timer, so a hung sleep path still reports a
    -- failure instead of suppressing Results entirely.
    local preflight_ok, preflight_err = pcall(bridge_preflight.start)
    if not preflight_ok then
        runtime.sleep = false
        print("[japi-lua] bridge preflight failed to start: " .. tostring(preflight_err))
    end

    -- When the debugger is listening, delay the suite so there is time to
    -- attach and set breakpoints (dev mode). Without debugger: run at once.
    -- NOTE: 1.0s (not 0.01s) — the Local*Order natives need the command-submit
    -- chain (game.dll [base+0xBE4238]+0x28) which is only up a few frames in.
    local suite_start
    local function start_suite()
        runtime.sleep = false
        if suite_start then
            jass.DestroyTimer(suite_start)
            suite_start = nil
        end
        local timer = jass.CreateTimer()
        jass.TimerStart(timer, dbg_port and 40.0 or 1.0, false, test_mod.run)
    end

    suite_start = jass.CreateTimer()
    jass.TimerStart(suite_start, 4.0, false, start_suite)
end

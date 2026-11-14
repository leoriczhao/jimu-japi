-- Reboot regression, phase 1: the map-boot VM.
--
-- tools/pack.ps1 -TestReboot arms a one-shot JASS timer that calls
-- UnitId("SimulateMapBoot") 6s after LoadScript. That handler resets the Lua VM
-- from C++ (lua_close + fresh state) and runs tests.reboot_child in it. This
-- phase therefore only leaves state behind that a correct reset must destroy:
-- a D3D session with live resources + a subscription, and a Lua bridge handler.
--
-- Deliberately no JASS timers here: this VM is closed from outside, and any
-- timer trampoline created here would resume into a dead lua_State.

local jass    = require "jass.common"
local globals = require "jass.globals"
local d3d     = require "jass.d3d"
local japi    = require "jass.japi"

local M = {}

function M.run()
    local status = d3d.status()
    local session = status.session_id
    if not session or session == 0 then
        print("[REBOOT] parent: no D3D session (state=" .. tostring(status.state) .. ")")
        globals.udg_lua_bridge_result = -1
        return
    end

    local font, font_err = d3d.Font.new { face = "Arial", height = 24 }
    local text
    if font then
        text = d3d.Text.new {
            font = font,
            text = "REBOOT PARENT",
            x = 200,
            y = 160,
            color = d3d.rgba(255, 220, 60, 255),
        }
    end
    local subscription = d3d.on("resize", function() end)

    -- jass.japi also appends a native-table entry, which this simulation cannot
    -- remove (a real map change rebuilds the whole JASS VM). Nothing calls that
    -- entry: the child probes the UnitId() dispatch path, which is the one the
    -- reset must clean up.

    -- Must not survive the VM reset: the child calls UnitId("RebootLeakProbe")
    -- and asserts that this closure never runs.
    japi("RebootLeakProbe", "()V", function()
        globals.udg_lua_error_result = 12345
    end)

    -- Parent -> child handoff through the JASS global table (it outlives the VM).
    -- udg_lua_test_value is the one probe global the injected JASS probes do not
    -- overwrite after LoadScript() returns.
    globals.udg_lua_test_value = session

    print(string.format(
        "[REBOOT] parent ready: session=%d font=%s text=%s subscription=%s font_err=%s",
        session, tostring(font ~= nil), tostring(text ~= nil),
        tostring(subscription ~= nil), tostring(font_err)))
end

return M

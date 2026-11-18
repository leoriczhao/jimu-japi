-- Reboot regression, phase 1: the map-boot VM.
--
-- tools/pack.ps1 -TestReboot arms a one-shot JASS timer that calls
-- UnitId("SimulateMapBoot") 6s after LoadScript. That handler resets the Lua VM
-- from C++ (lua_close + fresh state) and runs tests.reboot_child in it. This
-- phase therefore only leaves state behind that a correct reset must destroy:
-- a D3D session with live resources + a subscription, and a Lua bridge handler.
--
-- Only event-owned, initially stopped timers are left behind: VM reset must
-- destroy them before their Lua trampolines are released.

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

    -- FuncBind state must not survive the reset either: label an address through
    -- the bridge so the child can assert the table came back empty.
    local ht, key = globals.japi_ht, globals.japi__key
    jass.SaveStr(ht, key, 0, "(IS)V")
    jass.SaveInteger(ht, key, 1, 0x0012ABD0)
    jass.SaveStr(ht, key, 2, "reboot-should-drop")
    jass.UnitId("func_bind_trigger_name")

    -- Parent -> child handoff through the JASS global table (it outlives the VM).
    -- udg_lua_test_value is the one probe global the injected JASS probes do not
    -- overwrite after LoadScript() returns.
    globals.udg_lua_test_value = session

    -- Leave two event-owned JASS timers for reset_vm_state(true) to destroy.
    -- The synthetic texture id is never rendered; this probes timer ownership.
    local hook = require "jass.hook"
    local event_timers, created = {}, 0
    hook.hook("CreateTimer", function(orig)
        local timer = orig()
        event_timers[jass.GetHandleId(timer)] = true
        created = created + 1
        return timer
    end)
    local event = japi.TextureAddEvent(123456, 65, jass.code(function() end), 0)
    hook.unhook("CreateTimer")
    assert(event > 0 and created == 2, "reboot timer probe was not registered")
    globals.udg_lua_test_array[2] = 0
    globals.udg_lua_test_array[3] = 0
    hook.hook("PauseTimer", function(timer, orig)
        -- D3D polling has its own timer; count only this event's two timers.
        if event_timers[jass.GetHandleId(timer)] then
            globals.udg_lua_test_array[2] = globals.udg_lua_test_array[2] + 1
            -- Re-enter removal while the outer reset is cleaning the same entry.
            globals.udg_lua_test_array[3] = globals.udg_lua_test_array[3] + japi.GetTextureEventCount()
            japi.TextureRemoveEvent(123456, event)
        end
        return orig(timer)
    end)

    print(string.format(
        "[REBOOT] parent ready: session=%d font=%s text=%s subscription=%s font_err=%s",
        session, tostring(font ~= nil), tostring(text ~= nil),
        tostring(subscription ~= nil), tostring(font_err)))
end

return M

-- Reboot regression, phase 2: runs inside the freshly created Lua VM.
--
-- Loaded by the UnitId("SimulateMapBoot") bridge handler right after
-- lua_loader::on_map_boot() closed the previous state, so every value below
-- describes the new VM. The JASS global table survived; Lua state did not.

local jass    = require "jass.common"
local globals = require "jass.globals"
local d3d     = require "jass.d3d"

local passed, failed = 0, 0
local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  [PASS] " .. name)
    else
        failed = failed + 1
        print("  [FAIL] " .. name .. ": " .. tostring(err))
    end
end

print("\n-- reboot (Lua VM reset across a map boot) --")

local old_session = globals.udg_lua_test_value
local array_echo

check("phase 1 ran in the previous VM", function()
    -- Written by the previous VM, read here: the JASS global table outlived it.
    assert(old_session and old_session > 0, "parent session " .. tostring(old_session))
end)

check("the JASS globals channel works in the new VM", function()
    globals.udg_lua_test_value = old_session
    assert(globals.udg_lua_test_value == old_session,
        "scalar read " .. tostring(globals.udg_lua_test_value))
    globals.udg_lua_test_array[1] = 424242
    array_echo = globals.udg_lua_test_array[1]
    assert(array_echo == 424242, "array[1] read back " .. tostring(array_echo))
end)

local status = d3d.status()
check("phase 2 has a live D3D session", function()
    assert(status.available == true, "unavailable: " .. tostring(status.error))
    assert(status.session_id and status.session_id > 0, "session " .. tostring(status.session_id))
end)

check("the D3D session was recreated, not reused", function()
    assert(status.session_id ~= old_session,
        string.format("session %d survived the VM reset", old_session))
end)

check("FuncBind labels were cleared by the map boot", function()
    local jdbg = require "jass.debug"
    assert(jdbg.func_bind_count() == 0,
        "labels survived: " .. tostring(jdbg.func_bind_count()))
    assert(jdbg.save_func_addr() == 0,
        "anchor survived: " .. tostring(jdbg.save_func_addr()))
end)

check("old session resources were released", function()
    local stats = assert(d3d.stats())
    assert(stats.session_id == status.session_id,
        string.format("stats session %d vs %d", stats.session_id, status.session_id))
    assert(stats.fonts == 0, "fonts " .. tostring(stats.fonts))
    assert(stats.texts == 0, "texts " .. tostring(stats.texts))
    assert(stats.textures == 0, "textures " .. tostring(stats.textures))
    assert(stats.subscriptions == 0, "subscriptions " .. tostring(stats.subscriptions))
end)

check("old Lua bridge handlers were dropped", function()
    globals.udg_lua_error_result = 0
    jass.UnitId("RebootLeakProbe")
    assert(globals.udg_lua_error_result == 0,
        "stale Lua handler ran in the new VM (value "
        .. tostring(globals.udg_lua_error_result) .. ")")
end)

check("event timer cleanup tolerates reentrant removal", function()
    assert(globals.udg_lua_test_array[2] == 2,
        "expected 2 event timer pauses, got " .. tostring(globals.udg_lua_test_array[2]))
    assert(globals.udg_lua_test_array[3] == 0,
        "retiring events were still visible during timer cleanup")
    local japi = require "jass.japi"
    assert(japi.GetTextureEventCount() == 0, "old timer event survived the reset")
end)

check("the new VM can create and destroy D3D resources", function()
    local font, font_err = d3d.Font.new { face = "Arial", height = 20 }
    assert(font, font_err)
    local text, text_err = d3d.Text.new { font = font, text = "REBOOT CHILD", x = 40, y = 220 }
    assert(text, text_err)
    local stats = assert(d3d.stats())
    assert(stats.fonts == 1 and stats.texts == 1,
        string.format("fonts=%d texts=%d", stats.fonts, stats.texts))
    assert(text:destroy())
    assert(font:destroy())
    stats = assert(d3d.stats())
    assert(stats.fonts == 0 and stats.texts == 0,
        string.format("after destroy fonts=%d texts=%d", stats.fonts, stats.texts))
end)

check("the new VM receives D3D events again", function()
    local subscription = assert(d3d.on("resize", function() end))
    assert(subscription:is_active(), "subscription is not active")
    local stats = assert(d3d.stats())
    assert(stats.subscriptions == 1, "subscriptions " .. tostring(stats.subscriptions))
    assert(subscription:cancel())
    stats = assert(d3d.stats())
    assert(stats.subscriptions == 0, "subscriptions after cancel " .. tostring(stats.subscriptions))
end)

print(string.format("[REBOOT] old session=%d new session=%d array[1]=%s",
    old_session, status.session_id, tostring(array_echo)))
print(string.format("\nResults: %d passed, %d failed, %d total",
    passed, failed, passed + failed))

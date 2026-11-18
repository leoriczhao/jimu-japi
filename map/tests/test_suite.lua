-- ============================================================
-- japi.dll test suite
-- ============================================================
local jass    = require "jass.common"
local globals = require "jass.globals"
local message = require "jass.message"
local runtime = require "jass.runtime"
local japi    = require "jass.japi"
local hook    = require "jass.hook"
local util    = require "lib.util"
local scene   = require "lib.scene"
local test_ex = require "tests.test_ex"
local test_d3d_sdk = require "tests.test_d3d_sdk"
local test_d3d = require "tests.test_d3d"
local test_d3d_lifecycle = require "tests.test_d3d_lifecycle"

-- Handle-level agnostic helpers (works with integer or userdata)
local function handle_val(h)
    if type(h) == "userdata" then
        local hex = tostring(h):match("0x([0-9A-Fa-f]+)")
        return hex and tonumber(hex, 16) or 0
    end
    return h or 0
end
local function is_handle(h)
    return h ~= nil and h ~= 0 and handle_val(h) ~= 0
end

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1; print(string.format("  [PASS] %s", name))
    else        fail = fail + 1; print(string.format("  [FAIL] %s : %s", name, tostring(err)))
    end
end

local function run()
print("========================================")
print(" japi.dll test suite")
print("========================================")

-- ============================================================
-- 1. jass.common — JASS native calling
-- ============================================================
print("\n-- jass.common --")

test("module loaded", function()
    assert(type(jass) == "table")
    assert(type(jass.call) == "function")
end)

test("GetLocalPlayer returns handle", function()
    local p = jass.GetLocalPlayer()
    assert(is_handle(p), "expected handle, got " .. type(p) .. " = " .. tostring(p))
end)

test("metatable __index vs jass.call", function()
    local p1 = jass.GetLocalPlayer()
    local p2 = jass.call("GetLocalPlayer")
    assert(p1 == p2)
end)

test("DisplayTimedTextToPlayer", function()
    jass.DisplayTimedTextToPlayer(jass.GetLocalPlayer(), 0, 0, 3, "[test] hello")
end)

test("Player(0) returns handle", function()
    local p = jass.Player(0)
    assert(is_handle(p), "expected handle, got " .. type(p))
end)

test("GetLocalPlayer == Player(GetPlayerId(LocalPlayer))", function()
    local lp = jass.GetLocalPlayer()
    local id = jass.GetPlayerId(lp)
    local p  = jass.Player(id)
    assert(handle_val(lp) == handle_val(p),
        string.format("local=%d id=%d player=%d", handle_val(lp), id, handle_val(p)))
end)

test("GetTriggerPlayer returns nil at init", function()
    local tp = jass.GetTriggerPlayer()
    assert(tp == nil or handle_val(tp) == 0)
end)

test("call with string param", function()
    local p = jass.GetLocalPlayer()
    jass.call("DisplayTimedTextToPlayer", p, 0, 0, 3, "str test")
end)

test("call with real param", function()
    local p = jass.GetLocalPlayer()
    jass.call("DisplayTimedTextToPlayer", p, 3.5, 0, 3, "real test")
end)

test("integer return from native", function()
    local id = jass.call("GetPlayerId", jass.GetLocalPlayer())
    assert(type(id) == "number", "expected number, got " .. type(id))
end)

-- ============================================================
-- 2. jass.runtime — runtime configuration
-- ============================================================
print("\n-- jass.runtime --")

test("module loaded", function()
    assert(type(runtime) == "table")
end)

test("version non-empty", function()
    assert(type(runtime.version) == "string" and #runtime.version > 0,
        "version: " .. tostring(runtime.version))
end)

test("defaults", function()
    assert(runtime.sleep       == false)
    assert(runtime.console     == false)
    assert(runtime.catch_crash == true)
    assert(runtime.handle_level == 2)
end)

test("error_handle set/clear", function()
    runtime.error_handle = function(msg) return msg end
    assert(type(runtime.error_handle) == "function")
    runtime.error_handle = nil
    assert(runtime.error_handle == nil)
end)

test("sleep property toggles", function()
    runtime.sleep = true;  assert(runtime.sleep == true)
    runtime.sleep = false; assert(runtime.sleep == false)
end)

test("console property toggles", function()
    runtime.console = true;  assert(runtime.console == true)
    runtime.console = false; assert(runtime.console == false)
end)

test("handle_level property toggles", function()
    local old = runtime.handle_level
    runtime.handle_level = 2; assert(runtime.handle_level == 2)
    runtime.handle_level = 0; assert(runtime.handle_level == 0)
    runtime.handle_level = 2; assert(runtime.handle_level == 2)
    if old then runtime.handle_level = old end
end)

test("catch_crash property toggles", function()
    runtime.catch_crash = false; assert(runtime.catch_crash == false)
    runtime.catch_crash = true;  assert(runtime.catch_crash == true)
end)

-- ============================================================
-- 3. jass.japi — custom native registration
-- ============================================================
print("\n-- jass.japi --")

test("module loaded", function()
    assert(type(japi) == "table")
end)

test("register (II)I and call", function()
    japi("TestAdd", "(II)I", function(a, b) return a + b end)
    assert(japi.TestAdd(10, 32) == 42)
    assert(japi.TestAdd(-5, 5) == 0)
    assert(japi.TestAdd(0x7FFFFFFF, 1) == -0x80000000) -- 32-bit overflow wrap via hashtable
end)

test("register (R)R double", function()
    japi("TestDouble", "(R)R", function(x) return x * 2 end)
    local r = japi.TestDouble(3.5)
    assert(math.abs(r - 7.0) < 0.001, "expected 7.0, got " .. tostring(r))
end)

test("register (I)I with nil arg → 0", function()
    japi("TestNilArg", "(I)I", function(a) return a end)
    local r = japi.TestNilArg(nil)
    assert(r == 0, "nil should map to integer 0 via hashtable, got " .. tostring(r) .. " (" .. type(r) .. ")")
end)

test("register (SS)S concat returns string", function()
    japi("TestStrConcat", "(SS)S", function(a, b) return a .. "_" .. b end)
    local r = japi.TestStrConcat("hello", "world")
    assert(r == "hello_world", "got: " .. tostring(r))
end)


test("re-registration is rejected", function()
    japi("TestReReg", "(II)I", function(a, b) return a + b end)
    local ok, err = pcall(japi, "TestReReg", "(II)I", function(a, b) return a * b end)
    assert(not ok, "re-registration should error, but succeeded")
end)

test("iterate registered natives", function()
    local count = 0
    for _ in pairs(japi) do count = count + 1 end
    assert(count >= 1, "no registered natives found")
end)

-- ============================================================
-- 4. jass.hook — native hooking (via jass.call)
-- Bridge wrappers are JASS functions, not natives. Hook tests
-- use jass.call with natives registered by japi_table_add.
-- ============================================================
print("\n-- jass.hook --")

test("module loaded", function()
    assert(type(hook) == "table")
    assert(type(hook.hook) == "function")
    assert(type(hook.unhook) == "function")
end)

test("hook native TestAdd with multiplier", function()
    -- TestAdd is registered as a JASS native by init_native_registry
    hook.hook("TestAdd", function(a, b, orig)
        return orig(a, b) * 3
    end)
    -- Call via jass.call (uses native dispatch, not bridge wrapper)
    assert(jass.call("TestAdd", 2, 3) == 15, "hook multiply failed")
    hook.unhook("TestAdd")
    assert(jass.call("TestAdd", 2, 3) == 5, "unhook restore failed")
end)

test("hook native blocks original", function()
    hook.hook("TestAdd", function(a, b, orig)
        return 999
    end)
    local r = jass.call("TestAdd", 5, 3)
    assert(r == 999, "hook didn't block: got " .. tostring(r))
    hook.unhook("TestAdd")
    assert(jass.call("TestAdd", 5, 3) == 8, "restore after block failed")
end)

test("hook passes orig correctly", function()
    hook.hook("TestAdd", function(a, b, orig)
        return orig(a, b) + 100
    end)
    assert(jass.call("TestAdd", 2, 3) == 105)
    hook.unhook("TestAdd")
    assert(jass.call("TestAdd", 2, 3) == 5)
end)

test("double hook is error", function()
    hook.hook("TestAdd", function(a, b, orig) return orig(a, b) + 1 end)
    local ok, err = pcall(hook.hook, "TestAdd", function(a, b, o) return o(a, b) end)
    assert(not ok, "double hook should error")
    hook.unhook("TestAdd")
end)

test("hook nonexistent native errors", function()
    local ok, err = pcall(hook.hook, "NonExistentNative_XYZ", function() end)
    assert(not ok, "should error on nonexistent native")
end)

test("hook game native via jass.call", function()
    local lp = jass.GetLocalPlayer()
    local orig_id = jass.call("GetPlayerId", lp)
    hook.hook("GetPlayerId", function(p, orig)
        return orig(p) + 100
    end)
    local hooked_id = jass.call("GetPlayerId", lp)
    assert(hooked_id == orig_id + 100,
        string.format("hook game native: %d != %d + 100", hooked_id, orig_id))
    hook.unhook("GetPlayerId")
    local restored_id = jass.call("GetPlayerId", lp)
    assert(restored_id == orig_id,
        string.format("unhook restore: %d != %d", restored_id, orig_id))
end)

test("hook game native via metatable jass.X()", function()
    local lp = jass.GetLocalPlayer()
    local orig_id = jass.GetPlayerId(lp)
    hook.hook("GetPlayerId", function(p, orig)
        return orig(p) + 42
    end)
    local via_meta = jass.GetPlayerId(lp)
    assert(via_meta == orig_id + 42,
        string.format("metatable hook: %d != %d + 42", via_meta, orig_id))
    hook.unhook("GetPlayerId")
    assert(jass.GetPlayerId(lp) == orig_id)
end)

test("hook re-hook after unhook", function()
    local lp = jass.GetLocalPlayer()
    local orig = jass.call("GetPlayerId", lp)
    hook.hook("GetPlayerId", function(p, o) return o(p) + 1 end)
    assert(jass.call("GetPlayerId", lp) == orig + 1)
    hook.unhook("GetPlayerId")
    hook.hook("GetPlayerId", function(p, o) return o(p) + 10 end)
    assert(jass.call("GetPlayerId", lp) == orig + 10)
    hook.unhook("GetPlayerId")
    assert(jass.call("GetPlayerId", lp) == orig)
end)

-- ============================================================
-- 5. jass.message — input state
-- ============================================================
print("\n-- jass.message --")

test("module loaded", function()
    assert(type(message) == "table")
    assert(type(message.keyboard) == "table")
    assert(type(message.mouse) == "function")
end)

test("keyboard table read/write", function()
    message.keyboard[0x41] = true
    assert(message.keyboard[0x41] == true)
    message.keyboard[0x41] = nil
    assert(message.keyboard[0x41] == nil or message.keyboard[0x41] == false)
end)

test("keyboard mass read/write", function()
    for i = 1, 10 do
        message.keyboard[0x40 + i] = true
    end
    local count = 0
    for k, v in pairs(message.keyboard) do
        if v then count = count + 1 end
    end
    assert(count >= 10, "expected >=10 true keys, got " .. count)
    for i = 1, 10 do message.keyboard[0x40 + i] = nil end
end)

test("mouse returns world coords", function()
    local wx, wy = message.mouse()
    assert(type(wx) == "number" and type(wy) == "number")
end)

test("selection returns nil or a valid handle", function()
    local sel = util.get_selected_unit()
    -- The default handle_level=2 returns userdata for a selected unit.
    assert(sel == nil or is_handle(sel), "invalid selection: " .. tostring(sel))
end)

test("order functions exist and return boolean", function()
    assert(type(message.order_immediate) == "function")
    assert(type(message.order_point) == "function")
    assert(type(message.order_target) == "function")
    local r1 = message.order_immediate(0, 0)
    local r2 = message.order_point(0, 0, 0, 0)
    -- Signature: (order, x, y, target, flags); missing target used to be
    -- hidden by the no-selection early return in the native binding.
    local r3 = message.order_target(0, 0, 0, util.get_selected_unit(), 0)
    assert(type(r1) == "boolean")
    assert(type(r2) == "boolean")
    assert(type(r3) == "boolean")
end)

test("order_enable_debug toggles", function()
    assert(type(message.order_enable_debug) == "function")
    message.order_enable_debug(true)
    message.order_enable_debug(false)
    message.order_enable_debug(1)
    message.order_enable_debug(0)
end)

test("button all slots return types", function()
    for x = 0, 3 do
        for y = 0, 2 do
            local a, o, t = message.button(x, y)
            assert(type(a) == "number" or a == nil)
        end
    end
end)

test("hook set/clear", function()
    message.hook = function(msg) return true end
    assert(type(message.hook) == "function")
    message.hook = nil
    assert(message.hook == nil)
end)

test("hook nil clears and returns nil", function()
    message.hook = function(msg) return false end
    assert(type(message.hook) == "function")
    message.hook = nil
    assert(message.hook == nil)
    message.hook = nil
    assert(message.hook == nil)
end)

test("keyboard survives across accesses", function()
    for k in pairs(message.keyboard) do
        message.keyboard[k] = nil
    end
    message.keyboard[0x20] = true
    local kb1 = message.keyboard
    kb1[0x41] = true
    local kb2 = message.keyboard
    assert(kb2[0x20] == true, "key 0x20 should persist")
    assert(kb2[0x41] == true, "key 0x41 should persist across accesses")
    message.keyboard[0x20] = nil
    message.keyboard[0x41] = nil
end)

test("message.hook function callable with msg table", function()
    message.hook = function(msg)
        assert(type(msg) == "table", "hook should receive table")
        return true
    end
    local h = message.hook
    assert(type(h) == "function")
    local ok, _ = pcall(h, { type = "test", category = "test" })
    assert(ok, "hook function should accept msg table")
    message.hook = nil
end)

-- ============================================================
-- 6. jass.slk — game data tables (skip if module not loaded)
-- ============================================================
print("\n-- jass.slk --")

local slk_ok, slk = pcall(require, "jass.slk")
if slk_ok and type(slk) == "table" then
    test("module loaded", function()
        assert(type(slk) == "table")
    end)

    local slk_tests = {
        { name = "ability",      min_rows = 10, key = "AHbz", field = "code",  want = "AHbz"  },
        { name = "unit",         min_rows = 10, key = "hpea", field = "race",  want = "human" },
        { name = "item",         min_rows = 5,  key = "rat3", field = "class", want = nil     },
        { name = "buff",         min_rows = 5,  key = "Bpsd" },
        { name = "upgrade",      min_rows = 5  },
        { name = "destructable", min_rows = 1  },
        { name = "doodad",       min_rows = 1  },
    }

    for _, t in ipairs(slk_tests) do
        test(string.format("slk.%s lazy-loads", t.name), function()
            local data = slk[t.name]
            assert(type(data) == "table", "not a table")
            local count = 0
            for _ in pairs(data) do count = count + 1 end
            assert(count >= t.min_rows,
                string.format("%s: %d rows < %d", t.name, count, t.min_rows))
            if t.key then
                local row = data[t.key]
                assert(type(row) == "table",
                    string.format("%s[%s] not found", t.name, t.key))
                if t.field and t.want then
                    local v = row[t.field]
                    assert(tostring(v):lower() == t.want:lower(),
                        string.format("%s[%s].%s=%s ≠ %s",
                            t.name, t.key, t.field, tostring(v), t.want))
                end
            end
        end)
    end

    test("slk.ability second access is cached", function()
        local raw = rawget(slk, "ability")
        assert(type(raw) == "table", "cached ability table missing")
        local count = 0
        for _ in pairs(raw) do count = count + 1 end
        assert(count >= 10, "cached ability empty: " .. count)
    end)
else
    print("  [SKIP] jass.slk module not available")
end

-- ============================================================
-- 7. jass.sleep — coroutine sleep (skip if module not loaded)
-- ============================================================
print("\n-- jass.sleep --")

local sleep_ok, sleep_mod = pcall(require, "jass.sleep")
if sleep_ok and type(sleep_mod) == "table" then
    test("module loaded", function()
        assert(type(sleep_mod) == "table")
        assert(type(sleep) == "function", "global sleep not registered")
    end)

    test("sleep errors outside coroutine", function()
        local ok, err = pcall(sleep, 0.1)
        assert(not ok, "sleep should error outside coroutine")
    end)

    test("sleep in coroutine is callable", function()
        local co = coroutine.create(function()
            local t = sleep(0.01)
            return t
        end)
        assert(coroutine.status(co) == "suspended")
    end)

    test("runtime.sleep enable/disable", function()
        runtime.sleep = true;  assert(runtime.sleep == true)
        runtime.sleep = false; assert(runtime.sleep == false)
    end)
else
    print("  [SKIP] jass.sleep module not available")
end

-- ============================================================
-- 8. jass.code trampoline (AbilityId dispatch)
-- ============================================================
print("\n-- jass.code trampoline --")

test("jass.code + TriggerAddAction round-trip", function()
    local fired = false
    local cb = jass.code(function() fired = true end)
    local trig = jass.CreateTrigger()
    jass.TriggerAddAction(trig, cb)
    jass.TriggerExecute(trig)
    jass.DestroyTrigger(trig)
    assert(fired, "callback was not called!")
end)

-- ============================================================
-- 9. JASS <-> Lua bridge preflight
-- The probes themselves run from war3map.j's main() after LoadScript, using
-- UnitId("...") + hashtable slots and a real JASS trigger-action sleep/resume.
-- ============================================================
print("\n-- bridge preflight --")

test("JASS -> Lua UnitId callback", function()
    assert(_G.__JAPI_LUA_CALLBACK1 == 1,
        "LuaCallbackBridge ran " .. tostring(_G.__JAPI_LUA_CALLBACK1) .. " times")
end)

test("JASS -> Lua UnitId args/return", function()
    assert(globals.udg_lua_bridge_result == 42,
        "bridge result " .. tostring(globals.udg_lua_bridge_result))
end)

test("JASS -> Lua bridge handle round-trip", function()
    local expected = jass.GetHandleId(jass.Player(0))
    assert(globals.udg_lua_handle_result == expected,
        string.format("handle expected=%s actual=%s", tostring(expected),
            tostring(globals.udg_lua_handle_result)))
end)

test("JASS -> Lua error goes to runtime.error_handle", function()
    local found = false
    for _, msg in ipairs(_G.__JAPI_ERROR_MESSAGES or {}) do
        if tostring(msg):match("expected bridge probe error") then
            found = true
            break
        end
    end
    assert(found, "error_handle did not receive the bridge probe error")
end)

test("Lua sleep resumes in a JASS trigger action", function()
    local p = _G.__JAPI_PREFLIGHT
    assert(p, "preflight state missing")
    assert(p.done, string.format(
        "preflight did not finish (stage=%s ticks=%s error=%s)",
        tostring(p.stage), tostring(p.ticks), tostring(p.error)))
    assert(p.stage == 2,
        "sleep stage=" .. tostring(p.stage) .. " error=" .. tostring(p.error))
    assert(p.suspended, "watcher never observed the suspended state")
    assert(p.error == nil, tostring(p.error))
end)

test("jass.globals scalar and array writes", function()
    globals.udg_lua_test_value = 12345
    assert(globals.udg_lua_test_value == 12345,
        "scalar read " .. tostring(globals.udg_lua_test_value))

    -- tools/pack.ps1 force-allocates every declared array before LoadScript
    -- (self-assign at index 8191), so writes past index 0 must round-trip even
    -- on arrays no JASS code ever touched.
    globals.udg_lua_test_array[0] = 7
    assert(globals.udg_lua_test_array[0] == 7,
        "array[0] read " .. tostring(globals.udg_lua_test_array[0]))
    globals.udg_lua_test_array[1] = 424242
    assert(globals.udg_lua_test_array[1] == 424242,
        "array[1] read " .. tostring(globals.udg_lua_test_array[1]))
    globals.udg_lua_test_array[8191] = 99
    assert(globals.udg_lua_test_array[8191] == 99,
        "array[8191] read " .. tostring(globals.udg_lua_test_array[8191]))
    assert(#globals.udg_lua_test_array == 8192,
        "array_size " .. tostring(#globals.udg_lua_test_array))

    globals.udg_lua_test_array_untouched[5] = 77
    assert(globals.udg_lua_test_array_untouched[5] == 77,
        "untouched array[5] read " .. tostring(globals.udg_lua_test_array_untouched[5]))
    globals.udg_lua_test_string_array[7] = "japi"
    assert(globals.udg_lua_test_string_array[7] == "japi",
        "string array[7] read " .. tostring(globals.udg_lua_test_string_array[7]))
end)

test("handle_level 0/1/2 round-trip", function()
    local old = runtime.handle_level
    local ok, err = pcall(function()
        runtime.handle_level = 0
        local raw = jass.GetLocalPlayer()
        assert(type(raw) == "number" and raw > 0, "level 0 type " .. type(raw))
        assert(jass.GetPlayerId(raw) == 0, "level 0 GetPlayerId failed")

        runtime.handle_level = 1
        local light = jass.GetLocalPlayer()
        assert(type(light) == "userdata", "level 1 type " .. type(light))
        assert(handle_val(light) > 0, "level 1 handle value is zero")

        runtime.handle_level = 2
        local ud = jass.GetLocalPlayer()
        assert(type(ud) == "userdata" and handle_val(ud) > 0,
            "level 2 handle is invalid")
    end)
    runtime.handle_level = old
    assert(ok, err)
end)

test("userdata handle is collected after GC", function()
    local old = runtime.handle_level
    runtime.handle_level = 2
    -- Keep the only strong reference inside a helper frame so it is gone when
    -- collectgarbage runs; otherwise the caller's stack slot can retain it.
    local function weak_local_player()
        local h = jass.GetLocalPlayer()
        assert(type(h) == "userdata", "level 2 did not return userdata")
        return setmetatable({h}, {__mode = "v"})
    end
    local weak = weak_local_player()
    collectgarbage("collect")
    collectgarbage("collect")
    runtime.handle_level = old
    assert(weak[1] == nil, "handle userdata survived without a strong reference")
end)

-- ============================================================
-- 8d. GetFuncAddr (tools/pack.ps1 -WithGetFuncAddr)
-- The JASS side declares the engine's hidden SetHeroLevels -- registered by
-- game.dll with signature "(C)V", absent from common.j -- before the first
-- function, then builds GetFuncAddr(f) = SetHeroLevels(f) + LoadInteger(ht,
-- key, 0). Our DLL rewrites that native node's func_address at load time, so
-- the call reaches SetHeroLevels_capture and the code index lands in slot 0.
-- The probe timer pushes those integers back through the UnitId bridge into
-- SaveFunc and func_bind_trigger_name, so the whole round trip is JASS-driven.
--
-- This section runs before 8b on purpose: 8b starts with func_bind_clear(),
-- which would drop the label asserted below.
-- ============================================================
do
    if globals.udg_lua_getfunc_ready ~= 1 then
        print("  [SKIP] GetFuncAddr probe not injected (pack/deploy with -WithGetFuncAddr)")
    else
        local jdbg = require "jass.debug"
        local addr  = globals.udg_lua_getfunc_addr
        local addr2 = globals.udg_lua_getfunc_addr2
        local addr3 = globals.udg_lua_getfunc_addr3

        print(string.format("  [8d] GetFuncAddr addr=%s addr2=%s addr3=%s hits=%s",
            tostring(addr), tostring(addr2), tostring(addr3),
            tostring(globals.udg_lua_getfunc_hits)))

        test("GetFuncAddr returns stable non-zero code addresses", function()
            assert(type(addr) == "number" and addr ~= 0, "GetFuncAddr returned 0")
            assert(addr3 == addr, "one function yielded two addresses: " ..
                tostring(addr) .. " vs " .. tostring(addr3))
            assert(addr2 ~= 0 and addr2 ~= addr, "distinct functions collided")
        end)

        test("GetFuncAddr address reaches func_bind_trigger_name", function()
            local label = jdbg.func_bind_lookup(addr)
            assert(label == "jass-getfunc-target",
                "label lookup returned " .. tostring(label))
        end)

        test("GetFuncAddr address reaches SaveFunc", function()
            local anchor = jdbg.save_func_addr()
            assert(anchor == addr2, "SaveFunc anchor is " .. tostring(anchor) ..
                ", expected " .. tostring(addr2))
        end)

        test("GetFuncAddr address runs as a JASS trigger action", function()
            local before = globals.udg_lua_getfunc_hits
            local trig = jass.CreateTrigger()
            jass.TriggerAddAction(trig, addr)
            jass.TriggerExecute(trig)
            jass.DestroyTrigger(trig)
            assert(globals.udg_lua_getfunc_hits == before + 1,
                "action did not run: hits " .. tostring(globals.udg_lua_getfunc_hits))
        end)
    end
end

-- ============================================================
-- 8b. SaveFunc / func_bind_trigger_name (code address -> label)
-- The wire contract is builtin-japi's: SaveFunc stores one anchor address,
-- func_bind_trigger_name(address, label) labels an address, and both travel as
-- integers in hashtable slots (the bridge ABI has no 'C' type).
--
-- Where the addresses come from: jass.code(fn) gives a real code address for a
-- Lua function (its trampoline runs inside the game's VM) and
-- jass.debug.jass_func_address resolves natives by name. A map script *can* also
-- declare an engine native that common.j omits (SetHeroLevels) and take a JASS
-- function's address with it -- that is section 8d, packed with -WithGetFuncAddr.
-- The declaration is only legal when the name already exists in the engine's
-- native table and it precedes the first function; see
-- docs/planning/JASS-NATIVE-DECLARATIONS.md.
-- ============================================================
local jdbg = require "jass.debug"

local function fb_ht()
    local ht, key = globals.japi_ht, globals.japi__key
    assert(ht ~= nil and key ~= nil, "japi hashtable globals not available")
    return ht, key
end

local function save_func_rpc(address)
    local ht, key = fb_ht()
    jass.SaveStr(ht, key, 0, "(I)V")
    jass.SaveInteger(ht, key, 1, address)
    jass.UnitId("SaveFunc")
end

local function bind_label(address, label)
    local ht, key = fb_ht()
    jass.SaveStr(ht, key, 0, "(IS)V")
    jass.SaveInteger(ht, key, 1, address)
    jass.SaveStr(ht, key, 2, label)
    jass.UnitId("func_bind_trigger_name")
end

-- A Lua function turned into a real JASS code value. The label table keys on
-- exactly the address the VM would call for that function.
local trampoline_hits = 0
local action_addr = jass.code(function()
    trampoline_hits = trampoline_hits + 1
    return true
end)

test("jass.debug.jass_func_address resolves native functions", function()
    assert(type(action_addr) == "number" and action_addr ~= 0,
        "jass.code did not return a code address")
    local native_addr = jdbg.jass_func_address("UnitId")
    assert(native_addr ~= 0, "no code address for the native UnitId")
    assert(native_addr ~= action_addr, "native and trampoline share an address")
    assert(jdbg.jass_func_address("NoSuchJassFunction") == 0,
        "unknown name must resolve to 0")
end)

test("jass.code returns a code address the VM executes", function()
    trampoline_hits = 0
    local t = jass.CreateTrigger()
    jass.TriggerAddCondition(t, jass.Condition(action_addr))
    jass.TriggerEvaluate(t)
    jass.DestroyTrigger(t)
    assert(trampoline_hits == 1,
        "trampoline ran " .. tostring(trampoline_hits) .. " times")
end)

test("SaveFunc stores the anchor address sent through the bridge", function()
    jdbg.func_bind_clear()
    save_func_rpc(action_addr)
    assert(jdbg.save_func_addr() == action_addr,
        "anchor mismatch: " .. tostring(jdbg.save_func_addr()))
end)

test("func_bind_trigger_name stores exact UTF-8 labels per address", function()
    local a, b = 0x0012ABCD, 0x0012ABCE
    local utf8_label = "方向键左键崩溃A"
    bind_label(action_addr, "lua-trampoline")
    bind_label(b, "second")
    bind_label(a, utf8_label)
    assert(jdbg.func_bind_count() == 3,
        "count mismatch: " .. tostring(jdbg.func_bind_count()))
    assert(jdbg.func_bind_lookup(action_addr) == "lua-trampoline",
        "address label mismatch: " .. tostring(jdbg.func_bind_lookup(action_addr)))
    assert(jdbg.func_bind_lookup(b) == "second",
        "second label mismatch: " .. tostring(jdbg.func_bind_lookup(b)))
    assert(jdbg.func_bind_lookup(a) == utf8_label,
        "UTF-8 label mismatch: " .. tostring(jdbg.func_bind_lookup(a)))
    -- rebinding the same address replaces the label instead of adding a row
    bind_label(a, "rebound")
    assert(jdbg.func_bind_lookup(a) == "rebound", "rebind did not win")
    assert(jdbg.func_bind_count() == 3, "rebind added or dropped a row")
    assert(jdbg.func_bind_lookup(0) == nil, "address 0 must stay unknown")
    assert(jdbg.func_bind_lookup(0x7FFFFFF0) == nil, "garbage address must stay unknown")
end)

test("func_bind_clear drops every label and the table accepts new ones", function()
    jdbg.func_bind_clear()
    assert(jdbg.func_bind_count() == 0, "table not empty after clear")
    assert(jdbg.func_bind_lookup(action_addr) == nil, "stale label survived the clear")
    bind_label(action_addr, "lua-trampoline")
    assert(jdbg.func_bind_count() == 1, "table did not accept a label after clear")
    assert(jdbg.func_bind_lookup(action_addr) == "lua-trampoline", "restore failed")
end)

test("SaveFunc replaces the anchor and keeps the label table", function()
    local probe = 0x0012ABCF
    save_func_rpc(probe)
    assert(jdbg.save_func_addr() == probe,
        "anchor not replaced: " .. tostring(jdbg.save_func_addr()))
    assert(jdbg.func_bind_lookup(action_addr) == "lua-trampoline",
        "re-anchoring disturbed the label table")
    save_func_rpc(action_addr)
    assert(jdbg.save_func_addr() == action_addr, "anchor not restored")
end)

-- ============================================================
-- 8c. Generated JASS wrappers (tools/gen-jass-wrappers.ps1)
-- A map script cannot declare a native that only exists at runtime -- it is
-- compiled before the plugin registers anything -- so tools/pack.ps1 -WithJassWrappers
-- derives a builtin-style five-step JASS wrapper for every UnitId bridge
-- handler straight from the C++ registries. (Declaring an *engine* native such
-- as SetHeroLevels is legal under narrower rules: see section 8d and
-- docs/planning/JASS-NATIVE-DECLARATIONS.md.)
--
-- The injected probe calls a few generated wrappers from JASS and stores the
-- results in udg_lua_wrapper_*; comparing them against the same handlers
-- invoked through the Lua bridge catches any slot/type marshalling mistake.
-- ============================================================
if globals.udg_lua_wrapper_ready ~= 1 then
    print("  [SKIP] JASS wrappers not injected (pack/deploy with -WithJassWrappers)")
else
    local function wrapper_ht()
        local ht, key = globals.japi_ht, globals.japi__key
        assert(ht ~= nil and key ~= nil, "japi hashtable globals not available")
        return ht, key
    end

    -- Same handler, same hashtable, but driven from Lua instead of JASS.
    local function bridge_call(name, spec, ...)
        local ht, key = wrapper_ht()
        for i, v in ipairs({...}) do
            local t = type(v)
            if t == "number" then
                if math.type(v) == "integer" then jass.SaveInteger(ht, key, i, v)
                else jass.SaveReal(ht, key, i, v) end
            elseif t == "string" then
                jass.SaveStr(ht, key, i, v)
            elseif t == "boolean" then
                jass.SaveBoolean(ht, key, i, v)
            else
                error("unsupported bridge argument type " .. t)
            end
        end
        jass.SaveStr(ht, key, 0, spec)
        jass.UnitId(name)
        local r = spec:match("%)(.+)$")
        if r == "I" then return jass.LoadInteger(ht, key, 0)
        elseif r == "R" then return jass.LoadReal(ht, key, 0)
        elseif r == "S" then return jass.LoadStr(ht, key, 0)
        elseif r == "B" then return jass.LoadBoolean(ht, key, 0) end
    end

    test("generated JASS wrapper returns the bridge integer", function()
        local via_jass = globals.udg_lua_wrapper_int
        local via_lua = bridge_call("GetGameVersion", "()I")
        assert(type(via_jass) == "number" and via_jass > 0,
            "JASS wrapper returned no game version: " .. tostring(via_jass))
        assert(via_jass == via_lua,
            string.format("wrapper %s vs bridge %s", tostring(via_jass), tostring(via_lua)))
    end)

    test("generated JASS wrapper round-trips strings", function()
        local hex = globals.udg_lua_wrapper_hex
        assert(hex == "000000FF", "Hex(255) through the wrapper: " .. tostring(hex))
        assert(hex == bridge_call("Hex", "(I)S", 255), "wrapper and bridge disagree on Hex")
        local plugin = globals.udg_lua_wrapper_text
        assert(type(plugin) == "string" and #plugin > 0,
            "JASS wrapper returned no plugin version: " .. tostring(plugin))
        assert(plugin == bridge_call("GetPluginVersion", "()S"),
            string.format("wrapper %s vs bridge %s", tostring(plugin),
                tostring(bridge_call("GetPluginVersion", "()S"))))
    end)

    test("generated JASS wrappers keep real and boolean types", function()
        -- GetFps is a live frame counter, so sampling it twice (probe time and
        -- test time) cannot be compared. GetLittleMapX/SetLittleMapX are a
        -- deterministic real-valued pair: the probe reads the baseline, nudges
        -- it by 0.01 through the generated real parameter wrapper, reads the
        -- result back through the generated real return wrapper, and restores.
        local base = globals.udg_lua_wrapper_real_base
        local nudged = globals.udg_lua_wrapper_real
        assert(type(base) == "number" and type(nudged) == "number",
            string.format("JASS wrapper returned no real: base=%s nudged=%s",
                tostring(base), tostring(nudged)))
        assert(math.abs(nudged - (base + 0.01)) < 1e-4,
            string.format("SetLittleMapX/GetLittleMapX round trip %s -> %s",
                tostring(base), tostring(nudged)))
        local bridge_x = bridge_call("GetLittleMapX", "()R")
        assert(type(bridge_x) == "number",
            "bridge GetLittleMapX returned " .. type(bridge_x))
        local chat = globals.udg_lua_wrapper_bool
        assert(type(chat) == "boolean", "JASS wrapper returned no boolean: " .. tostring(chat))
        assert(chat == bridge_call("GetChatState", "()B"),
            "wrapper and bridge disagree on GetChatState")
    end)
end

-- ============================================================
-- Summary
local function finish()
    local scene_ok, scene_err = pcall(scene.reset, true)
    if not scene_ok then
        fail = fail + 1
        print("  [FAIL] restore empty rifleman scene : " .. tostring(scene_err))
    end
    print("")
    print("========================================")
    local total = pass + fail
    print(string.format(" Results: %d passed, %d failed, %d total", pass, fail, total))
    print("========================================")

    if fail > 0 then
        print("SOME TESTS FAILED (" .. fail .. "/" .. total .. ")")
    else
        print("ALL TESTS PASSED (" .. total .. "/" .. total .. ")")
        jass.DisplayTimedTextToPlayer(jass.GetLocalPlayer(), 0, 0, 10,
            "[japi.dll] ALL TESTS PASSED " .. total .. "/" .. total)
    end
end

local function run_d3d_then_finish()
    local function run_bridge_fixture()
        if type(test_d3d) == "table" and type(test_d3d.run) == "function" then
            test_d3d.run(function(dp, df)
                pass = pass + dp
                fail = fail + df
                local function shutdown_sdk()
                    if type(test_d3d_sdk.shutdown) == "function" then
                        test_d3d_sdk.shutdown(function(sp, sf)
                            pass = pass + sp
                            fail = fail + sf
                            finish()
                        end)
                    else
                        finish()
                    end
                end
                local function run_lifecycle_then_shutdown()
                    if type(test_d3d_lifecycle) == "table"
                        and type(test_d3d_lifecycle.run) == "function" then
                        test_d3d_lifecycle.run(function(lp, lf)
                            pass = pass + lp
                            fail = fail + lf
                            if type(test_d3d_lifecycle.verify_lifecycle) == "function" then
                                test_d3d_lifecycle.verify_lifecycle(function(vp, vf)
                                    pass = pass + vp
                                    fail = fail + vf
                                    shutdown_sdk()
                                end)
                            else
                                shutdown_sdk()
                            end
                        end)
                    else
                        shutdown_sdk()
                    end
                end
                if type(test_d3d_sdk.verify_events) == "function" then
                    test_d3d_sdk.verify_events(function(ep, ef)
                        pass = pass + ep
                        fail = fail + ef
                        run_lifecycle_then_shutdown()
                    end)
                else
                    shutdown_sdk()
                end
            end)
        else
            finish()
        end
    end
    if type(test_d3d_sdk) == "table" and type(test_d3d_sdk.run) == "function" then
        test_d3d_sdk.run(function(dp, df)
            pass = pass + dp
            fail = fail + df
            run_bridge_fixture()
        end)
    else
        run_bridge_fixture()
    end
end

-- ============================================================
-- 9. EX* natives fixture tests (tests.test_ex)
-- Local-order assertions are asynchronous, so the final Results line is
-- emitted only after their timer-driven verification completes.
-- ============================================================
if type(test_ex) == "table" and type(test_ex.run) == "function" then
    test_ex.run(function(ep, ef)
        pass = pass + ep
        fail = fail + ef
        run_d3d_then_finish()
    end)
else
    run_d3d_then_finish()
end
end  -- run()

return { run = run, get_results = function() return pass, fail end }

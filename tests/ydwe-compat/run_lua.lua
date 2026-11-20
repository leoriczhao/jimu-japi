-- tests/ydwe-compat/run_lua.lua
--
-- Offline tests for jass.ydwe. No War3 process, MPQ, DLL, pack or deploy step.
-- The module source is extracted from the exact raw string that ships inside
-- yd_japi.dll and run against fake jass.common/jass.japi modules.
--
-- Run from the repository root:
--   tools\w3x2lni\bin\w3x2lni-lua.exe tests\ydwe-compat\run_lua.lua

local function repo_root()
    local source = (debug.getinfo(1, "S").source or ""):gsub("\\", "/")
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local root = source:match("^(.*)/tests/ydwe%-compat/run_lua%.lua$")
    if root == nil or root == "" then return "." end
    return root
end

local root = repo_root()

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        error("cannot open " .. path .. ": " .. tostring(err), 0)
    end
    local data = file:read("*a")
    file:close()
    return data
end

local header_path = root .. "/src/src/lua_engine/lua_engine/libs_ydwe_lua.h"
local module_source = read_file(header_path):match(
    'R"JASS_YDWE%((.-)%)JASS_YDWE"')
assert(module_source ~= nil,
    "raw Lua source markers not found in " .. header_path)

local chunk, compile_err = load(module_source, "=jass.ydwe", "t")
assert(chunk ~= nil, "jass.ydwe source does not compile: " .. tostring(compile_err))

local passed, failed = 0, 0

local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  [PASS] " .. name)
    else
        failed = failed + 1
        print("  [FAIL] " .. name .. " : " .. tostring(err))
    end
end

local function expect_error(fragment, fn)
    local ok, err = pcall(fn)
    assert(not ok, "expected an error containing " .. fragment)
    assert(tostring(err):find(fragment, 1, true) ~= nil,
        "error did not contain " .. fragment .. ": " .. tostring(err))
end

-- ---------------------------------------------------------------- fake JASS

local function new_fake()
    local state = { calls = {} }
    local common = {}
    local japi = {}

    function common.GetHandleId(unit)
        state.calls.common_handle_id = (state.calls.common_handle_id or 0) + 1
        return unit.id
    end

    function common.ConvertUnitState(value)
        state.calls.convert = value
        return { converted = value }
    end

    function common.GetUnitState(unit, which)
        state.calls.common_get = { unit = unit, state = which }
        return 11.5
    end

    function common.SetUnitState(unit, which, value)
        state.calls.common_set = { unit = unit, state = which, value = value }
    end

    function japi.EXGetUnitState(handle, value)
        state.calls.japi_get = { handle = handle, state = value }
        return 22.5
    end

    function japi.EXSetUnitState(handle, value, new_value)
        state.calls.japi_set = {
            handle = handle, state = value, value = new_value,
        }
    end

    state.common = common
    state.japi = japi
    return state
end

local function load_module(fake)
    package.loaded["jass.common"] = nil
    package.loaded["jass.japi"] = nil
    package.loaded["jass.ydwe"] = nil
    package.preload["jass.common"] = function() return fake.common end
    package.preload["jass.japi"] = function() return fake.japi end
    return assert(chunk())
end

local unit = { id = 0x123456 }

-- ---------------------------------------------------------------- static checks

print("-- static scope --")

check("engine registers the jass.ydwe preload", function()
    local text = read_file(root .. "/src/src/lua_engine/lua_engine/open_lua_engine.cpp")
    assert(text:find('"jass.ydwe"', 1, true) ~= nil,
        "jass.ydwe is not registered on package.preload")
    assert(text:find("ydwe::open", 1, true) ~= nil,
        "ydwe::open is not referenced")
end)

check("CMake builds libs_ydwe.cpp", function()
    local text = read_file(root .. "/src/CMakeLists.txt")
    assert(text:find("libs_ydwe.cpp", 1, true) ~= nil,
        "libs_ydwe.cpp missing from LUA_ENGINE_SOURCES")
end)

check("libs_ydwe.cpp uses no memory/hook/native-registration path", function()
    local text = read_file(root .. "/src/src/lua_engine/lua_engine/libs_ydwe.cpp")
    for _, needle in ipairs({
        "war3_searcher", "handle_to_object", "VirtualProtect", "InlineHook",
        "japi_add", "register_cpp_handler", "get_vfn_ptr", "0x3BC",
        "warcraft3::jass::call", "SFileLoadFile",
    }) do
        assert(text:find(needle, 1, true) == nil,
            "forbidden mechanism in libs_ydwe.cpp: " .. needle)
    end
end)

check("module source requires only jass.common and jass.japi", function()
    local requires = {}
    for name in module_source:gmatch('require%s+"([^"]+)"') do
        requires[#requires + 1] = name
    end
    table.sort(requires)
    assert(#requires == 2, "expected two requires, got " .. #requires)
    assert(requires[1] == "jass.common", "unexpected require: " .. tostring(requires[1]))
    assert(requires[2] == "jass.japi", "unexpected require: " .. tostring(requires[2]))
end)

check("module source has no hook/native/memory path", function()
    for _, needle in ipairs({
        "japi_add", "SFileLoadFile", "VirtualProtect", "war3_searcher",
        "handle_to_object",
    }) do
        assert(module_source:find(needle, 1, true) == nil,
            "forbidden mechanism in jass.ydwe source: " .. needle)
    end
end)

-- ---------------------------------------------------------------- behaviour

print("-- unit_state behaviour --")

check("module exposes unit_state and native-shaped aliases", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    assert(type(ydwe.unit_state) == "table", "unit_state is " .. type(ydwe.unit_state))
    assert(ydwe.GetUnitState == ydwe.unit_state.get, "GetUnitState alias mismatch")
    assert(ydwe.SetUnitState == ydwe.unit_state.set, "SetUnitState alias mismatch")
    assert(ydwe.IsExtendedUnitState == ydwe.unit_state.is_extended,
        "IsExtendedUnitState alias mismatch")
end)

check("47 extended states and name/value tables agree", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    local count = 0
    for value, name in pairs(ydwe.unit_state.values) do
        count = count + 1
        assert(type(value) == "number", "non-numeric state value")
        assert(type(name) == "string", "non-string state name")
        assert(ydwe.unit_state.names[name] == value,
            "names/values disagree for " .. name)
    end
    assert(count == 47, "expected 47 extended states, got " .. count)
    assert(ydwe.unit_state.values[0x20] == "ARMOR", "ARMOR name mismatch")
    assert(ydwe.unit_state.names.ATTACK1_INTERVAL == 0x25, "interval value mismatch")
    assert(ydwe.unit_state.set_noop[0x14] == true, "0x14 must be a Set no-op")
end)

check("is_extended and name", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    assert(ydwe.unit_state.is_extended(0x20) == true)
    assert(ydwe.unit_state.is_extended(0) == false)
    assert(ydwe.unit_state.is_extended(4) == false)
    assert(ydwe.unit_state.is_extended("ARMOR") == false)
    assert(ydwe.unit_state.name(0x20) == "ARMOR")
    assert(ydwe.unit_state.name(0) == nil)
    assert(ydwe.unit_state.name(0x62) == nil)
end)

check("vanilla get routes to jass.common and preserves ConvertUnitState", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    local value = ydwe.unit_state.get(unit, 0)
    assert(value == 11.5, "unexpected return " .. tostring(value))
    assert(fake.calls.common_get ~= nil, "jass.common.GetUnitState was not called")
    assert(fake.calls.common_get.unit == unit, "unit identity changed")
    assert(fake.calls.common_get.state.converted == 0, "ConvertUnitState argument mismatch")
    assert(fake.calls.japi_get == nil, "extended path was used for a vanilla state")
end)

check("extended get routes to jass.japi with a handle id", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    local value = ydwe.unit_state.get(unit, 0x20)
    assert(value == 22.5, "unexpected return " .. tostring(value))
    assert(fake.calls.japi_get ~= nil, "EXGetUnitState was not called")
    assert(fake.calls.japi_get.handle == unit.id, "handle id mismatch")
    assert(fake.calls.japi_get.state == 0x20, "state mismatch")
    assert(fake.calls.common_get == nil, "vanilla path was used for an extended state")
end)

check("fractional state values are truncated", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    ydwe.unit_state.get(unit, 0x20 + 0.9)
    assert(fake.calls.japi_get.state == 0x20, "state was not floored")
end)

check("vanilla set routes to jass.common and returns nothing", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    local result = ydwe.unit_state.set(unit, 2, 50.0)
    assert(result == nil, "setter returned " .. tostring(result))
    assert(fake.calls.common_set ~= nil, "jass.common.SetUnitState was not called")
    assert(fake.calls.common_set.state.converted == 2, "ConvertUnitState mismatch")
    assert(fake.calls.common_set.value == 50.0, "value mismatch")
    assert(fake.calls.japi_set == nil, "extended setter was used for a vanilla state")
end)

check("extended set routes to jass.japi and returns nothing", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    local result = ydwe.unit_state.set(unit, 0x20, 7.0)
    assert(result == nil, "setter returned " .. tostring(result))
    assert(fake.calls.japi_set ~= nil, "EXSetUnitState was not called")
    assert(fake.calls.japi_set.handle == unit.id, "handle id mismatch")
    assert(fake.calls.japi_set.state == 0x20, "state mismatch")
    assert(fake.calls.japi_set.value == 7.0, "value mismatch")
    assert(fake.calls.common_set == nil, "vanilla setter was used for an extended state")
end)

check("Set no-op states raise instead of pretending success", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    expect_error("does not write", function()
        ydwe.unit_state.set(unit, 0x14, 1.0)
    end)
    expect_error("does not write", function()
        ydwe.unit_state.set(unit, 0x42, 1.0)
    end)
    assert(fake.calls.japi_set == nil, "no-op state reached EXSetUnitState")
end)

check("UjAPI-only and unknown states raise", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    for _, state in ipairs({ 4, 5, 6, 7 }) do
        expect_error("UjAPI-only", function()
            ydwe.unit_state.get(unit, state)
        end)
    end
    expect_error("unknown unit state", function()
        ydwe.unit_state.get(unit, 0x62)
    end)
    expect_error("unknown unit state", function()
        ydwe.unit_state.set(unit, 0x62, 1.0)
    end)
    assert(fake.calls.japi_get == nil and fake.calls.japi_set == nil,
        "unsupported state reached the EX handlers")
end)

check("invalid arguments raise", function()
    local fake = new_fake()
    local ydwe = load_module(fake)
    expect_error("must be a number", function()
        ydwe.unit_state.get(unit, "ARMOR")
    end)
    expect_error("not a finite number", function()
        ydwe.unit_state.get(unit, 0 / 0)
    end)
    expect_error("not a finite number", function()
        ydwe.unit_state.get(unit, math.huge)
    end)
    expect_error("out of range", function()
        ydwe.unit_state.get(unit, -1)
    end)
    expect_error("out of range", function()
        ydwe.unit_state.get(unit, 0x100000000)
    end)
    expect_error("must be a number", function()
        ydwe.unit_state.set(unit, 0x20, "seven")
    end)
end)

check("module does not replace jass.common functions", function()
    local fake = new_fake()
    local before_get = fake.common.GetUnitState
    local before_set = fake.common.SetUnitState
    load_module(fake)
    assert(fake.common.GetUnitState == before_get,
        "jass.common.GetUnitState was replaced")
    assert(fake.common.SetUnitState == before_set,
        "jass.common.SetUnitState was replaced")
end)

-- ---------------------------------------------------------------- summary

print(string.format("jass.ydwe offline: %d passed, %d failed, %d total",
    passed, failed, passed + failed))
if failed ~= 0 then
    os.exit(1)
end

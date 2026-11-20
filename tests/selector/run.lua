-- tests/selector/run.lua
--
-- OFFLINE tests for jass.selector.hero(). No Warcraft III process, MPQ, map
-- loader, pack step or native DLL is involved. The module source is extracted
-- from the exact raw string that ships inside yd_japi.dll, then run against a
-- fake jass.common.
--
-- Run from the repository root:
--   tools\w3x2lni\bin\w3x2lni-lua.exe tests\selector\run.lua
-- or through the wrapper:
--   powershell -NoProfile -ExecutionPolicy Bypass -File tests\selector\run.ps1

local function repo_root()
    local source = (debug.getinfo(1, "S").source or ""):gsub("\\", "/")
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local root = source:match("^(.*)/tests/selector/run%.lua$")
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

local header_path = root .. "/src/src/lua_engine/lua_engine/libs_selector_lua.h"
local module_source = read_file(header_path):match(
    'R"JASS_SELECTOR%((.-)%)JASS_SELECTOR"')
assert(module_source ~= nil,
    "raw Lua source markers not found in " .. header_path)

local chunk, compile_err = load(module_source, "=jass.selector", "t")
assert(chunk ~= nil, "jass.selector source does not compile: " .. tostring(compile_err))

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

local function fourcc(value)
    local a, b, c, d = value:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

-- ---------------------------------------------------------------- fake JASS

-- A deterministic fake of the small jass.common surface hero() uses. Handles
-- are opaque tables, which also proves the module does not care whether the
-- real runtime represents them as integers, light userdata or userdata.
local function new_fake(options)
    options = options or {}
    local state = {
        units = options.units or {},
        fail = options.fail or {},
        calls = {},
        group = nil,
        rect = nil,
        destroyed_groups = 0,
        destroyed_rects = 0,
        enum_filter = nil,
        null_handle = options.null_handle,
        nil_group = options.nil_group == true,
        zero_group = options.zero_group == true,
        nil_rect = options.nil_rect == true,
        zero_rect = options.zero_rect == true,
    }

    local function tick(name)
        state.calls[name] = (state.calls[name] or 0) + 1
        local at = state.fail[name]
        if at == true or (type(at) == "number" and state.calls[name] == at) then
            error("injected " .. name .. " failure", 0)
        end
    end

    local fake = {}

    function fake.CreateGroup()
        tick("CreateGroup")
        if state.nil_group then return nil end
        if state.zero_group then return 0 end
        state.group = { units = {}, destroyed = false }
        return state.group
    end

    function fake.GetWorldBounds()
        tick("GetWorldBounds")
        if state.nil_rect then return nil end
        if state.zero_rect then return 0 end
        state.rect = { destroyed = false }
        return state.rect
    end

    function fake.GroupEnumUnitsInRect(group, rect, filter)
        tick("GroupEnumUnitsInRect")
        assert(group == state.group, "wrong group handle")
        assert(rect == state.rect, "wrong rect handle")
        assert(filter == nil, "filter must stay nil")
        state.enum_filter = filter
        for i = 1, #state.units do
            group.units[i] = state.units[i]
        end
    end

    function fake.FirstOfGroup(group)
        tick("FirstOfGroup")
        assert(group == state.group, "wrong group handle")
        local unit = group.units[1]
        if unit == nil and state.null_handle ~= nil then
            return state.null_handle
        end
        return unit
    end

    function fake.GroupRemoveUnit(group, unit)
        tick("GroupRemoveUnit")
        assert(group == state.group, "wrong group handle")
        assert(group.units[1] == unit, "must remove the current group head")
        table.remove(group.units, 1)
    end

    function fake.GetUnitTypeId(unit)
        tick("GetUnitTypeId")
        return unit.id
    end

    function fake.DestroyGroup(group)
        tick("DestroyGroup")
        assert(group == state.group, "wrong group handle")
        assert(not group.destroyed, "group destroyed twice")
        group.destroyed = true
        state.destroyed_groups = state.destroyed_groups + 1
    end

    function fake.RemoveRect(rect)
        tick("RemoveRect")
        assert(rect == state.rect, "wrong rect handle")
        assert(not rect.destroyed, "rect removed twice")
        rect.destroyed = true
        state.destroyed_rects = state.destroyed_rects + 1
    end

    return fake, state
end

local function load_selector(fake)
    package.loaded["jass.common"] = nil
    package.loaded["jass.selector"] = nil
    package.preload["jass.common"] = function()
        return fake
    end
    return assert(chunk())
end

local function assert_handles_destroyed(state, label)
    assert(state.destroyed_groups == 1,
        label .. ": destroyed_groups=" .. tostring(state.destroyed_groups))
    assert(state.destroyed_rects == 1,
        label .. ": destroyed_rects=" .. tostring(state.destroyed_rects))
end

-- ---------------------------------------------------------------- static checks

print("-- static scope --")

check("engine registers the jass.selector preload", function()
    local text = read_file(root .. "/src/src/lua_engine/lua_engine/open_lua_engine.cpp")
    assert(text:find('"jass.selector"', 1, true) ~= nil,
        "jass.selector is not registered on package.preload")
    assert(text:find("selector::open", 1, true) ~= nil,
        "selector::open is not referenced")
end)

check("CMake builds libs_selector.cpp", function()
    local text = read_file(root .. "/src/CMakeLists.txt")
    assert(text:find("libs_selector.cpp", 1, true) ~= nil,
        "libs_selector.cpp missing from LUA_ENGINE_SOURCES")
end)

check("selector C++ uses no memory/hook/native-registration path", function()
    local text = read_file(root .. "/src/src/lua_engine/lua_engine/libs_selector.cpp")
    for _, needle in ipairs({
        "war3_searcher", "handle_to_object", "VirtualProtect", "InlineHook",
        "japi_add", "register_cpp_handler", "get_vfn_ptr", "0x3BC",
        "warcraft3::jass::call",
    }) do
        assert(text:find(needle, 1, true) == nil,
            "forbidden mechanism in libs_selector.cpp: " .. needle)
    end
end)

check("module source requires only jass.common", function()
    local requires = {}
    for name in module_source:gmatch('require%s+"([^"]+)"') do
        requires[#requires + 1] = name
    end
    assert(#requires == 1, "expected exactly one require, got " .. #requires)
    assert(requires[1] == "jass.common",
        "unexpected require: " .. tostring(requires[1]))
end)

-- ---------------------------------------------------------------- behaviour

print("-- hero() behaviour --")

check("hero() returns a dense array of heroes in enumeration order", function()
    local units = {
        { id = fourcc("Hpal") },  -- hero
        { id = fourcc("hfoo") },  -- non-hero
        { id = fourcc("Hmkg") },  -- hero
        { id = fourcc("h000") },  -- lowercase first byte: not a hero
    }
    local fake, state = new_fake({ units = units })
    local selector = load_selector(fake)

    local heroes = selector.hero()
    assert(type(heroes) == "table", "hero() returned " .. type(heroes))
    assert(#heroes == 2, "expected 2 heroes, got " .. #heroes)
    assert(heroes[1] == units[1], "first hero mismatch")
    assert(heroes[2] == units[3], "second hero mismatch")
    assert(heroes[3] == nil, "hero table has a hole")
    assert(state.enum_filter == nil, "GroupEnumUnitsInRect filter was not nil")
    assert_handles_destroyed(state, "normal")
end)

check("hero() treats uppercase first rawcode byte as a hero (YDWE predicate)", function()
    local units = {
        { id = fourcc("A000") },  -- custom uppercase id, YDWE's isupper() counts it
        { id = fourcc("h000") },  -- custom lowercase id, YDWE excludes it
    }
    local fake, state = new_fake({ units = units })
    local selector = load_selector(fake)

    local heroes = selector.hero()
    assert(#heroes == 1, "expected 1 hero, got " .. #heroes)
    assert(heroes[1] == units[1], "uppercase first byte was not counted")
    assert_handles_destroyed(state, "uppercase")
end)

check("hero() returns an empty dense table when no hero exists", function()
    local fake, state = new_fake({
        units = { { id = fourcc("hfoo") }, { id = fourcc("n000") } },
    })
    local selector = load_selector(fake)

    local heroes = selector.hero()
    assert(type(heroes) == "table")
    assert(#heroes == 0, "expected an empty table, got " .. #heroes)
    assert_handles_destroyed(state, "empty")
end)

check("hero() ignores a non-number GetUnitTypeId", function()
    local units = { { id = nil }, { id = fourcc("Hpal") } }
    local fake, state = new_fake({ units = units })
    local selector = load_selector(fake)

    local heroes = selector.hero()
    assert(#heroes == 1, "expected 1 hero, got " .. #heroes)
    assert(heroes[1] == units[2], "number-id hero mismatch")
    assert_handles_destroyed(state, "non-number id")
end)

check("handle_level 0 empty group (null handle 0) terminates the loop", function()
    local fake, state = new_fake({ units = {}, null_handle = 0 })
    local selector = load_selector(fake)

    local heroes = selector.hero()
    assert(#heroes == 0, "expected an empty table, got " .. #heroes)
    assert_handles_destroyed(state, "null handle")
end)

-- ---------------------------------------------------------------- failure paths

print("-- cleanup on error --")

check("CreateGroup nil is rejected and nothing is cleaned up", function()
    local fake, state = new_fake({ nil_group = true })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail")
    assert(tostring(err):find("CreateGroup", 1, true) ~= nil,
        "error does not mention CreateGroup: " .. tostring(err))
    assert(state.destroyed_groups == 0 and state.destroyed_rects == 0,
        "cleanup ran for handles that were never created")
end)

check("CreateGroup null integer 0 is rejected (handle_level 0)", function()
    local fake, state = new_fake({ zero_group = true })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail")
    assert(tostring(err):find("CreateGroup", 1, true) ~= nil,
        "error does not mention CreateGroup: " .. tostring(err))
    assert(state.destroyed_rects == 0, "rect cleanup ran without a rect")
end)

check("GetWorldBounds nil still destroys the group", function()
    local fake, state = new_fake({ nil_rect = true })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail")
    assert(tostring(err):find("GetWorldBounds", 1, true) ~= nil,
        "error does not mention GetWorldBounds: " .. tostring(err))
    assert(state.destroyed_groups == 1,
        "group was not destroyed: " .. tostring(state.destroyed_groups))
    assert(state.destroyed_rects == 0,
        "rect cleanup ran without a rect")
end)

check("GetWorldBounds null integer 0 is rejected and group cleaned (handle_level 0)", function()
    local fake, state = new_fake({ zero_rect = true })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail")
    assert(tostring(err):find("GetWorldBounds", 1, true) ~= nil,
        "error does not mention GetWorldBounds: " .. tostring(err))
    assert(state.destroyed_groups == 1,
        "group was not destroyed: " .. tostring(state.destroyed_groups))
    assert(state.destroyed_rects == 0,
        "rect cleanup ran without a rect")
end)

check("GroupEnumUnitsInRect error destroys group and rect", function()
    local fake, state = new_fake({
        units = { { id = fourcc("Hpal") } },
        fail = { GroupEnumUnitsInRect = true },
    })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail")
    assert(tostring(err):find("GroupEnumUnitsInRect failure", 1, true) ~= nil,
        "native error was not propagated: " .. tostring(err))
    assert_handles_destroyed(state, "enum error")
end)

check("FirstOfGroup error mid-loop destroys group and rect", function()
    local fake, state = new_fake({
        units = { { id = fourcc("hfoo") }, { id = fourcc("Hpal") } },
        fail = { FirstOfGroup = 2 },
    })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail")
    assert(tostring(err):find("FirstOfGroup failure", 1, true) ~= nil,
        "native error was not propagated: " .. tostring(err))
    assert_handles_destroyed(state, "first-of-group error")
end)

check("GetUnitTypeId error destroys group and rect", function()
    local fake, state = new_fake({
        units = { { id = fourcc("Hpal") } },
        fail = { GetUnitTypeId = true },
    })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail")
    assert(tostring(err):find("GetUnitTypeId failure", 1, true) ~= nil,
        "native error was not propagated: " .. tostring(err))
    assert_handles_destroyed(state, "unit-type-id error")
end)

check("GroupRemoveUnit error destroys group and rect", function()
    local fake, state = new_fake({
        units = { { id = fourcc("Hpal") } },
        fail = { GroupRemoveUnit = true },
    })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail")
    assert(tostring(err):find("GroupRemoveUnit failure", 1, true) ~= nil,
        "native error was not propagated: " .. tostring(err))
    assert_handles_destroyed(state, "group-remove error")
end)

check("cleanup failure after successful enumeration is reported", function()
    local fake, state = new_fake({
        units = { { id = fourcc("Hpal") } },
        fail = { DestroyGroup = true },
    })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail when cleanup fails")
    assert(tostring(err):find("DestroyGroup failure", 1, true) ~= nil,
        "cleanup error was not reported: " .. tostring(err))
    assert(state.destroyed_groups == 0,
        "fake reported a destroy that failed")
    assert(state.destroyed_rects == 1,
        "rect cleanup must still run after group cleanup fails")
end)

check("native error is not masked by a cleanup error", function()
    local fake = new_fake({
        units = { { id = fourcc("Hpal") } },
        fail = {
            GroupEnumUnitsInRect = true,
            DestroyGroup = true,
            RemoveRect = true,
        },
    })
    local selector = load_selector(fake)

    local ok, err = pcall(selector.hero)
    assert(not ok, "hero() must fail")
    local message = tostring(err)
    assert(message:find("GroupEnumUnitsInRect failure", 1, true) ~= nil,
        "original error was lost: " .. message)
    assert(message:find("DestroyGroup failure", 1, true) == nil,
        "cleanup error masked the original error: " .. message)
end)

-- ---------------------------------------------------------------- summary

print(string.format("Selector offline: %d passed, %d failed, %d total",
    passed, failed, passed + failed))
if failed ~= 0 then
    os.exit(1)
end

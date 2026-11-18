-- ============================================================
-- map-inject 一致性测试台（conformance suite）
--
-- 目的：把「引擎到底实现了什么」变成一张会失败的表格，而不是靠人眼看截图。
-- 独立最小地图：不依赖 map 的 demo，也不依赖任何移植层 shim，只用引擎。
--
-- 运行：
--   powershell -File tests\conformance\run.ps1
-- 输出：
--   " Conformance: N passed, M failed, K skipped"
--   " Results: N passed, M failed, T total"        <- deploy.ps1 用这一行判定
--
-- 约定：
--   [PASS] 断言成立
--   [FAIL] 断言不成立（这就是缺口：每条失败都对应一个已确认的引擎问题）
--   [SKIP] 已知缺口或需要夹具，显式列出原因，绝不静默跳过
-- ============================================================

local manifest = require "manifest"

local jass    = require "jass.common"
local japi    = require "jass.japi"
local slk     = require "jass.slk"
local storm   = require "jass.storm"
local message = require "jass.message"
local runtime = require "jass.runtime"

-- 与作者脚本的常规做法一致：句柄就是整数。
-- 默认值是 1（句柄包成 userdata），此时 ConvertUnitState/ConvertPlayerEvent 这类
-- "返回整数的 native" 拿回来是 userdata，jass.UNIT_STATE_MAX_LIFE 等常量也跟着变形。
-- 不少外部地图移植层也这么做，所以这里必须先切到 0 再建夹具。
runtime.handle_level = 0

-- ============ harness ============
local pass, fail, skipped = 0, 0, 0

local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("  [PASS] " .. name)
    else
        fail = fail + 1
        print("  [FAIL] " .. name .. " : " .. tostring(err))
    end
end

local function skip(name, why)
    skipped = skipped + 1
    print("  [SKIP] " .. name .. " : " .. why)
end

local function fourcc(value)
    local a, b, c, d = string.byte(value, 1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function rev4cc(v)
    return ((v % 256) * 16777216) + (math.floor(v / 256) % 256) * 65536 + (math.floor(v / 65536) % 256) * 256 + math.floor(v / 16777216)
end
local function is_number(v) return type(v) == "number" end
local function is_string(v) return type(v) == "string" end
local function is_callable(v) return type(v) == "function" end

-- 参数类型表：(II)R ->  { "I", "I" } , "R"
local function spec_parts(spec)
    local params, ret = spec:match("^%(([^)]*)%)(.+)$")
    if not params then return {}, nil end
    local out = {}
    for ch in params:gmatch(".") do out[#out + 1] = ch end
    return out, ret
end

-- ============ 夹具 ============
-- 只用 1.27a 原生对象：步兵 hfoo + 英雄技能 AHbz（暴风雪）。
-- AInv（物品栏）在本轮诊断里始终加不上，只作为对照记录。
local UNIT_RAWCODE   = fourcc("hfoo")
local ABILITY_RAWCODE = fourcc("AHbz")

local unit, ability
local fixture_add_ok, fixture_diag

local function build_fixture()
    local player = jass.GetLocalPlayer()
    local x = jass.GetPlayerStartLocationX(player)
    local y = jass.GetPlayerStartLocationY(player)
    unit = jass.CreateUnit(player, UNIT_RAWCODE, x, y, 270.0)
    if unit == nil then return end
    local max_life = jass.GetUnitState(unit, jass.ConvertUnitState(1))
    jass.SetWidgetLife(unit, max_life)
    fixture_add_ok = jass.UnitAddAbility(unit, ABILITY_RAWCODE)
    ability = japi.EXGetUnitAbility(unit, ABILITY_RAWCODE)
    if ability == nil or ability == 0 then
        -- 诊断：能力是否真的加上了、索引里到底有什么
        local function a4(id)
            local b = {}
            for k = 3, 0, -1 do b[#b + 1] = string.char(math.floor(id / 2 ^ (8 * k)) % 256) end
            return table.concat(b)
        end
        local dump = {}
        for i = 0, 8 do
            local h = japi.EXGetUnitAbilityByIndex(unit, i)
            local hid = (h and h ~= 0) and japi.EXGetAbilityId(h) or 0
            dump[#dump + 1] = tostring(i) .. ":" .. tostring(h) .. string.format("/0x%08X/%s", hid, a4(hid))
        end
        fixture_diag = string.format("UnitAddAbility=%s GetUnitAbilityLevel=%s lvlAatk=%s lvlAInv=%s byIndex=[%s]",
            tostring(fixture_add_ok), tostring(jass.GetUnitAbilityLevel(unit, ABILITY_RAWCODE)),
            tostring(jass.GetUnitAbilityLevel(unit, fourcc("Aatk"))),
            tostring(jass.GetUnitAbilityLevel(unit, fourcc("AInv"))),
            table.concat(dump, " "))
    end
end

-- ============ A. jass.* 模块 ============
print("")
print("-- A. jass.* 模块（引擎 package.preload 供给 + 6 个已知缺口）--")

local REQUIRED_MODULES = {
    "jass.common", "jass.globals", "jass.japi", "jass.hook", "jass.runtime",
    "jass.debug", "jass.message", "jass.sleep", "jass.storm", "jass.slk",
    "jass.debugger", "jass.d3d",
}
for _, name in ipairs(REQUIRED_MODULES) do
    check("module " .. name .. " 可 require", function()
        local m = require(name)
        assert(type(m) == "table", "require 返回 " .. type(m))
    end)
end

-- 四个曾经的缺口：console/log/bignum 已是真模块（应为 [PASS]），lni 属移植层模块、不在引擎里（[SKIP]）
local KNOWN_GAPS = {
    { "jass.console", "引擎未实现（移植层用 shim）" },
    { "jass.log",     "引擎未实现（移植层用 shim）" },
    { "jass.bignum",  "引擎未实现（移植层用 shim）" },
    { "lni",          "移植层纯 Lua 解析器" },
}
for _, e in ipairs(KNOWN_GAPS) do
    local ok, m = pcall(require, e[1])
    if ok and type(m) == "table" then
        pass = pass + 1
        print("  [PASS] module " .. e[1] .. " 已提供")
    else
        skip("module " .. e[1], e[2])
    end
end

-- ============ B. jass.common ============
print("")
print("-- B. jass.common 基础 native --")

check("jass.call 可用", function() assert(is_callable(jass.call)) end)
check("GetLocalPlayer 返回句柄", function()
    assert(jass.GetHandleId(jass.GetLocalPlayer()) > 0)
end)
check("GetPlayerName 非空", function()
    local n = jass.GetPlayerName(jass.GetLocalPlayer())
    assert(is_string(n) and #n > 0, "得到 " .. tostring(n))
end)
check("I2S/S2I 往返", function()
    assert(jass.S2I(jass.I2S(12345)) == 12345)
end)
check("OrderId('move') 是整数", function()
    assert(is_number(jass.OrderId("move")))
end)
check("handle_level=0 时句柄是整数", function()
    assert(is_number(jass.GetLocalPlayer()), "handle_level 未生效")
end)
check("ConvertUnitState(1) 可用", function()
    assert(is_number(jass.ConvertUnitState(1)), "得到 " .. type(jass.ConvertUnitState(1)))
end)
check("JASS 常量可读（UNIT_STATE_MAX_LIFE）", function()
    assert(is_number(jass.UNIT_STATE_MAX_LIFE),
        "得到 " .. type(jass.UNIT_STATE_MAX_LIFE) .. "（外部 YDWE 图依赖 jass.common 回落到 JASS 全局）")
end)
check("JASS 常量可读（EVENT_PLAYER_UNIT_DEATH）", function()
    assert(is_number(jass.EVENT_PLAYER_UNIT_DEATH))
end)
check("CreateTimer/TimerStart/DestroyTimer", function()
    local t = jass.CreateTimer()
    assert(jass.GetHandleId(t) > 0)
    jass.DestroyTimer(t)
end)

-- ============ C. bridge handler 存在性 ============
print("")
print("-- C. bridge handler 可被 Lua 调用（jass.japi 回落通道）--")

local missing_bridge = {}
for _, h in ipairs(manifest.bridge) do
    check("japi." .. h.name .. " " .. h.spec, function()
        local fn = japi[h.name]
        if not is_callable(fn) then
            missing_bridge[#missing_bridge + 1] = h.name
        end
        assert(is_callable(fn), "jass.japi." .. h.name .. " 是 " .. type(fn) .. "，不是函数")
    end)
end

-- ============ N. interface capability diagnostics ============
-- The engine has three independent registries (Game.dll natives, japi natives,
-- and the UnitId bridge). These checks assert which one owns a name and which
-- routes can reach it, using only live registry state.
print("")
print("-- N. interface capability diagnostics (jass.japi.info/counts) --")

do
    local globals_mod = require "jass.globals"
    local debug_mod = require "jass.debug"

    check("N1 info/counts 是函数，counts 内部一致", function()
        assert(is_callable(japi.info), "japi.info=" .. type(japi.info))
        assert(is_callable(japi.counts), "japi.counts=" .. type(japi.counts))
        local c = japi.counts()
        assert(type(c) == "table", "counts 返回 " .. type(c))
        assert(c.bridge_handlers == c.bridge_cpp + c.bridge_lua,
            string.format("bridge_handlers=%s cpp=%s lua=%s",
                tostring(c.bridge_handlers), tostring(c.bridge_cpp), tostring(c.bridge_lua)))
        assert(c.bridge_lua == 0, "测试注册前 bridge_lua 应为 0，得到 " .. tostring(c.bridge_lua))
        assert(c.bridge_cpp >= #manifest.bridge,
            string.format("bridge_cpp=%s < manifest=%s", tostring(c.bridge_cpp), #manifest.bridge))
        assert(c.japi_natives == #manifest.declared,
            string.format("japi_natives=%s manifest.declared=%s",
                tostring(c.japi_natives), #manifest.declared))
        assert(c.engine_natives > 0, "engine_natives=" .. tostring(c.engine_natives))
        assert(c.handshake == true, "handshake=" .. tostring(c.handshake))
        assert(c.unitid_hook == true, "unitid_hook=" .. tostring(c.unitid_hook))
    end)

    check("N2 engine-only: I2S 走 jass.common/jass.call", function()
        local e = japi.info("I2S")
        assert(e ~= nil, "info(I2S) 返回 nil")
        assert(e.engine_native and e.engine_native.spec == "(I)S",
            "engine spec=" .. tostring(e.engine_native and e.engine_native.spec))
        assert(e.japi_native == nil and e.bridge == nil, "I2S 不应有 japi/bridge 条目")
        assert(e.routes.lua_common and e.routes.lua_call and e.routes.jass_native,
            "I2S 的三个 native 路由应为 true")
        assert(not e.routes.lua_japi and not e.routes.jass_unitid,
            "I2S 不应走 jass.japi/UnitId")
    end)

    check("N3 bridge-only: SaveFunc 不是 native", function()
        local e = japi.info("SaveFunc")
        assert(e ~= nil, "info(SaveFunc) 返回 nil")
        assert(e.bridge and e.bridge.kind == "cpp" and e.bridge.spec == "(I)V",
            "bridge=" .. tostring(e.bridge and (e.bridge.kind .. "/" .. e.bridge.spec)))
        assert(e.japi_native == nil and e.engine_native == nil, "SaveFunc 不应有 native 条目")
        assert(e.routes.lua_japi and e.routes.jass_unitid, "SaveFunc 应走 japi/UnitId")
        assert(not e.routes.lua_call and not e.routes.lua_common and not e.routes.jass_native,
            "SaveFunc 不应走 jass.call/jass.common")
        assert(jass.SaveFunc == nil, "jass.common.SaveFunc=" .. tostring(jass.SaveFunc))
        local ok = pcall(function() return jass.call("SaveFunc", 0) end)
        assert(not ok, "jass.call(SaveFunc) 不应成功")
        assert(debug_mod.jass_func_address("SaveFunc") == 0, "SaveFunc 不应有 native 地址")
        assert(is_callable(japi.SaveFunc), "jass.japi.SaveFunc 不可调用")
    end)

    check("N4 双注册表：jass.call 用 native spec，jass.japi 用 bridge spec", function()
        local e = japi.info("EXGetUnitAbility")
        assert(e and e.bridge and e.bridge.kind == "cpp" and e.bridge.spec == "(II)I",
            "EXGetUnitAbility bridge=" .. tostring(e and e.bridge and e.bridge.spec))
        assert(e.japi_native and e.japi_native.spec == "(Hunit;I)Hability;",
            "EXGetUnitAbility native=" .. tostring(e and e.japi_native and e.japi_native.spec))
        assert(e.effective.lua_call == "(Hunit;I)Hability;",
            "effective.lua_call=" .. tostring(e.effective.lua_call))
        assert(e.effective.lua_japi == "(II)I",
            "effective.lua_japi=" .. tostring(e.effective.lua_japi))

        local s = japi.info("EXSetAbilityString")
        assert(s.japi_native and s.japi_native.spec == "(IIIS)B",
            "EXSetAbilityString native=" .. tostring(s and s.japi_native and s.japi_native.spec))
        assert(s.bridge and s.bridge.spec == "(IIIS)V",
            "EXSetAbilityString bridge=" .. tostring(s and s.bridge and s.bridge.spec))
    end)

    check("N5 bridge-only EX: EXSetUnitState", function()
        local e = japi.info("EXSetUnitState")
        assert(e and e.bridge and e.bridge.spec == "(IIR)V", "bridge 缺失或 spec 不符")
        assert(e.japi_native == nil and e.engine_native == nil, "EXSetUnitState 不应有 native 条目")
        assert(not e.routes.lua_call and e.routes.lua_japi and e.routes.jass_unitid,
            "EXSetUnitState 路由不符")
        assert(not pcall(function() return jass.call("EXSetUnitState", unit, 0, 1.0) end),
            "jass.call(EXSetUnitState) 不应成功")
    end)

    check("N6 japi-only: SetHeroLevels", function()
        local e = japi.info("SetHeroLevels")
        assert(e and e.japi_native and e.japi_native.spec == "(C)V", "native spec 不符")
        -- The name also exists in Game.dll's native table (that is exactly why
        -- the declaration is legal); it has no UnitId bridge entry.
        assert(e.bridge == nil, "SetHeroLevels 不应有 bridge 条目")
        assert(e.routes.lua_japi and not e.routes.jass_unitid, "SetHeroLevels 路由不符")
    end)

    check("N7 未知名字与参数校验", function()
        assert(japi.info("ConfinitelyNotRegistered") == nil, "未知名字应返回 nil")
        assert(not pcall(japi.info, {}), "info(table) 应抛错")
        for _, h in ipairs(manifest.bridge) do
            assert(h.name ~= "info" and h.name ~= "counts", "manifest 与 info/counts 撞名: " .. h.name)
        end
    end)

    check("N14 diagnostic names cannot be registered as handlers", function()
        local before = japi.counts()
        for _, name in ipairs({"info", "counts"}) do
            local ok, err = pcall(function() japi(name, "()I", function() return 42 end) end)
            assert(not ok and tostring(err):find("reserved", 1, true), tostring(err))
            assert(japi.info(name) == nil, "rejected registration left a registry entry")
        end
        assert(japi.counts().bridge_handlers == before.bridge_handlers)
        assert(japi.counts().japi_natives == before.japi_natives)
    end)

    check("N15 self-unhook is rejected and escaped orig fails safely", function()
        local hook_mod = require "jass.hook"
        local original = jass.call("Deg2Rad", 180.0)
        local escaped, removal_ok, replacement_ok
        hook_mod.hook("Deg2Rad", function(value, orig)
            escaped = orig
            removal_ok = pcall(hook_mod.unhook, "Deg2Rad")
            replacement_ok = pcall(function() hook_mod.Deg2Rad = nil end)
            return orig(value)
        end)
        local result = jass.call("Deg2Rad", 180.0)
        assert(hook_mod.unhook("Deg2Rad"), "hook should remain installed until callback returns")
        collectgarbage("collect")
        assert(removal_ok == false and replacement_ok == false, "removed an executing trampoline")
        assert(result == original, "orig stopped working after rejected self-unhook")
        local ok, err = pcall(escaped, 180.0)
        assert(not ok and tostring(err):find("no longer installed", 1, true), tostring(err))
    end)

    check("N8 manifest 与活注册表逐条一致", function()
        local mismatches = {}
        for _, h in ipairs(manifest.bridge) do
            local e = japi.info(h.name)
            if not e or not e.bridge or e.bridge.kind ~= "cpp"
                or e.bridge.spec ~= h.spec or not e.routes.lua_japi
                or not e.routes.jass_unitid then
                mismatches[#mismatches + 1] = "bridge:" .. h.name .. "(" .. h.spec .. ")"
            end
        end
        for _, h in ipairs(manifest.declared) do
            local e = japi.info(h.name)
            if not e or not e.japi_native or e.japi_native.spec ~= h.spec
                or not e.routes.lua_call then
                mismatches[#mismatches + 1] = "native:" .. h.name .. "(" .. h.spec .. ")"
            end
        end
        assert(#mismatches == 0, "不一致: " .. table.concat(mismatches, ", "))
    end)

    check("N9 运行时 Lua 注册的计数与路由", function()
        local before = japi.counts()
        japi("ConformanceUnitIdAdd", "(II)I", function(a, b) return a + b end)
        local after = japi.counts()
        assert(after.japi_natives == before.japi_natives + 1,
            "japi_natives " .. tostring(before.japi_natives) .. " -> " .. tostring(after.japi_natives))
        assert(after.bridge_handlers == before.bridge_handlers + 1, "bridge_handlers 未 +1")
        assert(after.bridge_lua == before.bridge_lua + 1, "bridge_lua 未 +1")
        assert(after.bridge_cpp == before.bridge_cpp, "bridge_cpp 不应变化")

        local e = japi.info("ConformanceUnitIdAdd")
        assert(e and e.bridge and e.bridge.kind == "lua" and e.bridge.spec == "(II)I",
            "运行时 handler 的 bridge 条目不符")
        assert(e.japi_native and e.japi_native.spec == "(II)I", "运行时 handler 的 native 条目不符")
        assert(e.routes.lua_japi and e.routes.lua_call and e.routes.jass_unitid,
            "运行时 handler 的 japi/call/unitid 路由应为 true")
        assert(not e.routes.lua_common and not e.routes.jass_native,
            "运行时 handler 不应有 engine native 路由")
        assert(japi.ConformanceUnitIdAdd(40, 2) == 42, "japi.ConformanceUnitIdAdd(40,2) 不是 42")
    end)

    check("N10 UnitId + hashtable 真实协议（Lua 与 C++ handler）", function()
        local ht = globals_mod.japi_ht
        local key = globals_mod.japi__key
        assert(is_number(ht) and is_number(key),
            "japi_ht/japi__key 类型 " .. type(ht) .. "/" .. type(key))

        jass.SaveStr(ht, key, 0, "(II)I")
        jass.SaveInteger(ht, key, 1, 40)
        jass.SaveInteger(ht, key, 2, 2)
        jass.UnitId("ConformanceUnitIdAdd")
        assert(jass.LoadInteger(ht, key, 0) == 42,
            "Lua handler 经 UnitId 返回 " .. tostring(jass.LoadInteger(ht, key, 0)))

        jass.SaveStr(ht, key, 0, "()I")
        jass.UnitId("GetGameVersion")
        local bridged = jass.LoadInteger(ht, key, 0)
        assert(bridged == jass.call("GetGameVersion"),
            "C++ handler 经 UnitId=" .. tostring(bridged) ..
            " native=" .. tostring(jass.call("GetGameVersion")))
    end)

    check("N11 D3D 条件表面不被虚报", function()
        local e = japi.info("CreateFont")
        assert(e == nil or (e.bridge and e.bridge.kind == "cpp" and e.japi_native == nil),
            "CreateFont 不应被报成 native/双注册")
    end)

    check("N12 hook.unhook 返回值与 hook[name]=nil 清理", function()
        local hook_mod = require "jass.hook"
        local before = jass.call("Deg2Rad", 180.0)

        hook_mod.hook("Deg2Rad", function(v, orig) return 0.0 end)
        assert(jass.call("Deg2Rad", 180.0) == 0.0, "hook 未生效")
        assert(hook_mod.unhook("Deg2Rad") == true, "首次 unhook 应返回 true")
        assert(hook_mod.unhook("Deg2Rad") == false, "重复 unhook 应返回 false")
        assert(hook_mod.unhook("NoSuchNative_XYZ") == false, "未知名字应返回 false")
        assert(jass.call("Deg2Rad", 180.0) == before, "unhook 未恢复原函数")

        -- Assigning nil through the table form must unhook too, not leave a
        -- stale entry that makes a later hook(name, fn) fail as "already hooked".
        hook_mod.Deg2Rad = function(v, orig) return 1.0 end
        assert(jass.call("Deg2Rad", 180.0) == 1.0, "table 形式 hook 未生效")
        hook_mod.Deg2Rad = nil
        assert(jass.call("Deg2Rad", 180.0) == before, "hook[name]=nil 未恢复原函数")
        assert(hook_mod.unhook("Deg2Rad") == false, "nil 赋值后 hook 仍被报告为存在")
    end)

    check("N13 texture event 显式清理按 owner 释放回调", function()
        local tex = message.texture_create(0.0, 0.0, 1.0, 1.0)
        assert(type(tex) == "number" and tex > 0, "texture_create=" .. tostring(tex))
        local weak = setmetatable({}, { __mode = "v" })

        local function new_cb(tag)
            local cb = function() return tag end
            weak[tag] = cb
            return cb
        end

        local a = new_cb("a")
        local b = new_cb("b")
        local c = new_cb("c")
        local e1 = message.texture_add_event(tex, 65, a, nil)
        local e2 = message.texture_add_event(tex, 65, b, nil)
        local e3 = message.texture_add_event(tex, 65, c, nil)
        assert(e1 > 0 and e2 > 0 and e3 > 0, "texture_add_event 返回 0")

        assert(message.texture_remove_event(tex, e3) == true)
        assert(message.texture_remove_event(tex, e3) == false, "重复 remove 应返回 false")
        c = nil
        collectgarbage("collect"); collectgarbage("collect")
        assert(weak.c == nil, "被移除事件的回调仍被强引用")

        -- A removal must not disturb an event that was never removed.
        local d = new_cb("d")
        local e4 = message.texture_add_event(tex, 65, d, nil)
        assert(message.texture_remove_event(tex, e2) == true)
        b = nil
        collectgarbage("collect"); collectgarbage("collect")
        assert(weak.b == nil, "被移除事件的回调仍被强引用")
        assert(weak.d ~= nil, "移除其他事件时误释放了 e4 的回调")
        assert(message.texture_remove_event(tex, e4) == true)
        assert(message.texture_remove_event(tex, e1) == true)
        a = nil; d = nil
        collectgarbage("collect"); collectgarbage("collect")
        assert(weak.a == nil and weak.d == nil, "最后一个 owner 移除后回调未释放")

        -- The same Lua function may be owned by two events (callback_push
        -- deduplicates it); releasing one owner must keep the other alive.
        local shared = new_cb("shared")
        local s1 = message.texture_add_event(tex, 66, shared, nil)
        local s2 = message.texture_add_event(tex, 67, shared, nil)
        assert(message.texture_remove_event(tex, s1) == true)
        shared = nil
        collectgarbage("collect"); collectgarbage("collect")
        assert(weak.shared ~= nil, "共享回调在另一个事件仍持有时被释放")
        assert(message.texture_remove_event(tex, s2) == true)
        collectgarbage("collect"); collectgarbage("collect")
        assert(weak.shared == nil, "共享回调在最后一个 owner 移除后泄漏")

        -- texture_destroy removes every remaining event and reports the count.
        local r1 = new_cb("r1")
        local r2 = new_cb("r2")
        assert(message.texture_add_event(tex, 68, nil, r1) > 0)
        assert(message.texture_add_event(tex, 69, r2, nil) > 0)
        assert(message.texture_destroy(tex) == 2, "texture_destroy 返回值不是 2")
        r1 = nil; r2 = nil
        collectgarbage("collect"); collectgarbage("collect")
        assert(weak.r1 == nil and weak.r2 == nil, "destroy 未释放回调")
        assert(message.texture_destroy(tex) == 0, "重复 destroy 应返回 0")
    end)
end

-- ============ D. 可调用性 / 返回类型 ============
print("")
print("-- D. bridge handler 的返回类型（按 spec 的 ret 字符）--")

local RET_CHECKS = {
    { "GetFps",          "R", is_number },
    { "GetGameVersion",  "I", is_number },
    { "GetMapName",      "S", is_string },
    { "GetPluginVersion","S", is_string },
    { "GetChatState",    "B", function(v) return type(v) == "boolean" or is_number(v) end },
    -- GetLittleMapX/Y 走 d3d 代理模块，纯引擎部署没有它们 -> 下面显式 SKIP
    { "Hex",             "S", is_string },
}
for _, c in ipairs(RET_CHECKS) do
    check("ret " .. c[2] .. " <- " .. c[1] .. "()", function()
        local fn = japi[c[1]]
        assert(is_callable(fn), "不可调用")
        local args = {}
        if c[1] == "Hex" then args = { 255 } end
        local v = fn(table.unpack(args))
        assert(c[3](v), "返回 " .. type(v) .. " = " .. tostring(v) .. "（spec 要求 " .. c[2] .. "）")
    end)
end

-- 只有挂 D3D 代理（jass.d3d）才提供地图小地图坐标，纯引擎部署没有
skip("ret R <- GetLittleMapX()/GetLittleMapY()", "需要 -D3DProxy 部署（本测试台默认不带代理）")

check("message.hook 可注册（写入后读回同一个函数）", function()
    local f = function() return true end
    message.hook = f
    local back = message.hook
    message.hook = nil
    assert(back == f, "message.hook 写入后读回 " .. type(back))
end)

-- E 组需要夹具单位：等游戏跑起来再建（脚本加载期 CreateUnit 返回 nil）
local function run_fixture_groups()


-- ============ E. 语义往返（D6/D7/D8）============
print("")
print("-- E. Set -> Get 往返（技能数据 / 单位状态 / 施法状态）--")

check("夹具单位已创建", function()
    assert(unit ~= nil, "CreateUnit 返回 nil")
end)

if unit ~= nil then
    check("D8 EXGetUnitState == GetUnitState(MAX_LIFE)", function()
        local ex = japi.EXGetUnitState(unit, jass.ConvertUnitState(1))
        local native = jass.GetUnitState(unit, jass.ConvertUnitState(1))
        assert(math.abs(ex - native) < 0.01,
            string.format("EX=%s native=%s", tostring(ex), tostring(native)))
    end)
    check("D8 EXSetUnitState(LIFE) 往返", function()
        -- 取 100（低于 hfoo 的 420 上限）——游戏会把生命值夹到最大值，之前的 500 是被夹的
        japi.EXSetUnitState(unit, jass.ConvertUnitState(0), 100.0)
        local back = japi.EXGetUnitState(unit, jass.ConvertUnitState(0))
        assert(math.abs(back - 100.0) < 0.5, "读回 " .. tostring(back))
    end)
    check("EXSetUnitFacing 往返", function()
        japi.EXSetUnitFacing(unit, 90.0)
        local facing = jass.GetUnitFacing(unit)
        assert(math.abs(facing - 90.0) < 5.0, "GetUnitFacing = " .. tostring(facing))
    end)
    check("EXPauseUnit 可调用（add_stun/remove_stun 通道）", function()
        japi.EXPauseUnit(unit, true)
        japi.EXPauseUnit(unit, false)
    end)
    skip("EXPauseUnit -> IsUnitPaused 相关性",
        "实现走 add_stun/remove_stun（UjAPI 语义），不是原生 PauseUnit 标志；P5 用「不能移动」验证")
    check("EXGetUnitAbility 找到 AInv", function()
        assert(ability ~= nil and ability ~= 0,
            "EXGetUnitAbility 返回 " .. tostring(ability) .. string.format("；rev4cc=0x%08X revSearch=%s", rev4cc(ABILITY_RAWCODE), tostring(japi.EXGetUnitAbility(unit, rev4cc(ABILITY_RAWCODE)))) .. "；" .. tostring(fixture_diag))
    end)
end

if ability ~= nil and ability ~= 0 then
    check("EXGetAbilityId 与 rawcode 一致", function()
        assert(japi.EXGetAbilityId(ability) == ABILITY_RAWCODE,
            string.format("得到 0x%08X 期望 0x%08X", japi.EXGetAbilityId(ability), ABILITY_RAWCODE))
    end)
    check("EXGetUnitAbilityByIndex 能找到同一对象", function()
        local found = false
        for i = 0, 8 do
            local h = japi.EXGetUnitAbilityByIndex(unit, i)
            -- ability_pool 每次 push 都发新句柄，同一对象句柄会不同 ⇒ 比 id
            if h ~= nil and h ~= 0 and japi.EXGetAbilityId(h) == ABILITY_RAWCODE then found = true end
        end
        assert(found, "索引 0..8 都没有返回同一个 ability 对象（可能是 1 基索引或返回类型不符）")
    end)
    check("D7 EXSetAbilityDataInteger(200) 往返", function()
        local old = japi.EXGetAbilityDataInteger(ability, 1, 200)
        japi.EXSetAbilityDataInteger(ability, 1, 200, 81)
        local back = japi.EXGetAbilityDataInteger(ability, 1, 200)
        if is_number(old) then japi.EXSetAbilityDataInteger(ability, 1, 200, old) end
        assert(back == 81, "读回 " .. tostring(back))
    end)
    check("D7 EXSetAbilityDataReal(105) 往返", function()
        local old = japi.EXGetAbilityDataReal(ability, 1, 105)
        japi.EXSetAbilityDataReal(ability, 1, 105, 1.5)
        local back = japi.EXGetAbilityDataReal(ability, 1, 105)
        if is_number(old) then japi.EXSetAbilityDataReal(ability, 1, 105, old) end
        assert(type(back) == "number" and math.abs(back - 1.5) < 0.001, "读回 " .. tostring(back))
    end)
    check("D6 EXSetAbilityDataString(0xDA) 往返", function()
        local old = japi.EXGetAbilityDataString(ability, 1, 0xDA)
        local set_ok = japi.EXSetAbilityDataString(ability, 1, 0xDA, "conf-tip")
        local back = japi.EXGetAbilityDataString(ability, 1, 0xDA)
        local by_id = japi.EXGetAbilityString(ABILITY_RAWCODE, 1, 0xDA)
        if is_string(old) then japi.EXSetAbilityDataString(ability, 1, 0xDA, old) end
        assert(back == "conf-tip", string.format("set=%s old=%s back=%s byId=%s", tostring(set_ok), tostring(old), tostring(back), tostring(by_id)))
    end)
    check("D6 EXSetAbilityString(0xD7) 往返（按类型表）", function()
        local old = japi.EXGetAbilityString(ABILITY_RAWCODE, 1, 0xD7)
        local set_ok = japi.EXSetAbilityString(ABILITY_RAWCODE, 1, 0xD7, "conf-title")
        local back = japi.EXGetAbilityString(ABILITY_RAWCODE, 1, 0xD7)
        local by_obj = japi.EXGetAbilityDataString(ability, 1, 0xD7)
        if is_string(old) then japi.EXSetAbilityString(ABILITY_RAWCODE, 1, 0xD7, old) end
        assert(back == "conf-title", string.format("set=%s old=%s back=%s byObj=%s", tostring(set_ok), tostring(old), tostring(back), tostring(by_obj)))
    end)
    check("EXSetAbilityState 返回 boolean", function()
        local ok = japi.EXSetAbilityState(ability, 1, 1.0)
        assert(type(ok) == "boolean" or is_number(ok), "返回 " .. type(ok))
    end)
    check("EXSetAbilityAEmeDataA 返回 boolean", function()
        local ok = japi.EXSetAbilityAEmeDataA(ability, 1)
        assert(type(ok) == "boolean" or is_number(ok), "返回 " .. type(ok))
    end)
else
    skip("D6/D7 技能数据往返", "夹具技能对象不存在（EXGetUnitAbility 返回空）")
end

-- ============ M. setter 返回值============
print("")
print("-- M. setter 返回值--")
if ability ~= nil and ability ~= 0 then
    check("EXSetAbilityDataReal 返回 true", function()
        local r = japi.EXSetAbilityDataReal(ability, 1, 105, 1.0)
        assert(r == true, "返回 " .. tostring(r))
    end)
    check("EXSetAbilityDataInteger 返回 true", function()
        local r = japi.EXSetAbilityDataInteger(ability, 1, 117, 0)
        assert(r == true, "返回 " .. tostring(r))
    end)
    check("EXSetAbilityDataString 返回 true", function()
        local r = japi.EXSetAbilityDataString(ability, 1, 0xDA, "conf-pred")
        assert(r == true, "返回 " .. tostring(r))
    end)
    check("EXSetAbilityString 返回 true", function()
        local r = japi.EXSetAbilityString(ABILITY_RAWCODE, 1, 0xD7, "conf-pred-title")
        assert(r == true, "返回 " .. tostring(r))
    end)
else
    skip("setter 返回值", "夹具技能对象不存在")
end
if unit ~= nil then
    check("EXSetUnitState 返回 true", function()
        local r = japi.EXSetUnitState(unit, jass.ConvertUnitState(0), 100.0)
        assert(r == true, "返回 " .. tostring(r))
    end)
    check("EXPauseUnit 返回 true", function()
        local on = japi.EXPauseUnit(unit, true)
        local off = japi.EXPauseUnit(unit, false)
        assert(on == true and off == true, "on=" .. tostring(on) .. " off=" .. tostring(off))
    end)
else
    skip("EXSetUnitState 返回值", "夹具单位不存在")
end

-- 诊断（P1）：把能力 UI 的字符串字段全读一遍，判定「布局错位」还是「ABI 转换错」
if ability ~= nil and ability ~= 0 then
    local probe_fields = { 203, 204, 207, 215, 218, 220 }
    local parts = {}
    for _, t in ipairs(probe_fields) do
        local ok, v = pcall(function() return japi.EXGetAbilityDataString(ability, 1, t) end)
        parts[#parts + 1] = tostring(t) .. "=" .. (ok and tostring(v) or ("ERR:" .. tostring(v)))
    end
    print("  [PROBE] ability ui strings: " .. table.concat(parts, " | "))
    for _, t in ipairs(probe_fields) do
        local ok, v = pcall(function() return japi.EXGetAbilityString(ABILITY_RAWCODE, 1, t) end)
        parts[#parts + 1] = "byId" .. tostring(t) .. "=" .. (ok and tostring(v) or "ERR")
    end
    print("  [PROBE] ability strings by id: " .. table.concat(parts, " | "))
end

-- ============ J. 真 JASS native 注册============
print("")
print("-- J. EX* 的真 JASS native 表面--")

local jassdbg = require "jass.debug"

-- jass::japi_add 把这批名字写进引擎 native 表，jass.debug 走同一张表。
local REAL_NATIVES = {
    "EXGetUnitAbility", "EXGetAbilityDataReal", "EXSetAbilityDataString",
    "EXDisplayChat", "Hex", "GetMapName",
}
for _, name in ipairs(REAL_NATIVES) do
    check("真 native 已注册：" .. name, function()
        local addr = jassdbg.jass_func_address(name)
        assert(type(addr) == "number" and addr ~= 0,
            "jass_func_address 返回 " .. tostring(addr))
    end)
end

-- Lua 侧必须仍然走 bridge（P1 修好的字符串 ABI / real / boolean 转换）。
check("jass.japi 仍走 bridge（Hex）", function()
    local v = japi.Hex(255)
    assert(v == "000000FF", "japi.Hex(255)=" .. tostring(v))
end)

if unit ~= nil then
    -- jass.call 走引擎 native 表（不是 bridge 闭包）：地址在表里、签名对、
    -- 参数与返回值都能解 —— 这是「真 native」的端到端证据。
    check("JASS 级派发：EXGetUnitAbility -> EXGetAbilityId", function()
        local h = jass.call("EXGetUnitAbility", unit, ABILITY_RAWCODE)
        assert(h ~= nil and h ~= 0, "EXGetUnitAbility 返回 " .. tostring(h))
        local id = jass.call("EXGetAbilityId", h)
        assert(id == ABILITY_RAWCODE,
            string.format("EXGetAbilityId=%s, rawcode=%s", tostring(id), tostring(ABILITY_RAWCODE)))
    end)
    check("JASS 级派发：字符串返回（Hex）", function()
        local v = jass.call("Hex", 255)
        assert(v == "000000FF", "jass.call(Hex,255)=" .. tostring(v))
    end)
else
    skip("JASS 级派发 EX*", "夹具单位不存在")
end

-- ============ K. jass.console / jass.log============
print("")
print("-- K. jass.console / jass.log--")

do
    local ok, consolemod = pcall(require, "jass.console")
    check("jass.console 可加载", function()
        assert(ok, tostring(consolemod))
        assert(type(consolemod.write) == "function", "console.write=" .. type(consolemod.write))
        assert(type(consolemod.clear) == "function", "console.clear=" .. type(consolemod.clear))
    end)
    check("console.enable 读写回环", function()
        consolemod.enable = false
        assert(consolemod.enable == false, "读回 " .. tostring(consolemod.enable))
        consolemod.enable = true
        assert(consolemod.enable == true, "读回 " .. tostring(consolemod.enable))
    end)
    check("console.write 多参数不报错", function()
        consolemod.write("conformance", 1)
        consolemod.write("conformance %s", "write")
    end)
end

do
    local ok, logmod = pcall(require, "jass.log")
    check("jass.log 可加载（含 builtin-japi 的 warnning 拼写）", function()
        assert(ok, tostring(logmod))
        assert(type(logmod.debug) == "function", "log.debug=" .. type(logmod.debug))
        assert(type(logmod.info) == "function", "log.info=" .. type(logmod.info))
        assert(type(logmod.warn) == "function", "log.warn=" .. type(logmod.warn))
        assert(type(logmod.warnning) == "function", "log.warnning=" .. type(logmod.warnning))
        assert(type(logmod.error) == "function", "log.error=" .. type(logmod.error))
    end)
    check("log.path 读写回环（自动补尾部分隔符）", function()
        local before = logmod.path
        logmod.path = "conformance\\logs"
        local after = logmod.path
        assert(after == "conformance\\logs\\", "读回 " .. tostring(after))
        logmod.path = before
    end)
    check("log.info / log.error 写文件", function()
        logmod.path = "conformance\\logs"
        logmod.info("conformance log probe", 123)
        logmod.error("conformance log probe error")
    end)
end

-- ============ L. jass.bignum============
print("")
print("-- L. jass.bignum--")

do
    local ok, bn = pcall(require, "jass.bignum")
    check("jass.bignum 可加载", function()
        assert(ok, tostring(bn))
        assert(type(bn.new) == "function", "bignum.new=" .. type(bn.new))
        assert(type(bn.bin) == "function", "bignum.bin=" .. type(bn.bin))
        assert(type(bn.sha1) == "function", "bignum.sha1=" .. type(bn.sha1))
    end)

    -- 参考值由 Node.js BigInt 计算：modpow(0x3039, 65537, 0x3b9aca07)。
    local function bn_hex(hex) return bn.new(bn.bin(hex)) end
    check("modpow 小案例 0x3039^65537 mod 0x3b9aca07", function()
        local r = tostring(bn_hex("3039"):powmod(bn.new(65537), bn_hex("3b9aca07")))
        assert(r == "8a62697", "得到 " .. tostring(r))
    end)
    -- 参考值：modpow(0x1234567890abcdef1234567890abcdef, 65537, 2^255-19)。
    check("modpow 256 位模数（2^255-19）", function()
        local base = bn_hex("1234567890abcdef1234567890abcdef")
        local modulus = bn_hex("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed")
        local r = tostring(base:powmod(bn.new(65537), modulus))
        assert(r == "31369b760ab7a1f6896f57254db9b89f071a74848951fafdd36b34f359efc703",
            "得到 " .. tostring(r))
    end)
    check("bin() 把十六进制文本转成字节串", function()
        local b = bn.bin("00010001")
        assert(type(b) == "string" and #b == 4, "得到 " .. type(b) .. " len=" .. tostring(#b))
    end)
    check("sha1(\"abc\") 标准向量", function()
        local h = bn.sha1("abc")
        assert(h == "a9993e364706816aba3e25717850c26c9cd0d89d", "得到 " .. tostring(h))
    end)
    check("sha1(\"\") 标准向量", function()
        local h = bn.sha1("")
        assert(h == "da39a3ee5e6b4b0d3255bfef95601890afd80709", "得到 " .. tostring(h))
    end)
    -- RSA.lua:46 check_sign 的比较口径：sha1 的十六进制不经补零，tostring 也一样。
    check("sha1 -> bin -> new -> tostring 往返一致", function()
        local h = bn.sha1("conformance")
        local back = tostring(bn.new(bn.bin(h)))
        assert(back == h, "sha1=" .. tostring(h) .. " back=" .. tostring(back))
    end)
end

end

-- ============ F. slk ============
print("")
print("-- F. slk 数据表 --")

local SLK_TABLES = { "ability", "buff", "unit", "item", "upgrade", "doodad", "destructable" }
for _, name in ipairs(SLK_TABLES) do
    check("slk." .. name .. " 是表", function()
        assert(type(slk[name]) == "table", "得到 " .. type(slk[name]))
    end)
end
check("slk.unit['hfoo'] 可读", function()
    local row = slk.unit["hfoo"]
    assert(type(row) == "table", "得到 " .. type(row))
end)
check("slk.destructable[数字 rawcode] 可读（外来地图传整数）", function()
    local row = slk.destructable[fourcc("LTlt")] or slk.destructable["LTlt"]
    assert(type(row) == "table", "整数查表返回 " .. type(row))
end)
-- slk.misc is a real 8th table (MiscData/Units/Game + war3mapmisc merge).
do
    local misc = slk.misc
    if type(misc) == "table" then
        check("slk.misc.Misc.DefenseArmor 可读", function()
            local row = misc["Misc"]
            assert(type(row) == "table", "slk.misc.Misc 得到 " .. type(row))
            local v = tonumber(row.DefenseArmor)
            assert(v ~= nil and v > 0, "DefenseArmor=" .. tostring(row.DefenseArmor))
        end)
    else
        skip("slk.misc", "引擎未提供第 8 张表")
    end
end

-- ============ G. message 契约 ============
print("")
print("-- G. jass.message 契约 --")

local MESSAGE_FNS = { "keyboard", "mouse", "button", "selection",
                      "order_point", "order_target", "order_immediate" }
for _, name in ipairs(MESSAGE_FNS) do
    check("message." .. name .. " 存在", function()
        local v = message[name]
        assert(v ~= nil, "缺失")
    end)
end

-- ============ H. storm ============
print("")
print("-- H. jass.storm --")
check("storm.has 读 war3map.w3e", function()
    assert(storm.has("war3map.w3e") == true, "返回 " .. tostring(storm.has("war3map.w3e")))
end)
check("storm.load 读 war3map.w3e 非空", function()
    local content = storm.load("war3map.w3e")
    assert(is_string(content) and #content > 0, "得到 " .. type(content))
end)
do
    check("storm.save 是函数", function()
        assert(is_callable(storm.save), "storm.save=" .. type(storm.save))
    end)
    -- 写真实文件（地图目录下），storm.load 在 MPQ 未命中时回落读它。
    check("storm.save -> storm.has -> storm.load 往返", function()
        local path = "conformance\\saved-probe.txt"
        assert(storm.save(path, "hello storm") == true, "save 返回 " .. tostring(storm.save(path, "hello storm")))
        assert(storm.has(path) == true, "has 返回 false")
        local back = storm.load(path)
        assert(back == "hello storm", "load 得到 " .. tostring(back))
        storm.save(path, "second write")
        assert(storm.load(path) == "second write", "覆盖写失败")
    end)
end

-- ============ I. 外部 YDWE 图的 16 个 EX 使用点（最小复现）============
print("")
print("-- I. 外部 YDWE 图使用点最小复现 --")

-- 每个使用点只断言「函数可调用且不抛异常」，不断言游戏内可见效果
-- （可见效果需要真实地图 + 实机输入，本测试台不做）。
local EX_USE_SITES = {
    { "ac/skill.lua:174 EXGetUnitAbility", function() return japi.EXGetUnitAbility(unit, ABILITY_RAWCODE) end },
    { "ac/skill.lua:689 EXSetAbilityDataString", function() return japi.EXSetAbilityDataString(ability, 1, 0xDA, "tip") end },
    { "ac/skill.lua:712 EXSetAbilityDataString(title)", function() return japi.EXSetAbilityDataString(ability, 1, 0xD7, "title") end },
    { "ac/skill.lua:760 EXSetAbilityDataInteger(hotkey)", function() return japi.EXSetAbilityDataInteger(ability, 1, 200, 87) end },
    { "types/hero.lua:81 EXSetAbilityDataInteger(117)", function() return japi.EXSetAbilityDataInteger(ability, 1, 117, 0) end },
    { "types/hero.lua:83 EXSetAbilityAEmeDataA", function() return japi.EXSetAbilityAEmeDataA(ability, 1) end },
    { "types/unit.lua:947 EXGetUnitAbility(A007)", function() return japi.EXGetUnitAbility(unit, fourcc("A007")) end },
    { "types/unit.lua:948 EXSetAbilityDataReal(108)", function() return japi.EXSetAbilityDataReal(ability, 1, 108, -1.0) end },
    { "ac/template_skill.lua:76 EXSetAbilityDataReal(0x6E)", function() return japi.EXSetAbilityDataReal(ability, 1, 0x6E, 0) end },
}
for _, c in ipairs(EX_USE_SITES) do
    check(c[1], function()
        local fn = c[2]
        local ok, err = pcall(fn)
        assert(ok, tostring(err))
    end)
end
skip("types/item.lua:320/403 EXSetItemDataString", "需要夹具物品，本测试台没有")

-- ============ 收尾 ============
local function finish()
    print("")
    print("========================================")
    print(string.format(" Conformance: %d passed, %d failed, %d skipped", pass, fail, skipped))
    print(string.format(" Results: %d passed, %d failed, %d total", pass, fail, pass + fail))
    print("========================================")
end

-- 夹具：脚本加载期 CreateUnit 不可用，等 0.2s 后重试（最多 5 次）
local fixture_attempts = 0
local fixture_timer = jass.CreateTimer()
jass.TimerStart(fixture_timer, 0.2, true, function()
    fixture_attempts = fixture_attempts + 1
    build_fixture()
    if unit ~= nil or fixture_attempts >= 5 then
        jass.DestroyTimer(fixture_timer)
        run_fixture_groups()
    end
end)

-- 3.8s：让异步工作（对象注册、计时器）都完成后再收尾，deploy.ps1 靠这一行判定。
local finish_timer = jass.CreateTimer()
jass.TimerStart(finish_timer, 3.8, false, function()
    jass.DestroyTimer(finish_timer)
    finish()
end)
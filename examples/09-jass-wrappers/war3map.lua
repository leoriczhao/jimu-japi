-- ============================================================
-- 示例 09 · JASS wrapper（-WithJassWrappers）
-- 编号      : 09-jass-wrappers
-- 用途      : pack.ps1 -WithJassWrappers 会把 C++ 注册表里的扩展 native 生成成
--             JASS 五部曲 wrapper，放进 war3map.j，让 JASS 触发器可以直接调用；
--             Lua 侧则用 hashtable bridge 调同一个 native。示例对比两条路径的结果，
--             证明 wrapper 真的落到引擎里，而不是只生成了文本。
-- 需要的开关: WithJassWrappers（pack.ps1 / deploy.ps1 同名开关）
-- 前置条件  : 空地图基座（war3map.j 里有 japi_ht / japi__key / udg_lua_wrapper_*）
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 6 项）
-- 验证状态  : 2026-11-16 静态 + 打包验证通过；实机数据来自 lead 的
--             -WithJassWrappers 回归（125 passed / 0 failed / 125 total）
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"
local globals = require "jass.globals"

-- 加载时就置存活标志：pack.ps1 注入的 JASS 探针只在 udg_lua_japi_alive==1 时才干活。
globals.udg_lua_japi_alive = 1

-- Lua 侧调扩展 native 的通用 bridge：
--   参数按 spec 存进 hashtable 的 slot 1..n，spec 存在 slot 0，
--   再用 UnitId("NativeName") 触发分发，返回值从 slot 0 读回。
local function bridge_call(name, spec, ...)
    local ht, key = globals.japi_ht, globals.japi__key
    if ht == nil or key == nil then
        error("地图里没有 japi_ht / japi__key（不是 pack.ps1 打出来的图？）")
    end
    local args = { ... }
    for i = 1, #args do
        local v = args[i]
        local t = type(v)
        if t == "number" then
            jass.SaveInteger(ht, key, i, v)      -- real 参数请改用 SaveReal
        elseif t == "string" then
            jass.SaveStr(ht, key, i, v)
        elseif t == "boolean" then
            jass.SaveBoolean(ht, key, i, v)
        else
            error("不支持的参数类型: " .. t)
        end
    end
    jass.SaveStr(ht, key, 0, spec)
    jass.UnitId(name)

    local ret = spec:match("%)%s*(.+)$")
    if ret == "I" then return jass.LoadInteger(ht, key, 0) end
    if ret == "R" then return jass.LoadReal(ht, key, 0) end
    if ret == "S" then return jass.LoadStr(ht, key, 0) end
    if ret == "B" then return jass.LoadBoolean(ht, key, 0) end
    return nil
end

-- ============ 以下为示例自检，粘到自己地图时可以删掉 ============

-- 自检 harness：输出约定与 map/game/demo.lua 一致（[PASS]/[FAIL] + 一行 Results）。
local pass, fail = 0, 0

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

local function finish()
    print("")
    print("========================================")
    print(string.format(" Results: %d passed, %d failed, %d total", pass, fail, pass + fail))
    print("========================================")
end

local PROBE_HINT = "JASS wrapper 探针没有注入：用 tools\\pack.ps1 / tools\\deploy.ps1 加 -WithJassWrappers 重新打包"

local function probe_ready()
    assert(globals.udg_lua_wrapper_ready == 1,
        "udg_lua_wrapper_ready = " .. tostring(globals.udg_lua_wrapper_ready) .. "。" .. PROBE_HINT)
end

check("JASS wrapper 探针已注入（udg_lua_wrapper_ready == 1）", probe_ready)

check("GetGameVersion：JASS wrapper 与 Lua bridge 结果一致", function()
    probe_ready()
    local via_jass = globals.udg_lua_wrapper_int
    local via_lua = bridge_call("GetGameVersion", "()I")
    assert(type(via_jass) == "number" and via_jass > 0, "JASS 侧 = " .. tostring(via_jass))
    assert(via_jass == via_lua,
        string.format("JASS %s vs Lua %s", tostring(via_jass), tostring(via_lua)))
end)

check("Hex(255) 在两侧都是 000000FF", function()
    probe_ready()
    local hex = globals.udg_lua_wrapper_hex
    assert(hex == "000000FF", "JASS 侧 = " .. tostring(hex))
    assert(hex == bridge_call("Hex", "(I)S", 255), "Lua bridge 结果不一致")
end)

check("GetPluginVersion 两侧一致且非空", function()
    probe_ready()
    local plugin = globals.udg_lua_wrapper_text
    assert(type(plugin) == "string" and #plugin > 0, "JASS 侧 = " .. tostring(plugin))
    assert(plugin == bridge_call("GetPluginVersion", "()S"), "Lua bridge 结果不一致")
end)

check("GetLittleMapX / SetLittleMapX 的 real 往返", function()
    probe_ready()
    local base = globals.udg_lua_wrapper_real_base
    local nudged = globals.udg_lua_wrapper_real
    assert(type(base) == "number" and type(nudged) == "number",
        string.format("base=%s nudged=%s", tostring(base), tostring(nudged)))
    assert(math.abs(nudged - (base + 0.01)) < 1e-4,
        string.format("nudged %s != base %s + 0.01", tostring(nudged), tostring(base)))
    assert(type(bridge_call("GetLittleMapX", "()R")) == "number", "GetLittleMapX 不是 number")
end)

check("GetChatState 两侧都是 boolean 且一致", function()
    probe_ready()
    local chat = globals.udg_lua_wrapper_bool
    assert(type(chat) == "boolean", "JASS 侧 = " .. tostring(chat))
    assert(chat == bridge_call("GetChatState", "()B"), "Lua bridge 结果不一致")
end)

local finish_timer = jass.CreateTimer()
jass.TimerStart(finish_timer, 3.8, false, function()
    jass.DestroyTimer(finish_timer)
    finish()
end)

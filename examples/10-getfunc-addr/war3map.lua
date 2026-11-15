-- ============================================================
-- 示例 10 · 函数地址与绑定标签（-WithGetFuncAddr）
-- 编号      : 10-getfunc-addr
-- 用途      : pack.ps1 -WithGetFuncAddr 会在 war3map.j 里声明隐藏 native
--             SetHeroLevels(code) 并建 GetFuncAddr(f)，把 code 参数转成整数地址，
--             填进 udg_lua_getfunc_*。示例用 jass.debug 把这些地址反查成标签、
--             取回 SaveFunc 存的锚点，并把地址直接当 TriggerAddAction 的 code 用。
-- 需要的开关: WithGetFuncAddr
-- 前置条件  : 空地图基座（war3map.j 里有 japi_ht / japi__key / udg_lua_getfunc_*）
-- 探针时序  : pack.ps1 -WithGetFuncAddr 注入的 JASS 探针在 2.20s 的一次性 timer 里
--             才调 GetFuncAddr/SaveFunc 并填 udg_lua_getfunc_*，所以本示例把检查放到 2.6s 再跑。
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 6 项）
-- 验证状态  : 2026-11-16 静态 + 打包验证通过；实机数据来自 lead 的
--             -WithGetFuncAddr 回归（126 passed / 0 failed / 126 total）
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"
local globals = require "jass.globals"
local jdbg = require "jass.debug"

-- 加载时置存活标志：-WithGetFuncAddr 的 JASS 探针只在 udg_lua_japi_alive==1 时干活。
globals.udg_lua_japi_alive = 1

-- 函数地址 -> 绑定标签（标签由 func_bind 系列绑定，便于日志/反查）。
local function describe_address(addr)
    local label = jdbg.func_bind_lookup(addr)
    print(string.format("[example 10] addr=%s -> %s", tostring(addr), tostring(label)))
    return label
end

-- 把地址当 code 用：TriggerAddAction 接受整数地址，等价于 JASS 里的 function 值。
local function run_code_address(addr)
    local trigger = jass.CreateTrigger()
    jass.TriggerAddAction(trigger, addr)
    jass.TriggerExecute(trigger)
    jass.DestroyTrigger(trigger)
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

local PROBE_HINT = "GetFuncAddr 探针没有注入：用 tools\\pack.ps1 / tools\\deploy.ps1 加 -WithGetFuncAddr 重新打包"

local function probe_ready()
    assert(globals.udg_lua_getfunc_ready == 1,
        "udg_lua_getfunc_ready = " .. tostring(globals.udg_lua_getfunc_ready) .. "。" .. PROBE_HINT)
end

local function probe_addr()
    probe_ready()
    local addr = globals.udg_lua_getfunc_addr
    assert(type(addr) == "number" and addr ~= 0, "udg_lua_getfunc_addr = " .. tostring(addr))
    return addr
end

-- pack.ps1 -WithGetFuncAddr 注入的 JASS 探针是一个 2.20s 的一次性 timer：
-- 它到点才填 udg_lua_getfunc_*。所以检查必须等到 2.6s 之后再跑；
-- 加载时就跑只会读到 0（那样 udg_lua_getfunc_ready == 0）。
local function run_checks()
    check("GetFuncAddr 探针已注入（udg_lua_getfunc_ready == 1）", probe_ready)

    check("code 参数转成非零整数地址", function()
        local addr = probe_addr()
        print(string.format("[example 10] addr=%d addr2=%d addr3=%d",
            addr, globals.udg_lua_getfunc_addr2, globals.udg_lua_getfunc_addr3))
    end)

    check("同一个函数两次转换得到同一地址，不同函数不撞车", function()
        local addr = probe_addr()
        assert(globals.udg_lua_getfunc_addr3 == addr, "同一函数两个地址")
        local addr2 = globals.udg_lua_getfunc_addr2
        assert(addr2 ~= 0 and addr2 ~= addr, "两个不同函数撞到同一地址")
    end)

    check("地址能反查到绑定标签", function()
        local addr = probe_addr()
        assert(describe_address(addr) == "jass-getfunc-target",
            "标签 = " .. tostring(jdbg.func_bind_lookup(addr)))
    end)

    check("jass.debug.save_func_addr 取回 SaveFunc 的锚点", function()
        probe_ready()
        assert(jdbg.save_func_addr() == globals.udg_lua_getfunc_addr2, "锚点地址不一致")
    end)

    check("地址可以当 code 传给 TriggerAddAction", function()
        local addr = probe_addr()
        local before = globals.udg_lua_getfunc_hits
        run_code_address(addr)
        assert(globals.udg_lua_getfunc_hits == before + 1,
            string.format("hits %s -> %s", tostring(before), tostring(globals.udg_lua_getfunc_hits)))
    end)
end

local check_timer = jass.CreateTimer()
jass.TimerStart(check_timer, 2.6, false, function()
    jass.DestroyTimer(check_timer)
    run_checks()
end)

local finish_timer = jass.CreateTimer()
jass.TimerStart(finish_timer, 3.8, false, function()
    jass.DestroyTimer(finish_timer)
    finish()
end)

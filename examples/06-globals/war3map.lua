-- ============================================================
-- 示例 06 · 读写 JASS 全局变量（jass.globals）
-- 编号      : 06-globals
-- 用途      : 演示 Lua 侧直接读写地图里的 udg_ 全局（标量、整型数组、字符串数组），
--             用于把 Lua 的配置/状态交给 JASS 触发器，或反过来读取 JASS 写的值。
-- 需要的开关: 无（数组预分配是 pack.ps1 默认行为，见 -NoArrayPrealloc）
-- 前置条件  : 空地图基座 reference\empty-map，它声明了 udg_lua_test_value /
--             udg_lua_test_array / udg_lua_test_string_array
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 5 项）
-- 说明      : 数组被 pack.ps1 强制预分配（每个 declared array 先自赋值 [8191]），
--             所以 #arr == 8192；打包时加 -NoArrayPrealloc 就没有这个保证。
-- 时序      : JASS 数组全局在加载阶段还没有数组块（#arr == 0、元素读 nil、写进去会被丢掉），
--             要等地图初始化跑完才可用；所以示例把数组 I/O 放进 1.0s 的一次性 timer，
--             检查在 1.2s。标量全局（udg_lua_test_value）加载时就能读写。
-- 验证状态  : 2026-11-16 静态 + 打包验证通过（tools\verify-examples.ps1）
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"
local globals = require "jass.globals"

-- jass.globals 是 JASS 全局变量表的代理：
--   globals.udg_xxx           标量，读写即赋值
--   globals.udg_xxx[i]        数组元素（下标 0 起，1.27a 数组上限 8191）
-- Lua 里看到的值类型会跟着 JASS 类型走（integer -> number，string -> string）。
local CONFIG = {
    value = 12345,
    array_index = 3,
    array_value = 77,
    label_index = 7,
    label = "japi-globals",
}

local function poke_globals()
    globals.udg_lua_test_value = CONFIG.value
    globals.udg_lua_test_array[CONFIG.array_index] = CONFIG.array_value
    globals.udg_lua_test_string_array[CONFIG.label_index] = CONFIG.label
end

-- 注意：数组全局在加载阶段还没有数组块（#arr == 0，元素读 nil，写进去会被丢掉），
-- 要等地图初始化跑完才可用，所以数组 I/O 放进一个 1.0s 的一次性 timer；
-- 标量全局不走这个限制，加载时直接赋值就行。
local poke_timer = jass.CreateTimer()
jass.TimerStart(poke_timer, 1.0, false, function()
    jass.DestroyTimer(poke_timer)
    poke_globals()
end)

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

-- 数组检查必须在 1.0s 的 poke_globals() 跑完之后：仓库实测加载阶段数组块还没分配，
-- 这里用 1.2s 再起一次，给 1.0s 那次留 200ms 余量。
local function run_checks()
    check("jass.globals 已加载", function()
        assert(type(globals) == "table", "globals 不是 table: " .. type(globals))
    end)

    check("标量全局可写可读", function()
        globals.udg_lua_test_value = 4242
        assert(globals.udg_lua_test_value == 4242,
            "读回 " .. tostring(globals.udg_lua_test_value))
    end)

    check("整型数组元素可写可读", function()
        globals.udg_lua_test_array[5] = 909
        assert(globals.udg_lua_test_array[5] == 909,
            "读回 " .. tostring(globals.udg_lua_test_array[5]))
        assert(globals.udg_lua_test_array[CONFIG.array_index] == CONFIG.array_value,
            "下标 " .. CONFIG.array_index .. " 被别的写入影响")
    end)

    check("字符串数组可写可读", function()
        globals.udg_lua_test_string_array[9] = "abc"
        assert(globals.udg_lua_test_string_array[9] == "abc",
            "读回 " .. tostring(globals.udg_lua_test_string_array[9]))
    end)

    check("数组被 pack.ps1 预分配为 8192 个槽位", function()
        local n = #globals.udg_lua_test_array
        assert(n == 8192, "数组长度 " .. tostring(n))
    end)
end

local check_timer = jass.CreateTimer()
jass.TimerStart(check_timer, 1.2, false, function()
    jass.DestroyTimer(check_timer)
    run_checks()
end)

local finish_timer = jass.CreateTimer()
jass.TimerStart(finish_timer, 3.8, false, function()
    jass.DestroyTimer(finish_timer)
    finish()
end)

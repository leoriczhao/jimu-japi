-- 示例 06 · 读写 JASS 全局变量（jass.globals）
-- 用途：演示在 Lua 中直接读写 JASS 的标量、整型数组和字符串数组全局变量。
-- 说明：数组全局变量需在地图初始化完成后访问（放进 timer 回调）。
-- 打包：japi build examples/06-globals
-- 运行：japi run   examples/06-globals

local jass = require "jass.common"
local globals = require "jass.globals"

-- 标量全局可在加载阶段直接读写
globals.udg_lua_test_value = 12345

-- 数组全局在地图初始化完成后读写
local t = jass.CreateTimer()
jass.TimerStart(t, 0.5, false, function()
    jass.DestroyTimer(t)

    globals.udg_lua_test_array[3] = 77
    globals.udg_lua_test_string_array[7] = "hello-jass-globals"

    local msg = string.format(
        "[Globals] value=%s, array[3]=%s, str[7]=%s",
        tostring(globals.udg_lua_test_value),
        tostring(globals.udg_lua_test_array[3]),
        tostring(globals.udg_lua_test_string_array[7])
    )
    jass.DisplayTimedTextToPlayer(jass.GetLocalPlayer(), 0.0, 0.0, 6.0, msg)
end)

-- 示例 10 · 函数地址与 jass.debug 查询
-- 用途：演示打包参数 --with-get-func-addr 与 jass.debug 的函数地址查询和句柄检查能力。
-- 打包：japi build examples/10-getfunc-addr --with-get-func-addr
-- 运行：japi run   examples/10-getfunc-addr --with-get-func-addr

local jass = require "jass.common"
local jdbg = require "jass.debug"

local t = jass.CreateTimer()
jass.TimerStart(t, 0.5, false, function()
    jass.DestroyTimer(t)

    local ex_addr = jdbg.jass_func_address("EXGetObject")
    local handle_count = jdbg.handlecount()
    local handle_max = jdbg.handlemax()

    jass.DisplayTimedTextToPlayer(
        jass.GetLocalPlayer(), 0.0, 0.0, 8.0,
        string.format(
            "|cFF00FFCC[Debug]|r EXGetObject=0x%08X, handles=%d/%d",
            ex_addr or 0, handle_count, handle_max
        )
    )
end)

-- 示例 02 · native hook + 输入回调
-- 用途：演示 jass.hook 接管原生 JASS 函数，以及 jass.message.hook 拦截按键输入。
-- 打包：japi build examples/02-input-hook
-- 运行：japi run   examples/02-input-hook

local jass = require "jass.common"
local hook = require "jass.hook"
local message = require "jass.message"

-- 1. 监听游戏内输入（WARK 键码：Q = 0x51；返回 false 表示吞掉本次输入）
message.hook = function(msg)
    if msg.type == "key_down" and msg.code == 0x51 then
        jass.DisplayTimedTextToPlayer(
            jass.GetLocalPlayer(), 0.0, 0.0, 3.0,
            "|cFFFFCC00[Input]|r 拦截了 Q 键按下事件"
        )
        return false
    end
    return true
end

-- 2. 使用 jass.hook 包装原生 native（最后一个参数 orig 为原实现）
hook.hook("GetPlayerName", function(player, orig)
    return "[Hooked] " .. tostring(orig(player))
end)

local t = jass.CreateTimer()
jass.TimerStart(t, 0.5, false, function()
    jass.DestroyTimer(t)
    local lp = jass.GetLocalPlayer()
    jass.DisplayTimedTextToPlayer(lp, 0.0, 0.0, 6.0, "当前玩家名: " .. jass.GetPlayerName(lp))
end)

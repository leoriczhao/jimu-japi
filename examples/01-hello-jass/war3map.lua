-- 示例 01 · Hello, jass.common
-- 用途：通过 require "jass.common" 调用标准 JASS native，向本地玩家输出提示。
-- 打包：japi build examples/01-hello-jass
-- 运行：japi run   examples/01-hello-jass

local jass = require "jass.common"

local function greet()
    local player = jass.GetLocalPlayer()
    local name = jass.GetPlayerName(player)
    local id = jass.GetPlayerId(player)

    jass.DisplayTimedTextToPlayer(
        player, 0.0, 0.0, 6.0,
        string.format("|cFF00FFCC[Hello]|r %s (player #%d)", tostring(name), id)
    )
end

local t = jass.CreateTimer()
jass.TimerStart(t, 0.5, false, function()
    jass.DestroyTimer(t)
    greet()
end)

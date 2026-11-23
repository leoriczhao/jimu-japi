-- 示例 07 · 查询游戏对象数据表（jass.slk）
-- 用途：演示通过 jass.slk 惰性读取技能、单位、物品等对象数据行。
-- 打包：japi build examples/07-slk
-- 运行：japi run   examples/07-slk

local jass = require "jass.common"
local slk = require "jass.slk"

local t = jass.CreateTimer()
jass.TimerStart(t, 0.5, false, function()
    jass.DestroyTimer(t)

    local blizzard = slk.ability["AHbz"]
    local peasant = slk.unit["hpea"]

    local lp = jass.GetLocalPlayer()
    if blizzard then
        jass.DisplayTimedTextToPlayer(
            lp, 0.0, 0.0, 6.0,
            string.format("[SLK] AHbz: name=%s, code=%s", tostring(blizzard.name), tostring(blizzard.code))
        )
    end
    if peasant then
        jass.DisplayTimedTextToPlayer(
            lp, 0.0, 0.0, 6.0,
            string.format("[SLK] hpea: race=%s, hp=%s", tostring(peasant.race), tostring(peasant.hp))
        )
    end
end)

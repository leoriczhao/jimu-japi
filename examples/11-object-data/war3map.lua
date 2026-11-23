-- 示例 11 · 代码化物编（objects.lua）
-- 用途：通过同目录构建期文件 objects.lua 声明自定义单位 'uO11' 与 3 级自定义技能 'AO11'，
--       运行时直接创建该单位、添加技能并经 jass.slk 读取对象属性。
-- 打包：japi build examples/11-object-data
-- 运行：japi run   examples/11-object-data

local jass = require "jass.common"
local slk = require "jass.slk"

local function fourcc(s)
    local a, b, c, d = s:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local t = jass.CreateTimer()
jass.TimerStart(t, 0.5, false, function()
    jass.DestroyTimer(t)

    local p0 = jass.Player(0)
    local x = jass.GetPlayerStartLocationX(p0)
    local y = jass.GetPlayerStartLocationY(p0)

    local unit = jass.CreateUnit(p0, fourcc("uO11"), x, y, 270.0)
    if unit then
        jass.UnitAddAbility(unit, fourcc("AO11"))
        jass.SetUnitAbilityLevel(unit, fourcc("AO11"), 3)
    end

    local row = slk.unit["uO11"]
    jass.DisplayTimedTextToPlayer(
        p0, 0.0, 0.0, 8.0,
        string.format(
            "|cFF00FFCC[ObjectData]|r 创建自定义单位 %s (HP=%s)",
            row and tostring(row.name) or "uO11",
            row and tostring(row.hp) or "?"
        )
    )
end)

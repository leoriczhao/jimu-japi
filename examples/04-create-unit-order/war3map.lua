-- 示例 04 · 创建单位并下达移动命令
-- 用途：在玩家 0 出生点创建一个步兵，补满生命值，并下达点目标移动命令。
-- 打包：japi build examples/04-create-unit-order
-- 运行：japi run   examples/04-create-unit-order

local jass = require "jass.common"

local function fourcc(s)
    local a, b, c, d = string.byte(s, 1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local UNIT_FOOTMAN = fourcc("hfoo")
local ORDER_MOVE = jass.OrderId("move")

local function spawn_and_march()
    local p0 = jass.Player(0)
    local x = jass.GetPlayerStartLocationX(p0)
    local y = jass.GetPlayerStartLocationY(p0)

    local unit = jass.CreateUnit(p0, UNIT_FOOTMAN, x, y, 270.0)
    if not unit then return end

    local max_life = jass.GetUnitState(unit, jass.UNIT_STATE_MAX_LIFE)
    jass.SetWidgetLife(unit, max_life)
    jass.IssuePointOrderById(unit, ORDER_MOVE, x + 512.0, y)
end

local t = jass.CreateTimer()
jass.TimerStart(t, 0.5, false, function()
    jass.DestroyTimer(t)
    spawn_and_march()
end)

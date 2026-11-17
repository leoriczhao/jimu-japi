-- ============================================================
-- 示例 04 · 造单位 + 下命令
-- 编号      : 04-create-unit-order
-- 用途      : 用 jass.CreateUnit 在玩家出生点造一个原生单位，补满血，再用
--             jass.IssuePointOrderById 下一条 move 点命令，最后确认它真的动了。
--             对应的 Lua 协程/sleep 版编排见示例 05。
-- 需要的开关: 无
-- 前置条件  : 空地图；不依赖地图布局，只用玩家 0 的出生点坐标
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 5 项）
-- 说明      : 单位 rawcode 用游戏原生 "hfoo"（步兵，非英雄）。空地图基座
--             reference\empty-map 只自定义了 Hrif，原生 rawcode 可以直接 CreateUnit。
-- 验证状态  : 2026-11-16 静态 + 打包验证通过（tools\verify-examples.ps1）
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"

-- fourcc：把 "hfoo" 这样的 4 字符 rawcode 转成 JASS 的 integer id。
local function fourcc(value)
    local a, b, c, d = string.byte(value, 1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local UNIT_RAWCODE = fourcc("hfoo")          -- 原生步兵
local MOVE_ORDER = jass.OrderId("move")      -- 命令 id 用字符串取，别硬编码数字

-- 在玩家 0 的出生点造单位；创建后按最大生命值补满血。
-- CreateUnit(player, unitid, x, y, facing) 的返回值是单位句柄，失败时为 nil。
local function spawn_unit(player, rawcode, facing)
    local x = jass.GetPlayerStartLocationX(player)
    local y = jass.GetPlayerStartLocationY(player)
    local unit = jass.CreateUnit(player, rawcode, x, y, facing or 270.0)
    if unit == nil then
        return nil
    end
    local max_life = jass.GetUnitState(unit, jass.ConvertUnitState(1))  -- 1 = 最大生命
    jass.SetWidgetLife(unit, max_life)
    return unit, x, y, max_life
end

-- 点目标命令：坐标是世界坐标；成功后引擎开始执行，返回值表示命令是否被接受。
local function move_to(unit, x, y)
    return jass.IssuePointOrderById(unit, MOVE_ORDER, x, y)
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

-- 异步时间线：1 拍造单位并下令，3 拍采样当前命令，9 拍（0.9s）断言位移，38 拍（3.8s）收尾。
local state = {
    tick = 0, unit = nil, x = nil, y = nil, max_life = nil,
    ordered = nil, current_order = nil, mover = nil,
}

local run_checks

local probe_timer
local function on_tick()
    state.tick = state.tick + 1
    local n = state.tick

    if n == 1 then
        state.unit, state.x, state.y, state.max_life = spawn_unit(jass.Player(0), UNIT_RAWCODE, 270.0)
        if state.unit ~= nil then
            state.ordered = move_to(state.unit, state.x + 512.0, state.y)
        end
    elseif n == 3 and state.unit ~= nil then
        state.current_order = jass.GetUnitCurrentOrder(state.unit)
    elseif n == 9 then
        if state.unit ~= nil then
            state.mover = {
                x = jass.GetUnitX(state.unit),
                y = jass.GetUnitY(state.unit),
            }
        end
        run_checks()
        if state.unit ~= nil then
            jass.RemoveUnit(state.unit)
        end
    elseif n == 38 then
        jass.PauseTimer(probe_timer)
        jass.DestroyTimer(probe_timer)
        finish()
    end
end

run_checks = function()
    check("CreateUnit 造出可用单位句柄", function()
        assert(state.unit ~= nil, "CreateUnit 返回 nil（rawcode 不在对象数据里？）")
        assert(jass.GetHandleId(state.unit) > 0, "句柄 id 为 0")
    end)

    check("单位类型与 rawcode 一致", function()
        assert(jass.GetUnitTypeId(state.unit) == UNIT_RAWCODE,
            string.format("GetUnitTypeId=%s, 期望 %s",
                tostring(jass.GetUnitTypeId(state.unit)), tostring(UNIT_RAWCODE)))
    end)

    check("SetWidgetLife 按最大生命补满", function()
        local life = jass.GetWidgetLife(state.unit)
        assert(state.max_life > 0, "最大生命 " .. tostring(state.max_life))
        assert(math.abs(life - state.max_life) < 0.01,
            string.format("当前 %s / 最大 %s", tostring(life), tostring(state.max_life)))
    end)

    check("move 点命令被接受并成为当前命令", function()
        assert(state.ordered == true, "IssuePointOrderById 返回 " .. tostring(state.ordered))
        assert(state.current_order == MOVE_ORDER,
            string.format("当前命令 %s != move %s",
                tostring(state.current_order), tostring(MOVE_ORDER)))
    end)

    check("单位确实向目标点移动", function()
        assert(state.mover ~= nil, "没采到 0.9s 时的坐标")
        local dx = state.mover.x - state.x
        local dy = state.mover.y - state.y
        local dist = math.sqrt(dx * dx + dy * dy)
        assert(dist > 32.0, string.format("0.9s 只移动了 %.1f", dist))
    end)
end

probe_timer = jass.CreateTimer()
jass.TimerStart(probe_timer, 0.1, true, on_tick)

-- ============================================================
-- 示例 01 · Hello, jass.common
-- 编号      : 01-hello-jass
-- 用途      : 最小可运行示例。require "jass.common" 之后，JASS native 以
--             jass.<native>(...) 的元表形式调用；jass.call("Name", ...) 是同一
--             分发路径的显式写法。示例读玩家名、句柄和玩家 id，并往屏幕打一条提示。
-- 需要的开关: 无（tools\pack.ps1 / tools\deploy.ps1 默认参数即可）
-- 前置条件  : 空地图（reference\empty-map 基座），不需要 D3D proxy
-- 预期日志  : 若干 "  [PASS] ..." 行，末尾一行 Results 行且 failed 为 0（本示例 5 项）
-- 验证状态  : 2026-11-16 静态 + 打包验证通过（tools\verify-examples.ps1）；
--             进游戏实机由 deploy.ps1 -MapDir 跑，见 examples\README.md
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"

-- 玩家、单位、触发器在 Lua 侧都是 userdata 句柄；每个 native 都是 jass 表上的
-- 一个字段，由 __index 分发到 JASS 的 native 表，不需要写任何 spec 字符串。
local function greet_native()
    local player = jass.GetLocalPlayer()                 -- 元表写法
    local name = jass.GetPlayerName(player)              -- 字符串返回值
    local id_meta = jass.GetPlayerId(player)             -- 整数返回值
    local id_call = jass.call("GetPlayerId", player)     -- 显式写法，结果相同

    -- 往玩家屏幕左上角打 3 秒提示（坐标是 0..1 的屏幕相对坐标）。
    jass.DisplayTimedTextToPlayer(player, 0.0, 0.0, 3.0,
        "hello from jass.common: " .. tostring(name))

    print(string.format("[example 01] player=%s id=%d id_via_jass.call=%d",
        tostring(name), id_meta, id_call))
    return player, name, id_meta, id_call
end

-- 贴进地图后这一行就会在脚本加载时执行；自检里会再调一次做逐项断言。
greet_native()

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

local player, name, id_meta, id_call = greet_native()

check("jass.common 已加载且 jass.call 可用", function()
    assert(type(jass) == "table", "jass 不是 table: " .. type(jass))
    assert(type(jass.call) == "function", "jass.call 缺失")
end)

check("GetLocalPlayer 返回可用句柄", function()
    assert(jass.GetHandleId(player) > 0,
        "GetHandleId 返回 " .. tostring(jass.GetHandleId(player)))
end)

check("元表调用与 jass.call 等价", function()
    assert(id_meta == id_call,
        string.format("元表 %s vs jass.call %s", tostring(id_meta), tostring(id_call)))
end)

check("GetPlayerName 返回非空字符串", function()
    assert(type(name) == "string" and #name > 0, "玩家名: " .. tostring(name))
end)

check("Player(id) 指回同一个玩家的句柄", function()
    local same = jass.Player(id_meta)
    assert(jass.GetHandleId(same) == jass.GetHandleId(player),
        string.format("Player(%d) 句柄 %s != %s", id_meta,
            tostring(jass.GetHandleId(same)), tostring(jass.GetHandleId(player))))
end)

-- 结果行必须从 timer 里打：3.5~4.5s 后所有异步工作都已完成，deploy.ps1 靠它判定成功。
local finish_timer = jass.CreateTimer()
jass.TimerStart(finish_timer, 3.8, false, function()
    jass.DestroyTimer(finish_timer)
    finish()
end)

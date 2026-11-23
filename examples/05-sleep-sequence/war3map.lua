-- 示例 05 · 协程等待（jass.sleep）与 Timer 链式编排
-- 用途：演示在 trigger action 线程内使用 sleep()，以及多步骤流程推荐的 timer 链写法。
-- 打包：japi build examples/05-sleep-sequence
-- 运行：japi run   examples/05-sleep-sequence

local jass = require "jass.common"
local runtime = require "jass.runtime"
local sleep = (require "jass.sleep").sleep

runtime.sleep = true

local function say(msg)
    jass.DisplayTimedTextToPlayer(jass.GetLocalPlayer(), 0.0, 0.0, 6.0, msg)
end

-- 1. 在 trigger action 中使用单次 sleep（依赖 TriggerSleepAction，不能在主线程/timer 中直接调用）
local trig = jass.CreateTrigger()
jass.TriggerAddAction(trig, jass.code(function()
    say("|cFF00FFCC[Sleep]|r 阶段 1：开始等待 0.5 秒...")
    sleep(0.5)
    say("|cFF00FFCC[Sleep]|r 阶段 2：等待结束，继续执行")
end))
jass.TriggerRegisterTimerEvent(trig, 0.2, false)

-- 2. 多步骤异步编排推荐使用一次性 timer 链
local function after(sec, fn)
    local t = jass.CreateTimer()
    jass.TimerStart(t, sec, false, function()
        jass.DestroyTimer(t)
        fn()
    end)
end

after(1.2, function()
    say("|cFFFFCC00[Timer]|r 流程第 1 步")
    after(0.8, function()
        say("|cFFFFCC00[Timer]|r 流程第 2 步完成")
    end)
end)

-- ============================================================
-- 示例 05 · 用 sleep 编排开场流程（jass.sleep）
-- 编号      : 05-sleep-sequence
-- 用途      : 在 trigger action 线程里用 sleep(seconds) 写线性流程，省掉一堆
--             timer 状态机。覆盖 require "jass.sleep"、runtime.sleep 开关、
--             "只能在 trigger/action 线程里 sleep" 这条约束。
-- 需要的开关: 无
-- 前置条件  : 空地图；测试不依赖真人输入
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 6 项）
-- 验证状态  : 2026-11-16 静态 + 打包验证通过（tools\verify-examples.ps1）
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"
local runtime = require "jass.runtime"
local sleep = (require "jass.sleep").sleep   -- require 只注册全局 sleep，模块表上也有

-- sleep 的恢复靠 TriggerSleepAction，而它只能唤醒 trigger/action 线程：
-- 在 timer 回调或主线程里 sleep 会报错。所以下面把流程塞进 trigger action。
runtime.sleep = true

local sequence = { stage = 0 }

local function run_opening_sequence()
    local trigger = jass.CreateTrigger()
    jass.TriggerAddAction(trigger, jass.code(function()
        sequence.stage = 1
        print("[example 05] stage 1: 刷第一波")
        sleep(0.30)
        sequence.stage = 2
        print("[example 05] stage 2: 0.30s 后刷第二波")
        sleep(0.30)
        sequence.stage = 3
        print("[example 05] stage 3: 0.60s 后开场结束")
    end))
    -- 一次性 timer 事件触发 action 线程。
    jass.TriggerRegisterTimerEvent(trigger, 0.05, false)
    return trigger
end

local opening_trigger = run_opening_sequence()

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

check("jass.sleep 已加载（模块表 + 全局 sleep）", function()
    assert(type(sleep) == "function", "模块表上没有 sleep 字段")
    assert(type(_G.sleep) == "function", "require 之后全局 sleep 没有注册")
end)

check("协程外调用 sleep 会报错（不是静默失败）", function()
    local ok = pcall(sleep, 0.01)
    assert(not ok, "协程外 sleep 竟然成功了")
end)

check("协程里 sleep 会让协程挂起", function()
    local co = coroutine.create(function()
        sleep(0.01)
    end)
    local ok, err = coroutine.resume(co)
    assert(ok, "resume 失败: " .. tostring(err))
    assert(coroutine.status(co) == "suspended",
        "状态 " .. tostring(coroutine.status(co)))
end)

-- 观察 stage 推进：0.02s 采样一次，记录 stage 1 被采到的次数。
local watch = { samples_stage1 = 0, last_stage = 0, seen_stage3 = false, restored = false }

local watch_timer
local function on_watch()
    local stage = sequence.stage
    if stage == 1 then
        watch.samples_stage1 = watch.samples_stage1 + 1
    end
    if stage == 3 then
        watch.seen_stage3 = true
        if not watch.restored then
            -- 流程跑完后把 sleep 模式关掉（和 map/tests/bridge_preflight.lua 一样）
            runtime.sleep = false
            watch.restored = true
        end
    end
    watch.last_stage = stage
end

local finish_timer
local function on_finish()
    check("trigger action 里 sleep 后流程继续推进到 stage 3", function()
        assert(watch.seen_stage3, "最后的 stage = " .. tostring(watch.last_stage))
    end)

    check("sleep(0.30) 期间确实挂起了（被采样到 >= 5 次，约 0.1s 以上）", function()
        assert(watch.samples_stage1 >= 5,
            "stage 1 只被采样 " .. tostring(watch.samples_stage1) .. " 次")
    end)

    check("流程跑完后 runtime.sleep 已复位为 false", function()
        assert(watch.restored, "stage 3 之后没有复位 runtime.sleep")
        assert(runtime.sleep == false, "runtime.sleep = " .. tostring(runtime.sleep))
    end)

    jass.PauseTimer(watch_timer)
    jass.DestroyTimer(watch_timer)
    jass.PauseTimer(finish_timer)
    jass.DestroyTimer(finish_timer)
    jass.DestroyTrigger(opening_trigger)
    finish()
end

watch_timer = jass.CreateTimer()
jass.TimerStart(watch_timer, 0.02, true, on_watch)

finish_timer = jass.CreateTimer()
jass.TimerStart(finish_timer, 3.8, false, on_finish)

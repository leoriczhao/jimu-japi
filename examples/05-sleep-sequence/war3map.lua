-- ============================================================
-- 示例 05 · 用 sleep 让 action 线程等一次（jass.sleep）
-- 编号      : 05-sleep-sequence
-- 用途      : 在 trigger action 线程里用 sleep(seconds) 挂起一次，做「进入 → 等一会 →
--             继续」；多步编排用 timer 链。覆盖 require "jass.sleep"、
--             runtime.sleep 开关、"只能在 trigger/action 线程里 sleep" 这条约束。
-- 需要的开关: 无
-- 前置条件  : 空地图；测试不依赖真人输入
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 6 项）
-- 时序      : 全部断言都在 0.02s 轮询 timer 里判定，不赌固定秒数；8s 兜底
-- 实测事实  : 2026-11-16 实机（1.27a，同一份 DLL，6 个独立探针）：
--             (1) sleep 本身可靠：恢复延迟约「参数 + 0.1s」（sleep(0.05)→0.075s，
--                 sleep(0.30)→0.43s），不是数秒级；
--             (2) **多段 sleep 串联不可靠**（探针 p3 通、p7 挂）；
--             (3) **绝不要在 action 顶部加「已运行就 return」的守卫**：挂起后的续跑
--                 依赖 action 被重新进入，守卫会把它掐死（探针 p6：第一段恢复、
--                 第二段 15s 都没回来）。所以本示例只有**一段** sleep、没有守卫；
--             (4) action 确实会被从头重入（p3 在 3.8s 内进了 6 次，每次都把 stage
--                 打回 1），所以状态用 stage 标记、多步编排用 timer 链。
-- 验证状态  : 2026-11-16 静态 + 打包验证通过（tools\verify-examples.ps1）
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"
local runtime = require "jass.runtime"
local sleep = (require "jass.sleep").sleep   -- require 只注册全局 sleep，模块表上也有

-- sleep 的恢复靠 TriggerSleepAction，而它只能唤醒 trigger/action 线程：
-- 在 timer 回调或主线程里 sleep 会直接报错。所以下面把流程塞进 trigger action。
runtime.sleep = true

-- clock 只用来把「实际等了多久」打进日志，作者自己的代码不需要它。
local clock = { tick = 0 }
local clock_timer = jass.CreateTimer()
jass.TimerStart(clock_timer, 0.1, true, function()
    clock.tick = clock.tick + 1
end)

-- 用 stage 标记进度：action 可能被从头重入，不要用「守卫」去挡，也不要假设它只跑一次。
local state = { stage = 0, entries = 0, slept_from_tick = -1, resumed_tick = -1 }

local function opening_action()
    state.entries = state.entries + 1
    print(string.format("[example 05] action entry #%d at tick %d", state.entries, clock.tick))

    -- 一段 sleep：睡之前改一个字段，睡之后再改一个，外面用 0.02s 轮询观察这两个状态。
    state.stage = 1
    state.slept_from_tick = clock.tick
    print(string.format("[example 05] stage 1 at tick %d: 挂起 0.30s", clock.tick))
    sleep(0.30)
    state.stage = 2
    state.resumed_tick = clock.tick
    print(string.format("[example 05] stage 2 at tick %d: 恢复了，接着往下走", clock.tick))
end

-- 一次性 timer 事件触发 action 线程（0.10s 后进入第一次）。
local opening_trigger = jass.CreateTrigger()
jass.TriggerAddAction(opening_trigger, jass.code(opening_action))
jass.TriggerRegisterTimerEvent(opening_trigger, 0.10, false)

-- 多步编排请用 timer 链，而不是多段 sleep 串联（串联实测不可靠）。
-- 这里每段 0.10s 只是为了让日志早于 sleep 的恢复点；真实写法按需求给 0.3s / 1s 都行。
local chain = { step = 1 }
local chain_timer = jass.CreateTimer()
jass.TimerStart(chain_timer, 0.10, false, function()
    jass.DestroyTimer(chain_timer)
    chain.step = 2
    print(string.format("[example 05] timer 链 step 2 at tick %d", clock.tick))
    local step3_timer = jass.CreateTimer()
    jass.TimerStart(step3_timer, 0.10, false, function()
        jass.DestroyTimer(step3_timer)
        chain.step = 3
        print(string.format("[example 05] timer 链 step 3 at tick %d: 多步编排完成", clock.tick))
    end)
end)

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

check("jass.sleep 已加载（模块表 + 全局 sleep 是同一个函数）", function()
    assert(type(sleep) == "function", "模块表上没有 sleep 字段")
    assert(type(_G.sleep) == "function", "require 之后全局 sleep 没有注册")
    assert(sleep == _G.sleep, "模块表上的 sleep 与全局 sleep 不是同一个函数")
end)

check("协程外调用 sleep 会报错（不是静默失败）", function()
    local ok = pcall(sleep, 0.01)
    assert(not ok, "协程外 sleep 竟然成功了")
end)

-- 0.02s 轮询：看到 stage 2 就收尾；不赌固定秒数，另起 8s 兜底。
local watch = {
    seen_stage1 = false,
    seen_stage2 = false,
    stage2_tick = -1,
}
local watch_timer
local fallback_timer
local done = false

local function finalize()
    if done then return end
    done = true

    -- 流程结束后把 sleep 模式关掉（和 map/tests/bridge_preflight.lua 一样）
    runtime.sleep = false

    check("trigger action 至少被进入 1 次（重入是 1.27a 的正常现象，不设上限）", function()
        assert(state.entries >= 1, "action 一次都没进入")
        print(string.format("  [info] action 共进入 %d 次，最后 stage = %d",
            state.entries, state.stage))
    end)

    check("挂起期间定时器看到过 stage == 1（确实睡过去了）", function()
        assert(watch.seen_stage1, "轮询一次都没看到 stage 1")
    end)

    check("之后定时器看到 stage == 2（确实恢复了），日志里带实测耗时", function()
        assert(watch.seen_stage2, "轮询没有看到 stage 2：sleep 之后没有恢复")
        -- action 会被重入，若用「第一次看到 stage 1」到「看到 stage 2」的墙钟差，会把重入的等待算进去（实测 1.1s）。
        -- 这里用 action 自己在 sleep 前后记的两个 tick，量的是真正恢复了的那一段。
        local waited_ticks = state.resumed_tick - state.slept_from_tick
        print(string.format("  [info] 最后一次 sleep：tick %d → tick %d，实测等了约 %.1fs（参数 0.30s）",
            state.slept_from_tick, state.resumed_tick, waited_ticks * 0.1))
    end)

    check("流程跑完后 runtime.sleep 已复位为 false", function()
        assert(runtime.sleep == false, "runtime.sleep = " .. tostring(runtime.sleep))
    end)

    jass.PauseTimer(watch_timer)
    jass.DestroyTimer(watch_timer)
    jass.PauseTimer(fallback_timer)
    jass.DestroyTimer(fallback_timer)
    jass.PauseTimer(clock_timer)
    jass.DestroyTimer(clock_timer)
    -- timer 链里的 timer 都是自毁的一次性 timer，这里不用再收。
    jass.DestroyTrigger(opening_trigger)
    finish()
end

local function on_watch()
    if state.stage == 1 and not watch.seen_stage1 then
        watch.seen_stage1 = true
    end
    if state.stage == 2 and not watch.seen_stage2 then
        watch.seen_stage2 = true
        watch.stage2_tick = clock.tick
        finalize()
    end
end

watch_timer = jass.CreateTimer()
jass.TimerStart(watch_timer, 0.02, true, on_watch)

-- 兜底：单段 sleep 实测 0.4s 级恢复，8s 足够；真挂了也要正常打 Results，不 hang 住地图。
fallback_timer = jass.CreateTimer()
jass.TimerStart(fallback_timer, 8.0, false, function()
    print(string.format("[example 05] 8s 兜底触发：entries=%d stage=%d", state.entries, state.stage))
    finalize()
end)
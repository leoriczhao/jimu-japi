-- Pre-suite JASS <-> Lua bridge probes.
--
-- This module is loaded from war3map.lua before LoadScript returns, so the
-- handlers are registered before war3map.j's main() calls UnitId("...").
-- It also runs a real sleep/resume probe: runtime.sleep is enabled, the sleep
-- action runs on a trigger thread (the thread type TriggerSleepAction can
-- resume), and a timer observes that the action was suspended and then resumed.

local jass = require "jass.common"
local japi = require "jass.japi"
local runtime = require "jass.runtime"
local sleep_module = require "jass.sleep"
local sleep = sleep_module.sleep

local M = {}

local state = {
    stage = 0,          -- 0 = not entered, 1 = sleeping, 2 = resumed
    suspended = false,  -- a watch tick observed stage 1
    ticks = 0,
    error = nil,
    done = false,
}
_G.__JAPI_PREFLIGHT = state
_G.__JAPI_ERROR_MESSAGES = {}
_G.__JAPI_LUA_CALLBACK1 = 0

local function log(message)
    print("[preflight] " .. tostring(message))
end

runtime.error_handle = function(message)
    local text = tostring(message)
    local messages = _G.__JAPI_ERROR_MESSAGES
    messages[#messages + 1] = text
    if not text:match("expected bridge probe error") then
        log("lua error: " .. text)
    end
end

-- Called from war3map.j through UnitId("Name") + hashtable slots.
japi("LuaCallbackBridge", "()V", function()
    _G.__JAPI_LUA_CALLBACK1 = _G.__JAPI_LUA_CALLBACK1 + 1
end)

japi("LuaBridgeProbe", "(II)I", function(a, b)
    return a + b
end)

japi("LuaErrorProbe", "()I", function()
    error("expected bridge probe error")
end)

japi("LuaHandleEcho", "(Hplayer;)Hplayer;", function(handle)
    return handle
end)

local function finish_sleep_test(reason)
    if state.done then return end
    state.done = true
    if reason then state.error = reason end
    runtime.sleep = false
end

-- Reserve the timer handles up front. The callbacks below are converted to
-- JASS code while runtime.sleep is true, which selects the main-thread trampoline.
function M.start()
    runtime.sleep = true

    -- Use a trigger thread rather than a raw timer callback: TriggerSleepAction
    -- resumes trigger/action threads, while a timer callback thread is not a
    -- persistent JASS thread.
    local sleep_trigger = jass.CreateTrigger()
    local sleep_action = jass.code(function()
        state.stage = 1
        sleep(0.30)
        state.stage = 2
    end)
    jass.TriggerAddAction(sleep_trigger, sleep_action)
    jass.TriggerRegisterTimerEvent(sleep_trigger, 0.10, false)

    local watch_timer = jass.CreateTimer()

    jass.TimerStart(watch_timer, 0.02, true, function()
        state.ticks = state.ticks + 1
        if state.stage == 1 then
            state.suspended = true
        end
        if state.stage == 2 then
            finish_sleep_test(nil)
            jass.PauseTimer(watch_timer)
            jass.DestroyTimer(watch_timer)
            jass.DestroyTrigger(sleep_trigger)
            return
        end
        if state.ticks >= 150 then  -- 3s at the timer's nominal tick
            finish_sleep_test("sleep callback did not resume")
            jass.PauseTimer(watch_timer)
            jass.DestroyTimer(watch_timer)
        end
    end)
end

return M

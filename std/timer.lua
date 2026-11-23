-- std/timer.lua — pooled zero-leak timers + shared 30Hz frame loop.
--
-- Features:
--   * Timer.after(delay, fn)         -> one-shot timer (returns handle with :cancel())
--   * Timer.loop(interval, fn, max)  -> repeating timer (return false from fn to stop)
--   * Timer.frame(fn)                -> shared 0.03s tick loop (zero per-listener JASS handles)
--   * Timer.stats()                  -> { pooled, active, frame_listeners }
--   * Internal timer pool recycles JASS timer handles (up to 64) to avoid handle leaks.

local jass = require "jass.common"
local util = require "std.util"

local Timer = {}

local MAX_POOL = 64
local FRAME_DT = 0.03

local pool = {}
local pool_n = 0
local active_count = 0

local function acquire_raw()
    if pool_n > 0 then
        local t = pool[pool_n]
        pool[pool_n] = nil
        pool_n = pool_n - 1
        return t
    end
    return jass.CreateTimer()
end

local function release_raw(t)
    if not t then return end
    jass.PauseTimer(t)
    if pool_n < MAX_POOL then
        pool_n = pool_n + 1
        pool[pool_n] = t
    else
        jass.DestroyTimer(t)
    end
end

local HandleMT = {}
HandleMT.__index = HandleMT

function HandleMT:cancel()
    if not self.active then return false end
    self.active = false
    active_count = active_count - 1
    local raw = self._raw
    self._raw = nil
    release_raw(raw)
    return true
end

function HandleMT:is_active()
    return self.active == true
end

--- Schedule a one-shot callback after `delay` seconds.
function Timer.after(delay, fn)
    assert(type(delay) == "number" and delay >= 0, "Timer.after: delay must be >= 0")
    assert(type(fn) == "function", "Timer.after: fn must be a function")

    local raw = acquire_raw()
    local handle = setmetatable({
        _raw = raw,
        active = true,
    }, HandleMT)
    active_count = active_count + 1

    jass.TimerStart(raw, delay, false, function()
        if not handle.active then return end
        handle.active = false
        active_count = active_count - 1
        handle._raw = nil
        release_raw(raw)
        util.safe_call(fn, handle)
    end)

    return handle
end

--- Schedule a repeating callback every `interval` seconds.
--- Optional `max_ticks` stops automatically after N executions.
--- Returning `false` from `fn(handle, tick)` also cancels the timer immediately.
function Timer.loop(interval, fn, max_ticks)
    assert(type(interval) == "number" and interval > 0, "Timer.loop: interval must be > 0")
    assert(type(fn) == "function", "Timer.loop: fn must be a function")

    local raw = acquire_raw()
    local handle = setmetatable({
        _raw = raw,
        active = true,
        ticks = 0,
    }, HandleMT)
    active_count = active_count + 1

    jass.TimerStart(raw, interval, true, function()
        if not handle.active then return end
        handle.ticks = handle.ticks + 1
        local ok, keep = util.safe_call(fn, handle, handle.ticks)
        if not handle.active then return end
        if (ok and keep == false) or (max_ticks and handle.ticks >= max_ticks) then
            handle:cancel()
        end
    end)

    return handle
end

-- ── Shared frame loop (single JASS timer drives all frame listeners) ────────

local frame_listeners = {}
local frame_order = {}
local frame_next_id = 1
local frame_count = 0
local frame_raw = nil

local function ensure_frame_timer()
    if frame_raw then return end
    frame_raw = acquire_raw()
    jass.TimerStart(frame_raw, FRAME_DT, true, function()
        -- Snapshot order so listeners may safely cancel themselves or add new ones.
        local snap = {}
        local n = 0
        for i = 1, #frame_order do
            local id = frame_order[i]
            if frame_listeners[id] then
                n = n + 1
                snap[n] = id
            end
        end
        for i = 1, n do
            local id = snap[i]
            local fn = frame_listeners[id]
            if fn then
                local ok, keep = util.safe_call(fn, FRAME_DT)
                if ok and keep == false then
                    if frame_listeners[id] then
                        frame_listeners[id] = nil
                        frame_count = frame_count - 1
                    end
                end
            end
        end
        -- Compact dead entries periodically.
        if #frame_order > frame_count * 2 + 8 then
            local compact = {}
            local k = 0
            for i = 1, #frame_order do
                local id = frame_order[i]
                if frame_listeners[id] then
                    k = k + 1
                    compact[k] = id
                end
            end
            frame_order = compact
        end
        if frame_count == 0 and frame_raw then
            local raw = frame_raw
            frame_raw = nil
            release_raw(raw)
        end
    end)
end

--- Register a callback on the shared ~33Hz (0.03s) frame ticker.
--- Returning `false` from `fn(dt)` automatically unsubscribes.
function Timer.frame(fn)
    assert(type(fn) == "function", "Timer.frame: fn must be a function")
    local id = frame_next_id
    frame_next_id = frame_next_id + 1
    frame_listeners[id] = fn
    frame_order[#frame_order + 1] = id
    frame_count = frame_count + 1
    ensure_frame_timer()

    local sub = { active = true }
    function sub:cancel()
        if not self.active then return false end
        self.active = false
        if frame_listeners[id] then
            frame_listeners[id] = nil
            frame_count = frame_count - 1
        end
        return true
    end
    function sub:is_active()
        return self.active and frame_listeners[id] ~= nil
    end
    return sub
end

function Timer.frame_dt()
    return FRAME_DT
end

function Timer.stats()
    return {
        pooled = pool_n,
        active = active_count,
        frame_listeners = frame_count,
    }
end

return Timer

-- std/signal.lua — UI-agnostic fine-grained reactive core (SolidJS / Fusion model).
--
-- Primitives:
--   local s   = Signal.state(initial [, equals])  -> s:get(), s:set(v), s:peek(), s:update(fn)
--   local c   = Signal.computed(fn)               -> auto-tracked derived read-only signal
--   local e   = Signal.effect(fn)                 -> auto-tracked reactive side-effect (supports cleanup fn)
--   Signal.batch(fn)                              -> coalesce multiple :set() calls into one flush
--   Signal.untrack(fn)                            -> read signals without tracking dependencies
--   local sc  = Signal.scope()                    -> lifecycle owner: sc:run(fn), sc:on_cleanup(fn), sc:destroy()
--   Signal.is_signal(v)                           -> true for state / computed signals

local Signal = {}

local SIGNAL_TAG = {}

-- Dynamic stacks for dependency tracking and scope ownership.
local current_observer = nil
local current_scope = nil
local batch_depth = 0
local pending_effects = {}
local pending_list = {}

local function safe_call(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        print("[std.signal] error: " .. tostring(err))
    end
    return ok, err
end

-- ── Dependency linking ─────────────────────────────────────────────────────

local function unlink_deps(obs)
    local deps = obs._deps
    if not deps then return end
    for i = 1, #deps do
        local src = deps[i]
        if src._subs then
            src._subs[obs] = nil
        end
        deps[i] = nil
    end
end

local function track(src)
    local obs = current_observer
    if not obs or obs._disposed then return end
    if not src._subs[obs] then
        src._subs[obs] = true
        obs._deps[#obs._deps + 1] = src
    end
end

local function flush_effects()
    if batch_depth > 0 then return end
    while #pending_list > 0 do
        local list = pending_list
        pending_list = {}
        for i = 1, #list do
            local eff = list[i]
            pending_effects[eff] = nil
            if not eff._disposed then
                eff:_run()
            end
        end
    end
end

local function notify_subs(src)
    -- Snapshot subscribers because running effects/computeds may mutate _subs.
    local snap = {}
    local n = 0
    for sub in pairs(src._subs) do
        n = n + 1
        snap[n] = sub
    end
    for i = 1, n do
        local sub = snap[i]
        if not sub._disposed then
            if sub._kind == "computed" then
                if not sub._dirty then
                    sub._dirty = true
                    notify_subs(sub)
                end
            elseif sub._kind == "effect" then
                if not pending_effects[sub] then
                    pending_effects[sub] = true
                    pending_list[#pending_list + 1] = sub
                end
            end
        end
    end
    flush_effects()
end

-- ── Scope (hierarchical lifecycle ownership) ───────────────────────────────

local ScopeMT = {}
ScopeMT.__index = ScopeMT

function ScopeMT:on_cleanup(fn)
    assert(type(fn) == "function", "Scope:on_cleanup expects a function")
    if self._disposed then
        safe_call(fn)
        return
    end
    self._cleanups[#self._cleanups + 1] = fn
end

function ScopeMT:run(fn, ...)
    assert(not self._disposed, "Scope:run called on destroyed scope")
    local prev = current_scope
    current_scope = self
    local ok, r1, r2, r3 = pcall(fn, ...)
    current_scope = prev
    if not ok then error(r1, 2) end
    return r1, r2, r3
end

function ScopeMT:child()
    local c = Signal.scope()
    if self._disposed then
        c:destroy()
    else
        self._children[#self._children + 1] = c
    end
    return c
end

function ScopeMT:destroy()
    if self._disposed then return false end
    self._disposed = true

    -- Destroy child scopes first (reverse creation order).
    for i = #self._children, 1, -1 do
        self._children[i]:destroy()
        self._children[i] = nil
    end
    -- Run cleanups in reverse registration order (LIFO).
    for i = #self._cleanups, 1, -1 do
        safe_call(self._cleanups[i])
        self._cleanups[i] = nil
    end
    return true
end

function ScopeMT:is_destroyed()
    return self._disposed == true
end

function Signal.scope()
    return setmetatable({
        _disposed = false,
        _cleanups = {},
        _children = {},
    }, ScopeMT)
end

function Signal.current_scope()
    return current_scope
end

function Signal.on_cleanup(fn)
    if current_scope then
        current_scope:on_cleanup(fn)
    end
end

-- ── State ──────────────────────────────────────────────────────────────────

local StateMT = {}
StateMT.__index = StateMT

function StateMT:get()
    track(self)
    return self._value
end

function StateMT:peek()
    return self._value
end

function StateMT:set(next_val)
    if self._equals then
        if self._equals(self._value, next_val) then return false end
    else
        if self._value == next_val then return false end
    end
    self._value = next_val
    notify_subs(self)
    return true
end

function StateMT:update(fn)
    return self:set(fn(self._value))
end

function Signal.state(initial, equals)
    return setmetatable({
        _tag = SIGNAL_TAG,
        _kind = "state",
        _value = initial,
        _equals = equals,
        _subs = {},
    }, StateMT)
end

-- ── Computed ───────────────────────────────────────────────────────────────

local ComputedMT = {}
ComputedMT.__index = ComputedMT

function ComputedMT:_eval()
    unlink_deps(self)
    local prev = current_observer
    current_observer = self
    local ok, val = pcall(self._fn)
    current_observer = prev
    if not ok then
        error(val, 2)
    end
    self._value = val
    self._dirty = false
end

function ComputedMT:get()
    if self._dirty and not self._disposed then
        self:_eval()
    end
    track(self)
    return self._value
end

function ComputedMT:peek()
    if self._dirty and not self._disposed then
        self:_eval()
    end
    return self._value
end

function ComputedMT:dispose()
    if self._disposed then return end
    self._disposed = true
    unlink_deps(self)
    self._subs = {}
end

function Signal.computed(fn)
    assert(type(fn) == "function", "Signal.computed expects a function")
    local self = setmetatable({
        _tag = SIGNAL_TAG,
        _kind = "computed",
        _fn = fn,
        _value = nil,
        _dirty = true,
        _disposed = false,
        _deps = {},
        _subs = {},
    }, ComputedMT)
    if current_scope then
        current_scope:on_cleanup(function() self:dispose() end)
    end
    return self
end

-- ── Effect ─────────────────────────────────────────────────────────────────

local EffectMT = {}
EffectMT.__index = EffectMT

function EffectMT:_run()
    if self._disposed then return end
    if self._cleanup then
        local c = self._cleanup
        self._cleanup = nil
        safe_call(c)
    end
    unlink_deps(self)
    local prev_obs = current_observer
    current_observer = self
    local ok, res = pcall(self._fn)
    current_observer = prev_obs
    if not ok then
        print("[std.signal] effect error: " .. tostring(res))
    elseif type(res) == "function" then
        self._cleanup = res
    end
end

function EffectMT:dispose()
    if self._disposed then return end
    self._disposed = true
    pending_effects[self] = nil
    if self._cleanup then
        local c = self._cleanup
        self._cleanup = nil
        safe_call(c)
    end
    unlink_deps(self)
end

function Signal.effect(fn)
    assert(type(fn) == "function", "Signal.effect expects a function")
    local self = setmetatable({
        _kind = "effect",
        _fn = fn,
        _deps = {},
        _cleanup = nil,
        _disposed = false,
    }, EffectMT)
    if current_scope then
        current_scope:on_cleanup(function() self:dispose() end)
    end
    self:_run()
    return self
end

-- ── Batch & Untrack & Helpers ──────────────────────────────────────────────

function Signal.batch(fn)
    batch_depth = batch_depth + 1
    local ok, err = pcall(fn)
    batch_depth = batch_depth - 1
    if batch_depth == 0 then
        flush_effects()
    end
    if not ok then error(err, 2) end
end

function Signal.untrack(fn, ...)
    local prev = current_observer
    current_observer = nil
    local ok, r1, r2, r3 = pcall(fn, ...)
    current_observer = prev
    if not ok then error(r1, 2) end
    return r1, r2, r3
end

function Signal.is_signal(v)
    return type(v) == "table" and v._tag == SIGNAL_TAG
end

--- Read either a Signal or a plain static value transparently.
function Signal.read(v)
    if Signal.is_signal(v) then
        return v:get()
    end
    return v
end

return Signal

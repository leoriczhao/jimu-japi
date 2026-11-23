-- std/effect.lua — zero-leak special effect helper with optional duration & 3D EX* transforms.

local jass = require "jass.common"
local Timer = require "std.timer"

local Effect = {}
local EffectMT = {}
EffectMT.__index = EffectMT

local function get_japi()
    local ok, japi = pcall(require, "jass.japi")
    return ok and japi or nil
end

function EffectMT:destroy()
    if self._destroyed then return false end
    self._destroyed = true
    if self._timer then
        self._timer:cancel()
        self._timer = nil
    end
    if self._handle then
        jass.DestroyEffect(self._handle)
        self._handle = nil
    end
    return true
end

function EffectMT:handle()
    return self._handle
end

function EffectMT:set_pos(x, y, z)
    if self._destroyed or not self._handle then return end
    local japi = get_japi()
    if not japi then return end
    if x and y and japi.EXSetEffectXY then japi.EXSetEffectXY(self._handle, x, y) end
    if z and japi.EXSetEffectZ then japi.EXSetEffectZ(self._handle, z) end
end

function EffectMT:set_scale(scale)
    if self._destroyed or not self._handle then return end
    local japi = get_japi()
    if japi and japi.EXSetEffectSize then japi.EXSetEffectSize(self._handle, scale) end
end

function EffectMT:set_speed(speed)
    if self._destroyed or not self._handle then return end
    local japi = get_japi()
    if japi and japi.EXSetEffectSpeed then japi.EXSetEffectSpeed(self._handle, speed) end
end

local function wrap_effect(raw, duration, opts)
    if not raw then return nil end
    local self = setmetatable({
        _handle = raw,
        _destroyed = false,
        _timer = nil,
    }, EffectMT)

    if opts then
        if opts.z then self:set_pos(nil, nil, opts.z) end
        if opts.scale then self:set_scale(opts.scale) end
        if opts.speed then self:set_speed(opts.speed) end
    end

    if duration == nil or duration <= 0 then
        -- War3 plays a special effect's death/birth animation cleanly when destroyed immediately.
        self:destroy()
    else
        self._timer = Timer.after(duration, function()
            self:destroy()
        end)
    end
    return self
end

--- Spawn a point special effect.
--- `duration`: nil/0 = burst (immediate DestroyEffect); >0 = auto-destroy after seconds;
---             pass `false` for persistent effect (caller calls `fx:destroy()`).
function Effect.play(model, x, y, duration, opts)
    local raw = jass.AddSpecialEffect(model, x, y)
    if duration == false then
        local self = setmetatable({ _handle = raw, _destroyed = false }, EffectMT)
        if opts then
            if opts.z then self:set_pos(nil, nil, opts.z) end
            if opts.scale then self:set_scale(opts.scale) end
            if opts.speed then self:set_speed(opts.speed) end
        end
        return self
    end
    return wrap_effect(raw, duration, opts)
end

--- Attach a special effect to a unit (Unit wrapper or raw handle) at `attach_point` (default "origin").
function Effect.attach(model, unit, attach_point, duration)
    local uh = (type(unit) == "table" and unit.handle) and unit:handle() or unit
    local raw = jass.AddSpecialEffectTarget(model, uh, attach_point or "origin")
    if duration == false then
        return setmetatable({ _handle = raw, _destroyed = false }, EffectMT)
    end
    return wrap_effect(raw, duration, nil)
end

return Effect

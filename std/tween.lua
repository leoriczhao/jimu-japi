-- std/tween.lua — lightweight frame-driven easing & color interpolation engine.
--
-- Driven by std.timer.frame (single shared timer, zero per-tween JASS handles).
--
-- Example:
--   local tw = Tween.to({
--       from = 0, to = 255, duration = 0.35, ease = "out_cubic",
--       on_update = function(v) label:set_color(util.rgba(255, 255, 255, v)) end,
--       on_complete = function() ... end,
--   })

local Timer = require "std.timer"
local util  = require "std.util"

local Tween = {}

local easings = {
    linear = function(t) return t end,
    in_quad = function(t) return t * t end,
    out_quad = function(t) return t * (2 - t) end,
    in_out_quad = function(t)
        if t < 0.5 then return 2 * t * t end
        return -1 + (4 - 2 * t) * t
    end,
    in_cubic = function(t) return t * t * t end,
    out_cubic = function(t)
        local u = t - 1
        return u * u * u + 1
    end,
    in_out_cubic = function(t)
        if t < 0.5 then return 4 * t * t * t end
        local u = 2 * t - 2
        return 0.5 * u * u * u + 1
    end,
    out_back = function(t)
        local c1 = 1.70158
        local c3 = c1 + 1
        local u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    end,
}

Tween.easings = easings

--- Interpolate two 0xAARRGGBB integers smoothly at factor t in [0..1].
function Tween.color(c1, c2, t)
    t = util.clamp(t, 0, 1)
    local a1, r1, g1, b1 = (c1 >> 24) & 0xFF, (c1 >> 16) & 0xFF, (c1 >> 8) & 0xFF, c1 & 0xFF
    local a2, r2, g2, b2 = (c2 >> 24) & 0xFF, (c2 >> 16) & 0xFF, (c2 >> 8) & 0xFF, c2 & 0xFF
    return util.argb(
        a1 + (a2 - a1) * t,
        r1 + (r2 - r1) * t,
        g1 + (g2 - g1) * t,
        b1 + (b2 - b1) * t
    )
end

--- Animate a numeric value from `opts.from` to `opts.to` over `opts.duration` seconds.
function Tween.to(opts)
    assert(type(opts) == "table", "Tween.to expects an options table")
    local from = assert(opts.from, "Tween.to: missing 'from'")
    local to = assert(opts.to, "Tween.to: missing 'to'")
    local duration = opts.duration or 0.25
    local on_update = opts.on_update
    local on_complete = opts.on_complete

    local ease_fn = easings.out_quad
    if type(opts.ease) == "function" then
        ease_fn = opts.ease
    elseif type(opts.ease) == "string" then
        ease_fn = assert(easings[opts.ease], "Tween.to: unknown easing '" .. opts.ease .. "'")
    end

    local handle = {
        active = true,
        finished = false,
        elapsed = 0,
        value = from,
    }

    if duration <= 0 then
        handle.active = false
        handle.finished = true
        handle.value = to
        if on_update then util.safe_call(on_update, to, 1.0) end
        if on_complete then util.safe_call(on_complete, handle) end
        function handle:cancel() return false end
        return handle
    end

    if on_update then
        util.safe_call(on_update, from, 0.0)
    end

    local sub
    sub = Timer.frame(function(dt)
        if not handle.active then return false end
        handle.elapsed = handle.elapsed + dt
        local t = util.clamp(handle.elapsed / duration, 0, 1)
        local eased = ease_fn(t)
        local val = from + (to - from) * eased
        handle.value = val
        if on_update then
            util.safe_call(on_update, val, t)
        end
        if t >= 1 then
            handle.active = false
            handle.finished = true
            if on_complete then
                util.safe_call(on_complete, handle)
            end
            return false
        end
        return true
    end)

    function handle:cancel()
        if not self.active then return false end
        self.active = false
        if sub then sub:cancel() end
        return true
    end

    return handle
end

return Tween

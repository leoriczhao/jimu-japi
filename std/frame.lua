-- std/frame.lua — General-purpose DzFrame backend adapter (auto-discovered via jass.japi).
--
-- Coordinate space (War3 native UI):
--   X in [0.0, 0.8], Y in [0.0, 0.6], origin (0, 0) = bottom-left.
--
-- Key guarantees:
--   * Zero hardcoded textures or map-specific assets.
--   * Stable event slots: each (frame, event_id) registers jass.code() +
--     DzFrameSetScriptByCode() AT MOST ONCE and dispatches through a mutable
--     Lua slot, preventing trampoline leaks when handlers are swapped.
--   * Deterministic cleanup: Frame.destroy(f) clears all rooted Lua event
--     slots before destroying/hiding the native frame.

local jass = require "jass.common"
local japi = require "jass.japi"

local Frame = {
    ANCHOR = {
        TOPLEFT     = 0,
        TOP         = 1,
        TOPRIGHT    = 2,
        LEFT        = 3,
        CENTER      = 4,
        RIGHT       = 5,
        BOTTOMLEFT  = 6,
        BOTTOM      = 7,
        BOTTOMRIGHT = 8,
    },
    EVENT = {
        CLICK        = 1,
        ENTER        = 2,
        LEAVE        = 3,
        UP           = 4,
        DOWN         = 5,
        WHEEL        = 6,
        DOUBLE_CLICK = 12,
    },
    ALIGN = {
        TOPLEFT     = 0,
        TOP         = 1,
        TOPRIGHT    = 2,
        LEFT        = 10,
        CENTER      = 18,
        RIGHT       = 34,
        BOTTOMLEFT  = 32,
        BOTTOM      = 33,
        BOTTOMRIGHT = 34,
    },
}

local seq = 0
-- event_slots[frame_handle] = { [event_id] = { fn = callback, root = dispatcher } }
local event_slots = {}

local function has_fn(name)
    local ok, fn = pcall(function() return japi[name] end)
    return ok and type(fn) == "function"
end

function Frame.is_available()
    return has_fn("DzGetGameUI")
       and has_fn("DzCreateFrameByTagName")
       and has_fn("DzFrameSetSize")
       and has_fn("DzFrameSetAbsolutePoint")
       and has_fn("DzFrameSetPoint")
       and has_fn("DzFrameSetText")
       and has_fn("DzFrameSetTexture")
       and has_fn("DzFrameShow")
       and has_fn("DzFrameSetScriptByCode")
end

function Frame.game_ui()
    return japi.DzGetGameUI()
end

function Frame.next_name(prefix)
    seq = seq + 1
    return (prefix or "ui_f") .. "_" .. tostring(seq)
end

function Frame.resolve_anchor(a)
    if type(a) == "number" then return a end
    if type(a) == "string" then
        local v = Frame.ANCHOR[a:upper()]
        if v ~= nil then return v end
    end
    return Frame.ANCHOR.TOPLEFT
end

function Frame.resolve_align(a)
    if type(a) == "number" then return a end
    if type(a) == "string" then
        local v = Frame.ALIGN[a:upper()]
        if v ~= nil then return v end
    end
    return Frame.ALIGN.LEFT
end

--- Create a native DzFrame by tag name ("BACKDROP", "TEXT", "BUTTON", "FRAME", "SPRITE", "EDITBOX", ...).
function Frame.create(tag, parent, template, name, id)
    local p = parent or Frame.game_ui()
    local fname = name or Frame.next_name(tag)
    local tpl = (template ~= nil) and template or "template"
    local f = japi.DzCreateFrameByTagName(tag, fname, p, tpl, id or 0)
    if (not f or f == 0) and tpl ~= "" then
        f = japi.DzCreateFrameByTagName(tag, Frame.next_name(tag), p, "", id or 0)
    end
    return f
end

--- Create a frame from a loaded FDF definition via DzCreateFrame.
function Frame.create_from_fdf(name, parent, id)
    if has_fn("DzCreateFrame") then
        return japi.DzCreateFrame(name, parent or Frame.game_ui(), id or 0)
    end
    return 0
end

function Frame.destroy(f)
    if not f or f == 0 then return end
    event_slots[f] = nil
    if has_fn("DzFrameShow") then
        pcall(japi.DzFrameShow, f, false)
    end
    if has_fn("DzDestroyFrame") then
        pcall(japi.DzDestroyFrame, f)
    end
end

function Frame.set_size(f, w, h)
    japi.DzFrameSetSize(f, w, h)
end

function Frame.set_abs_point(f, anchor, x, y)
    japi.DzFrameSetAbsolutePoint(f, Frame.resolve_anchor(anchor), x or 0.0, y or 0.0)
end

function Frame.set_point(f, anchor, rel, rel_anchor, x, y)
    japi.DzFrameSetPoint(
        f,
        Frame.resolve_anchor(anchor),
        rel or Frame.game_ui(),
        Frame.resolve_anchor(rel_anchor or anchor),
        x or 0.0,
        y or 0.0
    )
end

function Frame.clear_points(f)
    if has_fn("DzFrameClearAllPoints") then
        pcall(japi.DzFrameClearAllPoints, f)
    end
end

function Frame.set_all_points(f, rel)
    if has_fn("DzFrameSetAllPoints") then
        pcall(japi.DzFrameSetAllPoints, f, rel or Frame.game_ui())
    else
        Frame.set_point(f, 0, rel, 0, 0.0, 0.0)
        Frame.set_point(f, 8, rel, 8, 0.0, 0.0)
    end
end

function Frame.set_texture(f, path, flag)
    japi.DzFrameSetTexture(f, path or "", flag or 0)
end

function Frame.set_text(f, text)
    japi.DzFrameSetText(f, tostring(text or ""))
end

function Frame.get_text(f)
    if has_fn("DzFrameGetText") then
        return japi.DzFrameGetText(f) or ""
    end
    return ""
end

function Frame.set_font(f, font_path, size, flags)
    if has_fn("DzFrameSetFont") then
        pcall(japi.DzFrameSetFont, f, font_path or "Fonts\\dfst-m3u.ttf", size or 0.011, flags or 0)
    end
end

function Frame.set_align(f, align)
    if has_fn("DzFrameSetTextAlignment") then
        pcall(japi.DzFrameSetTextAlignment, f, Frame.resolve_align(align))
    end
end

function Frame.set_alpha(f, alpha)
    if has_fn("DzFrameSetAlpha") then
        pcall(japi.DzFrameSetAlpha, f, math.floor(alpha))
    end
end

function Frame.set_color(f, argb)
    if has_fn("DzFrameSetVertexColor") then
        pcall(japi.DzFrameSetVertexColor, f, argb)
    end
end

function Frame.set_enable(f, enabled)
    if has_fn("DzFrameSetEnable") then
        pcall(japi.DzFrameSetEnable, f, enabled and true or false)
    end
end

function Frame.show(f, visible)
    japi.DzFrameShow(f, visible and true or false)
end

function Frame.set_clip(f, clip)
    if has_fn("DzFrameSetClip") then
        pcall(japi.DzFrameSetClip, f, clip and true or false)
    end
end

function Frame.set_priority(f, prio)
    if has_fn("DzFrameSetPriority") then
        pcall(japi.DzFrameSetPriority, f, math.floor(prio))
    end
end

function Frame.set_scale(f, scale)
    if has_fn("DzFrameSetScale") then
        pcall(japi.DzFrameSetScale, f, scale)
    end
end

function Frame.set_model(f, path, model_type, flag)
    if has_fn("DzFrameSetModel") then
        pcall(japi.DzFrameSetModel, f, path or "", model_type or 0, flag or 0)
    end
end

function Frame.set_focus(f, focused)
    if has_fn("DzFrameSetFocus") then
        pcall(japi.DzFrameSetFocus, f, focused and true or false)
    end
end

function Frame.get_wheel_delta()
    if has_fn("DzGetWheelDelta") then
        return japi.DzGetWheelDelta() or 0
    end
    return 0
end

--- Attach or replace an event listener on a frame using a stable trampoline slot.
function Frame.on(f, event_id, fn)
    if not f or f == 0 then return end
    local bucket = event_slots[f]
    if not bucket then
        bucket = {}
        event_slots[f] = bucket
    end
    local slot = bucket[event_id]
    if slot then
        slot.fn = fn
        return
    end
    slot = { fn = fn }
    slot.root = function()
        local cb = slot.fn
        if cb then
            local ok, err = pcall(cb, f)
            if not ok then
                print("[std.frame] event callback error: " .. tostring(err))
            end
        end
    end
    bucket[event_id] = slot
    japi.DzFrameSetScriptByCode(f, event_id, jass.code(slot.root), false)
end

function Frame.off(f, event_id)
    local bucket = event_slots[f]
    if bucket and bucket[event_id] then
        bucket[event_id].fn = nil
    end
end

function Frame.active_event_frames()
    local n = 0
    for _ in pairs(event_slots) do n = n + 1 end
    return n
end

return Frame

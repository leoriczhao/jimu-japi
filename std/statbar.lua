-- std/statbar.lua — high-level themes & controls for native 1.27a CStatBar (16 APIs).
--
-- Themes:
--   StatBar.apply_theme("rpg")     -- native blue mana bar + offscreen/phantom cull
--   StatBar.apply_theme("moba")    -- crisp cyan mana bar + offscreen cull + P0 gold / ally green / enemy red
--   StatBar.apply_theme("clean")   -- vanilla bars + offscreen/phantom bar bug fix only
--   StatBar.apply_theme("vanilla") -- reset all overrides to stock 1.27a

local jass = require "jass.common"
local japi = require "jass.japi"
local util = require "std.util"

local StatBar = {}

local function unwrap_unit(u)
    if type(u) == "table" and u.handle then return u:handle() end
    return u
end

local function unwrap_player(p)
    if type(p) == "table" and p.handle then return p:handle() end
    if type(p) == "number" then return jass.Player(p) end
    return p
end

function StatBar.enable_mana_bar(enabled)
    if japi.EXSetManaBarEnabled then japi.EXSetManaBarEnabled(enabled == true) end
end

function StatBar.is_mana_bar_enabled()
    return japi.EXGetManaBarEnabled and japi.EXGetManaBarEnabled() == true or false
end

function StatBar.enable_offscreen_cull(enabled)
    if japi.EXSetOffscreenBarCull then japi.EXSetOffscreenBarCull(enabled == true) end
end

function StatBar.is_offscreen_cull_enabled()
    return japi.EXGetOffscreenBarCull and japi.EXGetOffscreenBarCull() == true or false
end

function StatBar.set_mana_style(opts)
    opts = opts or {}
    if opts.color and japi.EXSetManaBarColor then
        japi.EXSetManaBarColor(opts.color)
    end
    if opts.height and japi.EXSetManaBarHeight then
        japi.EXSetManaBarHeight(opts.height)
    end
    if opts.offset_y and japi.EXSetManaBarOffsetY then
        japi.EXSetManaBarOffsetY(opts.offset_y)
    end
end

function StatBar.style_unit(unit, opts)
    local h = unwrap_unit(unit)
    if not h or not opts then return end
    if opts.hp_color and japi.EXSetUnitHPBarColor then
        japi.EXSetUnitHPBarColor(h, opts.hp_color)
    end
    if (opts.hp_scale_x or opts.hp_scale_y) and japi.EXSetUnitHPBarScale then
        japi.EXSetUnitHPBarScale(h, opts.hp_scale_x or 1.0, opts.hp_scale_y or 1.0)
    end
    if opts.hp_visible ~= nil and japi.EXSetUnitHPBarVisible then
        japi.EXSetUnitHPBarVisible(h, opts.hp_visible == true)
    end
    if opts.mana_color and japi.EXSetUnitManaBarColor then
        japi.EXSetUnitManaBarColor(h, opts.mana_color)
    end
    if opts.mana_visible ~= nil and japi.EXSetUnitManaBarVisible then
        japi.EXSetUnitManaBarVisible(h, opts.mana_visible == true)
    end
end

function StatBar.style_type(type_id, opts)
    opts = opts or {}
    if japi.EXSetUnitTypeHPBarStyle then
        japi.EXSetUnitTypeHPBarStyle(
            util.fourcc(type_id),
            opts.color or 0,
            opts.scale_x or 1.0,
            opts.scale_y or 1.0
        )
    end
end

function StatBar.style_player(player, argb)
    local ph = unwrap_player(player)
    if ph and japi.EXSetPlayerHPBarColor then
        japi.EXSetPlayerHPBarColor(ph, argb)
    end
end

function StatBar.reset_unit(unit)
    local h = unwrap_unit(unit)
    if h and japi.EXResetUnitHPBar then japi.EXResetUnitHPBar(h) end
end

function StatBar.reset_all()
    if japi.EXResetAllStatBars then japi.EXResetAllStatBars() end
end

--- Apply a named visual preset ("rpg", "moba", "clean", "vanilla").
function StatBar.apply_theme(name)
    StatBar.reset_all()

    if name == "vanilla" then
        StatBar.enable_offscreen_cull(false)
        return true
    elseif name == "clean" then
        StatBar.enable_offscreen_cull(true)
        return true
    elseif name == "rpg" then
        StatBar.enable_mana_bar(true)
        StatBar.set_mana_style({
            color = 0xFF2878FF,
            height = 0.82,
            offset_y = -0.001,
        })
        StatBar.enable_offscreen_cull(true)
        return true
    elseif name == "moba" then
        StatBar.enable_mana_bar(true)
        StatBar.set_mana_style({
            color = 0xFF3296FF,
            height = 0.76,
            offset_y = -0.001,
        })
        StatBar.enable_offscreen_cull(true)
        local lp = jass.GetLocalPlayer()
        for pid = 0, 11 do
            local p = jass.Player(pid)
            if p then
                if p == lp then
                    StatBar.style_player(p, 0xFF32E864) -- self: bright emerald
                elseif jass.IsPlayerAlly(p, lp) then
                    StatBar.style_player(p, 0xFF4AA8FF) -- ally: sky blue
                else
                    StatBar.style_player(p, 0xFFFF4646) -- enemy: crimson red
                end
            end
        end
        return true
    end

    error("StatBar.apply_theme: unknown theme '" .. tostring(name) .. "'")
end

return StatBar

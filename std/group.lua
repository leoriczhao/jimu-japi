-- std/group.lua — zero-leak unit group queries backed by a single scratch group & rect.

local jass = require "jass.common"
local util = require "std.util"

local Group = {}

local scratch_group = nil
local scratch_rect = nil
local unit_wrap_fn = nil

function Group._set_unit_wrapper(fn)
    unit_wrap_fn = fn
end

local function get_group()
    if not scratch_group then
        scratch_group = jass.CreateGroup()
    end
    return scratch_group
end

local function get_rect(min_x, min_y, max_x, max_y)
    if not scratch_rect then
        scratch_rect = jass.Rect(min_x, min_y, max_x, max_y)
    else
        jass.SetRect(scratch_rect, min_x, min_y, max_x, max_y)
    end
    return scratch_rect
end

local function drain_group(g, filter_fn, raw)
    local results = {}
    local n = 0
    while true do
        local u = jass.FirstOfGroup(g)
        if not u or u == 0 then break end
        jass.GroupRemoveUnit(g, u)
        local item = (not raw and unit_wrap_fn) and unit_wrap_fn(u) or u
        if not filter_fn or filter_fn(item) then
            n = n + 1
            results[n] = item
        end
    end
    return results
end

--- Return all units within `radius` of `(x, y)` matching optional `filter_fn(unit)`.
function Group.in_range(x, y, radius, filter_fn, raw)
    local g = get_group()
    jass.GroupEnumUnitsInRange(g, x, y, radius, nil)
    return drain_group(g, filter_fn, raw)
end

--- Return all units inside `[min_x, min_y, max_x, max_y]` matching optional `filter_fn(unit)`.
function Group.in_rect(min_x, min_y, max_x, max_y, filter_fn, raw)
    local g = get_group()
    local r = get_rect(min_x, min_y, max_x, max_y)
    jass.GroupEnumUnitsInRect(g, r, nil)
    return drain_group(g, filter_fn, raw)
end

--- Return all units owned by `player` (Player wrapper or raw handle) matching optional `filter_fn`.
function Group.of_player(player, filter_fn, raw)
    local g = get_group()
    local ph = (type(player) == "table" and player.handle) and player:handle() or player
    jass.GroupEnumUnitsOfPlayer(g, ph, nil)
    return drain_group(g, filter_fn, raw)
end

--- Find the nearest unit within `radius` of `(x, y)` matching optional `filter_fn(unit)`.
function Group.nearest(x, y, radius, filter_fn)
    local list = Group.in_range(x, y, radius, filter_fn, false)
    local best, best_d2 = nil, math.huge
    for i = 1, #list do
        local u = list[i]
        local ux = (type(u) == "table" and u.x) and u:x() or jass.GetUnitX(u)
        local uy = (type(u) == "table" and u.y) and u:y() or jass.GetUnitY(u)
        local d2 = util.dist2(x, y, ux, uy)
        if d2 < best_d2 then
            best_d2 = d2
            best = u
        end
    end
    return best, best and math.sqrt(best_d2) or nil
end

return Group

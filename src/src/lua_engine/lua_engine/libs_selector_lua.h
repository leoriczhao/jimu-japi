#pragma once

// Canonical Lua source for jass.selector.
//
// This is the single source of truth for both the DLL and the offline mock
// tests: tests/selector/run.lua extracts the text between the raw-string
// markers below and runs it against a fake jass.common. Keep the delimiter
// unique; )JASS_SELECTOR" terminates the C++ literal.
//
// Scope guard: this module only calls public JASS natives through
// jass.common. It performs no memory reads, offsets, hooks, native
// registration or bridge work; YDWE's original CUnit-array implementation is
// intentionally not reproduced.
static const char selector_lua_source[] = R"JASS_SELECTOR(
-- jass.selector - map-author unit selectors.
--
-- hero() is the port of YDWE's jass.selector.hero(). The upstream version
-- walked the engine's private CUnit array with hard-coded offsets; this port
-- uses only public JASS natives so it stays inside the map-author feature
-- layer:
--
--   CreateGroup / GroupEnumUnitsInRect(GetWorldBounds()) / FirstOfGroup
--   GroupRemoveUnit for destructive iteration, and GetUnitTypeId for the
--   same hero test as YDWE: isupper(first rawcode byte).
--
-- The temporary group and rect are destroyed on every path, including native
-- errors. Dead/hidden units are whatever the engine exposes through the rect
-- group; no extra filters are applied (see tests/selector/README.md).

local jass = require "jass.common"

local M = {}

local HERO_ID_FIRST_MIN = 0x41 -- 'A'
local HERO_ID_FIRST_MAX = 0x5A -- 'Z'

local function is_hero_unit(unit)
    local id = jass.GetUnitTypeId(unit)
    if type(id) ~= "number" then
        return false
    end
    -- GetUnitTypeId returns a big-endian fourcc; its high byte is the first
    -- character. YDWE's libs_selector.cpp used isupper(unitid >> 24).
    local first = math.floor(id / 0x1000000) % 0x100
    return first >= HERO_ID_FIRST_MIN and first <= HERO_ID_FIRST_MAX
end

local function collect_heroes()
    local group
    local rect

    local ok, result = pcall(function()
        group = jass.CreateGroup()
        if group == nil or group == 0 then
            error("jass.selector.hero: CreateGroup() returned no handle", 0)
        end

        rect = jass.GetWorldBounds()
        if rect == nil or rect == 0 then
            error("jass.selector.hero: GetWorldBounds() returned no rect", 0)
        end

        jass.GroupEnumUnitsInRect(group, rect, nil)

        local heroes = {}
        while true do
            local unit = jass.FirstOfGroup(group)
            -- handle_level 0 pushes a null handle as integer 0; levels 1/2
            -- push nil. Accept both so the loop still terminates.
            if unit == nil or unit == 0 then
                break
            end
            -- Remove before filtering: FirstOfGroup always returns the head.
            jass.GroupRemoveUnit(group, unit)
            if is_hero_unit(unit) then
                heroes[#heroes + 1] = unit
            end
        end
        return heroes
    end)

    -- Cleanup runs for every failure point, including errors inside the loop.
    -- A cleanup error is reported only when the enumeration itself succeeded,
    -- so it can never hide the original native error.
    local cleanup_ok = true
    local cleanup_err

    if group ~= nil and group ~= 0 then
        local destroy_ok, destroy_err = pcall(jass.DestroyGroup, group)
        if not destroy_ok then
            cleanup_ok = false
            cleanup_err = destroy_err
        end
    end
    if rect ~= nil and rect ~= 0 then
        local remove_ok, remove_err = pcall(jass.RemoveRect, rect)
        if not remove_ok and cleanup_ok then
            cleanup_ok = false
            cleanup_err = remove_err
        end
    end

    if not ok then
        error(result, 0)
    end
    if not cleanup_ok then
        error(cleanup_err, 0)
    end
    return result
end

function M.hero()
    return collect_heroes()
end

return M
)JASS_SELECTOR";

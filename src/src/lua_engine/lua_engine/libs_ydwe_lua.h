#pragma once

// Canonical Lua source for jass.ydwe.
//
// This is the single source of truth for both the DLL and the offline tests:
// tests/ydwe-compat/run_lua.lua extracts the text between the raw-string
// markers and runs it against fake jass.common/jass.japi modules. Keep the
// delimiter unique; )JASS_YDWE" terminates the C++ literal.
//
// Scope guard: the module only calls public JASS natives/bridge handlers. It
// performs no memory reads, offsets, hooks, native-table changes or Storm
// interception. The 47-state table matches tools/ydwe-compat/unit_states.json;
// tests/ydwe-compat checks it against UnitState.cpp.
static const char ydwe_lua_source[] = R"JASS_YDWE(
-- jass.ydwe - YDWE unit-state compatibility layer for Lua map authors.
--
-- This is the SDK-side counterpart to tools/ydwe-compat/migrate_unit_state.py.
-- Nothing is hooked: vanilla states 0..3 go to jass.GetUnitState /
-- jass.SetUnitState, and the YDWE extended states actually implemented by the
-- existing EXGetUnitState / EXSetUnitState bridge handlers go to those
-- handlers. UjAPI-only states 4..7 and every unknown state raise a descriptive
-- error instead of silently reading/writing the wrong memory.
--
-- GetUnitState/SetUnitState themselves are NOT replaced. JASS source that
-- calls them directly must use the offline migration tool (or the generated
-- YDWEGetUnitState / YDWESetUnitState helpers); this module only serves Lua.

local common = require "jass.common"
local japi = require "jass.japi"

local M = {}

-- 47 extended states handled by EXGetUnitState. Values are the raw
-- ConvertUnitState() integers YDWE uses, not the vanilla 0..3 enum.
local EXTENDED = {
    [0x10] = "ATTACK1_DAMAGE_DICE",
    [0x11] = "ATTACK1_DAMAGE_SIDE",
    [0x12] = "ATTACK1_DAMAGE_BASE",
    [0x13] = "ATTACK1_DAMAGE_BONUS",
    [0x14] = "ATTACK1_DAMAGE_MIN",
    [0x15] = "ATTACK1_DAMAGE_MAX",
    [0x16] = "ATTACK1_RANGE",
    [0x20] = "ARMOR",
    [0x21] = "ATTACK1_DAMAGE_LOSS_FACTOR",
    [0x22] = "ATTACK1_WEAPON_SOUND",
    [0x23] = "ATTACK1_ATTACK_TYPE",
    [0x24] = "ATTACK1_MAX_TARGETS",
    [0x25] = "ATTACK1_INTERVAL",
    [0x26] = "ATTACK1_INITIAL_DELAY",
    [0x27] = "ATTACK1_RANGE_BUFFER",
    [0x28] = "ATTACK1_BACK_SWING",
    [0x29] = "ATTACK1_TARGET_TYPES",
    [0x30] = "ATTACK2_DAMAGE_DICE",
    [0x31] = "ATTACK2_DAMAGE_SIDE",
    [0x32] = "ATTACK2_DAMAGE_BASE",
    [0x33] = "ATTACK2_DAMAGE_BONUS",
    [0x34] = "ATTACK2_DAMAGE_LOSS_FACTOR",
    [0x35] = "ATTACK2_WEAPON_SOUND",
    [0x36] = "ATTACK2_ATTACK_TYPE",
    [0x37] = "ATTACK2_MAX_TARGETS",
    [0x38] = "ATTACK2_INTERVAL",
    [0x39] = "ATTACK2_INITIAL_DELAY",
    [0x40] = "ATTACK2_RANGE",
    [0x41] = "ATTACK2_RANGE_BUFFER",
    [0x42] = "ATTACK2_DAMAGE_MIN",
    [0x43] = "ATTACK2_DAMAGE_MAX",
    [0x44] = "ATTACK2_BACK_SWING",
    [0x45] = "ATTACK2_TARGET_TYPES",
    [0x46] = "ATTACK2_SPILL_DIST",
    [0x47] = "ATTACK2_SPILL_RADIUS",
    [0x50] = "ARMOR_TYPE",
    [0x51] = "RATE_OF_FIRE",
    [0x52] = "ACQUISITION_RANGE",
    [0x53] = "LIFE_REGEN",
    [0x54] = "MANA_REGEN",
    [0x55] = "MIN_RANGE",
    [0x56] = "ATTACK1_SPILL_DIST",
    [0x57] = "ATTACK1_SPILL_RADIUS",
    [0x58] = "ATTACK1_WEAPON_TYPE",
    [0x59] = "ATTACK2_WEAPON_TYPE",
    [0x60] = "AS_TARGET_TYPE",
    [0x61] = "TYPE",
}

local NAMES = {}
for value, name in pairs(EXTENDED) do
    NAMES[name] = value
end

local VANILLA = { [0] = true, [1] = true, [2] = true, [3] = true }
-- EXSetUnitState deliberately does not write these two attack-damage
-- aggregates (they are derived from dice/side/base/bonus).
local SET_NOOP = { [0x14] = true, [0x15] = true, [0x42] = true, [0x43] = true }
local UJAPI_ONLY = { [4] = true, [5] = true, [6] = true, [7] = true }

local function normalize_state(state)
    if type(state) ~= "number" then
        error("jass.ydwe: unit state must be a number, got " .. type(state), 3)
    end
    if state ~= state or state == math.huge or state == -math.huge then
        error("jass.ydwe: unit state is not a finite number", 3)
    end
    local value = math.floor(state)
    if value < 0 or value > 0xFFFFFFFF then
        error(string.format("jass.ydwe: unit state is out of range: %s", tostring(state)), 3)
    end
    return value
end

local function classify(value)
    if VANILLA[value] then
        return "vanilla"
    end
    if EXTENDED[value] then
        return "extended"
    end
    if UJAPI_ONLY[value] then
        error(string.format("jass.ydwe: unit state 0x%X is UjAPI-only; our EX handlers do not implement it", value), 3)
    end
    error(string.format("jass.ydwe: unknown unit state 0x%X", value), 3)
end

local unit_state = {}

function unit_state.is_extended(state)
    local ok, value = pcall(normalize_state, state)
    return ok and EXTENDED[value] ~= nil
end

function unit_state.name(state)
    local ok, value = pcall(normalize_state, state)
    if not ok then
        return nil
    end
    return EXTENDED[value]
end

function unit_state.get(unit, state)
    local value = normalize_state(state)
    local kind = classify(value)
    if kind == "vanilla" then
        return common.GetUnitState(unit, common.ConvertUnitState(value))
    end
    return japi.EXGetUnitState(common.GetHandleId(unit), value)
end

function unit_state.set(unit, state, value)
    local state_value = normalize_state(state)
    if type(value) ~= "number" then
        error("jass.ydwe: unit state value must be a number, got " .. type(value), 2)
    end
    local kind = classify(state_value)
    if kind == "vanilla" then
        common.SetUnitState(unit, common.ConvertUnitState(state_value), value)
        return
    end
    if SET_NOOP[state_value] then
        error(string.format("jass.ydwe: EXSetUnitState does not write state 0x%X", state_value), 2)
    end
    japi.EXSetUnitState(common.GetHandleId(unit), state_value, value)
end

unit_state.values = EXTENDED
unit_state.names = NAMES
unit_state.vanilla = { 0, 1, 2, 3 }
unit_state.set_noop = SET_NOOP

M.unit_state = unit_state
-- Explicit aliases for callers that prefer the native-shaped names. These are
-- module functions, not replacements for jass.GetUnitState/jass.SetUnitState.
M.GetUnitState = unit_state.get
M.SetUnitState = unit_state.set
M.IsExtendedUnitState = unit_state.is_extended
return M
)JASS_YDWE";

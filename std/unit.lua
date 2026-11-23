-- std/unit.lua — cached OO Unit wrapper with auto-cleanup and native CStatBar shortcuts.

local jass   = require "jass.common"
local util   = require "std.util"
local Event  = require "std.event"
local Player = require "std.player"
local Group  = require "std.group"

local Unit = {}
Unit.__index = Unit

local cache = {} -- [handle_id] = Unit instance

local function get_japi()
    local ok, japi = pcall(require, "jass.japi")
    return ok and japi or nil
end

local function raw_handle(u)
    if type(u) == "table" and u._handle then return u._handle end
    return u
end

--- Wrap an existing War3 unit handle (returns the same Unit instance for the same handle_id).
function Unit.wrap(handle)
    if not handle or handle == 0 then return nil end
    if getmetatable(handle) == Unit then return handle end
    local hid = jass.GetHandleId(handle)
    if not hid or hid == 0 then return nil end
    local existing = cache[hid]
    if existing then
        existing._handle = handle
        return existing
    end
    local self = setmetatable({
        _handle = handle,
        _hid = hid,
        _removed = false,
        data = {},
    }, Unit)
    cache[hid] = self
    return self
end

--- Create a new unit and wrap it.
--- `player`: Player object or raw handle; `type_id`: 4-char string (e.g. "hfoo") or fourcc int.
function Unit.create(player, type_id, x, y, facing)
    local ph = (type(player) == "table" and player.handle) and player:handle() or player
    local id = util.fourcc(type_id)
    local raw = jass.CreateUnit(ph, id, x or 0.0, y or 0.0, facing or 270.0)
    if not raw or raw == 0 then return nil end
    Event.register_unit_for_damage(raw)
    return Unit.wrap(raw)
end

--- Release a unit from the wrapper cache (called automatically by u:remove()).
function Unit.release(handle_or_unit)
    if not handle_or_unit then return end
    local hid
    if type(handle_or_unit) == "table" and handle_or_unit._hid then
        hid = handle_or_unit._hid
    elseif type(handle_or_unit) == "number" then
        hid = handle_or_unit
    else
        hid = jass.GetHandleId(handle_or_unit)
    end
    if hid and cache[hid] then
        cache[hid]._removed = true
        cache[hid] = nil
        Event.unregister_unit_for_damage(hid)
    end
end

function Unit.cached_count()
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    return n
end

-- ── Identity & lifecycle ───────────────────────────────────────────────────

function Unit:handle() return self._handle end
function Unit:id() return self._hid end
function Unit:is_valid() return not self._removed and self._handle ~= nil end

function Unit:type_id()
    return jass.GetUnitTypeId(self._handle)
end

function Unit:type_code()
    return util.id2str(self:type_id())
end

function Unit:name()
    return jass.GetUnitName(self._handle)
end

function Unit:owner()
    return Player.from_handle(jass.GetOwningPlayer(self._handle))
end

function Unit:is_alive()
    if self._removed then return false end
    return jass.GetWidgetLife(self._handle) > 0.405
end

function Unit:is_dead()
    return not self:is_alive()
end

function Unit:kill()
    if self._removed then return end
    jass.KillUnit(self._handle)
end

function Unit:remove()
    if self._removed then return end
    local h = self._handle
    Unit.release(self)
    self._handle = nil
    if h then jass.RemoveUnit(h) end
end

-- ── Position & movement ────────────────────────────────────────────────────

function Unit:x() return jass.GetUnitX(self._handle) end
function Unit:y() return jass.GetUnitY(self._handle) end
function Unit:pos() return jass.GetUnitX(self._handle), jass.GetUnitY(self._handle) end
function Unit:facing() return jass.GetUnitFacing(self._handle) end

function Unit:set_pos(x, y)
    jass.SetUnitX(self._handle, x)
    jass.SetUnitY(self._handle, y)
end

function Unit:set_facing(deg, instant)
    if instant then
        local japi = get_japi()
        if japi and japi.EXSetUnitFacing then
            japi.EXSetUnitFacing(self._handle, deg)
            return
        end
    end
    jass.SetUnitFacing(self._handle, deg)
end

function Unit:move_to(x, y)
    return jass.IssuePointOrder(self._handle, "move", x, y)
end

function Unit:attack_move(x, y)
    return jass.IssuePointOrder(self._handle, "attack", x, y)
end

function Unit:stop()
    return jass.IssueImmediateOrder(self._handle, "stop")
end

function Unit:distance_to(target_or_x, y)
    local ux, uy = self:pos()
    if type(target_or_x) == "table" and target_or_x.pos then
        local tx, ty = target_or_x:pos()
        return util.dist(ux, uy, tx, ty)
    end
    return util.dist(ux, uy, target_or_x, y)
end

-- ── Vitals & combat ────────────────────────────────────────────────────────

function Unit:hp()
    return jass.GetUnitState(self._handle, jass.UNIT_STATE_LIFE)
end

function Unit:max_hp()
    return jass.GetUnitState(self._handle, jass.UNIT_STATE_MAX_LIFE)
end

function Unit:hp_pct()
    local m = self:max_hp()
    return (m > 0) and (self:hp() / m) or 0
end

function Unit:set_hp(v)
    jass.SetUnitState(self._handle, jass.UNIT_STATE_LIFE, util.clamp(v, 0, self:max_hp()))
end

function Unit:heal(delta)
    self:set_hp(self:hp() + delta)
end

function Unit:mp()
    return jass.GetUnitState(self._handle, jass.UNIT_STATE_MANA)
end

function Unit:max_mp()
    return jass.GetUnitState(self._handle, jass.UNIT_STATE_MAX_MANA)
end

function Unit:set_mp(v)
    jass.SetUnitState(self._handle, jass.UNIT_STATE_MANA, util.clamp(v, 0, self:max_mp()))
end

--- Deal damage from this unit to `target` (Unit wrapper or raw handle).
function Unit:damage(target, amount, opts)
    opts = opts or {}
    local th = raw_handle(target)
    local attack   = opts.attack ~= false
    local ranged   = opts.ranged == true
    local atk_type = opts.attack_type or jass.ATTACK_TYPE_NORMAL
    local dmg_type = opts.damage_type or jass.DAMAGE_TYPE_NORMAL
    local wpn_type = opts.weapon_type or jass.WEAPON_TYPE_WHOKNOWS
    return jass.UnitDamageTarget(self._handle, th, amount, attack, ranged, atk_type, dmg_type, wpn_type)
end

-- ── Abilities & state ──────────────────────────────────────────────────────

function Unit:add_ability(id)
    return jass.UnitAddAbility(self._handle, util.fourcc(id))
end

function Unit:remove_ability(id)
    return jass.UnitRemoveAbility(self._handle, util.fourcc(id))
end

function Unit:ability_level(id)
    return jass.GetUnitAbilityLevel(self._handle, util.fourcc(id))
end

function Unit:set_ability_level(id, level)
    return jass.SetUnitAbilityLevel(self._handle, util.fourcc(id), level)
end

function Unit:pause(flag)
    local japi = get_japi()
    if japi and japi.EXPauseUnit then
        japi.EXPauseUnit(self._handle, flag == true)
    else
        jass.PauseUnit(self._handle, flag == true)
    end
end

-- ── Native 1.27a CStatBar shortcuts ────────────────────────────────────────

function Unit:set_hp_bar_color(argb)
    local japi = get_japi()
    if japi and japi.EXSetUnitHPBarColor then japi.EXSetUnitHPBarColor(self._handle, argb) end
end

function Unit:set_hp_bar_scale(sx, sy)
    local japi = get_japi()
    if japi and japi.EXSetUnitHPBarScale then japi.EXSetUnitHPBarScale(self._handle, sx, sy or 1.0) end
end

function Unit:set_hp_bar_visible(visible)
    local japi = get_japi()
    if japi and japi.EXSetUnitHPBarVisible then japi.EXSetUnitHPBarVisible(self._handle, visible == true) end
end

function Unit:set_mana_bar_color(argb)
    local japi = get_japi()
    if japi and japi.EXSetUnitManaBarColor then japi.EXSetUnitManaBarColor(self._handle, argb) end
end

function Unit:set_mana_bar_visible(visible)
    local japi = get_japi()
    if japi and japi.EXSetUnitManaBarVisible then japi.EXSetUnitManaBarVisible(self._handle, visible == true) end
end

function Unit:reset_bar()
    local japi = get_japi()
    if japi and japi.EXResetUnitHPBar then japi.EXResetUnitHPBar(self._handle) end
end

-- Wire Unit.wrap into std.event and std.group so queries/events return Unit instances.
Event._set_wrappers(Unit.wrap, nil)
Group._set_unit_wrapper(Unit.wrap)

return Unit

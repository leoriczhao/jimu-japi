-- std/event.lua — unified Lua pub/sub bus with lazy War3 native event bridging.
--
-- Pure custom events:
--   local tok = Event.on("wave:start", function(wave) ... end)
--   Event.emit("wave:start", 3)
--   tok:cancel()   -- or Event.off("wave:start", tok)
--
-- Built-in War3 events (auto-wired lazily on first subscription):
--   "unit:death"         -> { unit, killer }
--   "unit:attacked"      -> { unit, attacker }
--   "unit:spell_effect"  -> { unit, ability_id, target_unit, target_x, target_y }
--   "unit:spell_cast"    -> { unit, ability_id }
--   "unit:pickup_item"   -> { unit, item }
--   "unit:drop_item"     -> { unit, item }
--   "unit:use_item"      -> { unit, item }
--   "unit:level_up"      -> { unit, level }
--   "unit:damage"        -> { target, source, amount, is_physical, is_attack, is_ranged,
--                             damage_type, attack_type, set_amount(v) }
--   "player:chat"        -> { player, text }
--   "key:down" / "key:up"-> { code, state }
--   "map:end"            -> ()
--   "map:broken_network" -> ()

local jass = require "jass.common"
local util = require "std.util"

local Event = {}

local listeners = {}     -- [name] = { list = { token, ... } }
local wired = {}         -- [name] = true once native bridge is installed
local next_id = 1

-- Optional lazy resolver so std.event does not cyclically require std.unit / std.player.
local wrap_unit_fn = nil
local wrap_player_fn = nil

function Event._set_wrappers(unit_wrap, player_wrap)
    if unit_wrap ~= nil then wrap_unit_fn = unit_wrap end
    if player_wrap ~= nil then wrap_player_fn = player_wrap end
end

local function wrap_unit(h)
    if not h or h == 0 then return nil end
    return wrap_unit_fn and wrap_unit_fn(h) or h
end

local function wrap_player(h)
    if not h or h == 0 then return nil end
    return wrap_player_fn and wrap_player_fn(h) or h
end

local function emit(name, ...)
    local bucket = listeners[name]
    if not bucket or #bucket == 0 then return 0 end
    -- Snapshot to allow safe subscribe/unsubscribe inside callbacks.
    local snap = {}
    local n = #bucket
    for i = 1, n do snap[i] = bucket[i] end

    local called = 0
    for i = 1, n do
        local tok = snap[i]
        if tok.active then
            if tok.once then
                tok:cancel()
            end
            util.safe_call(tok.fn, ...)
            called = called + 1
        end
    end
    return called
end

-- ── Lazy native bridges ────────────────────────────────────────────────────

local function register_any_player_unit_event(event_const, builder)
    local trig = jass.CreateTrigger()
    for pid = 0, 15 do
        local p = jass.Player(pid)
        if p then
            jass.TriggerRegisterPlayerUnitEvent(trig, p, event_const, nil)
        end
    end
    jass.TriggerAddAction(trig, jass.code(builder))
    return trig
end

local damage_trig = nil
local damage_registered = {} -- [handle_id] = true

local function ensure_damage_trigger()
    if damage_trig then return end
    local ok_japi, japi = pcall(require, "jass.japi")
    damage_trig = jass.CreateTrigger()
    jass.TriggerAddAction(damage_trig, jass.code(function()
        local target_h = jass.GetTriggerUnit()
        local source_h = jass.GetEventDamageSource()
        local amount = jass.GetEventDamage()
        local is_phys, is_atk, is_ranged, dmg_type, atk_type = false, false, false, 0, 0
        if ok_japi and japi and japi.EXGetEventDamageData then
            is_phys   = japi.EXGetEventDamageData(1) ~= 0
            is_atk    = japi.EXGetEventDamageData(2) ~= 0
            is_ranged = japi.EXGetEventDamageData(3) ~= 0
            dmg_type  = japi.EXGetEventDamageData(4) or 0
            atk_type  = japi.EXGetEventDamageData(5) or 0
        end
        local ev = {
            target = wrap_unit(target_h),
            source = wrap_unit(source_h),
            amount = amount,
            is_physical = is_phys,
            is_attack = is_atk,
            is_ranged = is_ranged,
            damage_type = dmg_type,
            attack_type = atk_type,
            set_amount = function(new_val)
                if ok_japi and japi and japi.EXSetEventDamage then
                    japi.EXSetEventDamage(new_val)
                end
            end,
        }
        emit("unit:damage", ev)
    end))

    -- Hook units already on the map at the moment of subscription.
    if jass.CreateGroup and jass.GetWorldBounds and jass.GroupEnumUnitsInRect then
        local g = jass.CreateGroup()
        local world = jass.GetWorldBounds()
        jass.GroupEnumUnitsInRect(g, world, nil)
        while true do
            local u = jass.FirstOfGroup(g)
            if not u or u == 0 then break end
            jass.GroupRemoveUnit(g, u)
            Event.register_unit_for_damage(u)
        end
        jass.DestroyGroup(g)
    end
end

--- Register a newly created unit handle on the shared "unit:damage" trigger.
--- Safe and idempotent; automatically called by std.unit.create().
function Event.register_unit_for_damage(unit_handle)
    if not damage_trig or not unit_handle or unit_handle == 0 then return end
    local hid = jass.GetHandleId(unit_handle)
    if not hid or hid == 0 or damage_registered[hid] then return end
    damage_registered[hid] = true
    jass.TriggerRegisterUnitEvent(damage_trig, unit_handle, jass.EVENT_UNIT_DAMAGED)
end

function Event.unregister_unit_for_damage(hid)
    if hid then damage_registered[hid] = nil end
end

local keyboard_wired = false
local function ensure_keyboard_bridge()
    if keyboard_wired then return end
    keyboard_wired = true
    local ok, message = pcall(require, "jass.message")
    if not ok or not message then return end
    local prev = message.hook
    message.hook = function(msg)
        if msg then
            if msg.type == "key_down" then
                emit("key:down", { code = msg.code, state = msg.state })
            elseif msg.type == "key_up" then
                emit("key:up", { code = msg.code, state = msg.state })
            end
        end
        if prev then return prev(msg) end
        return true
    end
end

local native_wirers = {
    ["unit:death"] = function()
        register_any_player_unit_event(jass.EVENT_PLAYER_UNIT_DEATH, function()
            emit("unit:death", {
                unit = wrap_unit(jass.GetTriggerUnit()),
                killer = wrap_unit(jass.GetKillingUnit()),
            })
        end)
    end,
    ["unit:attacked"] = function()
        register_any_player_unit_event(jass.EVENT_PLAYER_UNIT_ATTACKED, function()
            emit("unit:attacked", {
                unit = wrap_unit(jass.GetTriggerUnit()),
                attacker = wrap_unit(jass.GetAttacker()),
            })
        end)
    end,
    ["unit:spell_effect"] = function()
        register_any_player_unit_event(jass.EVENT_PLAYER_UNIT_SPELL_EFFECT, function()
            emit("unit:spell_effect", {
                unit = wrap_unit(jass.GetTriggerUnit()),
                ability_id = jass.GetSpellAbilityId(),
                target_unit = wrap_unit(jass.GetSpellTargetUnit()),
                target_x = jass.GetSpellTargetX and jass.GetSpellTargetX() or 0,
                target_y = jass.GetSpellTargetY and jass.GetSpellTargetY() or 0,
            })
        end)
    end,
    ["unit:spell_cast"] = function()
        register_any_player_unit_event(jass.EVENT_PLAYER_UNIT_SPELL_CAST, function()
            emit("unit:spell_cast", {
                unit = wrap_unit(jass.GetTriggerUnit()),
                ability_id = jass.GetSpellAbilityId(),
            })
        end)
    end,
    ["unit:pickup_item"] = function()
        register_any_player_unit_event(jass.EVENT_PLAYER_UNIT_PICKUP_ITEM, function()
            emit("unit:pickup_item", {
                unit = wrap_unit(jass.GetTriggerUnit()),
                item = jass.GetManipulatedItem(),
            })
        end)
    end,
    ["unit:drop_item"] = function()
        register_any_player_unit_event(jass.EVENT_PLAYER_UNIT_DROP_ITEM, function()
            emit("unit:drop_item", {
                unit = wrap_unit(jass.GetTriggerUnit()),
                item = jass.GetManipulatedItem(),
            })
        end)
    end,
    ["unit:use_item"] = function()
        register_any_player_unit_event(jass.EVENT_PLAYER_UNIT_USE_ITEM, function()
            emit("unit:use_item", {
                unit = wrap_unit(jass.GetTriggerUnit()),
                item = jass.GetManipulatedItem(),
            })
        end)
    end,
    ["unit:level_up"] = function()
        register_any_player_unit_event(jass.EVENT_PLAYER_HERO_LEVEL, function()
            local u = jass.GetTriggerUnit()
            emit("unit:level_up", {
                unit = wrap_unit(u),
                level = jass.GetHeroLevel(u),
            })
        end)
    end,
    ["unit:damage"] = ensure_damage_trigger,
    ["player:chat"] = function()
        local trig = jass.CreateTrigger()
        for pid = 0, 15 do
            local p = jass.Player(pid)
            if p then
                jass.TriggerRegisterPlayerChatEvent(trig, p, "", false)
            end
        end
        jass.TriggerAddAction(trig, jass.code(function()
            emit("player:chat", {
                player = wrap_player(jass.GetTriggerPlayer()),
                text = jass.GetEventPlayerChatString(),
            })
        end))
    end,
    ["key:down"] = ensure_keyboard_bridge,
    ["key:up"] = ensure_keyboard_bridge,
    ["map:end"] = function()
        local ok, me = pcall(require, "jass.map_event")
        if ok and me and me.on then
            me.on("endGame", function() emit("map:end") end)
        end
    end,
    ["map:broken_network"] = function()
        local ok, me = pcall(require, "jass.map_event")
        if ok and me and me.on then
            me.on("brokenNetwork", function() emit("map:broken_network") end)
        end
    end,
}

local function maybe_wire(name)
    if wired[name] then return end
    local wirer = native_wirers[name]
    if wirer then
        wired[name] = true
        wirer()
    end
end

-- ── Public API ─────────────────────────────────────────────────────────────

local function add_listener(name, fn, once)
    assert(type(name) == "string" and #name > 0, "Event.on: name must be a non-empty string")
    assert(type(fn) == "function", "Event.on: fn must be a function")

    maybe_wire(name)

    local bucket = listeners[name]
    if not bucket then
        bucket = {}
        listeners[name] = bucket
    end

    local tok = {
        id = next_id,
        name = name,
        fn = fn,
        once = once == true,
        active = true,
    }
    next_id = next_id + 1

    function tok:cancel()
        if not self.active then return false end
        self.active = false
        local b = listeners[self.name]
        if b then
            for i = #b, 1, -1 do
                if b[i] == self then
                    table.remove(b, i)
                    break
                end
            end
        end
        return true
    end

    bucket[#bucket + 1] = tok
    return tok
end

function Event.on(name, fn)
    return add_listener(name, fn, false)
end

function Event.once(name, fn)
    return add_listener(name, fn, true)
end

function Event.off(name, token)
    if type(token) == "table" and token.cancel then
        return token:cancel()
    end
    local b = listeners[name]
    if not b then return false end
    for i = #b, 1, -1 do
        if b[i].fn == token then
            b[i].active = false
            table.remove(b, i)
            return true
        end
    end
    return false
end

function Event.emit(name, ...)
    return emit(name, ...)
end

function Event.count(name)
    local b = listeners[name]
    return b and #b or 0
end

function Event.clear(name)
    if name then
        local b = listeners[name]
        if b then
            for i = 1, #b do b[i].active = false end
            listeners[name] = nil
        end
    else
        for k, b in pairs(listeners) do
            for i = 1, #b do b[i].active = false end
            listeners[k] = nil
        end
    end
end

return Event

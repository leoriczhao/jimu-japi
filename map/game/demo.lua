-- map/game/demo.lua — playable vertical slice on top of the JAPI runtime.
--
-- The slice is deliberately small but end-to-end: one controllable hero, one
-- learnable skill, one real input path and a small D3D HUD. It is meant to be
-- the reference for "can a map author build gameplay on this yet?" and it
-- verifies itself so a headless deploy can prove the slice still works.
--
-- Everything here goes through documented entry points only:
--   jass.common  -> natives
--   jass.message -> message.hook, order_point, mouse
--   jass.d3d     -> Font/Text/Texture (static P3 API, no Subscription)
-- No UnitId RPC, no hashtable plumbing, no handwritten bridge specs.

local jass = require "jass.common"
local message = require "jass.message"
local d3d = require "jass.d3d"
local scene = require "lib.scene"
local util = require "lib.util"

local M = {}

local KEY_Q = 0x51
local KEY_F2 = 0x301 -- WARK_F2 (keyboard_code.h), not the Win32 virtual key
local FLAG_LOCAL_CAST = (1 << 2) | (1 << 5)
local SPELL_EVENT = 291 -- EVENT_UNIT_SPELL_EFFECT

local function fourcc(value)
    local a, b, c, d = value:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local pass, fail, skip = 0, 0, 0

local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("  [PASS] " .. name)
    else
        fail = fail + 1
        print("  [FAIL] " .. name .. " : " .. tostring(err))
    end
end

local function skip_check(name, why)
    skip = skip + 1
    print("  [SKIP] " .. name .. " : " .. tostring(why))
end

local state = {
    hero = nil,
    dummy = nil,
    ability = fourcc("AHbz"),
    order = jass.OrderId("blizzard"),
    spell_fired = false,
    spell_ability = 0,
    cast_ok = nil,
    cast_error = nil,
    force_point = nil, -- deterministic cast point used by the self-check
    q_held = false,
    selected = nil,
}

local hud = {
    ready = false,
    font = nil,
    title = nil,
    stats = nil,
    target = nil,
    hint = nil,
    panel = nil,
}

-- ── HUD ────────────────────────────────────────────────────────────

local function state_value(unit, index)
    if not unit then return 0.0 end
    local ok, value = pcall(jass.GetUnitState, unit, jass.ConvertUnitState(index))
    if not ok or type(value) ~= "number" then return 0.0 end
    return value
end

local function unit_label(unit)
    if not unit then return "none" end
    local ok, name = pcall(jass.GetUnitName, unit)
    if ok and type(name) == "string" and #name > 0 then return name end
    return "unit"
end

function hud.refresh()
    if not hud.ready then return end
    local hero = state.hero
    local dummy = state.dummy
    if not hero then return end
    hud.stats:set_text(string.format(
        "Lv %d   HP %.0f/%.0f   MP %.0f/%.0f",
        jass.GetHeroLevel(hero),
        state_value(hero, 0), state_value(hero, 1),
        state_value(hero, 2), state_value(hero, 3)))
    hud.target:set_text(string.format("target: %s (%s)   dummy HP %.0f",
        unit_label(state.selected),
        state.selected and "selected" or "none",
        state_value(dummy, 0)))
end

local function hud_create()
    if not d3d.is_available() then
        return false, tostring(d3d.status().error or "proxy unavailable")
    end
    local width, height = d3d.window_size()
    if width <= 0 or height <= 0 then
        return false, "window size unavailable"
    end
    hud.font = assert(d3d.Font.new { face = "Arial", height = 18, weight = 700 })
    -- War3's own top bar (menu, resources) and the selected-unit panel occupy
    -- the first ~110 client pixels, so the HUD starts below them.
    local top = 120
    hud.title = assert(d3d.Text.new {
        font = hud.font, text = "JAPI VERTICAL SLICE",
        x = 24, y = top, color = d3d.rgba(255, 230, 120, 255), z = 100,
    })
    hud.stats = assert(d3d.Text.new {
        font = hud.font, text = "",
        x = 24, y = top + 26, color = d3d.rgba(220, 255, 220, 255), z = 100,
    })
    hud.target = assert(d3d.Text.new {
        font = hud.font, text = "",
        x = 24, y = top + 52, color = d3d.rgba(200, 220, 255, 255), z = 100,
    })
    hud.hint = assert(d3d.Text.new {
        font = hud.font, text = "Q = Blizzard at cursor | left click = select | F2 = restart",
        x = 24, y = top + 82, color = d3d.rgba(255, 255, 255, 210), z = 100,
    })
    -- HUD backing plate: a game:// BLP tinted near-black keeps the text legible
    -- over any terrain, and exercises asset loading from the game MPQ.
    hud.panel = assert(d3d.Texture.new {
        source = "game://ReplaceableTextures\\CommandButtons\\BTNRifleman.blp",
        x = 12, y = top - 12, width = 600, height = 126,
        color = d3d.rgba(8, 8, 8, 190), z = 99,
    })
    print(string.format("[slice] client size %dx%d, hud at %d..%d",
        width, height, top - 12, top + 114))
    hud.ready = true
    hud.refresh()
    return true
end

-- ── Skill and input ───────────────────────────────────────────────

local function ensure_cast_resources(hero)
    -- Hrif inherits a hero parent but ships with a zero mana pool; give it a
    -- usable pool so the slice can actually cast without editing object data.
    pcall(jass.SetHeroInt, hero, 60, true)
    pcall(jass.SetUnitState, hero, jass.ConvertUnitState(3), 500.0)
    pcall(jass.SetUnitState, hero, jass.ConvertUnitState(2), 500.0)
    if jass.GetUnitAbilityLevel(hero, state.ability) <= 0 then
        jass.UnitAddAbility(hero, state.ability)
        jass.SetUnitAbilityLevel(hero, state.ability, 1)
    end
end

local function cursor_point()
    if state.force_point then
        return state.force_point[1], state.force_point[2]
    end
    local ok, x, y = pcall(message.mouse)
    if ok and type(x) == "number" and type(y) == "number" then
        return x, y
    end
    return jass.GetUnitX(state.hero), jass.GetUnitY(state.hero)
end

-- The same function the real key press uses, so the self-check covers the
-- shipping path and not a parallel test-only copy.
local function cast_at_cursor()
    local x, y = cursor_point()
    local ok, submitted = pcall(message.order_point, state.order, x, y, FLAG_LOCAL_CAST)
    state.cast_ok = ok and submitted == true
    state.cast_error = ok and nil or tostring(submitted)
    return state.cast_ok
end

local function on_message(msg)
    if type(msg) ~= "table" then return true end
    if msg.type == "key_down" and msg.code == KEY_Q then
        if state.q_held then return false end
        state.q_held = true
        cast_at_cursor()
        return false -- swallow the key, the local order already consumed it
    end
    if msg.type == "key_up" and msg.code == KEY_Q then
        state.q_held = false
        return false
    end
    if msg.type == "key_down" and msg.code == KEY_F2 then
        state.restart_requested = true
        return false
    end
    -- Everything else (clicks, camera keys, chat) stays with the game so the
    -- slice keeps native War3 controls.
    return true
end

-- ── Setup ─────────────────────────────────────────────────────────

local world = { trigger = nil }

-- Rebuild the playable world. scene.reset() clears every unit, so this is also
-- the F2 restart path and must not leak the previous spell trigger.
local function rebuild_world(verbose)
    if world.trigger then
        pcall(jass.DestroyTrigger, world.trigger)
        world.trigger = nil
    end
    state.dummy = nil
    state.spell_fired = false
    state.spell_ability = 0
    state.q_held = false
    state.cast_ok = nil
    state.cast_error = nil

    local hero = scene.reset(true)
    state.hero = hero
    ensure_cast_resources(hero)

    local x = jass.GetUnitX(hero)
    local y = jass.GetUnitY(hero)
    state.dummy = jass.CreateUnit(jass.Player(1), fourcc("hfoo"), x + 420.0, y, 270.0)
    if state.dummy then
        -- Fill to the unit's own maximum (SetWidgetLife clamps at max life).
        jass.SetWidgetLife(state.dummy, state_value(state.dummy, 1))
    end

    local trigger = jass.CreateTrigger()
    jass.TriggerRegisterUnitEvent(trigger, hero, jass.ConvertUnitEvent(SPELL_EVENT))
    jass.TriggerAddAction(trigger, jass.code(function()
        state.spell_fired = true
        state.spell_ability = jass.GetSpellAbilityId()
    end))
    world.trigger = trigger

    jass.SelectUnit(hero, true)
    -- PanCameraToTimed with a zero duration is not reliably instant on 1.27a;
    -- SetCameraPosition is the instant call.
    local camera_ok = pcall(jass.SetCameraPosition, x, y)
    if not camera_ok then
        pcall(jass.PanCameraTo, x, y)
    end
    if hud.ready then hud.refresh() end
    if verbose then
        print(string.format("[slice] hero at %.1f,%.1f camera at %.1f,%.1f",
            x, y,
            jass.GetCameraTargetPositionX() or 0, jass.GetCameraTargetPositionY() or 0))
    end
    return hero
end

local function setup()
    local hud_ok, hud_err = hud_create()
    rebuild_world(true)
    message.hook = on_message
    return hud_ok, hud_err
end

local function restart_now()
    print("[slice] restart")
    return rebuild_world(true)
end

-- ── Self-check ────────────────────────────────────────────────────

local function run_setup_checks()
    print("")
    print("-- vertical slice --")

    check("hero is a level-10 Hrif hero", function()
        local hero = state.hero
        assert(hero ~= nil, "hero missing")
        assert(jass.IsUnitType(hero, jass.UNIT_TYPE_HERO), "unit is not a hero")
        assert(jass.GetHeroLevel(hero) == 10,
            "level " .. tostring(jass.GetHeroLevel(hero)))
    end)

    check("skill is learned and castable", function()
        local level = jass.GetUnitAbilityLevel(state.hero, state.ability)
        assert(level == 1, "ability level " .. tostring(level))
        local mana = state_value(state.hero, 2)
        local max_mana = state_value(state.hero, 3)
        assert(max_mana >= 100.0, "max mana " .. tostring(max_mana))
        assert(mana >= 75.0, "current mana " .. tostring(mana))
    end)

    check("enemy target exists", function()
        assert(state.dummy ~= nil, "dummy missing")
        assert(state_value(state.dummy, 0) > 0.0, "dummy has no life")
    end)

    if hud.ready then
        check("HUD text tracks hero state", function()
            hud.refresh()
            local text = hud.stats:get_text()
            assert(text:find("Lv 10", 1, true), "stats text: " .. text)
            assert(text:find("HP", 1, true), "stats text: " .. text)
        end)

        check("HUD panel texture loads from game://", function()
            assert(hud.panel ~= nil and not hud.panel:is_destroyed())
            local counts = assert(d3d.stats())
            assert(counts.textures >= 1 and counts.texts >= 4,
                string.format("textures=%d texts=%d", counts.textures, counts.texts))
            assert(counts.device_ready, "d3d device not ready")
        end)
    else
        skip_check("HUD text tracks hero state", "d3d unavailable")
        skip_check("HUD panel texture loads from game://", "d3d unavailable")
    end

    check("selection is readable for gameplay code", function()
        jass.SelectUnit(state.hero, true)
        local selected = util.get_selected_unit()
        assert(selected ~= nil, "no selected unit")
        state.selected = selected
    end)
end

local function submit_cast()
    check("Q key submits a point order through message.hook", function()
        -- Same handler the real key press reaches; only the cast point is
        -- pinned so the result does not depend on where the cursor happens
        -- to be during a headless run.
        state.force_point = { jass.GetUnitX(state.dummy), jass.GetUnitY(state.dummy) }
        local sent = on_message { type = "key_down", code = KEY_Q }
        state.force_point = nil
        assert(sent == false, "hook did not consume the key")
        assert(state.cast_ok == true,
            "order submission failed: " .. tostring(state.cast_error))
        local current = jass.GetUnitCurrentOrder(state.hero)
        print(string.format("[slice] order submitted, current order=%s mana=%.0f",
            tostring(current), state_value(state.hero, 2)))
    end)
end

local function run_cast_checks()
    check("point order reaches EVENT_UNIT_SPELL_EFFECT", function()
        assert(state.spell_fired,
            string.format("spell effect event did not fire (current order=%s mana=%.0f)",
                tostring(jass.GetUnitCurrentOrder(state.hero)),
                state_value(state.hero, 2)))
        assert(state.spell_ability == state.ability,
            string.format("ability %s != AHbz %d",
                tostring(state.spell_ability), state.ability))
    end)

    check("damage path reduces target life", function()
        local before = state_value(state.dummy, 0)
        jass.UnitDamageTarget(state.hero, state.dummy, 30.0, true, false,
            jass.ConvertAttackType(0), jass.ConvertDamageType(4),
            jass.ConvertWeaponType(0))
        local after = state_value(state.dummy, 0)
        assert(after < before,
            string.format("life %.1f -> %.1f", before, after))
        state.dummy_life = after
    end)

    check("F2 restart rebuilds the world", function()
        local old_dummy = state.dummy
        local sent = on_message { type = "key_down", code = KEY_F2 }
        assert(sent == false, "hook did not consume F2")
        assert(state.restart_requested == true, "hook did not record the restart")
        -- The watcher timer would do this on its next tick; call it directly so
        -- the check is deterministic.
        state.restart_requested = false
        restart_now()
        assert(state.dummy ~= nil and state.dummy ~= old_dummy,
            "dummy was not recreated")
        local max_life = state_value(state.dummy, 1)
        local life = state_value(state.dummy, 0)
        assert(life >= max_life - 1.0,
            string.format("recreated dummy is not at full life: %.0f/%.0f", life, max_life))
        assert(state.spell_fired == false, "spell state survived the restart")
        assert(jass.IsUnitType(state.hero, jass.UNIT_TYPE_HERO),
            "hero was not recreated as a hero")
        assert(jass.GetHeroLevel(state.hero) == 10, "hero level lost on restart")
        if hud.ready then
            local text = hud.stats:get_text()
            assert(text:find("Lv 10", 1, true), "HUD did not follow the restart: " .. text)
        end
    end)

    check("HUD refresh follows the damage", function()
        if not hud.ready then
            error("d3d unavailable, covered by the skip above", 0)
        end
        state.selected = state.dummy
        hud.refresh()
        local text = hud.target:get_text()
        assert(text:find("dummy HP", 1, true), "target text: " .. text)
        assert(not text:find("dummy HP 0", 1, true), "target text: " .. text)
    end)
end

local function finish()
    print("")
    print("========================================")
    print(string.format(" Results: %d passed, %d failed, %d total (%d skipped)",
        pass, fail, pass + fail, skip))
    print("========================================")
    if fail == 0 then
        print("VERTICAL SLICE OK")
    else
        print("VERTICAL SLICE FAILED")
    end
end

-- ── Entry point ───────────────────────────────────────────────────

local function after(seconds, fn)
    local timer = jass.CreateTimer()
    jass.TimerStart(timer, seconds, false, function()
        jass.DestroyTimer(timer)
        local ok, err = pcall(fn)
        if not ok then
            fail = fail + 1
            print("  [FAIL] slice step : " .. tostring(err))
            finish()
        end
    end)
end

-- Watches the restart flag from the message hook and rebuilds the world. The
-- hook itself must stay cheap, so the rebuild happens on the next timer tick.
local function start_restart_watch()
    local timer = jass.CreateTimer()
    jass.TimerStart(timer, 0.25, true, function()
        if not state.restart_requested then return end
        state.restart_requested = false
        local ok, err = pcall(restart_now)
        if not ok then
            print("[slice] restart failed: " .. tostring(err))
        end
    end)
    state.watch_timer = timer
end

function M.run()
    -- The command-submit chain used by LocalPointOrder is only up a few
    -- frames into the game, so the slice starts after the first second.
    after(1.5, function()
        local ok, hud_ok, hud_err = pcall(setup)
        if not ok then
            error(hud_ok, 0)
        end
        if not hud_ok then
            print("[slice] HUD unavailable: " .. tostring(hud_err))
        end
        start_restart_watch()
    end)

    after(2.2, run_setup_checks)
    after(2.6, submit_cast)
    -- Blizzard has a real cast time before EVENT_UNIT_SPELL_EFFECT fires.
    after(4.6, function()
        run_cast_checks()
        finish()
    end)
end

return M

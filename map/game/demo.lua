-- map/game/demo.lua — playable wave-defense slice + its self-check.
--
-- The game itself lives in map/game/wave.lua. This file owns the deterministic
-- self-check that a headless deploy runs (-Demo): it drives the game through
-- the very same functions a player reaches (game tick, wave spawn, input hook,
-- restart) and then leaves the session in a fresh, playable run.
--
-- Everything here goes through documented entry points only:
--   jass.common  -> natives
--   jass.message -> message.hook, order_point, mouse
--   jass.d3d     -> Font/Text/Texture (static P3 API, no Subscription)
-- No UnitId RPC, no hashtable plumbing, no handwritten bridge specs.

local jass = require "jass.common"
local message = require "jass.message"
local d3d = require "jass.d3d"
local util = require "lib.util"
local wave = require "game.wave"

local M = {}

local KEY_Q = 0x51
local SPELL_EVENT = 291 -- EVENT_UNIT_SPELL_EFFECT

local S = wave.state
local CFG = wave.config
-- wave.lua creates the HUD during setup, so this is rebound right after it.
local hud = { ready = false }
local move_origin = { x = 0.0, y = 0.0 }

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

local function state_value(unit, index)
    if not unit then return 0.0 end
    local ok, value = pcall(jass.GetUnitState, unit, jass.ConvertUnitState(index))
    if not ok or type(value) ~= "number" then return 0.0 end
    return value
end

local function after(seconds, fn)
    local timer = jass.CreateTimer()
    jass.TimerStart(timer, seconds, false, function()
        jass.DestroyTimer(timer)
        local ok, err = pcall(fn)
        if not ok then
            fail = fail + 1
            print("  [FAIL] slice step : " .. tostring(err))
        end
    end)
end

-- ── spell observation ─────────────────────────────────────────────

local spell = { fired = false, ability = 0, trigger = nil }

local function arm_spell_trigger()
    if spell.trigger then
        pcall(jass.DestroyTrigger, spell.trigger)
        spell.trigger = nil
    end
    spell.fired = false
    spell.ability = 0
    local trigger = jass.CreateTrigger()
    jass.TriggerRegisterUnitEvent(trigger, S.hero, jass.ConvertUnitEvent(SPELL_EVENT))
    jass.TriggerAddAction(trigger, jass.code(function()
        spell.fired = true
        spell.ability = jass.GetSpellAbilityId()
    end))
    spell.trigger = trigger
end

-- ── checks: world and game loop ───────────────────────────────────

local function kill_all_creeps()
    for _, entry in ipairs(S.creeps) do
        if not entry.dead then
            pcall(jass.KillUnit, entry.unit)
        end
    end
end

local function run_world_checks()
    print("")
    print("-- wave defense slice --")

    check("hero is a level-10 Hrif hero", function()
        local hero = S.hero
        assert(hero ~= nil, "hero missing")
        assert(jass.IsUnitType(hero, jass.UNIT_TYPE_HERO), "unit is not a hero")
        assert(jass.GetHeroLevel(hero) == 10,
            "level " .. tostring(jass.GetHeroLevel(hero)))
    end)

    check("base building exists at full life", function()
        assert(S.base ~= nil, "base missing")
        local life = state_value(S.base, 0)
        local max_life = state_value(S.base, 1)
        assert(max_life >= CFG.base_hp - 1.0,
            string.format("max life %.0f < %.0f", max_life, CFG.base_hp))
        assert(life >= max_life - 1.0,
            string.format("life %.0f/%.0f", life, max_life))
        assert(S.base_max >= CFG.base_hp - 1.0, "state base_max not synced")
    end)

    if hud.ready then
        check("HUD text plate is live", function()
            local counts = assert(d3d.stats())
            assert(counts.device_ready, "d3d device not ready")
            assert(counts.texts >= 6, "texts=" .. tostring(counts.texts))
            -- One texture: the plate behind the text. Health bars are the
            -- engine's, so the overlay must not allocate bar quads any more.
            assert(counts.textures == 1, "textures=" .. tostring(counts.textures))
            local text = hud.wave:get_text()
            assert(text:find("Wave", 1, true), "wave text: " .. text)
            assert(not hud.banner:get_visible(), "banner leaked from a previous run")
        end)
    else
        skip_check("HUD text plate is live", "d3d unavailable")
    end

    check("run starts in prep with a full clock", function()
        assert(S.phase == "prep", "phase " .. tostring(S.phase))
        assert(S.wave == 0, "wave " .. tostring(S.wave))
        assert(S.kills == 0 and S.score == 0, "counters not reset")
        assert(math.abs(S.time_left - CFG.time_limit) < 0.01,
            "time left " .. tostring(S.time_left))
    end)
end

local function run_loop_checks()
    print("")
    print("-- wave loop --")

    check("wave 1 spawns through the game tick", function()
        S.prep_left = 0.03
        wave.tick(0.25)
        assert(S.phase == "wave", "phase " .. tostring(S.phase))
        assert(S.wave == 1, "wave " .. tostring(S.wave))
        assert(wave.creeps_alive() == CFG.wave_sizes[1],
            string.format("alive %d != %d", wave.creeps_alive(), CFG.wave_sizes[1]))
    end)

    check("creeps carry an attack order toward the base", function()
        local entry = S.creeps[1]
        assert(entry ~= nil, "no creep")
        local order = jass.GetUnitCurrentOrder(entry.unit)
        local attack = jass.OrderId("attack")
        local move = jass.OrderId("move")
        assert(order == attack or order == move,
            string.format("order %s expected attack %s or move %s",
                tostring(order), tostring(attack), tostring(move)))
    end)

    check("damaging a creep lowers its life", function()
        local entry = S.creeps[2] or S.creeps[1]
        local before = state_value(entry.unit, 0)
        jass.UnitDamageTarget(S.hero, entry.unit, 40.0, true, false,
            jass.ConvertAttackType(0), jass.ConvertDamageType(4),
            jass.ConvertWeaponType(0))
        local got = state_value(entry.unit, 0)
        assert(got < before, string.format("life %.1f -> %.1f", before, got))
        entry.life = got
    end)

    check("killing a creep scores", function()
        local entry = S.creeps[1]
        jass.KillUnit(entry.unit)
        wave.tick(0.25)
        assert(S.kills == 1, "kills " .. tostring(S.kills))
        assert(S.score == CFG.kill_score, "score " .. tostring(S.score))
    end)

    check("clearing a wave opens the next prep window", function()
        kill_all_creeps()
        wave.tick(0.25)
        assert(wave.creeps_alive() == 0, "creeps still alive")
        assert(S.phase == "prep", "phase " .. tostring(S.phase))
        assert(S.wave == 1, "wave " .. tostring(S.wave))
        assert(S.prep_left > 0.0, "prep_left " .. tostring(S.prep_left))
    end)

    check("the prep window spawns the next wave", function()
        S.prep_left = 0.02
        wave.tick(0.25)
        assert(S.wave == 2, "wave " .. tostring(S.wave))
        assert(wave.creeps_alive() == CFG.wave_sizes[2],
            string.format("alive %d != %d", wave.creeps_alive(), CFG.wave_sizes[2]))
    end)

    if hud.ready then
        check("HUD follows the wave and the kill count", function()
            wave.hud_refresh()
            local text = hud.wave:get_text()
            assert(text:find("Wave 2/", 1, true), "wave text: " .. text)
            assert(text:find("kills " .. tostring(S.kills), 1, true),
                "kill count " .. tostring(S.kills) .. " missing: " .. text)
            assert(text:find("score " .. tostring(S.score), 1, true),
                "score " .. tostring(S.score) .. " missing: " .. text)
        end)
    else
        skip_check("HUD follows the wave and the kill count", "d3d unavailable")
    end

    check("base damage reaches the game state", function()
        local before = state_value(S.base, 0)
        jass.UnitDamageTarget(S.hero, S.base, 150.0, true, false,
            jass.ConvertAttackType(0), jass.ConvertDamageType(4),
            jass.ConvertWeaponType(0))
        wave.tick(0.25)
        assert(S.base_hp < before,
            string.format("base %.1f -> %.1f", before, S.base_hp))
        if hud.ready then
            local text = hud.base:get_text()
            assert(text:find("BASE", 1, true), "base text: " .. text)
            assert(not text:find("BASE  0/", 1, true), "base text: " .. text)
        end
    end)

    check("losing the base ends the run in defeat", function()
        jass.SetWidgetLife(S.base, 1.0)
        jass.UnitDamageTarget(S.hero, S.base, 50.0, true, false,
            jass.ConvertAttackType(0), jass.ConvertDamageType(4),
            jass.ConvertWeaponType(0))
        wave.tick(0.25)
        assert(S.phase == "defeat", "phase " .. tostring(S.phase))
        assert(S.finish_reason == "base", "reason " .. tostring(S.finish_reason))
        if hud.ready then
            assert(hud.banner:get_visible(), "defeat banner not shown")
        end
    end)

    check("restart rebuilds a clean run", function()
        assert(wave.restart(true), "restart failed")
        arm_spell_trigger()
        assert(S.phase == "prep", "phase " .. tostring(S.phase))
        assert(S.wave == 0 and S.kills == 0 and S.score == 0, "counters survived")
        assert(#S.creeps == 0, "creeps survived")
        assert(S.hero ~= nil and state_value(S.hero, 0) > 0.0, "hero missing")
        local life = state_value(S.base, 0)
        assert(life >= CFG.base_hp - 1.0, string.format("base life %.0f", life))
        if hud.ready then
            assert(not hud.banner:get_visible(), "banner survived the restart")
        end
    end)

    check("clearing the final wave ends the run in victory", function()
        local total = #CFG.wave_sizes
        wave.spawn_wave(total)
        local base_hp = state_value(S.base, 0)
        kill_all_creeps()
        wave.tick(0.25)
        assert(S.phase == "victory", "phase " .. tostring(S.phase))
        assert(S.kills == CFG.wave_sizes[total],
            string.format("kills %d != %d", S.kills, CFG.wave_sizes[total]))
        assert(S.score >= math.floor(base_hp),
            string.format("score %d < base %.0f", S.score, base_hp))
        if hud.ready then
            assert(hud.banner:get_visible(), "victory banner not shown")
        end
    end)

    check("restart after a win leaves a playable run", function()
        assert(wave.restart(true), "restart failed")
        arm_spell_trigger()
        assert(S.phase == "prep" and S.wave == 0, "run not fresh")
        assert(S.time_left > CFG.time_limit - 1.0, "clock not reset")
    end)
end

-- ── checks: engine health bars and damage feedback ───────────────

local function damage(unit, amount)
    jass.UnitDamageTarget(S.hero, unit, amount, true, false,
        jass.ConvertAttackType(0), jass.ConvertDamageType(4),
        jass.ConvertWeaponType(0))
end

local function run_feedback_checks()
    print("")
    print("-- engine health bars and damage feedback --")

    -- A fresh wave gives the damage checks live targets.
    wave.spawn_wave(1)
    local entry = nil
    for _, candidate in ipairs(S.creeps) do
        if not candidate.dead then entry = candidate break end
    end
    assert(entry ~= nil, "wave 1 spawned no creeps")

    wave.set_cursor_override(jass.GetUnitX(S.hero), jass.GetUnitY(S.hero))
    wave.hud_tick()

    check("health bars are the engine's, and the camera stays free", function()
        assert(not wave.camera_locked(), "camera is locked to the hero")
        if hud.ready then
            -- Only the text plate: no overlays, no bar quads.
            local counts = assert(d3d.stats())
            assert(counts.textures == 1,
                "overlay drew " .. tostring(counts.textures) .. " textures")
        end
    end)

    check("damage lowers a creep's life under its engine bar", function()
        local before = state_value(entry.unit, 0)
        damage(entry.unit, (entry.max_life or 420.0) * 0.85)
        local after = state_value(entry.unit, 0)
        assert(after < before, string.format("life %.1f -> %.1f", before, after))
        assert(after > 0.0, "creep died on the feedback hit")
    end)

    check("creep damage raises a damage number", function()
        local target = nil
        for _, candidate in ipairs(S.creeps) do
            if not candidate.dead then target = candidate.unit break end
        end
        assert(target ~= nil, "no live creep left to hit")
        local before = wave.float_count()
        damage(target, 30.0)
        wave.tick(0.25)
        assert(wave.float_count() > before,
            string.format("floating numbers %d -> %d", before, wave.float_count()))
    end)

    check("base damage flashes the base and floats a number", function()
        local hits, floats = wave.base_hits(), wave.float_count()
        damage(S.base, 60.0)
        wave.tick(0.25)
        assert(wave.base_hits() > hits,
            string.format("base hits %d -> %d", hits, wave.base_hits()))
        assert(wave.float_count() > floats, "no damage number above the base")
    end)
end

-- ── checks: input paths ───────────────────────────────────────────

local function run_move_checks()
    print("")
    print("-- input paths --")

    local mouse_ok, mx, my = pcall(message.mouse)
    check("cursor position is readable for aiming", function()
        assert(mouse_ok, tostring(mx))
        assert(type(mx) == "number" and type(my) == "number",
            "message.mouse returned " .. type(mx) .. "," .. type(my))
    end)

    -- Movement a player uses is the engine's own left-click order: mouse buttons
    -- never reach message.hook on 1.27a in windowed mode (the CGameUI dispatch it
    -- reads carries keyboard codes only), so the hook passes clicks straight
    -- through instead of re-implementing them. This check covers the scripted
    -- path gameplay code would use to command the hero.
    local dx = jass.GetUnitX(S.hero) + 220.0
    local dy = jass.GetUnitY(S.hero) + 120.0
    move_origin.x = jass.GetUnitX(S.hero)
    move_origin.y = jass.GetUnitY(S.hero)
    local submitted = wave.move_to(dx, dy, true)

    check("scripted move order is submitted", function()
        assert(submitted == true,
            "order submission failed: " .. tostring(S.move_error))
    end)
end

local function run_move_result_checks()
    local order = jass.GetUnitCurrentOrder(S.hero)
    local hx, hy = jass.GetUnitX(S.hero), jass.GetUnitY(S.hero)
    local moved = math.sqrt((hx - move_origin.x) ^ 2 + (hy - move_origin.y) ^ 2)
    print(string.format("[slice] move: order=%s moved=%.1f", tostring(order), moved))

    check("move order drives the hero", function()
        local wanted = jass.OrderId("move")
        assert(order == wanted or moved > 8.0,
            string.format("order %s != move %s and hero moved %.1f",
                tostring(order), tostring(wanted), moved))
    end)

    -- Aim the skill next to the hero: message.order_point submits against the
    -- current view (it resolves through the camera), so the point must stay on
    -- screen. This is also where a player aims: at what the camera shows.
    wave.set_cursor_override(jass.GetUnitX(S.hero) + 120.0, jass.GetUnitY(S.hero) - 160.0)
    local consumed = wave.on_message { type = "key_down", code = KEY_Q }
    check("Q key casts Blizzard through message.hook", function()
        assert(consumed == false, "hook did not consume the key")
        assert(S.cast_ok == true,
            "order submission failed: " .. tostring(S.cast_error))
        assert(S.cast_count == 1, "cast count " .. tostring(S.cast_count))
        assert(S.cd_left > 0.0, "cooldown not armed")
    end)
end

local function run_cast_checks()
    check("point order reaches EVENT_UNIT_SPELL_EFFECT", function()
        assert(spell.fired, string.format(
            "spell effect event did not fire (order=%s mana=%.0f)",
            tostring(jass.GetUnitCurrentOrder(S.hero)), state_value(S.hero, 2)))
        assert(spell.ability == wave.ability,
            string.format("ability %s != AHbz %s",
                tostring(spell.ability), tostring(wave.ability)))
    end)

    check("cooldown gate rejects a second cast", function()
        S.cd_left = 4.0
        local again = wave.try_cast()
        assert(again == false, "cooldown gate let the cast through")
        assert(S.cast_count == 1, "cast count " .. tostring(S.cast_count))
    end)

    check("selection is readable for gameplay code", function()
        jass.SelectUnit(S.hero, true)
        local selected = util.get_selected_unit()
        assert(selected ~= nil, "no selected unit")
    end)
end

-- ── report ────────────────────────────────────────────────────────

function finish()
    print("")
    print("========================================")
    print(string.format(" Results: %d passed, %d failed, %d total (%d skipped)",
        pass, fail, pass + fail, skip))
    print("========================================")
    if fail == 0 then
        print("WAVE DEFENSE SLICE OK")
    else
        print("WAVE DEFENSE SLICE FAILED")
    end
end

-- ── entry point ───────────────────────────────────────────────────

function M.run()
    -- The command-submit chain behind LocalPointOrder is only up a few frames
    -- into the game, so the slice starts after the first second.
    after(1.5, function()
        local ok, hud_err = wave.setup(true)
        if not ok then
            error("world setup failed: " .. tostring(hud_err), 0)
        end
        if hud_err then
            print("[slice] HUD unavailable: " .. tostring(hud_err))
        end
        hud = wave.hud
        arm_spell_trigger()
    end)

    -- Game-loop checks are synchronous: the clock is not running yet, so every
    -- step is driven by wave.tick() and the result cannot race a timer.
    after(2.2, run_world_checks)
    after(2.3, run_loop_checks)

    after(2.35, run_feedback_checks)
    after(2.5, run_move_checks)
    after(3.0, run_move_result_checks)

    after(5.6, function()
        run_cast_checks()
        -- Leave a fresh, playable run: the self-check ends up in victory/defeat
        -- states, and a human session should start from wave one.
        wave.set_cursor_override(nil)
        wave.restart(true)
        wave.start_clock()
        print("[slice] game running: left click = move, Q = Blizzard at cursor, R = restart")
        finish()
    end)

end

return M
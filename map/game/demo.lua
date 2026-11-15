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
local camera = require "lib.camera"
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
        check("HUD text, bars and panel are live", function()
            local counts = assert(d3d.stats())
            assert(counts.device_ready, "d3d device not ready")
            assert(counts.texts >= 6, "texts=" .. tostring(counts.texts))
            assert(counts.textures >= 20, "textures=" .. tostring(counts.textures))
            local text = hud.wave:get_text()
            assert(text:find("Wave", 1, true), "wave text: " .. text)
            assert(not hud.banner:get_visible(), "banner leaked from a previous run")
        end)
    else
        skip_check("HUD text, bars and panel are live", "d3d unavailable")
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

-- ── checks: overhead bars, projection, damage numbers ────────────

local function bar_for(list, unit)
    for _, bar in ipairs(list) do
        if bar.unit == unit then return bar end
    end
    return nil
end

local function damage(unit, amount)
    jass.UnitDamageTarget(S.hero, unit, amount, true, false,
        jass.ConvertAttackType(0), jass.ConvertDamageType(4),
        jass.ConvertWeaponType(0))
end

local function run_feedback_checks()
    print("")
    print("-- overhead health bars, projection and damage numbers --")

    -- A fresh wave gives the bars something to track.
    wave.spawn_wave(1)
    local entry = nil
    for _, candidate in ipairs(S.creeps) do
        if not candidate.dead then entry = candidate break end
    end

    wave.set_cursor_override(jass.GetUnitX(S.hero), jass.GetUnitY(S.hero))
    wave.hud_tick()

    check("overlay projection uses the measured frustum", function()
        local cam = wave.camera_state()
        assert(cam.ready, "camera basis unavailable")
        -- These three constants were measured on 1.27a by pointing the cursor at
        -- grid points (see docs/guide/MINIMAL-GAME-LOOP.md): the engine stretches
        -- a 4:3 frustum across the client and puts the principal point above the
        -- geometric centre. Re-deriving them at runtime used to drag the bars
        -- ~95 px off, so the check pins them down instead.
        local expected_fx = 0.91092 * cam.width
        local expected_fy = 1.21454 * cam.height
        local expected_cy = 0.40835 * cam.height
        assert(math.abs(cam.focal_x - expected_fx) <= 1.0,
            string.format("focal x %.2f, expected %.2f", cam.focal_x, expected_fx))
        assert(math.abs(cam.focal_y - expected_fy) <= 1.0,
            string.format("focal y %.2f, expected %.2f", cam.focal_y, expected_fy))
        assert(math.abs(cam.center_y - expected_cy) <= 1.0,
            string.format("centre y %.2f, expected %.2f", cam.center_y, expected_cy))
        local sx, sy, on_screen = camera.project(cam.target_x, cam.target_y, cam.target_z)
        assert(on_screen, "camera target projected off screen")
        local off = math.sqrt((sx - cam.width * 0.5) ^ 2 + (sy - cam.center_y) ^ 2)
        assert(off < 1.5,
            string.format("camera target landed %.1f px off the anchor", off))
    end)

    check("the cursor pick round-trips through the projection", function()
        -- The engine resolves the terrain point under the cursor for us; when the
        -- cursor is over the field that is a free ground-truth sample of the whole
        -- projection (basis, focal lengths and principal point at once).
        local okm, mx, my = pcall(message.mouse)
        local oks, nx, ny = pcall(message.mouse_screen)
        local cam = wave.camera_state()
        local usable = okm and oks and type(mx) == "number" and type(nx) == "number"
            and not (mx == 0.0 and my == 0.0)
            and nx > 0.02 and nx < 0.98 and ny > 0.02 and ny < 0.98
        if not usable then
            print("  (cursor is off the battlefield, round-trip sample skipped)")
            return
        end
        local gz = camera.ground_z(mx, my)
        local sx, sy = camera.project(mx, my, gz)
        local dx, dy = sx - nx * cam.width, sy - ny * cam.height
        local off = math.sqrt(dx * dx + dy * dy)
        assert(off < 6.0,
            string.format("cursor pick landed %.1f px off its pixel", off))
    end)

    check("base and hero carry overhead bars", function()
        -- Refresh first: the list a restarted run inherits can be stale and
        -- would report a bar that is no longer on the frame.
        wave.hud_tick()
        local list = wave.bars()
        local function describe()
            if #list == 0 then return "none drawn" end
            local parts = {}
            for _, bar in ipairs(list) do
                parts[#parts + 1] = string.format("%s@%d,%d", bar.kind, bar.x, bar.y)
            end
            return table.concat(parts, " ")
        end
        assert(bar_for(list, S.hero) ~= nil, "no bar for the hero (drawn: " .. describe() .. ")")
        if bar_for(list, S.base) == nil then
            -- The base can sit under the console or above the top bar; those
            -- bars are dropped on purpose, so the check asks for the recorded
            -- reason instead of a bar nobody would see.
            local skip = wave.bar_skip("base")
            assert(skip ~= nil,
                "no bar for the base and no drop reason (drawn: " .. describe() .. ")")
            print(string.format("[demo] base bar skipped: %s at sy=%.1f",
                skip.reason, skip.sy))
        end
    end)

    check("bars are anchored over the units, not on the ground", function()
        local list = wave.bars()
        -- The base may be dropped (console/top bar), so one bar is enough to
        -- check the anchor rule.
        assert(#list >= 1, "drawn " .. tostring(#list) .. " bars")
        for _, bar in ipairs(list) do
            local gx, gy, on_screen = camera.project(bar.world_x, bar.world_y,
                camera.ground_z(bar.world_x, bar.world_y))
            assert(on_screen, bar.kind .. " ground point off screen")
            -- Lifting the anchor off the ground also shifts it slightly towards
            -- the screen centre (a head is closer to the camera than the ground
            -- under it), so the sideways match is proportional, not exact.
            local drift = math.max(24.0, bar.w)
            assert(math.abs(bar.screen_x - gx) < drift,
                string.format("%s bar drifted %.1f px sideways", bar.kind,
                    math.abs(bar.screen_x - gx)))
            assert(bar.screen_y < gy - 4.0,
                string.format("%s bar sits %.1f px below its head anchor", bar.kind,
                    bar.screen_y - gy))
        end
    end)

    assert(entry ~= nil, "wave 1 spawned no creeps")

    check("a bar follows its unit across the ground", function()
        local before = bar_for(wave.bars(), entry.unit)
        assert(before ~= nil, "no bar before the move")
        jass.SetUnitPosition(entry.unit,
            jass.GetUnitX(entry.unit) + 60.0, jass.GetUnitY(entry.unit))
        wave.hud_tick()
        local after = bar_for(wave.bars(), entry.unit)
        assert(after ~= nil, "bar vanished after the move")
        local moved = math.abs(after.screen_x - before.screen_x)
            + math.abs(after.screen_y - before.screen_y)
        assert(moved > 6.0, string.format("bar moved %.1f px", moved))
    end)

    wave.set_cursor_override(jass.GetUnitX(entry.unit), jass.GetUnitY(entry.unit))
    wave.hud_tick()

    check("cursor over a creep highlights its bar", function()
        local hover = wave.hovered()
        assert(hover ~= nil, "no creep under the cursor")
        assert(hover.unit == entry.unit, "hovered a different creep")
        local bar = bar_for(wave.bars(), entry.unit)
        assert(bar ~= nil, "no bar for the hovered creep")
        assert(bar.hover == true, "bar not flagged as hovered")
    end)

    check("hurt creeps read shorter and redder", function()
        local before = bar_for(wave.bars(), entry.unit)
        assert(before ~= nil, "no bar for the wave-1 creep")
        assert(before.frac > 0.9, string.format("fresh creep at %.2f", before.frac))
        -- Damage relative to the life the unit really has: a wave's toughness
        -- comes from its unit type, not from a max-life write.
        local max_life = entry.max_life or 420.0
        damage(entry.unit, max_life * 0.85)
        wave.hud_tick()
        local after = bar_for(wave.bars(), entry.unit)
        assert(after ~= nil, "bar vanished after damage")
        assert(after.frac < 0.35, string.format("frac %.2f", after.frac))
        assert(after.filled < before.filled,
            string.format("fill %d -> %d px", before.filled, after.filled))
        local red = math.floor(after.color / 65536) % 256
        local green = math.floor(after.color / 256) % 256
        assert(red > green, string.format("fill colour %06X is not red", after.color))
    end)

    check("a dead creep no longer has a bar", function()
        damage(entry.unit, 100000.0)
        wave.tick(0.25)
        wave.hud_tick()
        assert(bar_for(wave.bars(), entry.unit) == nil, "bar survived its unit")
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
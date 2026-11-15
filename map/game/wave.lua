-- map/game/wave.lua — wave-defense game built on the documented JAPI surface.
--
-- The game is deliberately small (five waves, three minutes) but it is a real
-- loop: prep -> spawn -> fight -> score -> win/lose -> restart. Everything goes
-- through documented entry points only:
--
--   jass.common  -> natives (units, orders, widget state)
--   jass.message -> message.hook, order_point, mouse
--   jass.d3d     -> Font/Text/Texture (static P3 API)
--
-- map/game/demo.lua drives this module through M.tick / M.spawn_wave / M.restart
-- so the self-check exercises the shipping code paths instead of a test copy.

local jass = require "jass.common"
local message = require "jass.message"
local d3d = require "jass.d3d"
local scene = require "lib.scene"

local M = {}

local KEY_Q = 0x51
local KEY_R = 0x52
local KEY_F2 = 0x301
-- Local-order flags used by builtin-japi's LocalPointOrder examples.
local FLAG_LOCAL = (1 << 2) | (1 << 5)
-- ConvertUnitState indices
local LIFE, MAX_LIFE, MANA, MAX_MANA = 0, 1, 2, 3

local CFG = {
    wave_sizes = { 3, 4, 4, 5, 5 },
    wave_life = { 160.0, 190.0, 220.0, 250.0, 280.0 },
    wave_speed = { 190.0, 200.0, 215.0, 225.0, 240.0 },
    prep_first = 4.0,
    prep_break = 7.0,
    time_limit = 180.0,
    base_hp = 1200.0,
    spawn_radius = 1100.0,
    hero_respawn = 6.0,
    cast_cd = 6.0,
    cast_mana = 75.0,
    kill_score = 100,
}

M.config = CFG

-- ── State ─────────────────────────────────────────────────────────

local S = {
    phase = "idle", -- idle | prep | wave | victory | defeat
    wave = 0,
    kills = 0,
    score = 0,
    base_hp = CFG.base_hp,
    base_max = CFG.base_hp,
    time_left = CFG.time_limit,
    prep_left = 0,
    creeps = {},
    hero = nil,
    base = nil,
    clock = nil, -- the 0.25s game-loop timer, created by M.start_clock()
    cd_left = 0.0,
    q_held = false,
    restart_requested = false,
    hero_dead = false,
    move_ok = nil,
    move_error = nil,
    cast_ok = nil,
    cast_error = nil,
    cast_count = 0,
    finish_reason = nil,
    hud = { ready = false },
}

M.state = S
-- The HUD table is filled in by setup(); demo.lua rebinds it after that.
M.hud = S.hud

-- ── Small helpers ─────────────────────────────────────────────────

local function fourcc(value)
    local a, b, c, d = value:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function state_value(unit, index)
    if not unit then return 0.0 end
    local ok, value = pcall(jass.GetUnitState, unit, jass.ConvertUnitState(index))
    if not ok or type(value) ~= "number" then return 0.0 end
    return value
end

local function unit_alive(unit)
    if not unit then return false end
    local ok, id = pcall(jass.GetUnitTypeId, unit)
    if not ok or type(id) ~= "number" or id == 0 then return false end
    return state_value(unit, LIFE) > 0.0
end

local function pct(value, maximum)
    if not maximum or maximum <= 0.0 then return 0.0 end
    local frac = value / maximum
    if frac < 0.0 then frac = 0.0 end
    if frac > 1.0 then frac = 1.0 end
    return frac
end

-- ── World geometry ────────────────────────────────────────────────

local function world_bounds()
    local ok, rect = pcall(jass.GetWorldBounds)
    if not ok or not rect then return nil end
    local ok2, minx = pcall(jass.GetRectMinX, rect)
    local ok3, miny = pcall(jass.GetRectMinY, rect)
    local ok4, maxx = pcall(jass.GetRectMaxX, rect)
    local ok5, maxy = pcall(jass.GetRectMaxY, rect)
    if not (ok2 and ok3 and ok4 and ok5) then return nil end
    if type(minx) ~= "number" or type(miny) ~= "number"
        or type(maxx) ~= "number" or type(maxy) ~= "number" then
        return nil
    end
    return minx, miny, maxx, maxy
end

local function clamp_point(x, y, inset)
    local minx, miny, maxx, maxy = world_bounds()
    if not minx then return x, y end
    if x < minx + inset then x = minx + inset end
    if x > maxx - inset then x = maxx - inset end
    if y < miny + inset then y = miny + inset end
    if y > maxy - inset then y = maxy - inset end
    return x, y
end

local function walkable(x, y)
    -- PATHING_TYPE_WALKABILITY == 0 in common.j's convert helper
    local ok, result = pcall(jass.IsTerrainPathable, x, y,
        jass.ConvertPathingType and jass.ConvertPathingType(0) or 0)
    if not ok then return true end -- never block spawning on a failed probe
    return result ~= false
end

-- ── HUD ───────────────────────────────────────────────────────────

local hud = S.hud

local function hud_create()
    if not d3d.is_available() then
        return false, tostring(d3d.status().error or "proxy unavailable")
    end
    local width, height = d3d.window_size()
    if width <= 0 or height <= 0 then
        return false, "window size unavailable"
    end

    local panel_source = "game://ReplaceableTextures\\CommandButtons\\BTNRifleman.blp"
    local bar_source = "game://ReplaceableTextures\\CommandButtons\\BTNSteelMelee.blp"

    hud.font = assert(d3d.Font.new { face = "Arial", height = 17, weight = 700 })
    hud.big_font = assert(d3d.Font.new { face = "Arial", height = 30, weight = 900 })

    -- War3's own top bar and the selected-unit panel own the first ~110 client
    -- pixels, so the plate starts below them.
    local top = 118
    hud.panel = assert(d3d.Texture.new {
        source = panel_source,
        x = 12, y = top - 12, width = 780, height = 194,
        color = d3d.rgba(8, 8, 10, 200), z = 99,
    })
    hud.title = assert(d3d.Text.new {
        font = hud.font, text = "JAPI WAVE DEFENSE",
        x = 26, y = top, color = d3d.rgba(255, 230, 120, 255), z = 100,
    })
    hud.wave = assert(d3d.Text.new {
        font = hud.font, text = "",
        x = 26, y = top + 24, color = d3d.rgba(235, 245, 255, 255), z = 100,
    })
    hud.base = assert(d3d.Text.new {
        font = hud.font, text = "",
        x = 26, y = top + 52, color = d3d.rgba(200, 230, 255, 255), z = 100,
    })
    hud.hero = assert(d3d.Text.new {
        font = hud.font, text = "",
        x = 26, y = top + 96, color = d3d.rgba(220, 255, 220, 255), z = 100,
    })
    hud.hint = assert(d3d.Text.new {
        font = hud.font,
        text = "Left click = move | Q = Blizzard at cursor | R = restart",
        x = 26, y = top + 142, color = d3d.rgba(255, 255, 255, 200), z = 100,
    })

    -- Bars are tinted textures; set_rect() drives the width.
    hud.base_bar_bg = assert(d3d.Texture.new {
        source = bar_source, x = 26, y = top + 74, width = 748, height = 12,
        color = d3d.rgba(20, 24, 20, 220), z = 100,
    })
    hud.base_bar = assert(d3d.Texture.new {
        source = bar_source, x = 26, y = top + 74, width = 748, height = 12,
        color = d3d.rgba(70, 210, 110, 235), z = 101,
    })
    hud.hero_bar_bg = assert(d3d.Texture.new {
        source = bar_source, x = 26, y = top + 118, width = 748, height = 10,
        color = d3d.rgba(20, 20, 24, 220), z = 100,
    })
    hud.hero_bar = assert(d3d.Texture.new {
        source = bar_source, x = 26, y = top + 118, width = 748, height = 10,
        color = d3d.rgba(110, 190, 255, 235), z = 101,
    })

    hud.banner = assert(d3d.Text.new {
        font = hud.big_font, text = "",
        x = 190, y = 300, color = d3d.rgba(255, 240, 150, 255), z = 110,
    })
    hud.banner:set_visible(false)

    hud.layout = {
        top = top,
        base_bar = { x = 26, y = top + 74, w = 748, h = 12 },
        hero_bar = { x = 26, y = top + 118, w = 748, h = 10 },
    }
    print(string.format("[game] client %dx%d, hud %d..%d", width, height, top - 12, top + 160))
    hud.ready = true
    return true
end

local function bar_set(node, layout, frac)
    if not node then return end
    local width = math.max(0, math.floor(layout.w * frac + 0.5))
    node:set_rect(layout.x, layout.y, width, layout.h)
    node:set_visible(width > 0)
end

local function hud_refresh()
    if not hud.ready then return end
    local wave_total = #CFG.wave_sizes
    local status
    if S.phase == "prep" then
        status = string.format("next wave in %.1fs", math.max(0.0, S.prep_left))
    elseif S.phase == "wave" then
        status = string.format("creeps alive %d", M.creeps_alive())
    elseif S.phase == "victory" then
        status = "victory"
    elseif S.phase == "defeat" then
        status = "defeat"
    else
        status = "idle"
    end
    hud.wave:set_text(string.format(
        "Wave %d/%d   %s   time %.0fs   kills %d   score %d",
        S.wave, wave_total, status, math.max(0.0, S.time_left), S.kills, S.score))

    hud.base:set_text(string.format("BASE  %.0f/%.0f", math.max(0.0, S.base_hp), S.base_max))
    bar_set(hud.base_bar, hud.layout.base_bar, pct(S.base_hp, S.base_max))

    local hero = S.hero
    local hero_text
    if hero and unit_alive(hero) then
        local q = "READY"
        if S.cd_left > 0.05 then q = string.format("%.1fs", S.cd_left) end
        hero_text = string.format("HERO  Lv %d  HP %.0f/%.0f  MP %.0f/%.0f  Q %s",
            jass.GetHeroLevel(hero),
            state_value(hero, LIFE), state_value(hero, MAX_LIFE),
            state_value(hero, MANA), state_value(hero, MAX_MANA), q)
    else
        hero_text = "HERO  dead - respawning"
    end
    hud.hero:set_text(hero_text)
    if hero and unit_alive(hero) then
        bar_set(hud.hero_bar, hud.layout.hero_bar, pct(state_value(hero, LIFE), state_value(hero, MAX_LIFE)))
    else
        bar_set(hud.hero_bar, hud.layout.hero_bar, 0.0)
    end
end

local function hud_banner(text, argb)
    if not hud.ready then return end
    hud.banner:set_text(text)
    if argb then hud.banner:set_color(argb) end
    hud.banner:set_visible(true)
end

M.hud_refresh = hud_refresh

-- ── Feedback: floating text and hit flash ─────────────────────────

local function floating_text(x, y, text, r, g, b)
    local ok, tag = pcall(jass.CreateTextTag)
    if not ok or not tag then return end
    pcall(jass.SetTextTagText, tag, text, 0.022, 90.0)
    pcall(jass.SetTextTagPos, tag, x, y, 90.0)
    pcall(jass.SetTextTagColor, tag, r or 255, g or 220, b or 120, 255)
    pcall(jass.SetTextTagPermanent, tag, false)
    pcall(jass.SetTextTagLifespan, tag, 1.1)
    pcall(jass.SetTextTagVelocity, tag, 0.0, 0.045)
    pcall(jass.SetTextTagVisibility, tag, true)
end

local function hit_flash(unit)
    pcall(jass.SetUnitVertexColor, unit, 255, 90, 90, 255)
    local timer = jass.CreateTimer()
    jass.TimerStart(timer, 0.12, false, function()
        jass.DestroyTimer(timer)
        pcall(jass.SetUnitVertexColor, unit, 255, 255, 255, 255)
    end)
end

-- ── Waves ─────────────────────────────────────────────────────────

local function spawn_point(index, total, wave)
    local bx = jass.GetUnitX(S.base)
    local by = jass.GetUnitY(S.base)
    local angle = math.rad(40.0 + (index - 1) * (360.0 / total) + (wave * 23) % 30)
    local radius = CFG.spawn_radius
    for _ = 1, 4 do
        local x, y = clamp_point(bx + math.cos(angle) * radius, by + math.sin(angle) * radius, 400.0)
        if walkable(x, y) then return x, y end
        radius = radius * 0.7
    end
    return clamp_point(bx + math.cos(angle) * radius, by + math.sin(angle) * radius, 300.0)
end

local function order_attack(unit, x, y)
    local ok, issued = pcall(jass.IssuePointOrder, unit, "attack", x, y)
    if ok and issued then return true end
    local ok2, issued2 = pcall(jass.IssuePointOrderById, unit, 851983, x, y) -- 0x0D0015 attack
    if ok2 and issued2 then return true end
    local ok3 = pcall(jass.IssuePointOrder, unit, "move", x, y)
    return ok3 and true or false
end

local function spawn_creep(wave, index, total)
    local x, y = spawn_point(index, total, wave)
    local ok, unit = pcall(jass.CreateUnit, jass.Player(1), fourcc("hfoo"), x, y, 270.0)
    if not ok or not unit then
        print("[game] creep spawn failed: " .. tostring(unit))
        return nil
    end
    pcall(jass.SetUnitState, unit, jass.ConvertUnitState(MAX_LIFE), CFG.wave_life[wave])
    pcall(jass.SetWidgetLife, unit, CFG.wave_life[wave])
    pcall(jass.SetUnitMoveSpeed, unit, CFG.wave_speed[wave])
    order_attack(unit, jass.GetUnitX(S.base), jass.GetUnitY(S.base))
    local entry = {
        unit = unit,
        wave = wave,
        life = state_value(unit, LIFE),
        dead = false,
        order = jass.GetUnitCurrentOrder(unit),
    }
    S.creeps[#S.creeps + 1] = entry
    return entry
end

function M.spawn_wave(wave)
    local total = #CFG.wave_sizes
    if wave < 1 then wave = 1 end
    if wave > total then wave = total end
    S.wave = wave
    S.phase = "wave"
    S.prep_left = 0.0
    local size = CFG.wave_sizes[wave]
    for i = 1, size do spawn_creep(wave, i, size) end
    print(string.format("[game] wave %d/%d spawned: %d creeps, hp %.0f, speed %.0f",
        wave, total, size, CFG.wave_life[wave], CFG.wave_speed[wave]))
    hud_refresh()
    return size
end

local function update_creeps()
    for _, entry in ipairs(S.creeps) do
        if not entry.dead then
            local alive = unit_alive(entry.unit)
            local life = state_value(entry.unit, LIFE)
            if not alive or life <= 0.0 then
                entry.dead = true
                S.kills = S.kills + 1
                S.score = S.score + CFG.kill_score
                floating_text(jass.GetUnitX(entry.unit), jass.GetUnitY(entry.unit),
                    "+" .. tostring(CFG.kill_score), 255, 235, 120)
            else
                if entry.life and life < entry.life - 0.5 then
                    local dealt = entry.life - life
                    floating_text(jass.GetUnitX(entry.unit), jass.GetUnitY(entry.unit),
                        "-" .. string.format("%.0f", dealt), 255, 140, 130)
                end
                entry.life = life
                if entry.order == nil or entry.order == 0 then
                    entry.order = jass.GetUnitCurrentOrder(entry.unit)
                end
            end
        end
    end
end

function M.creeps_alive()
    local count = 0
    for _, entry in ipairs(S.creeps) do
        if not entry.dead and unit_alive(entry.unit) then count = count + 1 end
    end
    return count
end

function M.creeps_total()
    return #S.creeps
end

-- ── Win / lose ────────────────────────────────────────────────────

local function finish(kind, reason)
    if S.phase == "victory" or S.phase == "defeat" then return end
    S.phase = kind
    S.finish_reason = reason
    if kind == "victory" then
        S.score = S.score + math.floor(math.max(0.0, S.base_hp))
        hud_banner("VICTORY   score " .. tostring(S.score), d3d.rgba(255, 240, 140, 255))
        print(string.format("[game] VICTORY  kills=%d score=%d base=%.0f time=%.1f",
            S.kills, S.score, S.base_hp, CFG.time_limit - S.time_left))
    else
        hud_banner("DEFEAT (" .. tostring(reason or "base") .. ")  score " .. tostring(S.score),
            d3d.rgba(255, 130, 130, 255))
        print(string.format("[game] DEFEAT  reason=%s wave=%d kills=%d base=%.0f time=%.1f",
            tostring(reason), S.wave, S.kills, S.base_hp, CFG.time_limit - S.time_left))
    end
    message.hook = nil
    hud_refresh()
end

M.finish = finish

-- ── Hero ──────────────────────────────────────────────────────────

local function ensure_hero_resources(hero)
    pcall(jass.SetHeroInt, hero, 60, true)
    pcall(jass.SetUnitState, hero, jass.ConvertUnitState(MANA), 500.0)
    pcall(jass.SetUnitState, hero, jass.ConvertUnitState(MAX_MANA), 500.0)
    local blizzard = fourcc("AHbz")
    if jass.GetUnitAbilityLevel(hero, blizzard) <= 0 then
        pcall(jass.UnitAddAbility, hero, blizzard)
        pcall(jass.SetUnitAbilityLevel, hero, blizzard, 1)
    end
    M.ability = blizzard
end

local function respawn_hero()
    local hero = S.hero
    if not hero then return end
    local x = jass.GetUnitX(S.base) + 120.0
    local y = jass.GetUnitY(S.base)
    local revived = pcall(jass.ReviveHero, hero, x, y, true)
    if not revived then
        pcall(jass.SetUnitPosition, hero, x, y)
        pcall(jass.SetWidgetLife, hero, state_value(hero, MAX_LIFE))
    end
    S.hero_dead = false
    pcall(jass.SelectUnit, hero, true)
    pcall(jass.SetCameraPosition, x, y)
    print("[game] hero revived")
end

-- ── Input ─────────────────────────────────────────────────────────

local function cursor_point()
    if S.cursor_override then return S.cursor_override[1], S.cursor_override[2] end
    local ok, x, y = pcall(message.mouse)
    if ok and type(x) == "number" and type(y) == "number" then return x, y end
    return jass.GetUnitX(S.hero), jass.GetUnitY(S.hero)
end

-- Movement goes through jass.common's point order on the hero itself.
--
-- message.order_point is deliberately NOT used here: measured on 1.27a, that
-- path returns true but a "move" order never reaches the unit (order stays 0,
-- position does not change), while the same call with a "blizzard" order does
-- cast. It is the local ability-cast submit path, so movement uses the normal
-- native and the cast keeps using message.order_point.
function M.move_to(x, y, verbose)
    local ok, submitted = false, nil
    if S.hero then
        ok, submitted = pcall(jass.IssuePointOrder, S.hero, "move", x, y)
    end
    S.move_ok = ok and submitted == true
    S.move_error = ok and nil or tostring(submitted)
    if verbose then
        print(string.format("[game] move order to %.1f,%.1f submitted=%s %s",
            x, y, tostring(S.move_ok), tostring(S.move_error or "")))
    end
    return S.move_ok
end

local function cast_blizzard(x, y)
    local ok, submitted = pcall(message.order_point, jass.OrderId("blizzard"), x, y, FLAG_LOCAL)
    S.cast_ok = ok and submitted == true
    S.cast_error = ok and nil or tostring(submitted)
    if S.cast_ok then
        S.cast_count = S.cast_count + 1
        S.cd_left = CFG.cast_cd
    end
    return S.cast_ok
end

-- Deterministic cursor for the self-check: the real path (message.mouse) is
-- still what a player hits; only the headless run pins the point.
function M.set_cursor_override(x, y)
    if x == nil then
        S.cursor_override = nil
    else
        S.cursor_override = { x, y }
    end
end

function M.try_cast(x, y)
    if S.phase == "victory" or S.phase == "defeat" then return false end
    if not S.hero or not unit_alive(S.hero) then return false end
    if S.cd_left > 0.05 then return false end
    if state_value(S.hero, MANA) < CFG.cast_mana then return false end
    local cx, cy = x, y
    if type(cx) ~= "number" or type(cy) ~= "number" then cx, cy = cursor_point() end
    return cast_blizzard(cx, cy)
end

local function on_message(msg)
    if type(msg) ~= "table" then return true end
    if msg.type == "key_down" then
        if msg.code == KEY_Q then
            if S.q_held then return false end
            S.q_held = true
            local cast = M.try_cast()
            print(string.format("[game] Q: cast %s (cd %.1fs, mana %.0f)",
                cast and "submitted" or "blocked", S.cd_left, state_value(S.hero, MANA)))
            return false
        end
        if msg.code == KEY_R or msg.code == KEY_F2 then
            S.restart_requested = true
            print("[game] restart requested")
            return false
        end
        return true
    end
    if msg.type == "key_up" then
        if msg.code == KEY_Q then
            S.q_held = false
            return false
        end
        return true
    end
    -- Mouse buttons never reach this hook on War3 1.27a in windowed mode (the
    -- CGameUI dispatch that feeds it only carries keyboard codes, and the WndProc
    -- hook feeds the d3d input queue instead), so movement is the engine's own
    -- left-click order and every click passes straight through.
    return true
end

M.on_message = on_message

-- ── Lifecycle ─────────────────────────────────────────────────────

local function reset_counters()
    S.phase = "prep"
    S.wave = 0
    S.kills = 0
    S.score = 0
    S.base_hp = CFG.base_hp
    S.base_max = CFG.base_hp
    S.time_left = CFG.time_limit
    S.prep_left = CFG.prep_first
    S.creeps = {}
    S.cd_left = 0.0
    S.q_held = false
    S.restart_requested = false
    S.hero_dead = false
    S.finish_reason = nil
    S.move_ok = nil
    S.cast_ok = nil
    S.cast_count = 0
end

local function build_world(verbose)
    local hero = scene.reset(true)
    S.hero = hero
    ensure_hero_resources(hero)

    local hx = jass.GetUnitX(hero)
    local hy = jass.GetUnitY(hero)
    local bx, by = clamp_point(hx, hy - 560.0, 480.0)
    -- The base uses the biggest hall available so a run survives a few waves;
    -- higher tiers are tried first and the first one that spawns wins.
    local base, base_id
    for _, type_id in ipairs({ "hcas", "hkee", "hhou" }) do
        local ok, unit = pcall(jass.CreateUnit, jass.Player(0), fourcc(type_id), bx, by, 270.0)
        if ok and unit then
            base, base_id = unit, type_id
            break
        end
    end
    if not base then
        print("[game] base spawn failed at " .. string.format("%.0f,%.0f", bx, by))
        return false
    end
    S.base = base
    pcall(jass.SetUnitInvulnerable, base, false)
    pcall(jass.SetUnitName, base, "JAPI Base")

    -- SetUnitState(MAX_LIFE) does not always stick on a building that was just
    -- created, so the real ceiling is read back and becomes the run's base hp.
    pcall(jass.SetUnitState, base, jass.ConvertUnitState(MAX_LIFE), CFG.base_hp)
    S.base_max = state_value(base, MAX_LIFE)
    if S.base_max <= 0.0 then S.base_max = CFG.base_hp end
    if S.base_max < CFG.base_hp then
        print(string.format("[game] base %s caps at %.0f hp", base_id, S.base_max))
        CFG.base_hp = S.base_max
    end
    pcall(jass.SetWidgetLife, base, S.base_max)
    S.base_hp = state_value(base, LIFE)

    pcall(jass.SelectUnit, hero, true)
    pcall(jass.SetCameraPosition, bx, by)
    -- Keep the camera locked on the hero: a wave runs far from the base, and an
    -- unlocked camera loses the player as soon as the hero leaves the screen.
    pcall(jass.SetCameraTargetController, hero, 0.0, 0.0, false)
    if verbose then
        print(string.format("[game] hero at %.0f,%.0f  base %s at %.0f,%.0f (%.0f/%.0f hp)",
            hx, hy, base_id, bx, by, S.base_hp, S.base_max))
    end
    return true
end

function M.restart(verbose)
    reset_counters()
    if hud.ready then hud.banner:set_visible(false) end
    if not build_world(verbose) then return false end
    message.hook = on_message
    hud_refresh()
    if verbose then print("[game] restart: wave 1 prep") end
    return true
end

function M.new(verbose)
    reset_counters()
    if not build_world(verbose) then return false, "world build failed" end
    message.hook = on_message
    hud_refresh()
    return true
end

function M.tick(dt)
    dt = dt or 0.25
    if S.phase == "prep" then
        S.prep_left = S.prep_left - dt
        if S.prep_left <= 0.0 then M.spawn_wave(S.wave + 1) end
    elseif S.phase == "wave" then
        update_creeps()
        local alive = M.creeps_alive()
        if alive == 0 then
            if S.wave >= #CFG.wave_sizes then
                finish("victory")
            else
                S.phase = "prep"
                S.prep_left = CFG.prep_break
                print(string.format("[game] wave %d cleared, next in %.1fs", S.wave, S.prep_left))
            end
        end
    end

    if S.phase == "prep" or S.phase == "wave" then
        S.time_left = S.time_left - dt
        if S.time_left <= 0.0 then
            S.time_left = 0.0
            finish("defeat", "time")
        end
    end

    if S.cd_left > 0.0 then
        S.cd_left = math.max(0.0, S.cd_left - dt)
    end

    -- Base and hero health are read from the engine, not tracked by hand, so
    -- any damage source (creeps, scripts, cheats) feeds the same state.
    if S.base then
        S.base_hp = state_value(S.base, LIFE)
        if S.base_hp <= 0.0 and S.phase ~= "defeat" and S.phase ~= "victory" then
            S.base_hp = 0.0
            finish("defeat", "base")
        end
    end
    if S.hero and not S.hero_dead then
        if not unit_alive(S.hero) then
            S.hero_dead = true
            print(string.format("[game] hero died, respawning in %.1fs", CFG.hero_respawn))
            local timer = jass.CreateTimer()
            jass.TimerStart(timer, CFG.hero_respawn, false, function()
                jass.DestroyTimer(timer)
                respawn_hero()
            end)
        end
    end

    hud_refresh()
end

local function game_loop()
    local timer = jass.CreateTimer()
    jass.TimerStart(timer, 0.25, true, function()
        local ok, err = pcall(M.tick, 0.25)
        if not ok then print("[game] tick failed: " .. tostring(err)) end
        if S.restart_requested then
            S.restart_requested = false
            local ok2, err2 = pcall(M.restart, true)
            if not ok2 then print("[game] restart failed: " .. tostring(err2)) end
        end
    end)
    S.clock = timer
    return timer
end

function M.start_clock()
    if S.clock then return S.clock end
    return game_loop()
end

function M.stop_clock()
    if not S.clock then return end
    pcall(jass.DestroyTimer, S.clock)
    S.clock = nil
end

function M.setup(verbose)
    local hud_ok, hud_err = hud_create()
    if not hud_ok then print("[game] HUD unavailable: " .. tostring(hud_err)) end
    local ok, err = M.new(verbose)
    if not ok then return false, err end
    return true, hud_err
end

return M

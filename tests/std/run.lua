-- tests/std/run.lua — Comprehensive offline unit test suite for all 10 std.* modules.
-- Runs under w3x2lni-lua (Lua 5.3/5.4) with zero War3 process required.

local root = arg[1] or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

-- ── Mock jass.* environment ────────────────────────────────────────────────

local next_hid = 0x100001
local function new_handle(kind, extra)
    local h = extra or {}
    h._kind = kind
    h._hid = next_hid
    next_hid = next_hid + 1
    return h
end

local active_timers = {}
local created_timers = 0
local destroyed_timers = 0
local triggers = {}
local created_effects = {}
local statbar_calls = {}
local units = {}
local players = {}
for pid = 0, 15 do
    players[pid] = new_handle("player", {
        pid = pid, name = "Player" .. pid, gold = 500, lumber = 200,
        sx = pid * 100, sy = pid * 50,
    })
end

local mock_common = {
    EVENT_PLAYER_UNIT_DEATH = 1,
    EVENT_PLAYER_UNIT_ATTACKED = 2,
    EVENT_PLAYER_UNIT_SPELL_EFFECT = 3,
    EVENT_PLAYER_UNIT_SPELL_CAST = 4,
    EVENT_PLAYER_UNIT_PICKUP_ITEM = 5,
    EVENT_PLAYER_UNIT_DROP_ITEM = 6,
    EVENT_PLAYER_UNIT_USE_ITEM = 7,
    EVENT_PLAYER_HERO_LEVEL = 8,
    EVENT_UNIT_DAMAGED = 9,
    PLAYER_STATE_RESOURCE_GOLD = 1,
    PLAYER_STATE_RESOURCE_LUMBER = 2,
    UNIT_STATE_LIFE = 0,
    UNIT_STATE_MAX_LIFE = 1,
    UNIT_STATE_MANA = 2,
    UNIT_STATE_MAX_MANA = 3,
    ATTACK_TYPE_NORMAL = 1,
    DAMAGE_TYPE_NORMAL = 4,
    WEAPON_TYPE_WHOKNOWS = 0,

    GetHandleId = function(h) return h and h._hid or 0 end,
    code = function(fn) return fn end,

    -- Timers
    CreateTimer = function()
        created_timers = created_timers + 1
        return new_handle("timer", { running = false })
    end,
    TimerStart = function(t, dur, periodic, fn)
        t.running = true
        t.dur = dur
        t.periodic = periodic
        t.fn = fn
        t.elapsed = 0
        active_timers[t] = true
    end,
    PauseTimer = function(t)
        if t then t.running = false; active_timers[t] = nil end
    end,
    DestroyTimer = function(t)
        if t then t.running = false; active_timers[t] = nil; destroyed_timers = destroyed_timers + 1 end
    end,

    -- Triggers & events
    CreateTrigger = function()
        local tr = new_handle("trigger", { events = {}, actions = {} })
        triggers[#triggers + 1] = tr
        return tr
    end,
    TriggerRegisterPlayerUnitEvent = function(tr, p, ev)
        tr.events[#tr.events + 1] = { kind = "pu", p = p, ev = ev }
    end,
    TriggerRegisterUnitEvent = function(tr, u, ev)
        tr.events[#tr.events + 1] = { kind = "u", u = u, ev = ev }
    end,
    TriggerRegisterPlayerChatEvent = function(tr, p, msg, exact)
        tr.events[#tr.events + 1] = { kind = "chat", p = p }
    end,
    TriggerAddAction = function(tr, fn)
        tr.actions[#tr.actions + 1] = fn
    end,

    -- Players
    Player = function(pid) return players[pid] end,
    GetPlayerId = function(p) return p.pid end,
    GetLocalPlayer = function() return players[0] end,
    GetPlayerName = function(p) return p.name end,
    SetPlayerName = function(p, n) p.name = n end,
    GetPlayerState = function(p, st) return st == 1 and p.gold or p.lumber end,
    SetPlayerState = function(p, st, v)
        if st == 1 then p.gold = v else p.lumber = v end
    end,
    DisplayTimedTextToPlayer = function(p, x, y, d, s) p.last_msg = s end,
    IsPlayerAlly = function(a, b) return (a.pid < 6) == (b.pid < 6) end,
    IsPlayerEnemy = function(a, b) return (a.pid < 6) ~= (b.pid < 6) end,
    GetPlayerStartLocationX = function(p) return p.sx end,
    GetPlayerStartLocationY = function(p) return p.sy end,

    -- Units
    CreateUnit = function(p, tid, x, y, face)
        local u = new_handle("unit", {
            owner = p, tid = tid, x = x, y = y, face = face,
            name = "MockUnit", hp = 500, max_hp = 500, mp = 200, max_mp = 200,
            abilities = {}, orders = {}, paused = false,
        })
        units[u._hid] = u
        return u
    end,
    GetUnitTypeId = function(u) return u.tid end,
    GetUnitName = function(u) return u.name end,
    GetOwningPlayer = function(u) return u.owner end,
    GetWidgetLife = function(u) return u.hp end,
    KillUnit = function(u) u.hp = 0 end,
    RemoveUnit = function(u) units[u._hid] = nil; u.removed = true end,
    GetUnitX = function(u) return u.x end,
    GetUnitY = function(u) return u.y end,
    SetUnitX = function(u, x) u.x = x end,
    SetUnitY = function(u, y) u.y = y end,
    GetUnitFacing = function(u) return u.face end,
    SetUnitFacing = function(u, f) u.face = f end,
    IssuePointOrder = function(u, ord, x, y) u.orders[#u.orders + 1] = { ord, x, y }; return true end,
    IssueImmediateOrder = function(u, ord) u.orders[#u.orders + 1] = { ord }; return true end,
    GetUnitState = function(u, st)
        if st == 0 then return u.hp
        elseif st == 1 then return u.max_hp
        elseif st == 2 then return u.mp
        elseif st == 3 then return u.max_mp end
        return 0
    end,
    SetUnitState = function(u, st, v)
        if st == 0 then u.hp = v elseif st == 2 then u.mp = v end
    end,
    UnitDamageTarget = function(src, tgt, amt)
        tgt.hp = math.max(0, tgt.hp - amt)
        return true
    end,
    UnitAddAbility = function(u, id) u.abilities[id] = 1; return true end,
    UnitRemoveAbility = function(u, id) u.abilities[id] = nil; return true end,
    GetUnitAbilityLevel = function(u, id) return u.abilities[id] or 0 end,
    SetUnitAbilityLevel = function(u, id, lv) u.abilities[id] = lv; return lv end,
    PauseUnit = function(u, f) u.paused = f end,

    -- Groups & Rects
    CreateGroup = function() return new_handle("group", { items = {} }) end,
    DestroyGroup = function(g) g.destroyed = true end,
    Rect = function(x0, y0, x1, y1) return new_handle("rect", { x0=x0, y0=y0, x1=x1, y1=y1 }) end,
    SetRect = function(r, x0, y0, x1, y1) r.x0, r.y0, r.x1, r.y1 = x0, y0, x1, y1 end,
    GetWorldBounds = function() return new_handle("rect", { x0=-5000, y0=-5000, x1=5000, y1=5000 }) end,
    GroupEnumUnitsInRange = function(g, x, y, r)
        g.items = {}
        for _, u in pairs(units) do
            local dx, dy = u.x - x, u.y - y
            if dx*dx + dy*dy <= r*r then g.items[#g.items + 1] = u end
        end
    end,
    GroupEnumUnitsInRect = function(g, rect)
        g.items = {}
        for _, u in pairs(units) do
            if u.x >= rect.x0 and u.x <= rect.x1 and u.y >= rect.y0 and u.y <= rect.y1 then
                g.items[#g.items + 1] = u
            end
        end
    end,
    GroupEnumUnitsOfPlayer = function(g, p)
        g.items = {}
        for _, u in pairs(units) do
            if u.owner == p then g.items[#g.items + 1] = u end
        end
    end,
    FirstOfGroup = function(g) return g.items[1] end,
    GroupRemoveUnit = function(g, u)
        for i = 1, #g.items do
            if g.items[i] == u then table.remove(g.items, i); return end
        end
    end,

    -- Effects
    AddSpecialEffect = function(model, x, y)
        local fx = new_handle("fx", { model = model, x = x, y = y, destroyed = false })
        created_effects[#created_effects + 1] = fx
        return fx
    end,
    AddSpecialEffectTarget = function(model, u, pt)
        local fx = new_handle("fx", { model = model, unit = u, pt = pt, destroyed = false })
        created_effects[#created_effects + 1] = fx
        return fx
    end,
    DestroyEffect = function(fx) fx.destroyed = true end,
}

local mana_enabled = false
local cull_enabled = false
local mock_japi = {
    EXSetManaBarEnabled = function(v) mana_enabled = v; statbar_calls[#statbar_calls + 1] = "mana:" .. tostring(v) end,
    EXGetManaBarEnabled = function() return mana_enabled end,
    EXSetOffscreenBarCull = function(v) cull_enabled = v; statbar_calls[#statbar_calls + 1] = "cull:" .. tostring(v) end,
    EXGetOffscreenBarCull = function() return cull_enabled end,
    EXSetManaBarColor = function(c) statbar_calls[#statbar_calls + 1] = string.format("mana_col:0x%X", c) end,
    EXSetManaBarHeight = function(h) statbar_calls[#statbar_calls + 1] = "mana_h:" .. tostring(h) end,
    EXSetManaBarOffsetY = function(o) statbar_calls[#statbar_calls + 1] = "mana_oy:" .. tostring(o) end,
    EXSetUnitHPBarColor = function(u, c) u.bar_color = c end,
    EXSetUnitHPBarScale = function(u, sx, sy) u.bar_sx, u.bar_sy = sx, sy end,
    EXSetUnitHPBarVisible = function(u, v) u.bar_vis = v end,
    EXSetUnitManaBarColor = function(u, c) u.mbar_color = c end,
    EXSetUnitManaBarVisible = function(u, v) u.mbar_vis = v end,
    EXSetUnitTypeHPBarStyle = function(id, c, sx, sy) statbar_calls[#statbar_calls + 1] = "type:" .. tostring(id) end,
    EXSetPlayerHPBarColor = function(p, c) p.bar_color = c end,
    EXResetUnitHPBar = function(u) u.bar_color = nil end,
    EXResetAllStatBars = function() mana_enabled = false; statbar_calls[#statbar_calls + 1] = "reset_all" end,
    EXSetUnitFacing = function(u, f) u.face = f; u.instant_face = true end,
    EXPauseUnit = function(u, f) u.paused = f; u.ex_paused = true end,
    EXSetEffectXY = function(fx, x, y) fx.x, fx.y = x, y end,
    EXSetEffectZ = function(fx, z) fx.z = z end,
    EXSetEffectSize = function(fx, s) fx.scale = s end,
    EXSetEffectSpeed = function(fx, s) fx.speed = s end,
}

local mock_message = { hook = nil }
local mock_map_event = {
    subs = {},
    on = function(name, fn)
        mock_map_event.subs[name] = fn
        return 1
    end,
}

-- Minimal mock D3D adapter for std.ui
local function make_fake_d3d()
    local counts = { fonts = 0, texts = 0, textures = 0, subs = 0 }
    local resize_cb = nil
    local win_w, win_h = 1280, 720

    local d3d = {
        mouse = { LEFT = 0, RIGHT = 1 },
        is_available = function() return true end,
        window_size = function() return win_w, win_h end,
        set_window_size = function(w, h)
            win_w, win_h = w, h
            if resize_cb then resize_cb({ width = w, height = h }) end
        end,
        on = function(ev, fn)
            if ev == "resize" then resize_cb = fn end
            counts.subs = counts.subs + 1
            local active = true
            return { cancel = function() if active then active = false; counts.subs = counts.subs - 1; resize_cb = nil end end }
        end,
        counts = function() return counts end,
        Font = {
            new = function(opts)
                counts.fonts = counts.fonts + 1
                local destroyed = false
                return {
                    opts = opts,
                    destroy = function() if not destroyed then destroyed = true; counts.fonts = counts.fonts - 1 end end,
                }
            end,
        },
        Text = {
            new = function(opts)
                counts.texts = counts.texts + 1
                local destroyed = false
                local obj = {
                    text = opts.text, x = opts.x, y = opts.y, color = opts.color, visible = opts.visible ~= false,
                }
                function obj:set_text(s) self.text = s end
                function obj:set_position(x, y) self.x, self.y = x, y end
                function obj:set_color(c) self.color = c end
                function obj:set_visible(v) self.visible = v end
                function obj:destroy() if not destroyed then destroyed = true; counts.texts = counts.texts - 1 end end
                return obj
            end,
        },
        Texture = {
            new = function(opts)
                counts.textures = counts.textures + 1
                local destroyed = false
                local obj = {
                    x = opts.x, y = opts.y, w = opts.width, h = opts.height,
                    color = opts.color, visible = opts.visible ~= false, hit_test = opts.hit_test == true,
                    handlers = {},
                }
                function obj:set_rect(x, y, w, h) self.x, self.y, self.w, self.h = x, y, w, h end
                function obj:set_color(c) self.color = c end
                function obj:set_visible(v) self.visible = v end
                function obj:set_hit_test(v) self.hit_test = v end
                function obj:on(ev, fn)
                    self.handlers[ev] = fn
                    counts.subs = counts.subs + 1
                    local active = true
                    return { cancel = function() if active then active = false; counts.subs = counts.subs - 1; self.handlers[ev] = nil end end }
                end
                function obj:fire(ev, payload)
                    if self.handlers[ev] then self.handlers[ev](payload or {}) end
                end
                function obj:destroy() if not destroyed then destroyed = true; counts.textures = counts.textures - 1 end end
                return obj
            end,
        },
    }
    return d3d
end

package.preload["jass.common"]    = function() return mock_common end
package.preload["jass.japi"]      = function() return mock_japi end
package.preload["jass.message"]   = function() return mock_message end
package.preload["jass.map_event"] = function() return mock_map_event end

-- Advance all active mock timers by `dt` seconds.
local function step_timers(dt)
    local list = {}
    for t in pairs(active_timers) do list[#list + 1] = t end
    for i = 1, #list do
        local t = list[i]
        if t.running then
            t.elapsed = t.elapsed + dt
            while t.running and t.elapsed + 1e-9 >= t.dur do
                t.elapsed = t.elapsed - t.dur
                if not t.periodic then
                    t.running = false
                    active_timers[t] = nil
                end
                t.fn()
                if not t.periodic then break end
            end
        end
    end
end

-- ── Test harness ───────────────────────────────────────────────────────────

local pass, fail = 0, 0
local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("  [PASS] " .. name)
    else
        fail = fail + 1
        print("  [FAIL] " .. name .. ": " .. tostring(err))
    end
end

print("std.* offline unit test suite")

local std = require "std"

-- 1. std.util
check("std.util fourcc / id2str roundtrip & cache", function()
    local id = std.util.fourcc("hfoo")
    assert(id == 0x68666F6F)
    assert(std.util.fourcc(id) == id)
    assert(std.util.id2str(id) == "hfoo")
    assert(std.util.rgba(255, 128, 0, 200) == 0xC8FF8000)
    assert(math.abs(std.util.dist(0, 0, 3, 4) - 5.0) < 1e-6)
    local px, py = std.util.polar(10, 20, 100, 0)
    assert(math.abs(px - 110) < 1e-6 and math.abs(py - 20) < 1e-6)
end)

-- 2. std.timer
check("std.timer after / loop / cancel & timer pooling", function()
    local fired = 0
    std.timer.after(0.10, function() fired = fired + 1 end)
    step_timers(0.05)
    assert(fired == 0)
    step_timers(0.06)
    assert(fired == 1)
    assert(std.timer.stats().pooled >= 1, "timer should be pooled after completion")

    local ticks = 0
    local lp = std.timer.loop(0.05, function(_, n) ticks = n end, 3)
    step_timers(0.20)
    assert(ticks == 3 and not lp:is_active())

    local cancelled = 0
    local h = std.timer.after(0.10, function() cancelled = cancelled + 1 end)
    assert(h:cancel() == true and h:cancel() == false)
    step_timers(0.20)
    assert(cancelled == 0)
end)

check("std.timer shared frame ticker auto-starts and auto-stops", function()
    local frames = 0
    local sub = std.timer.frame(function(dt)
        frames = frames + 1
        if frames >= 3 then return false end
    end)
    assert(std.timer.stats().frame_listeners == 1)
    step_timers(0.10)
    assert(frames == 3)
    assert(std.timer.stats().frame_listeners == 0)
    assert(not sub:is_active())
end)

-- 3. std.event
check("std.event on / once / emit / off / keyboard bridge", function()
    local sum = 0
    local t1 = std.event.on("custom:score", function(n) sum = sum + n end)
    std.event.once("custom:score", function(n) sum = sum + n * 10 end)
    std.event.emit("custom:score", 2)
    assert(sum == 22)
    std.event.emit("custom:score", 3)
    assert(sum == 25)
    t1:cancel()
    std.event.emit("custom:score", 100)
    assert(sum == 25)

    local last_key = nil
    local kt = std.event.on("key:down", function(ev) last_key = ev.code end)
    assert(type(mock_message.hook) == "function")
    mock_message.hook({ type = "key_down", code = 0x51, state = 0 })
    assert(last_key == 0x51)
    kt:cancel()
end)

-- 4. std.player
check("std.player singleton cache, resources & relationships", function()
    local p0 = std.player.get(0)
    local p0b = std.player.local_player()
    assert(p0 == p0b and p0:is_local())
    p0:add_gold(250)
    assert(p0:gold() == 750)
    p0:say("hello")
    assert(p0:handle().last_msg == "hello")
    assert(p0:is_enemy(std.player.get(10)))
    assert(p0:is_ally(std.player.get(1)))
end)

-- 5. std.unit & std.group
check("std.unit OO wrapper, identity cache, StatBar shortcuts & auto-cleanup", function()
    local p0 = std.player.get(0)
    local u = std.unit.create(p0, "hfoo", 100, 200, 90)
    assert(u and u:type_code() == "hfoo")
    assert(std.unit.wrap(u:handle()) == u)
    u.data.role = "tank"
    assert(std.unit.wrap(u:handle()).data.role == "tank")

    u:set_pos(300, 400)
    local x, y = u:pos()
    assert(x == 300 and y == 400)

    u:set_facing(180, true)
    assert(u:handle().instant_face == true and u:facing() == 180)
    u:set_hp_bar_color(0xFFFFD700)
    u:set_hp_bar_scale(1.2, 1.3)
    assert(u:handle().bar_color == 0xFFFFD700 and u:handle().bar_sx == 1.2)

    local found = std.group.in_range(300, 400, 50)
    assert(#found == 1 and found[1] == u)
    local nearest, dist = std.group.nearest(330, 440, 100)
    assert(nearest == u and math.abs(dist - 50) < 1e-6)

    local u2 = std.unit.create(std.player.get(10), "ogru", 310, 410, 0)
    u:damage(u2, 125)
    assert(u2:hp() == 375)

    local before_cached = std.unit.cached_count()
    u:remove()
    assert(not u:is_valid() and std.unit.cached_count() == before_cached - 1)
    u2:remove()
end)

-- 6. std.effect
check("std.effect burst & timed auto-destroy", function()
    local fx1 = std.effect.play("Abilities\\Spells\\Human\\ThunderClap\\ThunderClapCaster.mdl", 0, 0)
    assert(fx1:handle() == nil) -- immediately destroyed burst
    local fx2 = std.effect.play("Abilities\\Spells\\Other\\Drain\\ManaDrainTarget.mdl", 10, 20, 0.10, { scale = 1.5, z = 60 })
    assert(fx2:handle() ~= nil and fx2:handle().scale == 1.5 and fx2:handle().z == 60)
    step_timers(0.12)
    assert(fx2:handle() == nil)
end)

-- 7. std.statbar
check("std.statbar themes (rpg / moba / clean / vanilla)", function()
    std.statbar.apply_theme("rpg")
    assert(std.statbar.is_mana_bar_enabled() == true)
    assert(std.statbar.is_offscreen_cull_enabled() == true)

    std.statbar.apply_theme("moba")
    assert(players[0].bar_color == 0xFF32E864)
    assert(players[1].bar_color == 0xFF4AA8FF)
    assert(players[10].bar_color == 0xFFFF4646)

    std.statbar.apply_theme("clean")
    assert(std.statbar.is_mana_bar_enabled() == false)
    assert(std.statbar.is_offscreen_cull_enabled() == true)

    std.statbar.apply_theme("vanilla")
    assert(std.statbar.is_offscreen_cull_enabled() == false)
end)

-- 8. std.tween
check("std.tween easing & color interpolation", function()
    local last = 0
    local done = false
    std.tween.to({
        from = 0, to = 100, duration = 0.09, ease = "out_cubic",
        on_update = function(v) last = v end,
        on_complete = function() done = true end,
    })
    step_timers(0.12)
    assert(done == true and math.abs(last - 100) < 1e-6)
    local mid = std.tween.color(0xFF000000, 0xFFFFFFFF, 0.5)
    assert(((mid >> 16) & 0xFF) == 127)
end)

-- 9. std.d3d_ui (optional D3D fallback: panel, label, button, progress_bar, tooltip, fade_to, resize, clean destroy)
check("std.d3d_ui components, tooltip, animated progress_bar, resize & zero-leak destroy", function()
    local d3d = make_fake_d3d()
    local ctx = std.d3d_ui.new({ d3d = d3d })
    local pnl = ctx:panel({
        padding = 12, spacing = 8,
        position = function(w, h, pw, ph) return w - pw - 20, h - ph - 20 end,
    })
    local lbl = pnl:label({ text = "Hero Panel", width = 180 })
    local bar = pnl:progress_bar({
        width = 180, height = 18, value = 50, max = 100,
        label_format = "HP %d / %d",
        tooltip = "Hero Health",
    })
    local clicked = 0
    local btn = pnl:button({
        text = "Heal", width = 180, height = 34,
        tooltip = "Restore 50 HP",
        on_click = function() clicked = clicked + 1 end,
    })

    -- Hover shows tooltip, click fires callback
    btn._bg:fire("enter")
    assert(ctx._tooltip and ctx._tooltip.visible == true)
    assert(ctx._tooltip.txt.text == "Restore 50 HP")
    btn._bg:fire("click")
    assert(clicked == 1)
    btn._bg:fire("leave")
    assert(ctx._tooltip.visible == false)

    -- Smooth progress_bar animation
    bar:set_value(100, 100, 0.09)
    step_timers(0.12)
    assert(math.abs(bar._ratio - 1.0) < 1e-6)
    assert(bar._text.text == "HP 100 / 100")

    -- Fade animation
    lbl:fade_to(128, 0.06)
    step_timers(0.09)
    assert(((lbl._text_color >> 24) & 0xFF) == 128)

    -- Resize reflow moves anchored panel
    local x1 = pnl:get_rect()
    d3d.set_window_size(1920, 1080)
    local x2 = pnl:get_rect()
    assert(x2 > x1, "panel should move right on wider viewport")

    -- Destroy releases 100% of native D3D resources
    ctx:destroy()
    ctx:destroy() -- idempotent
    local c = d3d.counts()
    assert(c.fonts == 0 and c.texts == 0 and c.textures == 0 and c.subs == 0,
        string.format("resource leak: fonts=%d texts=%d textures=%d subs=%d",
            c.fonts, c.texts, c.textures, c.subs))
end)

-- 10. std.signal (state, computed, effect, batch, untrack, scope LIFO cleanup)
check("std.signal state / computed / effect / batch / scope cleanup", function()
    local S = std.signal
    local sc = S.scope()
    local a = S.state(2)
    local b = S.state(3)
    local runs = 0
    local cleaned = 0
    local sum
    sc:run(function()
        sum = S.computed(function() return a:get() + b:get() end)
        S.effect(function()
            runs = runs + 1
            local _ = sum:get()
            return function() cleaned = cleaned + 1 end
        end)
    end)
    assert(sum:get() == 5 and runs == 1)

    -- Batch coalesces multiple state updates into ONE effect flush
    S.batch(function()
        a:set(10)
        b:set(20)
    end)
    assert(sum:get() == 30 and runs == 2 and cleaned == 1)

    -- Untrack does not subscribe
    local u = S.untrack(function() return a:get() end)
    assert(u == 10)

    -- Scope destroy disposes all effects & computeds
    sc:destroy()
    assert(cleaned == 2)
    a:set(99)
    assert(runs == 2, "disposed effect must not run after scope:destroy()")
end)

-- 11. std.frame (DzFrame adapter: stable event slots = zero trampoline leak)
local function make_mock_dzframe()
    local live_frames = {}
    local total_created = 0
    local script_regs = 0
    local wheel_delta = 0
    local game_ui = { _id = 1, tag = "GAMEUI", visible = true }

    local dz = {
        DzGetGameUI = function() return game_ui end,
        DzCreateFrameByTagName = function(tag, name, parent, tpl, id)
            total_created = total_created + 1
            local f = {
                _id = total_created + 1, tag = tag, name = name, parent = parent,
                tpl = tpl, w = 0, h = 0, visible = true, text = "", tex = "",
                alpha = 255, color = 0xFFFFFFFF, enabled = true, clip = false,
                priority = 0, scale = 1.0, model = "", events = {}, points = {},
            }
            live_frames[f] = true
            return f
        end,
        DzDestroyFrame = function(f) live_frames[f] = nil; f.destroyed = true end,
        DzFrameSetSize = function(f, w, h) f.w, f.h = w, h end,
        DzFrameSetAbsolutePoint = function(f, a, x, y) f.abs = { a = a, x = x, y = y } end,
        DzFrameSetPoint = function(f, a, rel, ra, x, y) f.point = { a = a, rel = rel, ra = ra, x = x, y = y } end,
        DzFrameClearAllPoints = function(f) f.point = nil; f.abs = nil end,
        DzFrameSetAllPoints = function(f, rel) f.all_points = rel end,
        DzFrameSetTexture = function(f, tex, flag) f.tex = tex end,
        DzFrameSetText = function(f, txt) f.text = txt end,
        DzFrameGetText = function(f) return f.text end,
        DzFrameSetFont = function(f, path, sz, fl) f.font = path; f.font_size = sz end,
        DzFrameSetTextAlignment = function(f, al) f.align = al end,
        DzFrameSetAlpha = function(f, a) f.alpha = a end,
        DzFrameSetVertexColor = function(f, c) f.color = c end,
        DzFrameSetEnable = function(f, en) f.enabled = en end,
        DzFrameShow = function(f, v) f.visible = v end,
        DzFrameSetClip = function(f, cl) f.clip = cl end,
        DzFrameSetPriority = function(f, p) f.priority = p end,
        DzFrameSetScale = function(f, s) f.scale = s end,
        DzFrameSetModel = function(f, m) f.model = m end,
        DzFrameSetScriptByCode = function(f, ev, fn)
            script_regs = script_regs + 1
            f.events[ev] = fn
        end,
        DzGetWheelDelta = function() return wheel_delta end,
    }
    return dz, {
        live_count = function()
            local n = 0; for _ in pairs(live_frames) do n = n + 1 end; return n
        end,
        total_created = function() return total_created end,
        script_regs = function() return script_regs end,
        set_wheel = function(d) wheel_delta = d end,
        game_ui = game_ui,
    }
end

check("std.frame stable event slots prevent trampoline leaks on re-bind", function()
    local dz, spy = make_mock_dzframe()
    for k, v in pairs(dz) do mock_japi[k] = v end

    assert(std.frame.is_available() == true)
    local f = std.frame.create("BUTTON")
    local hits = ""
    std.frame.on(f, std.frame.EVENT.CLICK, function() hits = hits .. "A" end)
    std.frame.on(f, std.frame.EVENT.CLICK, function() hits = hits .. "B" end)
    -- Must only register DzFrameSetScriptByCode ONCE for the same (frame, event_id)!
    assert(spy.script_regs() == 1, "expected 1 script reg, got " .. spy.script_regs())
    f.events[std.frame.EVENT.CLICK]()
    assert(hits == "B")

    std.frame.destroy(f)
    assert(spy.live_count() == 0 and std.frame.active_event_frames() == 0)
end)

-- 12. std.ui general-purpose DzFrame framework (DSL, Signal props, Row/Column/Grid/Scroll/Overlay, Show, For pool, component, provide/use)
check("std.ui general-purpose DzFrame DSL, reactive layout, For pool & zero-leak destroy", function()
    local dz, spy = make_mock_dzframe()
    for k, v in pairs(dz) do mock_japi[k] = v end

    local UI = std.ui
    local title = UI.state("Initial")
    local show_extra = UI.state(true)
    local items = UI.state({ "Alpha", "Beta" })
    local clicks = 0

    local Badge = UI.component(function(props)
        local theme = UI.use("theme")
        return UI.Box {
            w = 0.06, h = 0.025,
            UI.Text {
                ref = props.ref_name,
                w = 0.06, h = 0.025,
                text = props.label,
                font = theme.font,
                size = theme.font_size,
            },
        }
    end)

    local mounted = UI.mount(
        UI.Column {
            anchor = "TOPLEFT", x = 0.02, y = -0.02, padding = 0.01, gap = 0.005,
            UI.Text { ref = "title", w = 0.16, h = 0.02, text = title },
            UI.Show {
                when = show_extra,
                UI.Button {
                    ref = "btn", w = 0.10, h = 0.03,
                    on_click = function() clicks = clicks + 1 end,
                },
            },
            UI.Grid {
                ref = "grid", cols = 2, cell_w = 0.06, cell_h = 0.025, gap = 0.004,
                UI.For {
                    each = items, max = 4,
                    render = function(item_sig, idx)
                        return Badge { label = item_sig, ref_name = "slot_" .. idx }
                    end,
                },
            },
            UI.Scroll {
                ref = "scroll", w = 0.12, h = 0.05, content_h = 0.15, step = 0.02,
                UI.Text { w = 0.12, h = 0.15, text = "Long content" },
            },
            UI.Overlay {
                UI.Box { w = 0.05, h = 0.02 },
            },
        },
        { theme = { font = "Fonts\\custom.ttf", font_size = 0.012 } }
    )

    -- Signal prop updates text in place
    assert(mounted:ref("title").frame.text == "Initial")
    title:set("Updated")
    assert(mounted:ref("title").frame.text == "Updated")

    -- Theme context propagated to custom component
    assert(mounted:ref("slot_1").frame.font == "Fonts\\custom.ttf")
    assert(mounted:ref("slot_1").frame.text == "Alpha")
    assert(mounted:ref("slot_2").frame.text == "Beta")

    -- Button click fires
    mounted:ref("btn").frame.events[std.frame.EVENT.CLICK]()
    assert(clicks == 1)

    -- Show toggles visibility and reflows parent Column height
    local h_before = mounted:root().h
    show_extra:set(false)
    assert(mounted:ref("btn").frame.visible == false)
    assert(mounted:root().h < h_before, "Column should shrink when Show hides a child")

    -- For pool updates in place with ZERO new frames created!
    local created_before = spy.total_created()
    items:set({ "One", "Two", "Three" })
    assert(spy.total_created() == created_before, "ForPool must reuse existing slots without creating frames")
    assert(mounted:ref("slot_1").frame.text == "One")
    assert(mounted:ref("slot_3").frame.text == "Three")
    assert(mounted:ref("slot_4").parent_frame.visible == false)

    -- Scroll clips viewport and reacts to mouse wheel
    local scr = mounted:ref("scroll")
    assert(scr.frame.clip == true)
    spy.set_wheel(-1)
    scr.frame.events[std.frame.EVENT.WHEEL]()
    assert(math.abs(scr.scroll_y:peek() - 0.02) < 1e-6)

    -- Destroy cleans 100% of frames, event slots, and signal subscriptions
    mounted:destroy()
    assert(mounted:is_destroyed())
    assert(spy.live_count() == 0, "all frames must be destroyed, left=" .. spy.live_count())
    assert(std.frame.active_event_frames() == 0, "all event slots must be cleared")
end)

print(string.format("std.* offline: %d passed, %d failed, %d total", pass, fail, pass + fail))
if fail > 0 then os.exit(1) end

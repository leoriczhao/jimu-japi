-- tests/ui/test_ui.lua
--
-- OFFLINE MOCKED-ADAPTER TESTS for lib/ui.lua. No Warcraft III process is
-- started and no native jass.d3d function is called. The fake adapter implements
-- the documented native hit-testing rules (visible + hit_test + z ordering,
-- pointer capture, 6 px click threshold, enter/leave hover polling).
--
-- The same suite is run against map/lib/ui.lua and the example copy so a stale
-- copy fails the "library copy sync" check in run-offline.ps1.

local M = {}

local function approx(a, b)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.001
end

function M.run(ui, fake_mod, label)
    local pass, fail = 0, 0

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

    local function eq(actual, expected, what)
        assert(actual == expected, string.format("%s: expected %s, got %s",
            what or "value", tostring(expected), tostring(actual)))
    end

    local function rect(node, ex, ey, ew, eh, what)
        local x, y, w, h = node:get_rect()
        eq(x, ex, (what or "rect") .. ".x")
        eq(y, ey, (what or "rect") .. ".y")
        eq(w, ew, (what or "rect") .. ".w")
        eq(h, eh, (what or "rect") .. ".h")
    end

    local function baseline(fake, what)
        local s = assert(fake.stats())
        assert(s.fonts == 0 and s.texts == 0 and s.textures == 0,
            string.format("%s: leaked font/text/texture counts %d/%d/%d",
                what or "baseline", s.fonts, s.texts, s.textures))
        assert(s.subscriptions == 0,
            string.format("%s: leaked subscriptions %d", what or "baseline",
                s.subscriptions))
    end

    local function center(node)
        local x, y, w, h = node:get_rect()
        return x + w / 2, y + h / 2
    end

    local function stats_snapshot(fake)
        local s = assert(fake.stats())
        return {
            fonts = s.fonts, texts = s.texts,
            textures = s.textures, subscriptions = s.subscriptions,
        }
    end

    local function stats_equal(fake, snapshot, what)
        local s = assert(fake.stats())
        assert(s.fonts == snapshot.fonts and s.texts == snapshot.texts
            and s.textures == snapshot.textures
            and s.subscriptions == snapshot.subscriptions,
            string.format("%s: counts %d/%d/%d/%d, expected %d/%d/%d/%d",
                what or "stats", s.fonts, s.texts, s.textures, s.subscriptions,
                snapshot.fonts, snapshot.texts, snapshot.textures,
                snapshot.subscriptions))
    end

    print(string.format("-- mocked adapter suite: %s --", label))

    check("row/column padding, spacing, hidden collapse and absolute client rects", function()
        local fake = fake_mod.new { width = 800, height = 600 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local col = assert(ctx:column {
            padding = 10, spacing = 5,
            position = function(w, h) return w - 300, h - 200 end,
        })
        local row = assert(col:row { padding = 2, spacing = 7 })
        local a = assert(row:button { width = 40, height = 30 })
        local b = assert(row:button { width = 50, height = 20 })
        local c = assert(col:button { width = 20, height = 10 })

        rect(col, 500, 400, 121, 69, "column")
        rect(row, 510, 410, 101, 34, "row")
        rect(a, 512, 412, 40, 30, "a")
        rect(b, 559, 412, 50, 20, "b")
        rect(c, 510, 449, 20, 10, "c")
        local tx, ty, tw, th = a.texture:get_rect()
        eq(tx, 512, "a.texture.x")
        eq(ty, 412, "a.texture.y")
        eq(tw, 40, "a.texture.w")
        eq(th, 30, "a.texture.h")

        assert(a:set_hidden(true))
        eq(a:get_state(), "hidden", "a state")
        eq(a.texture:get_hit_test(), false, "hidden hit_test")
        eq(a.texture:get_visible(), false, "hidden visible")
        rect(b, 512, 412, 50, 20, "b after a hidden")
        eq(select(3, row:get_rect()), 54, "row width after a hidden")
        eq(select(3, col:get_rect()), 74, "column width after a hidden")

        assert(a:set_hidden(false))
        rect(b, 559, 412, 50, 20, "b after a shown")

        fake._resize(1000, 700)
        rect(col, 700, 500, 121, 69, "column after resize")
        rect(a, 712, 512, 40, 30, "a after resize")
        rect(b, 759, 512, 50, 20, "b after resize")
        rect(c, 710, 549, 20, 10, "c after resize")

        assert(ctx:destroy())
        assert(ctx:destroy())
        baseline(fake, "layout")
    end)

    check("label position and hover/pressed/disabled colors use native Text/Texture", function()
        local fake = fake_mod.new { width = 800, height = 600 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local clicks, blocked = 0, 0
        local bg = { normal = 0xE0181E2C, hover = 0xF0304C78,
            pressed = 0xFF6094D0, disabled = 0xBE1E1E1E }
        local fg = { normal = 0xFFEBF0FF, hover = 0xFFFFFFFF,
            pressed = 0xFFFFFFFF, disabled = 0xFF808080 }
        local button = assert(ctx:button {
            x = 100, y = 120, width = 150, height = 36,
            text = "Hi", font_size = 16, text_padding = 8,
            colors = bg, text_colors = fg,
            on_click = function() clicks = clicks + 1 end,
            on_blocked_click = function() blocked = blocked + 1 end,
        })

        rect(button, 100, 120, 150, 36, "button")
        local tx, ty = button.text:get_position()
        eq(tx, 108, "label.x")
        eq(ty, 130, "label.y (vertically centred)")
        eq(button.font_height, 16, "cached font height")
        local color_bg, color_fg = button:get_colors()
        eq(color_bg, bg.normal, "normal bg")
        eq(color_fg, fg.normal, "normal fg")

        local cx, cy = center(button)
        fake._mouse_move(cx, cy)
        eq(button:get_state(), "hover", "hover state")
        color_bg, color_fg = button:get_colors()
        eq(color_bg, bg.hover, "hover bg")
        eq(color_fg, fg.hover, "hover fg")

        fake._mouse_down(cx, cy)
        eq(button:get_state(), "pressed", "pressed state")
        color_bg, color_fg = button:get_colors()
        eq(color_bg, bg.pressed, "pressed bg")
        eq(color_fg, fg.pressed, "pressed fg")

        fake._mouse_up(cx, cy)
        eq(clicks, 1, "click count")
        eq(button:get_state(), "hover", "state after release")

        fake._mouse_move(1, 1)
        eq(button:get_state(), "normal", "state after leave")
        color_bg = button:get_colors()
        eq(color_bg, bg.normal, "normal bg after leave")

        assert(button:set_enabled(false))
        eq(button:get_state(), "disabled", "disabled state")
        eq(button.texture:get_hit_test(), true, "disabled still consumes clicks")
        fake._mouse_click(cx, cy)
        eq(clicks, 1, "disabled must not call on_click")
        eq(blocked, 1, "disabled blocked click count")
        eq(button:get_blocked_clicks(), 1, "node blocked click count")
        color_bg, color_fg = button:get_colors()
        eq(color_bg, bg.disabled, "disabled bg")
        eq(color_fg, fg.disabled, "disabled fg")

        assert(button:set_hidden(true))
        eq(button:get_state(), "hidden", "hidden state")
        eq(button.texture:get_hit_test(), false, "hidden hit_test")
        fake._mouse_click(cx, cy)
        eq(clicks, 1, "hidden must not call on_click")
        eq(blocked, 1, "hidden click must not reach the blocked handler")

        assert(button:set_hidden(false))
        assert(button:set_enabled(true))
        fake._mouse_click(cx, cy)
        eq(clicks, 2, "click after re-enabling")

        assert(ctx:destroy())
        baseline(fake, "colors")
    end)

    check("disabling preserves hover so re-enabling restores it", function()
        local fake = fake_mod.new { width = 400, height = 200 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local button = assert(ctx:button { width = 80, height = 24, text = "H" })
        local cx, cy = center(button)
        fake._mouse_move(cx, cy)
        eq(button:get_state(), "hover", "initial hover")
        fake._mouse_down(cx, cy)
        eq(button:get_state(), "pressed", "initial press")
        assert(button:set_enabled(false))
        eq(button:get_state(), "disabled", "disabled while hovering")
        assert(button:set_enabled(true))
        eq(button:get_state(), "hover", "hover restored after re-enable")
        fake._mouse_up(cx, cy)
        eq(button:get_state(), "hover", "hover after release")
        fake._mouse_move(300, 150)
        eq(button:get_state(), "normal", "leave while enabled")
        assert(ctx:destroy())
        baseline(fake, "hover preserve")
    end)

    check("container enabled/hidden state propagates to descendants", function()
        local fake = fake_mod.new { width = 640, height = 480 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local row = assert(ctx:row { padding = 4, spacing = 6 })
        local first = assert(row:button { width = 60, height = 24, text = "A" })
        local second = assert(row:button { width = 60, height = 24, text = "B" })
        local clicks = 0
        first.on_click = function() clicks = clicks + 1 end

        assert(row:set_enabled(false))
        eq(first:get_state(), "disabled", "child disabled")
        eq(second:get_state(), "disabled", "second child disabled")
        eq(first.texture:get_hit_test(), true, "disabled child consumes")
        local cx, cy = center(first)
        fake._mouse_click(cx, cy)
        eq(clicks, 0, "container-disabled click must not run")

        assert(row:set_enabled(true))
        assert(row:set_hidden(true))
        eq(first:get_state(), "hidden", "child hidden")
        eq(first.texture:get_hit_test(), false, "hidden child hit_test")
        fake._mouse_click(cx, cy)
        eq(clicks, 0, "container-hidden click must not run")

        assert(row:set_hidden(false))
        eq(first:get_state(), "normal", "child restored")
        fake._mouse_click(cx, cy)
        eq(clicks, 1, "click after container restore")

        assert(ctx:destroy())
        baseline(fake, "propagation")
    end)

    check("idempotent destroy, baseline counts, resize subscription cancellation", function()
        local fake = fake_mod.new { width = 800, height = 600 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local button = assert(ctx:button { width = 80, height = 24, text = "X" })
        local before = stats_snapshot(fake)
        eq(before.fonts, 1, "font count")
        eq(before.texts, 1, "text count")
        eq(before.textures, 1, "texture count")
        eq(before.subscriptions, 6, "resize + 5 button subscriptions")

        assert(ctx:destroy())
        assert(ctx:destroy())
        assert(button:destroy())
        assert(button:destroy())
        baseline(fake, "after destroy")

        assert(ctx:is_destroyed())
        assert(button:is_destroyed())
        assert(not pcall(ctx.reflow, ctx), "reflow after destroy must throw")
        assert(not pcall(ctx.button, ctx, { width = 10, height = 10 }),
            "button creation after destroy must throw")

        local errors = #fake._state.callback_errors
        fake._resize(1200, 900)
        eq(#fake._state.callback_errors, errors, "cancelled resize must not dispatch")
        baseline(fake, "after resize")
    end)

    check("reentrant destroy in click callback (button and whole context)", function()
        local fake = fake_mod.new { width = 800, height = 600 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local clicks = 0
        local button = assert(ctx:button {
            width = 100, height = 30, text = "self",
            on_click = function(self)
                clicks = clicks + 1
                assert(self:destroy(), "button self-destroy failed")
            end,
        })
        local cx, cy = center(button)
        fake._mouse_click(cx, cy)
        eq(clicks, 1, "self-destroy click count")
        assert(button:is_destroyed())
        assert(ctx:is_destroyed() == false)
        local after_self = stats_snapshot(fake)
        eq(after_self.textures, 0, "self-destroy texture")
        eq(after_self.subscriptions, 1, "self-destroy leaves resize subscription")
        assert(ctx:destroy())
        baseline(fake, "self-destroy")

        local fake2 = fake_mod.new { width = 800, height = 600 }
        local ctx2 = assert(ui.new(fake2), "ui.new failed")
        local clicks2 = 0
        local button2 = assert(ctx2:button {
            width = 100, height = 30, text = "ctx",
            on_click = function()
                clicks2 = clicks2 + 1
                assert(ctx2:destroy(), "context self-destroy failed")
            end,
        })
        local cx2, cy2 = center(button2)
        fake2._mouse_click(cx2, cy2)
        eq(clicks2, 1, "context-destroy click count")
        assert(ctx2:is_destroyed())
        assert(button2:is_destroyed())
        baseline(fake2, "context-destroy")
        assert(ctx2:destroy())
    end)

    check("user callback errors are contained and keep the subscription alive", function()
        local fake = fake_mod.new { width = 800, height = 600 }
        local errors = {}
        local ctx = assert(ui.new {
            d3d = fake,
            on_error = function(_, message) errors[#errors + 1] = message end,
        }, "ui.new options failed")
        local calls = 0
        local button = assert(ctx:button {
            width = 100, height = 30, text = "err",
            on_click = function() calls = calls + 1; error("boom") end,
        })
        local subscriptions = stats_snapshot(fake).subscriptions
        local cx, cy = center(button)
        fake._mouse_click(cx, cy)
        eq(calls, 1, "error callback invoked")
        eq(#errors, 1, "one reported error")
        assert(tostring(errors[1]):find("boom", 1, true) ~= nil, "error text missing")
        eq(stats_snapshot(fake).subscriptions, subscriptions,
            "click subscription survives a callback error")
        eq(#fake._state.callback_errors, 0,
            "library must not leak the callback error into native dispatch")

        fake._mouse_click(cx, cy)
        eq(calls, 2, "second click still delivered")
        eq(#errors, 2, "second error reported")
        assert(ctx:destroy())
        baseline(fake, "callback error")
    end)

    check("creation failure rolls back partially created resources", function()
        local function new_fake() return fake_mod.new { width = 800, height = 600 } end

        local fake = new_fake()
        fake._state.fail.window_size = true
        local ctx, err = ui.new(fake)
        assert(ctx == nil and type(err) == "string", "window_size failure must return nil, err")
        fake._state.fail.window_size = false
        baseline(fake, "window_size failure")

        fake = new_fake()
        fake._fail_next("module_on")
        ctx, err = ui.new(fake)
        assert(ctx == nil and type(err) == "string", "resize subscription failure must return nil, err")
        baseline(fake, "resize subscription failure")

        local function button_failure(kind, after)
            local f = new_fake()
            local c = assert(ui.new(f), "ui.new failed")
            local before = stats_snapshot(f)
            if kind ~= nil then f._fail_next(kind, after) end
            local b, failure = c:button { width = 80, height = 24, text = "rollback" }
            assert(b == nil and type(failure) == "string",
                tostring(kind) .. " failure must return nil, err")
            stats_equal(f, before, tostring(kind) .. " rollback")
            assert(c:destroy())
            baseline(f, tostring(kind) .. " rollback")
        end

        button_failure("texture", 1)
        button_failure("font", 1)
        button_failure("text", 1)
        button_failure("subscription", 3)

        -- Reflow failure after all resources exist: window_size goes away during
        -- the creation-time reflow, so the whole button must be rolled back.
        local f = new_fake()
        local c = assert(ui.new(f), "ui.new failed")
        local before = stats_snapshot(f)
        f._state.fail.window_size = true
        local b, failure = c:button { width = 80, height = 24, text = "reflow" }
        f._state.fail.window_size = false
        assert(b == nil and type(failure) == "string", "reflow failure must return nil, err")
        stats_equal(f, before, "reflow rollback")
        assert(c:destroy())
        baseline(f, "reflow rollback")
    end)

    check("resize reflow failure is reported but the subscription stays active", function()
        local fake = fake_mod.new { width = 800, height = 600 }
        local errors = {}
        local ctx = assert(ui.new {
            d3d = fake,
            on_error = function(_, message) errors[#errors + 1] = message end,
        }, "ui.new options failed")
        local button = assert(ctx:button { x = 10, y = 20, width = 80, height = 24, text = "R" })
        local subscriptions = stats_snapshot(fake).subscriptions

        fake._state.fail.window_size = true
        fake._resize(900, 650)
        fake._state.fail.window_size = false
        eq(stats_snapshot(fake).subscriptions, subscriptions,
            "resize subscription must survive a reflow error")
        assert(#errors == 1 and tostring(errors[1]):find("resize reflow failed", 1, true),
            "resize reflow error was not reported")
        eq(#fake._state.callback_errors, 0,
            "library must not leak the reflow error into native dispatch")

        fake._resize(1000, 700)
        local x, y = button:get_rect()
        eq(x, 10, "top-level button x")
        eq(y, 20, "top-level button y")
        assert(ctx:destroy())
        baseline(fake, "resize error")
    end)

    check("textless buttons create no Font/Text and still click", function()
        local fake = fake_mod.new { width = 640, height = 480 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local clicks = 0
        local button = assert(ctx:button {
            width = 64, height = 24,
            on_click = function() clicks = clicks + 1 end,
        })
        local s = stats_snapshot(fake)
        eq(s.fonts, 0, "font count")
        eq(s.texts, 0, "text count")
        eq(s.textures, 1, "texture count")
        eq(s.subscriptions, 6, "subscription count")
        local cx, cy = center(button)
        fake._mouse_click(cx, cy)
        eq(clicks, 1, "textless click")
        assert(ctx:destroy())
        baseline(fake, "textless")
    end)

    check("zero ARGB and z=0 are preserved instead of replaced by defaults", function()
        local fake = fake_mod.new { width = 300, height = 200 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local button = assert(ctx:button {
            x = 10, y = 20, width = 100, height = 30, text = "zero", z = 0,
            colors = { normal = 0, hover = 0, pressed = 0, disabled = 0 },
            text_colors = { normal = 0, hover = 0, pressed = 0, disabled = 0 },
        })
        local bg, fg = button:get_colors()
        eq(bg, 0, "normal bg")
        eq(fg, 0, "normal fg")
        eq(button.texture:get_z(), 0, "texture z")
        eq(button.text:get_z(), 1, "label z")
        local cx, cy = center(button)
        fake._mouse_move(cx, cy)
        bg, fg = button:get_colors()
        eq(bg, 0, "hover bg")
        eq(fg, 0, "hover fg")
        assert(ctx:destroy())
        baseline(fake, "zero colors")
    end)

    check("invalid options fail before native allocation", function()
        local fake = fake_mod.new { width = 300, height = 200 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local before = stats_snapshot(fake)
        local cases = {
            { "on_click type", { on_click = true } },
            { "colors type", { colors = "red" } },
            { "hover color range", { colors = { hover = 0x100000000 } } },
            { "fractional z", { z = 1.5 } },
            { "negative width", { width = -1 } },
            { "NaN padding", { padding = 0 / 0 } },
            { "source type", { source = 5 } },
            { "position type", { position = 5 } },
            { "text type", { text = {} } },
            { "zero font size", { text = "x", font_size = 0 } },
        }
        for _, case in ipairs(cases) do
            local node, err = ctx:button(case[2])
            assert(node == nil and type(err) == "string", case[1] .. " must fail")
            stats_equal(fake, before, case[1] .. " rollback")
        end
        local bad_ctx, err = ui.new { d3d = fake, on_error = 5 }
        assert(bad_ctx == nil and type(err) == "string", "invalid on_error must fail")
        assert(ctx:destroy())
        baseline(fake, "invalid options")
    end)

    check("hidden container leaves parent flow and restores", function()
        local fake = fake_mod.new { width = 800, height = 600 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local row = assert(ctx:row { padding = 5, spacing = 10 })
        local first = assert(row:button { width = 40, height = 20 })
        local middle = assert(row:column { padding = 2, spacing = 3 })
        local inside = assert(middle:button { width = 30, height = 10 })
        assert(middle:button { width = 20, height = 12 })
        local last = assert(row:button { width = 50, height = 20 })

        rect(first, 5, 5, 40, 20, "first")
        rect(middle, 55, 5, 34, 29, "middle")
        rect(last, 99, 5, 50, 20, "last")
        eq(select(3, row:get_rect()), 154, "row width")

        assert(inside:set_visible(false))
        eq(inside:get_state(), "hidden", "inside hidden via set_visible")
        assert(inside:set_visible(true))
        eq(inside:get_state(), "normal", "inside restored via set_visible")

        assert(middle:set_hidden(true))
        eq(inside:get_state(), "hidden", "descendant hidden")
        eq(inside.texture:get_hit_test(), false, "descendant hit_test")
        eq(select(3, row:get_rect()), 110, "row width after middle hidden")
        rect(last, 55, 5, 50, 20, "last after middle hidden")

        assert(middle:set_hidden(false))
        rect(last, 99, 5, 50, 20, "last after middle shown")
        assert(ctx:destroy())
        baseline(fake, "hidden container")
    end)

    check("failed native destroy collapses layout and retries", function()
        for _, kind in ipairs({ "texture", "text", "font" }) do
            local fake = fake_mod.new { width = 400, height = 200 }
            local ctx = assert(ui.new(fake), "ui.new failed")
            local row = assert(ctx:row { padding = 0, spacing = 4 })
            local first = assert(row:button { width = 40, height = 20, text = "A" })
            local second = assert(row:button { width = 40, height = 20, text = "B" })
            eq(select(1, second:get_rect()), 44, kind .. ": second before failure")

            fake._fail_next_destroy(kind)
            local ok, err = first:destroy()
            assert(ok == nil and type(err) == "string",
                kind .. ": destroy failure must return nil, err")
            assert(tostring(err):find("injected", 1, true) ~= nil, kind .. ": error text")
            assert(first:is_destroyed(), kind .. ": node marked destroyed")
            eq(#row.children, 2, kind .. ": node retained for retry")
            eq(select(1, second:get_rect()), 0, kind .. ": layout collapse")
            if kind == "texture" then
                eq(first.texture:get_visible(), false, "failed texture hidden")
                eq(first.texture:get_hit_test(), false, "failed texture not clickable")
            end
            local leaked = assert(fake.stats())
            assert(leaked.fonts + leaked.texts + leaked.textures > 0,
                kind .. ": failure must leave a handle")
            eq(#fake._state.callback_errors, 0, kind .. ": native callback errors")

            if kind == "text" then
                assert(ctx:destroy(), "context retry must release remaining handles")
            else
                assert(first:destroy(), "direct retry must release remaining handles")
                eq(#row.children, 1, kind .. ": node removed after retry")
                assert(ctx:destroy())
            end
            baseline(fake, kind .. " retry")
        end
    end)

    check("reentrant destroy from on_blocked_click", function()
        local fake = fake_mod.new { width = 400, height = 200 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local clicks = 0
        local button = assert(ctx:button {
            width = 80, height = 24, text = "D", enabled = false,
            on_click = function() clicks = clicks + 1 end,
            on_blocked_click = function(self)
                assert(self.context:destroy(), "context self-destroy failed")
            end,
        })
        local cx, cy = center(button)
        fake._mouse_click(cx, cy)
        eq(clicks, 0, "disabled on_click must not run")
        assert(ctx:is_destroyed())
        assert(button:is_destroyed())
        eq(#fake._state.callback_errors, 0, "native callback errors")
        baseline(fake, "blocked self-destroy")
    end)

    check("failed child creation preserves the parent", function()
        local fake = fake_mod.new { width = 400, height = 200 }
        local ctx = assert(ui.new(fake), "ui.new failed")
        local row = assert(ctx:row { padding = 4, spacing = 6 })
        assert(row:button { width = 20, height = 20 })
        local before = stats_snapshot(fake)
        fake._fail_next("texture")
        local child, err = row:button { width = 20, height = 20, text = "bad" }
        assert(child == nil and type(err) == "string", "child creation must fail")
        stats_equal(fake, before, "child rollback")
        eq(#row.children, 1, "parent child count")
        assert(row:button { width = 20, height = 20 })
        assert(ctx:destroy())
        baseline(fake, "child rollback")
    end)

    return pass, fail
end

return M

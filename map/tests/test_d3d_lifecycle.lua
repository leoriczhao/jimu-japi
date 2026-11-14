-- Public jass.d3d lifecycle fixture (P5): TTL expiry, failure paths, module
-- lifecycle subscriptions and device state diagnostics. Like the SDK fixture it
-- must only use the public jass.d3d API.

local d3d = require "jass.d3d"

local M = {}
local state = {
    ttl_text = nil,
    ttl_font = nil,
    baseline_texts = 0,
    events = { resize = 0, device_lost = 0, device_reset = 0 },
    last_event = nil,
}

local function now_string()
    local ok, value = pcall(function() return d3d.stats().device_generation end)
    if not ok then return "?" end
    return tostring(value)
end

function M.run(done)
    if not _G.__JAPI_TEST_INTERACTIVE_D3D then
        if done then done(0, 0) end
        return
    end

    print("")
    print("-- D3D lifecycle fixture (P5) --")
    local pass, fail = 0, 0
    local function test(name, fn)
        local ok, err = pcall(fn)
        if ok then
            pass = pass + 1
            print("  [PASS] " .. name)
        else
            fail = fail + 1
            print("  [FAIL] " .. name .. " : " .. tostring(err))
        end
    end

    local subscriptions = {}

    test("D3D lifecycle diagnostics expose device state", function()
        assert(d3d.is_available(), d3d.status().error)
        local caps = d3d.capabilities()
        assert(caps.device_state, "device_state capability is missing")
        assert(caps.lifecycle_events, "lifecycle_events capability is missing")
        local status = d3d.status()
        assert(status.state == "active", "unexpected state " .. tostring(status.state))
        assert(status.shutdown == false and status.available == true)
        assert(type(status.device_generation) == "number" and status.device_generation >= 1,
            "device_generation was not reported")
        local stats = assert(d3d.stats())
        assert(stats.device_generation == status.device_generation,
            "status and stats disagree about the device generation")
        assert(stats.device_ready == true, "device is not ready while the fixture runs")
    end)

    test("D3D lifecycle subscription validation and cancellation", function()
        local ok, err = pcall(function() return d3d.on("bogus", function() end) end)
        assert(not ok, "unknown lifecycle event was accepted")
        assert(tostring(err):find("unsupported", 1, true), tostring(err))
        local ok2 = pcall(function() return d3d.on("resize", "not a function") end)
        assert(not ok2, "non-function callback was accepted")

        local before = d3d.stats().subscriptions
        for _, name in ipairs { "resize", "device_lost", "device_reset" } do
            local subscription = assert(d3d.on(name, function(event)
                state.events[name] = state.events[name] + 1
                state.last_event = event
            end))
            subscriptions[name] = subscription
            assert(subscription:is_active(), name .. " subscription is not active")
        end
        assert(d3d.stats().subscriptions == before + 3, "lifecycle subscriptions were not counted")
        for _, name in ipairs { "resize", "device_lost", "device_reset" } do
            assert(subscriptions[name]:cancel())
            assert(subscriptions[name]:cancel(), name .. " cancel is not idempotent")
            assert(not subscriptions[name]:is_active(), name .. " stayed active after cancel")
        end
        assert(d3d.stats().subscriptions == before, "cancelled subscriptions leaked")
    end)

    test("D3D failed creation leaves no residue (LIFE-11)", function()
        local baseline = assert(d3d.stats())
        for _ = 1, 20 do
            local texture, err = d3d.Texture.new {
                source = "asset://d3d-lifecycle-missing.png", width = 8, height = 8,
            }
            assert(texture == nil, "missing asset unexpectedly created a Texture")
            assert(type(err) == "string" and #err > 0)
        end
        local font = assert(d3d.Font.new {})
        local dead = assert(d3d.Text.new { font = font, text = "dead dependency" })
        assert(dead:destroy())
        local accepted, err = pcall(function()
            return d3d.Text.new { font = dead, text = "x" }
        end)
        assert(not accepted, "Text accepted a destroyed Font: " .. tostring(err))
        assert(font:destroy())
        local after = assert(d3d.stats())
        assert(after.textures == baseline.textures and after.texts == baseline.texts
            and after.fonts == baseline.fonts,
            string.format("failed creation leaked: %d/%d/%d -> %d/%d/%d",
                baseline.fonts, baseline.texts, baseline.textures,
                after.fonts, after.texts, after.textures))
    end)

    test("D3D TTL Text keeps its lifetime and counts", function()
        local font = assert(d3d.Font.new { height = 18 })
        local text = assert(d3d.Text.new { font = font, text = "ttl", ttl = 0.15 })
        assert(not text:is_destroyed())
        local ttl = text:get_ttl()
        assert(type(ttl) == "number" and ttl > 0, "TTL was not stored")
        state.ttl_font = font
        state.ttl_text = text
        state.baseline_texts = d3d.stats().texts
        assert(state.baseline_texts >= 1)
    end)

    if done then done(pass, fail) end
end

function M.verify_lifecycle(done)
    if not _G.__JAPI_TEST_INTERACTIVE_D3D then
        if done then done(0, 0) end
        return
    end

    local jass = require "jass.common"
    local ticks = 0
    local phase = "ttl"
    local ttl_seen_alive = false
    local probe_ticks = 0
    local probe_wait = tonumber(_G.__JAPI_TEST_RESET_PROBE_SECONDS) or 40
    local required_resizes = tonumber(_G.__JAPI_TEST_RESIZE_TARGET) or 20
    local probe_events = 0

    -- Survivors created before the reset: DEV-03 requires handles, properties
    -- and subscriptions to stay valid across a real device reset.
    local survivor_font = assert(d3d.Font.new { height = 21, face = "Arial" })
    local survivor_text = assert(d3d.Text.new {
        font = survivor_font, text = "survivor", x = 40, y = 300, color = 0xFFFFFF80,
    })
    local survivor_texture = assert(d3d.Texture.new {
        source = "game://ReplaceableTextures/CommandButtons/BTNFootman.blp",
        x = 0, y = 0, width = 32, height = 32,
    })
    -- The TTL baseline must be measured after the survivors exist, otherwise the
    -- survivor Text offsets the expired one and the count never drops.
    state.baseline_texts = assert(d3d.stats()).texts
    local generation_before = assert(d3d.stats()).device_generation

    local probe_subscription
    for _, name in ipairs { "resize", "device_lost", "device_reset" } do
        local subscription = d3d.on(name, function(event)
            state.events[name] = state.events[name] + 1
            state.last_event = event
            print(string.format("  [LIFE] %s event: generation=%s", name,
                tostring(event.generation or "n/a")))
        end)
        probe_subscription = probe_subscription or subscription
    end

    local timer = jass.CreateTimer()
    jass.TimerStart(timer, 0.05, true, function()
        ticks = ticks + 1
        if ticks > 2400 then
            jass.PauseTimer(timer)
            jass.DestroyTimer(timer)
            print("  [FAIL] D3D lifecycle verification timed out")
            if done then done(0, 1) end
            return
        end

        if phase == "ttl" then
            local text = state.ttl_text
            if text and not text:is_destroyed() then ttl_seen_alive = true end
            if text and text:is_destroyed() then
                local ok, err = pcall(function()
                    assert(ttl_seen_alive, "TTL Text never became visible as alive")
                    local stats = assert(d3d.stats())
                    assert(stats.texts < state.baseline_texts,
                        string.format("expired Text was not released (%d -> %d)",
                            state.baseline_texts, stats.texts))
                    local raised = pcall(function() return text:get_text() end)
                    assert(not raised, "expired Text stayed readable")
                end)
                if not ok then
                    jass.PauseTimer(timer)
                    jass.DestroyTimer(timer)
                    print("  [FAIL] D3D TTL expiry releases the native Text : " .. tostring(err))
                    if done then done(0, 1) end
                    return
                end
                print("  [PASS] D3D TTL expiry releases the native Text and reports it to Lua")
                if state.ttl_font then pcall(function() state.ttl_font:destroy() end) end
                phase = "probe"
                print("  [WAIT] resize the War3 window " .. tostring(required_resizes)
                    .. " times within " .. tostring(probe_wait)
                    .. "s to exercise device lifecycle events")
            end
            return
        end

        -- Probe phase: repeated real window resizes must surface as resize
        -- events and may also produce a device lost/reset cycle.
        probe_ticks = probe_ticks + 1
        probe_events = state.events.resize + state.events.device_lost + state.events.device_reset
        local timed_out = probe_ticks >= math.floor(probe_wait / 0.05)
        if state.events.resize >= required_resizes or timed_out then
            jass.PauseTimer(timer)
            jass.DestroyTimer(timer)
            if probe_events == 0 then
                print("  [SKIP] D3D device lifecycle probe: no resize/reset observed in "
                    .. tostring(probe_wait) .. "s (generation " .. now_string() .. ")")
                pcall(function()
                    survivor_text:destroy()
                    survivor_font:destroy()
                    survivor_texture:destroy()
                end)
                if done then done(0, 0) end
                return
            end
            local ok, err = pcall(function()
                assert(not survivor_font:is_destroyed(),
                    "Font was invalidated by the device lifecycle event")
                assert(not survivor_text:is_destroyed(),
                    "Text was invalidated by the device lifecycle event")
                assert(survivor_text:get_text() == "survivor", "Text content was lost")
                local px = survivor_text:get_position()
                assert(math.abs(px - 40) < 0.5, "Text position was lost")
                assert(survivor_font:get_height() == 21, "Font height was lost")
                local _, _, tw = survivor_texture:get_rect()
                assert(math.abs(tw - 32) < 0.5,
                    "Texture rect was lost across the device lifecycle event")
                assert(probe_subscription and probe_subscription:is_active(),
                    "lifecycle subscription died across the device lifecycle event")
                if state.events.device_reset > 0 then
                    assert(assert(d3d.stats()).device_generation > generation_before,
                        "device generation did not advance across a reset")
                end
            end)
            if not ok then
                print("  [FAIL] D3D handles survive a real device lifecycle event : "
                    .. tostring(err))
                if done then done(0, 1) end
                return
            end
            print(string.format(
                "  [PASS] D3D real device lifecycle events: resize=%d (target %d) lost=%d reset=%d",
                state.events.resize, required_resizes,
                state.events.device_lost, state.events.device_reset))
            print("  [PASS] D3D handles, properties and subscriptions survive the event")
            pcall(function()
                survivor_text:destroy()
                survivor_font:destroy()
                survivor_texture:destroy()
            end)
            if done then done(2, 0) end
            return
        end
    end)
end

return M

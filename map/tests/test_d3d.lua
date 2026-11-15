-- D3D9 proxy visual and interaction fixture.
-- Loaded in every bundle, but only run when pack.ps1 sets
-- _G.__JAPI_TEST_INTERACTIVE_D3D.
local jass = require "jass.common"
local globals = require "jass.globals"

local pass, fail = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print(string.format("  [PASS] %s", name))
    else
        fail = fail + 1
        print(string.format("  [FAIL] %s : %s", name, tostring(err)))
    end
end

local HT, KEY
local function rpc_ready()
    if HT then return true end
    HT = globals.japi_ht
    KEY = globals.japi__key
    return HT ~= nil and KEY ~= nil
end

local function save_slot(slot, value)
    local kind = type(value)
    if kind == "number" then
        if math.type(value) == "integer" then
            jass.SaveInteger(HT, KEY, slot, value)
        else
            jass.SaveReal(HT, KEY, slot, value)
        end
    elseif kind == "string" then
        jass.SaveStr(HT, KEY, slot, value)
    elseif kind == "boolean" then
        jass.SaveBoolean(HT, KEY, slot, value)
    else
        error("unsupported D3D RPC arg type " .. kind)
    end
end

local function call(name, spec, ...)
    assert(rpc_ready(), "japi hashtable globals not available")
    for i, value in ipairs({...}) do
        save_slot(i, value)
    end
    jass.SaveStr(HT, KEY, 0, spec)
    jass.UnitId(name)
    local ret = spec:match("%)(%a)")
    if ret == "I" or ret == "H" then
        return jass.LoadInteger(HT, KEY, 0)
    elseif ret == "R" then
        return jass.LoadReal(HT, KEY, 0)
    elseif ret == "S" then
        return jass.LoadStr(HT, KEY, 0)
    elseif ret == "B" then
        return jass.LoadBoolean(HT, KEY, 0)
    end
end

local function run(done)
    if not _G.__JAPI_TEST_INTERACTIVE_D3D then
        done(0, 0)
        return
    end

    print("\n-- D3D9 proxy visual fixture --")
    local font, text, texture
    local event_id, event_baseline
    local event_press_seen, event_release_seen = false, false
    local event_key = 0 -- WARK_SHIFT on Warcraft III 1.27a

    test("D3D proxy registered, device wrapped, frame rendered", function()
        local status = call("GetD3DStatus", "()I") or 0
        assert((status & 0x3F) == 0x3F,
            string.format("expected status bits 0x3F, got 0x%02X", status))
    end)

    test("D3D window dimensions available", function()
        local width = call("GetWindowWidth", "()I")
        local height = call("GetWindowHeight", "()I")
        assert(width and width >= 640, "window width=" .. tostring(width))
        assert(height and height >= 480, "window height=" .. tostring(height))
    end)

    test("D3D font properties and string ABI round-trip", function()
        font = call("CreateFont", "()I")
        assert(font and font ~= 0, "CreateFont returned 0")
        call("SetFontHeight", "(II)V", font, 34)
        call("SetFontWeight", "(II)V", font, 700)
        call("SetFontItalic", "(IB)V", font, false)
        call("SetFontFaceName", "(IS)V", font, "Arial")
        assert(call("GetFontHeight", "(I)I", font) == 34)
        assert(call("GetFontWeight", "(I)I", font) == 700)
        assert(call("GetFontFaceName", "(I)S", font) == "Arial")
    end)

    test("D3D text object visible-state round-trip", function()
        text = call("CreateText", "(ISRRRI)I", font,
            "JAPI D3D P4 - click, Shift, then drag outside",
            72.0, 72.0, -1.0, -256)
        assert(text and text ~= 0, "CreateText returned 0")
        assert(call("GetTextString", "(I)S", text):match("JAPI D3D P4"))
        assert(math.abs(call("GetTextX", "(I)R", text) - 72.0) < 0.01)
        assert(math.abs(call("GetTextY", "(I)R", text) - 72.0) < 0.01)
        assert(call("GetTextColor", "(I)I", text) == -256)
    end)

    test("D3D texture loads and exposes dimensions", function()
        texture = call("CreateTexture", "(SRRRRII)I",
            "japi_d3d_visual_probe.bmp", 72.0, 136.0, 256.0, 192.0, -1, 9000)
        assert(texture and texture ~= 0, "CreateTexture returned 0")
        assert(math.abs(call("GetTextureWidth", "(I)R", texture) - 256.0) < 0.01)
        assert(math.abs(call("GetTextureHeight", "(I)R", texture) - 192.0) < 0.01)
        assert(math.abs(call("GetTexturePixelWidth", "(I)R", texture) - 128.0) < 0.01,
            "pixel width=" .. tostring(call("GetTexturePixelWidth", "(I)R", texture)))
        assert(math.abs(call("GetTexturePixelHeight", "(I)R", texture) - 128.0) < 0.01,
            "pixel height=" .. tostring(call("GetTexturePixelHeight", "(I)R", texture)))
        local status = call("GetD3DStatus", "()I") or 0
        assert((status & 0x40) == 0x40,
            string.format("texture status bit missing: 0x%02X", status))
    end)

    test("D3D texture source rect uses builtin rect ABI", function()
        local source = jass.Rect(8.0, 16.0, 96.0, 112.0)
        jass.SaveStr(HT, KEY, 0, "(IHrect;)V")
        jass.SaveInteger(HT, KEY, 1, texture)
        jass.SaveRectHandle(HT, KEY, 2, source)
        jass.UnitId("SetTextureSrcRect")
        jass.RemoveSavedHandle(HT, KEY, 2)
        jass.RemoveRect(source)

        jass.RemoveSavedHandle(HT, KEY, 0)
        jass.SaveStr(HT, KEY, 0, "(I)Hrect;")
        jass.SaveInteger(HT, KEY, 1, texture)
        jass.UnitId("GetTextureSrcRect")
        local actual = jass.LoadRectHandle(HT, KEY, 0)
        assert(actual ~= nil, "GetTextureSrcRect returned nil")
        assert(math.abs(jass.GetRectMinX(actual) - 8.0) < 0.01)
        assert(math.abs(jass.GetRectMinY(actual) - 16.0) < 0.01)
        assert(math.abs(jass.GetRectMaxX(actual) - 96.0) < 0.01)
        assert(math.abs(jass.GetRectMaxY(actual) - 112.0) < 0.01)
        jass.RemoveSavedHandle(HT, KEY, 0)
        jass.RemoveRect(actual)
    end)

    test("D3D texture trigger switch gates hit-test", function()
        call("SetTextureTrigger", "(IB)V", texture, false)
        assert(call("GetMouseInTexture", "(I)B", texture) == false)
        call("SetTextureTrigger", "(IB)V", texture, true)
    end)

    test("D3D GetFuncAddr channel captures JASS code", function()
        local code = jass.code(function() end)
        jass.call("SetHeroLevels", code)
        assert(jass.LoadInteger(HT, KEY, 0) == code)
    end)

    test("D3D TextureAddEvent registers JASS code callbacks", function()
        event_baseline = call("GetTextureEventCount", "()I") or 0

        local press_code = jass.code(function()
            if event_press_seen then return end
            event_press_seen = true
            test("D3D TextureAddEvent press callback context", function()
                local parent = jass.GetHandleId(jass.GetExpiredTimer())
                assert(parent and parent ~= 0, "missing expired timer")
                assert(jass.LoadInteger(HT, parent, 0x0FF) == texture)
                assert(jass.LoadInteger(HT, parent, 0x100) == event_key)
                assert(jass.LoadInteger(HT, parent, 0x101) == 1)
                assert(jass.LoadInteger(HT, parent, 0x0FE) == event_id)
            end)
            call("SetTextString", "(IS)V", text,
                "JAPI D3D EVENT PRESS PASS - release Shift")
            call("SetTextColor", "(II)V", text, -16711936)
        end)

        local release_code = jass.code(function()
            if event_release_seen then return end
            event_release_seen = true
            test("D3D TextureAddEvent release callback context", function()
                local parent = jass.GetHandleId(jass.GetExpiredTimer())
                assert(parent and parent ~= 0, "missing expired timer")
                assert(jass.LoadInteger(HT, parent, 0x0FF) == texture)
                assert(jass.LoadInteger(HT, parent, 0x100) == event_key)
                assert(jass.LoadInteger(HT, parent, 0x101) == 0)
                assert(jass.LoadInteger(HT, parent, 0x0FE) == event_id)
            end)
            -- Compare against the count just before the removal: another fixture event (the
            -- synthetic keyboard probe) owns its own registration at the same time, so an absolute
            -- baseline would depend on which of the two registrations is released first.
            local before_remove = call("GetTextureEventCount", "()I")
            call("TextureRemoveEvent", "(II)V", texture, event_id)
            test("D3D TextureRemoveEvent releases registration", function()
                local now = call("GetTextureEventCount", "()I")
                assert(now == before_remove - 1,
                    string.format("event count %d -> %d (expected %d)",
                        before_remove, now, before_remove - 1))
            end)
            call("SetTextString", "(IS)V", text,
                "JAPI D3D EVENT PASS - move cursor outside")
            call("SetTextColor", "(II)V", text, -16711936)
        end)

        -- WARK_SHIFT is 0 on 1.27a. The key must be pressed while the real
        -- cursor is inside the rendered texture.
        event_id = call("TextureAddEvent", "(IIII)I",
            texture, event_key, press_code, release_code)
        assert(event_id and event_id ~= 0, "TextureAddEvent returned 0")
        assert(call("GetTextureEventCount", "()I") == event_baseline + 1)
    end)

    test("D3D font width round-trip and DestroyFont release", function()
        local temp_font = call("CreateFont", "()I")
        assert(temp_font and temp_font ~= 0, "CreateFont returned 0")
        call("SetFontWidth", "(II)V", temp_font, 24)
        assert(call("GetFontWidth", "(I)I", temp_font) == 24,
            "font width=" .. tostring(call("GetFontWidth", "(I)I", temp_font)))
        call("DestroyFont", "(I)V", temp_font)
        assert(call("GetFontHeight", "(I)I", temp_font) == 0,
            "destroyed font still reports a height")
    end)

    test("D3D text position and lifetime round-trip", function()
        call("SetTextX", "(IR)V", text, 100.0)
        call("SetTextY", "(IR)V", text, 120.0)
        assert(math.abs(call("GetTextX", "(I)R", text) - 100.0) < 0.01)
        assert(math.abs(call("GetTextY", "(I)R", text) - 120.0) < 0.01)
        call("SetTextX", "(IR)V", text, 72.0)
        call("SetTextY", "(IR)V", text, 72.0)
        assert(math.abs(call("GetTextX", "(I)R", text) - 72.0) < 0.01)
        assert(math.abs(call("GetTextY", "(I)R", text) - 72.0) < 0.01)

        assert(math.abs(call("GetTextTime", "(I)R", text) + 1.0) < 0.01,
            "permanent ttl=" .. tostring(call("GetTextTime", "(I)R", text)))
        call("SetTextTime", "(IR)V", text, 12.0)
        local running = call("GetTextTime", "(I)R", text)
        assert(running > 11.0 and running <= 12.0,
            "ttl after SetTextTime=" .. tostring(running))
        call("SetTextTime", "(IR)V", text, -1.0)
        assert(math.abs(call("GetTextTime", "(I)R", text) + 1.0) < 0.01)
    end)

    test("D3D texture rectangle round-trip", function()
        call("SetTextureX", "(IR)V", texture, 200.0)
        call("SetTextureY", "(IR)V", texture, 300.0)
        call("SetTextureWidth", "(IR)V", texture, 320.0)
        call("SetTextureHeight", "(IR)V", texture, 240.0)
        assert(math.abs(call("GetTextureX", "(I)R", texture) - 200.0) < 0.01)
        assert(math.abs(call("GetTextureY", "(I)R", texture) - 300.0) < 0.01)
        assert(math.abs(call("GetTextureWidth", "(I)R", texture) - 320.0) < 0.01)
        assert(math.abs(call("GetTextureHeight", "(I)R", texture) - 240.0) < 0.01)
        call("SetTextureX", "(IR)V", texture, 72.0)
        call("SetTextureY", "(IR)V", texture, 136.0)
        call("SetTextureWidth", "(IR)V", texture, 256.0)
        call("SetTextureHeight", "(IR)V", texture, 192.0)
        assert(math.abs(call("GetTextureX", "(I)R", texture) - 72.0) < 0.01)
        assert(math.abs(call("GetTextureY", "(I)R", texture) - 136.0) < 0.01)
        assert(math.abs(call("GetTextureWidth", "(I)R", texture) - 256.0) < 0.01)
        assert(math.abs(call("GetTextureHeight", "(I)R", texture) - 192.0) < 0.01)
    end)

    test("D3D texture colour, level and rotation round-trip", function()
        assert(call("GetTextureColor", "(I)I", texture) == -1,
            "default colour=" .. tostring(call("GetTextureColor", "(I)I", texture)))
        assert(call("GetTextureLevel", "(I)I", texture) == 9000,
            "default level=" .. tostring(call("GetTextureLevel", "(I)I", texture)))
        call("SetTextureColor", "(II)V", texture, 2130771712) -- 0x7F00FF00
        call("SetTextureLevel", "(II)V", texture, 9500)
        call("SetTextureRotation", "(IR)V", texture, 1.5)
        assert(call("GetTextureColor", "(I)I", texture) == 2130771712)
        assert(call("GetTextureLevel", "(I)I", texture) == 9500)
        assert(math.abs(call("GetTextureRotation", "(I)R", texture) - 1.5) < 0.01)
        call("SetTextureColor", "(II)V", texture, -1)
        call("SetTextureLevel", "(II)V", texture, 9000)
        call("SetTextureRotation", "(IR)V", texture, 0.0)
        assert(call("GetTextureColor", "(I)I", texture) == -1)
        assert(call("GetTextureLevel", "(I)I", texture) == 9000)
        assert(math.abs(call("GetTextureRotation", "(I)R", texture)) < 0.01)
    end)

    test("D3D SetTexture re-decodes pixels from a new path", function()
        call("SetTexture", "(IS)V", texture, "japi_d3d_missing_probe.bmp")
        assert(call("GetTexturePixelWidth", "(I)R", texture) == 0.0,
            "missing path still reports pixels="
                .. tostring(call("GetTexturePixelWidth", "(I)R", texture)))
        call("SetTexture", "(IS)V", texture, "japi_d3d_visual_probe.bmp")
        assert(math.abs(call("GetTexturePixelWidth", "(I)R", texture) - 128.0) < 0.01,
            "restored pixel width="
                .. tostring(call("GetTexturePixelWidth", "(I)R", texture)))
    end)

    test("D3D DestroyTexture releases the handle", function()
        local temp_texture = call("CreateTexture", "(SRRRRII)I",
            "japi_d3d_visual_probe.bmp", 480.0, 400.0, 64.0, 64.0, -1, 9000)
        assert(temp_texture and temp_texture ~= 0, "CreateTexture returned 0")
        assert(math.abs(call("GetTextureWidth", "(I)R", temp_texture) - 64.0) < 0.01)
        call("DestroyTexture", "(I)V", temp_texture)
        assert(call("GetTextureWidth", "(I)R", temp_texture) == 0.0,
            "destroyed texture still reports a width")
        assert(call("GetMouseInTexture", "(I)B", temp_texture) == false)
    end)

    test("D3D GetMouseVector reports client pixels", function()
        local mx = call("GetMouseVectorX", "()R")
        local my = call("GetMouseVectorY", "()R")
        assert(type(mx) == "number" and type(my) == "number",
            "mouse vector types " .. type(mx) .. "/" .. type(my))
        assert(math.abs(mx) < 4000 and math.abs(my) < 4000,
            string.format("mouse vector %.1f,%.1f", mx, my))
    end)

    test("D3D ShowConsole hides and restores the minimap frame", function()
        local original = call("GetLittleMapX", "()R")
        assert(type(original) == "number", "GetLittleMapX returned " .. type(original))
        call("ShowConsole", "(B)V", false)
        local hidden = call("GetLittleMapX", "()R")
        assert(math.abs(hidden + 2.0) < 0.01,
            "hidden little map x=" .. tostring(hidden))
        call("ShowConsole", "(B)V", true)
        local restored = call("GetLittleMapX", "()R")
        assert(math.abs(restored - original) < 0.01,
            "restored little map x=" .. tostring(restored)
                .. " expected " .. tostring(original))
    end)

    test("D3D ShowFpsText toggles without breaking fps stats", function()
        call("ShowFpsText", "(B)V", true)
        call("ShowFpsText", "(B)V", false)
        local fps = call("GetFps", "()R")
        assert(type(fps) == "number" and fps >= 0 and fps < 1000,
            "fps=" .. tostring(fps))
    end)

    -- WARK_E on 1.27a (wark_to_vk maps A..Z to their ASCII codes).
    -- SetKeyboard posts WM_KEYDOWN/UP, so the synthetic key only reaches this
    -- texture while the real cursor is inside it. Q is deliberately avoided:
    -- test_d3d_sdk.lua keeps a hover-only Q subscription on the same rectangle
    -- and asserts that Q pressed outside must not fire it.
    local keyboard_key = 0x45
    local key_event_id, key_event_baseline
    local key_press_seen, key_release_seen = false, false

    local function key_press_code()
        if key_press_seen then return end
        key_press_seen = true
        test("D3D SetKeyboard synthetic press reaches the texture", function()
            local parent = jass.GetHandleId(jass.GetExpiredTimer())
            assert(parent and parent ~= 0, "missing expired timer")
            assert(jass.LoadInteger(HT, parent, 0x100) == keyboard_key,
                "event key=" .. tostring(jass.LoadInteger(HT, parent, 0x100)))
            assert(jass.LoadInteger(HT, parent, 0x101) == 1)
        end)
    end

    local function key_release_code()
        if key_release_seen then return end
        key_release_seen = true
        test("D3D SetKeyboard synthetic release reaches the texture", function()
            local parent = jass.GetHandleId(jass.GetExpiredTimer())
            assert(parent and parent ~= 0, "missing expired timer")
            assert(jass.LoadInteger(HT, parent, 0x100) == keyboard_key)
            assert(jass.LoadInteger(HT, parent, 0x101) == 0)
        end)
        local before_remove = call("GetTextureEventCount", "()I")
        call("TextureRemoveEvent", "(II)V", texture, key_event_id)
        test("D3D keyboard TextureRemoveEvent releases registration", function()
            local now = call("GetTextureEventCount", "()I")
            assert(now == before_remove - 1,
                string.format("event count %d -> %d (expected %d)",
                    before_remove, now, before_remove - 1))
        end)
    end

    test("D3D TextureAddEvent registers a keyboard key", function()
        key_event_baseline = call("GetTextureEventCount", "()I") or 0
        key_event_id = call("TextureAddEvent", "(IIII)I",
            texture, keyboard_key, jass.code(key_press_code), jass.code(key_release_code))
        assert(key_event_id and key_event_id ~= 0, "TextureAddEvent returned 0")
        assert(call("GetTextureEventCount", "()I") == key_event_baseline + 1)
    end)

    if not text or text == 0 or not texture or texture == 0 then
        done(pass, fail)
        return
    end

    print("  [WAIT] click inside, press Shift, then hold left and drag outside")
    -- The SetKeyboard probe sends its own key (E) while the cursor is inside.
    local entered = false
    local inside_ticks = 0
    local key_press_sent, key_release_sent = false, false
    local timer = jass.CreateTimer()
    jass.TimerStart(timer, 0.05, true, function()
        local inside = call("GetMouseInTexture", "(I)B", texture)
        if inside then
            inside_ticks = inside_ticks + 1
            -- SetKeyboard goes through PostMessage, so the synthetic key can be
            -- dropped (the game ignores keys while another window owns the
            -- foreground). Resend every tick while the cursor is inside instead
            -- of only every fourth one: the inside window can be short.
            if not key_press_seen then
                key_press_sent = true
                call("SetKeyboard", "(IB)V", keyboard_key, true)
            elseif key_press_seen and not key_release_sent then
                key_release_sent = true
                call("SetKeyboard", "(IB)V", keyboard_key, false)
            end
            if not entered then
                entered = true
                call("SetTextString", "(IS)V", text,
                    "JAPI D3D HOVER PASS - press Shift")
                call("SetTextColor", "(II)V", text, -16711936)
                print("  [D3D] cursor entered texture")
                test("D3D SetTextureShow gates the hit-test", function()
                    call("SetTextureShow", "(IB)V", texture, false)
                    assert(call("GetMouseInTexture", "(I)B", texture) == false,
                        "hidden texture still reported a hit")
                    call("SetTextureShow", "(IB)V", texture, true)
                    assert(call("GetMouseInTexture", "(I)B", texture) == true,
                        "shown texture no longer hit-tests")
                end)
                test("D3D GetMouseVector falls inside the texture rect", function()
                    local mx = call("GetMouseVectorX", "()R")
                    local my = call("GetMouseVectorY", "()R")
                    local x = call("GetTextureX", "(I)R", texture)
                    local y = call("GetTextureY", "(I)R", texture)
                    local w = call("GetTextureWidth", "(I)R", texture)
                    local h = call("GetTextureHeight", "(I)R", texture)
                    assert(mx >= x - 1.0 and mx <= x + w + 1.0,
                        string.format("mouse x=%.1f outside %.1f..%.1f", mx, x, x + w))
                    assert(my >= y - 1.0 and my <= y + h + 1.0,
                        string.format("mouse y=%.1f outside %.1f..%.1f", my, y, y + h))
                end)
            end
        elseif entered then
            if not event_press_seen or not event_release_seen then
                entered = false
                call("SetTextString", "(IS)V", text,
                    "JAPI D3D EVENT WAIT - move inside and press Shift")
                call("SetTextColor", "(II)V", text, -256)
                return
            end
            test("D3D SetKeyboard synthetic key completed", function()
                assert(key_press_seen and key_release_seen,
                    string.format("synthetic key press=%s release=%s",
                        tostring(key_press_seen), tostring(key_release_seen)))
            end)
            pass = pass + 1
            print("  [PASS] D3D real cursor enter/leave hit-test")
            call("SetTextString", "(IS)V", text,
                "JAPI D3D VISUAL + HOVER + EVENT PASS")
            call("SetTextColor", "(II)V", text, -16711936)
            jass.PauseTimer(timer)
            jass.DestroyTimer(timer)
            done(pass, fail)
        end
    end)
end

return { run = run }

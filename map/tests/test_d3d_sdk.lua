-- Public jass.d3d SDK fixture. This file must not use UnitId, japi_ht, or
-- handwritten bridge specs; those belong to test_d3d.lua only.

local d3d = require "jass.d3d"

local M = {}
local visual_resources

function M.run(done)
    if not _G.__JAPI_TEST_INTERACTIVE_D3D then
        if done then done(0, 0) end
        return
    end

    print("")
    print("-- D3D public Lua SDK fixture --")
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

    test("D3D SDK module and ABI availability", function()
        assert(d3d.is_available(), d3d.status().error)
        assert(type(d3d.version()) == "string" and #d3d.version() > 0)
        assert(d3d.abi_version() == 1)
        local caps = d3d.capabilities()
        assert(caps.session and caps.generation_handles)
        assert(caps.resource_counts and caps.core_properties)
        assert(caps.text_alpha and caps.unified_render_queue and caps.asset_memory)
        local width, height = d3d.window_size()
        assert(width > 0 and height > 0)
        assert(d3d.rgba(0x11, 0x22, 0x33, 0x44) == 0x44112233)

        local session = d3d.status().session_id
        package.loaded["jass.d3d"] = nil
        local reloaded = require "jass.d3d"
        collectgarbage("collect")
        assert(reloaded.is_available())
        assert(reloaded.status().session_id == session)
    end)

    local font
    local text
    local texture

    test("D3D SDK Font userdata properties", function()
        local err
        font, err = d3d.Font.new {
            face = "Arial",
            height = 28,
            width = 1,
            weight = 700,
            italic = true,
        }
        assert(font, err)
        assert(type(font) == "userdata")
        assert(font:get_face() == "Arial")
        assert(font:get_height() == 28)
        assert(font:get_width() == 1)
        assert(font:get_weight() == 700)
        assert(font:get_italic() == true)
        assert(font:set_face("Courier New"))
        assert(font:set_height(30))
        assert(font:set_width(0))
        assert(font:set_weight(600))
        assert(font:set_italic(false))
        assert(font:get_face() == "Courier New")
        assert(font:get_height() == 30 and font:get_width() == 0)
        assert(font:get_weight() == 600 and font:get_italic() == false)
        assert(not font:is_destroyed())
        local ok, range_err = pcall(function() font:set_weight(1001) end)
        assert(not ok and tostring(range_err):find("range", 1, true))
    end)

    test("D3D SDK Text userdata properties and Font dependency", function()
        local err
        text, err = d3d.Text.new {
            font = font,
            text = "SDK TEXT",
            x = 320,
            y = 72,
            color = d3d.rgba(255, 255, 0, 255),
            ttl = nil,
            visible = true,
            z = 123,
        }
        assert(text, err)
        assert(type(text) == "userdata")
        assert(text:get_text() == "SDK TEXT")
        local x, y = text:get_position()
        assert(math.abs(x - 320) < 0.01 and math.abs(y - 72) < 0.01)
        assert(text:get_color() == 0xFFFFFF00)
        assert(text:get_ttl() == nil)
        assert(text:get_visible() == true and text:get_z() == 123)
        assert(text:get_font() == font)
        assert(text:set_text("SDK TEXT UPDATED"))
        assert(text:set_position(330, 80))
        assert(text:set_color(0xFF00FF00))
        assert(text:set_ttl(30))
        assert(text:set_visible(false))
        assert(text:set_z(124))
        local long_text = string.rep("sdk", 1800)
        assert(text:set_text(long_text))
        assert(text:get_text() == long_text)
        assert(text:set_text("SDK TEXT UPDATED"))
        assert(text:get_text() == "SDK TEXT UPDATED")
        x, y = text:get_position()
        assert(x == 330 and y == 80)
        assert(text:get_color() == 0xFF00FF00 and text:get_ttl() > 0)
        assert(text:get_visible() == false and text:get_z() == 124)
        assert(text:set_visible(true))
        local destroyed, dep_err = font:destroy()
        assert(destroyed == nil and type(dep_err) == "string")
        assert(not font:is_destroyed())
    end)

    test("D3D SDK Texture userdata properties", function()
        local err
        texture, err = d3d.Texture.new {
            source = "d3d-sdk-probe.png",
            x = 320,
            y = 136,
            width = 256,
            height = 192,
            color = 0xFFFFFFFF,
            rotation = 0,
            z = 200,
            visible = true,
            hit_test = true,
        }
        assert(texture, err)
        assert(type(texture) == "userdata")
        assert(texture:get_source() == "asset://d3d-sdk-probe.png")
        local x, y, width, height = texture:get_rect()
        assert(x == 320 and y == 136 and width == 256 and height == 192)
        assert(texture:set_rect(340, 150, 240, 180))
        assert(texture:set_source_rect(4, 8, 100, 110))
        local left, top, right, bottom = texture:get_source_rect()
        assert(left == 4 and top == 8 and right == 100 and bottom == 110)
        assert(texture:set_color(0x80FFFFFF))
        assert(texture:set_rotation(90))
        assert(texture:set_z(201))
        assert(texture:set_visible(true))
        assert(texture:set_hit_test(true))
        assert(texture:get_color() == 0x80FFFFFF)
        assert(texture:get_rotation() == 90 and texture:get_z() == 201)
        assert(texture:get_visible() and texture:get_hit_test())
        local pixel_width, pixel_height = texture:pixel_size()
        assert(pixel_width == 16 and pixel_height == 16)
        assert(texture:contains(460, 240))
        assert(not texture:contains(570, 160), "rotated hit test used the unrotated AABB")
        assert(not texture:contains(10, 10))
    end)

    test("D3D SDK MPQ PNG/BLP assets and failure contract", function()
        local baseline = assert(d3d.stats())
        local png = assert(d3d.Texture.new {
            source = "asset://d3d-sdk-probe.png",
            width = 32, height = 32,
        })
        local blp = assert(d3d.Texture.new {
            source = "asset://war3mapMap.blp",
            width = 32, height = 32,
        })
        local game_blp = assert(d3d.Texture.new {
            source = "game://ReplaceableTextures/CommandButtons/BTNFootman.blp",
            width = 32, height = 32,
        })
        local pw, ph = png:pixel_size()
        assert(pw == 16 and ph == 16)
        local bw, bh = blp:pixel_size()
        assert(bw == 256 and bh == 256)
        local gw, gh = game_blp:pixel_size()
        assert(gw > 0 and gh > 0)
        assert(png:state() == "ready" and png:error() == nil)
        assert(png:reload())

        local shared = assert(d3d.stats())
        assert(shared.asset_cache.entries == baseline.asset_cache.entries + 2,
            "same URI/data did not share one cache entry")

        local missing, missing_err = d3d.Texture.new {
            source = "asset://missing/d3d-sdk.png",
        }
        assert(missing == nil
            and missing_err == "D3D asset not found: asset://missing/d3d-sdk.png")

        local corrupt, corrupt_err = d3d.Texture.new {
            source = "asset://d3d-sdk-corrupt.png",
        }
        assert(corrupt == nil
            and corrupt_err == "texture asset is invalid: asset://d3d-sdk-corrupt.png")

        local traversal, traversal_err = d3d.Texture.new {
            source = "asset://../outside.png",
        }
        assert(traversal == nil
            and traversal_err == "D3D asset URI rejected: asset://../outside.png")
        local file, file_err = d3d.Texture.new {
            source = "file://C:/outside.png",
        }
        assert(file == nil and file_err == "D3D asset URI rejected: file:// is disabled")

        local old_source = texture:get_source()
        local changed, change_err = texture:set_source("asset://missing/reload.png")
        assert(changed == nil
            and change_err == "D3D asset not found: asset://missing/reload.png")
        assert(texture:get_source() == old_source,
            "failed set_source replaced the working texture")

        local after_failures = assert(d3d.stats())
        assert(after_failures.textures == baseline.textures + 3,
            "failed asset loads leaked a texture handle")
        assert(game_blp:destroy() and blp:destroy() and png:destroy())
        local final = assert(d3d.stats())
        assert(final.textures == baseline.textures
            and final.asset_cache.entries == baseline.asset_cache.entries,
            "asset cache or handles did not return to baseline")
    end)

    test("D3D SDK P3 alpha and unified z visual fixture configured", function()
        visual_resources = {}
        visual_resources.font = assert(d3d.Font.new {
            face = "Arial",
            height = 24,
            weight = 700,
        })

        -- One deliberately interleaved same-z stack. Correct stable ordering
        -- is: low text, opaque cover, high text. The old type-batched renderer
        -- incorrectly placed both texts above both textures.
        visual_resources.background = assert(d3d.Texture.new {
            source = "asset://d3d-sdk-probe.png",
            x = 420, y = 136, width = 330, height = 240,
            color = 0xFF707070, z = 100,
        })
        visual_resources.low = assert(d3d.Text.new {
            font = visual_resources.font,
            text = "LOW TEXT MUST BE HIDDEN",
            x = 450, y = 180,
            color = 0xFFFFFF00, z = 200,
        })
        visual_resources.cover = assert(d3d.Texture.new {
            source = "asset://d3d-sdk-probe.png",
            x = 435, y = 165, width = 300, height = 60,
            color = 0xFF202020, z = 200,
        })
        visual_resources.high = assert(d3d.Text.new {
            font = visual_resources.font,
            text = "HIGH TEXT MUST BE VISIBLE",
            x = 450, y = 180,
            color = 0xFF00FF00, z = 200,
        })
        visual_resources.title = assert(d3d.Text.new {
            font = visual_resources.font,
            text = "P3 UNIFIED Z + TEXT ALPHA",
            x = 430, y = 140,
            color = 0xFFFFFFFF, z = 300,
        })
        visual_resources.alpha100 = assert(d3d.Text.new {
            font = visual_resources.font,
            text = "ALPHA 100%",
            x = 450, y = 245,
            color = 0xFFFFFFFF, z = 300,
        })
        visual_resources.alpha50 = assert(d3d.Text.new {
            font = visual_resources.font,
            text = "ALPHA 50%",
            x = 450, y = 280,
            color = 0x80FFFFFF, z = 300,
        })
        visual_resources.alpha0 = assert(d3d.Text.new {
            font = visual_resources.font,
            text = "ALPHA 0% MUST BE INVISIBLE",
            x = 450, y = 315,
            color = 0x00FFFFFF, z = 300,
        })

        assert(visual_resources.low:get_z() == 200)
        assert(visual_resources.cover:get_z() == 200)
        assert(visual_resources.high:get_z() == 200)
        assert(visual_resources.alpha100:get_color() == 0xFFFFFFFF)
        assert(visual_resources.alpha50:get_color() == 0x80FFFFFF)
        assert(visual_resources.alpha0:get_color() == 0x00FFFFFF)
    end)

    test("D3D SDK explicit destruction and use-after-destroy", function()
        assert(texture:destroy())
        assert(texture:destroy())
        assert(texture:is_destroyed())
        local ok, err = pcall(function() return texture:get_rect() end)
        assert(not ok and tostring(err):find("destroyed", 1, true))

        assert(text:destroy())
        assert(text:destroy())
        assert(text:is_destroyed() and not text:is_alive())
        assert(font:destroy())
        assert(font:destroy())
        assert(font:is_destroyed())
    end)

    test("D3D SDK GC and __close return counts to baseline", function()
        local baseline = assert(d3d.stats())
        do
            local gc_font = assert(d3d.Font.new {})
            local gc_text = assert(d3d.Text.new { font = gc_font, text = "gc" })
            local gc_texture = assert(d3d.Texture.new {
                source = "asset://d3d-sdk-probe.png", width = 8, height = 8,
            })
            assert(gc_text and gc_texture)
        end
        collectgarbage("collect")
        collectgarbage("collect")
        do
            local close_font <close> = assert(d3d.Font.new {})
            assert(not close_font:is_destroyed())
        end
        do
            local dependency_font = assert(d3d.Font.new {})
            local dependency_text = assert(d3d.Text.new {
                font = dependency_font,
                text = "dependency",
            })
            local weak = setmetatable({dependency_font}, {__mode = "v"})
            assert(dependency_text:destroy())
            dependency_font = nil
            collectgarbage("collect")
            collectgarbage("collect")
            assert(weak[1] == nil, "destroyed Text retained its Font uservalue")
        end
        local stats = assert(d3d.stats())
        assert(stats.fonts == baseline.fonts
            and stats.texts == baseline.texts
            and stats.textures == baseline.textures,
            string.format("resource leak: before=%d/%d/%d after=%d/%d/%d",
                baseline.fonts, baseline.texts, baseline.textures,
                stats.fonts, stats.texts, stats.textures))
    end)

    if done then done(pass, fail) end
end

function M.shutdown(done)
    if not _G.__JAPI_TEST_INTERACTIVE_D3D then
        if done then done(0, 0) end
        return
    end
    local pass, fail = 0, 0
    local ok, err = pcall(function()
        local before = assert(d3d.stats())
        assert(before.fonts > 0 and before.texts > 0 and before.textures > 0,
            "bridge fixture did not leave mixed resources for batch cleanup")
        assert(d3d.shutdown())
        assert(d3d.shutdown())
        visual_resources = nil
        collectgarbage("collect")
        assert(not d3d.is_available())
        local status = d3d.status()
        assert(status.shutdown and status.session_id == 0)
        local font, create_err = d3d.Font.new {}
        assert(font == nil and type(create_err) == "string" and #create_err > 0)
    end)
    if ok then
        pass = 1
        print("  [PASS] D3D SDK idempotent shutdown batches mixed resources")
    else
        fail = 1
        print("  [FAIL] D3D SDK idempotent shutdown batches mixed resources : " .. tostring(err))
    end
    if done then done(pass, fail) end
end

return M

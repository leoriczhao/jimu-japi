-- 示例 08 · D3D 贴图交互订阅（click / enter / leave / resize）
-- 用途：创建一块可命中的 D3D 贴图按钮，绑定点击与悬停事件，并监听窗口尺寸变化。
-- 打包：japi build examples/08-d3d-subscription
-- 运行：japi run   examples/08-d3d-subscription

local jass = require "jass.common"
local d3d = require "jass.d3d"

local clicks = 0

local t = jass.CreateTimer()
jass.TimerStart(t, 0.2, false, function()
    jass.DestroyTimer(t)
    if not d3d.is_available() then
        print("[Example 08] D3D unavailable: " .. tostring(d3d.status().error))
        return
    end

    local panel = d3d.Texture.new({
        source = "game://ReplaceableTextures/CommandButtons/BTNFootman.blp",
        x = 100, y = 140, width = 128, height = 128,
        color = d3d.rgba(255, 255, 255, 230),
        z = 150,
        hit_test = true,
    })

    panel:on("enter", function()
        panel:set_color(d3d.rgba(255, 255, 180, 255))
    end)

    panel:on("leave", function()
        panel:set_color(d3d.rgba(255, 255, 255, 230))
    end)

    panel:on("click", function(ev)
        clicks = clicks + 1
        jass.DisplayTimedTextToPlayer(
            jass.GetLocalPlayer(), 0.0, 0.0, 4.0,
            string.format("|cFF00FFCC[D3D]|r 点击面板第 %d 次 (%.0f, %.0f)", clicks, ev.x, ev.y)
        )
    end, { button = d3d.mouse.LEFT })

    d3d.on("resize", function(ev)
        print(string.format("[Example 08] window resized: %dx%d", ev.width, ev.height))
    end)
end)

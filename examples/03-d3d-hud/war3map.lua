-- 示例 03 · D3D HUD（Font / Text / Texture）
-- 用途：使用 jass.d3d 绘制一块半透明底板与实时刷新的 HUD 文本。
-- 说明：0.5.0 起支持零重启进程内 D3D9 激活，无需手动预装代理即可在 D3D9 模式下直接使用。
-- 打包：japi build examples/03-d3d-hud
-- 运行：japi run   examples/03-d3d-hud

local jass = require "jass.common"
local d3d = require "jass.d3d"

local hud = { frames = 0 }

local function create_hud()
    if not d3d.is_available() then
        print("[HUD] D3D unavailable: " .. tostring(d3d.status().error))
        return false
    end

    local font = d3d.Font.new({ face = "Arial", height = 18, weight = 700 })
    local panel = d3d.Texture.new({
        source = "game://ReplaceableTextures/CommandButtons/BTNRifleman.blp",
        x = 12, y = 108, width = 320, height = 64,
        color = d3d.rgba(8, 8, 8, 190),
        z = 99,
    })
    local label = d3d.Text.new({
        font = font,
        text = "japi d3d hud",
        x = 24, y = 124,
        color = d3d.rgba(255, 230, 120, 255),
        z = 100,
    })

    hud.font, hud.panel, hud.label = font, panel, label
    return true
end

local t = jass.CreateTimer()
jass.TimerStart(t, 0.2, false, function()
    jass.DestroyTimer(t)
    if not create_hud() then return end

    local tick = jass.CreateTimer()
    jass.TimerStart(tick, 0.1, true, function()
        if not hud.label then return end
        hud.frames = hud.frames + 1
        hud.label:set_text(string.format("japi d3d hud - frame %d", hud.frames))
    end)
end)

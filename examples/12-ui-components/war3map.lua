-- 示例 12 · D3D UI 组件库（行列布局 + 按钮 + 窗口缩放自适应）
-- 用途：演示 lib/ui.lua 的 column / row / button 组件以及响应窗口缩放的本地 UI 面板。
-- 打包：japi build examples/12-ui-components
-- 运行：japi run   examples/12-ui-components

local jass = require "jass.common"
local d3d = require "jass.d3d"
local ui = require "lib.ui"

local clicks = 0

local t = jass.CreateTimer()
jass.TimerStart(t, 0.2, false, function()
    jass.DestroyTimer(t)
    if not d3d.is_available() then
        print("[Example 12] D3D unavailable: " .. tostring(d3d.status().error))
        return
    end

    local ctx = assert(ui.new())
    local col = assert(ctx:column({
        padding = 12,
        spacing = 10,
        position = function(w, h)
            return math.max(16, w - 260), math.max(120, h - 260)
        end,
    }))

    local row = assert(col:row({ padding = 4, spacing = 10 }))
    row:button({
        text = "点击计数: 0",
        width = 200,
        height = 44,
        on_click = function(self)
            clicks = clicks + 1
            self:set_text("点击计数: " .. tostring(clicks))
        end,
    })

    col:button({
        text = "禁用按钮示例",
        enabled = false,
        width = 200,
        height = 36,
    })
end)

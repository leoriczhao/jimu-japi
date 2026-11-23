# Lua 标准库指南（`std.*`）

SDK 内置了零排泄、按需打包（Tree-Shaking）的地图开发标准库 `std.*`。
地图工程中**无需手动复制任何库文件**，直接 `require "std.xxx"`，`japi build` 会自动只将用到的模块打进 `war3map.lua`；如需定制，在自己工程下新建同名 `std/xxx.lua` 即可覆盖。

## 模块总览

| 模块 | 职责 | 常用入口 |
|---|---|---|
| `std.util` | 缓存 `fourcc`/`id2str`、向量/距离/角度、ARGB 颜色 | `util.fourcc("hfoo")`, `util.polar(...)`, `util.rgba(...)` |
| `std.signal` | UI 无关的细粒度响应式内核（SolidJS/Fusion 模型） | `Signal.state`, `Signal.computed`, `Signal.effect`, `Signal.batch`, `Signal.scope` |
| `std.frame` | 通用 `DzFrame` 后端适配（经 `jass.japi` 自动发现 KKAPI，固定事件槽零 trampoline 泄漏） | `Frame.create`, `Frame.set_point`, `Frame.on`, `Frame.destroy` |
| `std.ui` | **通用声明式 + 响应式 `DzFrame` UI 框架**（零业务假设、零写死皮肤） | `UI.Box`/`Text`/`Image`/`Button`/`Model`/`Input`/`Raw`, `Row`/`Column`/`Grid`/`Scroll`/`Overlay`, `Show`/`For`, `component`, `provide`/`use`, `mount` |
| `std.d3d_ui` | 可选 `jass.d3d` 渲染层 UI 组件库（无 KKAPI 的纯单机原版 1.27a 备用） | `D3DUI.new()`, `ctx:panel`, `node:button`, `node:progress_bar` |
| `std.timer` | 池化零泄漏定时器 + 共享 33Hz 帧循环 | `Timer.after(sec, fn)`, `Timer.loop(iv, fn, max)`, `Timer.frame(fn)` |
| `std.event` | 统一事件总线（惰性自动桥接 War3 原生事件与伤害数据） | `Event.on("unit:damage", fn)`, `Event.on("unit:death", fn)`, `Event.on("key:down", fn)` |
| `std.player` | 玩家对象单例封装 | `Player.get(0)`, `p:add_gold(100)`, `p:say(...)`, `p:set_hp_bar_color(...)` |
| `std.unit` | 单位面向对象封装（句柄缓存、自定义 `u.data`、移除自动清理） | `Unit.create(p0, "hfoo", x, y)`, `u:damage(t, 50)`, `u:set_hp_bar_color(...)` |
| `std.group` | 复用临时组与矩形的零泄漏单位查询 | `Group.in_range(x, y, r, filter)`, `Group.nearest(...)` |
| `std.effect` | 自动定时销毁的特技与 3D 变换 | `Effect.play(mdl, x, y, dur, opts)`, `Effect.attach(mdl, u, "origin", dur)` |
| `std.statbar` | 原生 1.27a `CStatBar` 血蓝条控制与预设 | `StatBar.apply_theme("rpg" \| "moba" \| "clean" \| "vanilla")` |
| `std.tween` | 基于共享帧循环的缓动动画与颜色插值 | `Tween.to({ from, to, duration, ease, on_update })`, `Tween.color(...)` |

## 通用 `std.ui` 示例（基于 `DzFrame` + `std.signal`）

```lua
local Timer = require "std.timer"
local UI    = require "std.ui"

-- 自定义通用组件（零框架耦合）
local MyRowItem = UI.component(function(props)
    local theme = UI.use("theme")
    return UI.Box {
        w = 0.16, h = 0.024, tex = theme.item_bg,
        UI.Text { fill = true, text = props.label, font = theme.font, size = 0.011, align = "CENTER" },
    }
end)

Timer.after(0.2, function()
    local count = UI.state(0)
    local items = UI.state({ "Item A", "Item B" })
    local title = UI.computed(function() return "Clicks: " .. tostring(count:get()) end)

    local app = UI.mount(
        UI.Column {
            anchor = "TOPRIGHT", x = -0.02, y = -0.04, padding = 0.01, gap = 0.006,
            tex = "UI\\Widgets\\ToolTips\\Human\\human-tooltip-background.blp",
            UI.Text { w = 0.16, h = 0.02, text = title, align = "CENTER" },
            UI.Button {
                w = 0.16, h = 0.028,
                on_click = function()
                    count:update(function(n) return n + 1 end)
                    items:set({ "Item A", "Item B", "Item #" .. tostring(count:peek()) })
                end,
                UI.Box {
                    fill = true, tex = "UI\\Widgets\\Glues\\GlueScreen-Button1-BackdropBackground.blp",
                    UI.Text { fill = true, text = "+1", align = "CENTER" },
                },
            },
            -- 固定池化列表：只创建 4 组 Frame 槽位并永久复用，零重建泄漏
            UI.For {
                each = items, max = 4,
                render = function(item_sig)
                    return MyRowItem { label = item_sig }
                end,
            },
        },
        { theme = { font = "Fonts\\dfst-m3u.ttf", item_bg = "UI\\Widgets\\ToolTips\\Human\\human-tooltip-background.blp" } }
    )

    -- 随时一键释放全部 Frame、事件槽与 Signal 订阅
    -- app:destroy()
end)
```

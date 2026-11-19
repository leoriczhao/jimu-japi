# jass.d3d 五分钟 Quickstart

> 目标读者：已经能用本项目打包并运行地图的 Lua 作者。
> 只用到三个公开入口：`jass.common`（native）、`jass.message`（输入/命令）、`jass.d3d`（显示）。
> 不需要 `UnitId`、hashtable 或任何手写 bridge spec。

## 0. 先确认链路通

```powershell
cd src; .\build.bat                      # 编译 yd_japi.dll + newD3d9.dll
.\.\tools\deploy.ps1 -Demo              # 打包 + 启动 War3 + 跑垂直切片（11 项断言）
```

切片跑绿说明 proxy、Lua VM、D3D 绘制和输入都正常；此时窗口里能看到 HUD 文字和底板。
详细入口见 [STATUS.md 第 4 节](../STATUS.md)。

### 让地图自带代理

```powershell
.\tools\pack.ps1        # 代理每次都会打进去，没有开关
```

代理和 D3DX 会一起进地图（`d3d9.tga` / `d3dx9_42.tga` / `d3d9.tga.sha256`），别人拿到 `.w3x`
不用再单独装一遍。代理是 `d3d9.dll` 的替身，只能随进程启动加载，所以**第一次**运行地图时
它只是被写到 `war3.exe` 旁边（日志 `D3D: staged d3d9.dll from the map`），**重开一次游戏**
才生效。机器上已经有同版本代理时直接跳过；已有别人的 `d3d9.dll` 时不覆盖，只记日志。

## 1. 最小 HUD（可直接粘进 war3map.lua 的函数）

```lua
local jass = require "jass.common"
local d3d  = require "jass.d3d"

local hud = {}

function hud.create()
    if not d3d.is_available() then
        print("[hud] unavailable: " .. tostring(d3d.status().error))
        return false
    end
    local width, height = d3d.window_size()
    if width <= 0 or height <= 0 then return false end

    hud.font = assert(d3d.Font.new { face = "Arial", height = 18, weight = 700 })
    -- War3 顶栏 + 左上单位面板占掉前 ~110 个客户区像素，正文从 120 起。
    hud.title = assert(d3d.Text.new {
        font = hud.font, text = "HELLO MAP",
        x = 24, y = 120, color = d3d.rgba(255, 230, 120, 255), z = 100,
    })
    hud.panel = assert(d3d.Texture.new {
        source = "game://ReplaceableTextures\\CommandButtons\\BTNRifleman.blp",
        x = 12, y = 108, width = 320, height = 64,
        color = d3d.rgba(8, 8, 8, 190), z = 99,   -- 近黑半透明底板
    })
    return true
end

function hud.destroy()
    for _, object in ipairs { hud.panel, hud.title, hud.font } do
        if object and not object:is_destroyed() then object:destroy() end
    end
end
```

要点：

- `Font` 必须比使用它的 `Text` 活得久；有依赖时销毁 Font 会报错。
- `z` 小的先画；同 `z` 按创建顺序画。文字和贴图共用一条队列。
- 坐标是**客户区像素**（左上角原点），不是 0..1 归一化坐标。
- 颜色用 `d3d.rgba(r, g, b[, a])`（a 默认 255），内部是 ARGB。
- 文字直接写 UTF-8 中文即可，proxy 用 `DrawTextW` 渲染。

## 2. 让 HUD 跟着游戏状态更新

```lua
local timer = jass.CreateTimer()

local function tick()
    local hero = jass.GetTriggerUnit() -- 换成你自己的单位句柄
    if hero then
        hud.title:set_text(string.format("HP %.0f",
            jass.GetUnitState(hero, jass.ConvertUnitState(0))))
    end
end

jass.TimerStart(timer, 0.1, true, jass.code(tick))
```

`jass.code(fn)` 把 Lua 函数变成 JASS code，可用于 timer/trigger 回调（普通回归与
`-Demo` 里的 F2 重启都是这条路）。

## 3. 加一点交互（贴图订阅）

```lua
local sub = hud.panel:on("click", function(event)
    print(string.format("clicked at local (%.0f, %.0f)", event.local_x, event.local_y))
end, { button = d3d.mouse.LEFT })

-- 结束时取消；也可以直接 hud.panel:destroy()，会连带取消全部订阅。
sub:cancel()
```

事件名：`enter` / `leave` / `mouse_down` / `mouse_up` / `click` / `key_down` / `key_up`。
选项：`button`（鼠标事件）、`key`（键盘事件，取 `d3d.key.Q` 这类 WARK 值）、
`hover_only`（默认 `true`，要求光标在贴图内）、`propagate`（默认 `false`）、
`keep_on_error`（默认 `false`，回调报错即取消订阅）。

> 输入事件要求 War3 窗口是前台窗口。游戏内 1.27a 的 CGameUI 分发只送键盘消息，
> 鼠标按钮由窗口 `WM_*` 消息 + 异步按键状态补齐，两条源共用同一状态机去重。

## 4. 响应窗口缩放与设备重建

```lua
local modules = {
    d3d.on("resize", function(event)
        print(string.format("window is now %dx%d", event.width, event.height))
    end),
    d3d.on("device_reset", function(event)
        print("device reset, generation=" .. event.generation)
        -- 句柄、属性、订阅都保持有效；这里只做需要重算的布局。
    end),
}
```

窗口尺寸变化会触发真实的 device reset（2026-11-15 实测 20 次 resize → 20 次 reset，
generation 1→21），过程中 Font/Text/Texture 的句柄、文本、位置、尺寸和订阅全部保持有效，
所以不需要重建对象——只需要重新计算依赖窗口尺寸的坐标。

`device_lost` 事件通道存在，但 1.27a 窗口模式下 lost→reset 在同一帧完成，观测不到；
不要把它当作必发事件。

## 5. 收尾

```lua
d3d.shutdown()   -- 批量销毁同 session 内 SDK 创建的全部资源并取消订阅
```

`shutdown()` 之后所有旧句柄访问都会报 `... is destroyed or belongs to a closed session`，
重复调用是幂等的。地图结束/重开时 SDK 的 context GC 也会做同样的清理。

## 6. 出问题时先看什么

| 现象 | 先查 |
|---|---|
| `d3d.is_available()` 为 false | `d3d.status().error`；代理是否已落地（地图自带，但首次运行只是写到 `war3.exe` 旁，需重开一次游戏；`deploy.ps1` 会当场装） |
| 构造返回 `nil, err` | 错误文本就是原因（`D3D asset not found: ...` 等），见 API 文档错误表 |
| 订阅收不到事件 | 窗口是否前台；是否 `hover_only`；是否按了正确的 WARK 键码 |
| 运行日志 | `C:\ProgramData\japi_debug.txt`（`[D3D SDK]` 前缀） |
| 计数器 | `d3d.stats()`（fonts/texts/textures/subscriptions/device_generation） |

完整的类型、字段、错误文本和生命周期规则见 [D3D-LUA-API.md](D3D-LUA-API.md)；
从旧接口迁移见 [D3D-LUA-MIGRATION.md](D3D-LUA-MIGRATION.md)。

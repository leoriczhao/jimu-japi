# 代码化物编与基础 UI

把 `examples/11-object-data` 或 `examples/12-ui-components` 整个复制成自己的地图工程。前者演示构建期单位/技能声明，后者演示客户端按钮与线性布局。这两项复用现有 DLL、打包器和 D3D 原语，不需要修改 C++。

## 代码化物编

在项目的 `war3map.lua` 旁边放 `objects.lua`：

```lua
unit {
    id = 'u001', parent = 'hfoo',
    fields = { unam = 'My Footman', uhpm = 725, umvs = 300 },
}
ability {
    id = 'A001', parent = 'AHbz',
    fields = {
        anam = 'My Blizzard', alev = 3, aher = 0,
        acdn = { 9.0, 7.0, 5.0 },
        amcs = { 30, 40, 50 },
    },
}
```

正常打包即可，不增加开关：

```powershell
.\tools\pack.ps1 -MapDir examples\11-object-data -OutFile build\objects.w3x
.\tools\verify-examples.ps1 -Filter 11 -Live -Timeout 160
```

打包器先编译基座原有 LNI 数据，再把声明追加到真实 `war3map.w3u` / `war3map.w3a` 文件。已有对象记录被保留，原始基座和声明文件不被修改；只写打包工作目录。

`objects.lua` 是构建专用保留文件，不会进入运行时模块表，也不要在游戏脚本里 `require "objects"`。声明环境只暴露 `unit` 和 `ability`，可用 Lua 局部变量、字面量、算术；不提供标准库、文件系统或游戏接口。这不是对不可信程序的资源隔离机制。

字段使用四字符物编字段 ID，并按随仓库获取的 w3x2lni 1.27.1 元数据验证：

| 类型 | 本轮字段 |
|---|---|
| 单位标量 | `unam` 名称、`uhpm` 生命、`umpi` 初始魔法、`umvs` 移速、`usca` 缩放、`uabi` 技能列表 |
| 技能标量 | `anam` 名称、`alev` 等级数、`aher` 英雄标志、`aite` 物品标志 |
| 技能等级表 | `acdn` 冷却、`amcs` 魔耗、`aran` 距离、`aare` 范围、`adur` 持续、`ahdu` 英雄持续、`atp1` 提示、`aub1` 扩展提示 |

限制和错误规则：

- ID/父 ID 必须是四个 ASCII 字母、数字或下划线；显式指定，不自动编号。父对象目前只接受对应类型的原生对象。
- 声明之间的重复 ID、与原生对象或目标基座记录冲突的 ID 会失败。重复构建同一输入得到相同物编字节。
- 技能必须明确填写 `alev`（1..100）；每个等级表恰好包含 1..alev 的连续值，不自动填补或复制标量。
- 字段名、整数/实数/字符串类型和范围会验证；额外玩法语义（例如正生命、0/1 标志、有效技能列表）仍由作者保证。
- 支持既有版本 1/2 物编二进制；其他版本、损坏数据或未转换的冲突 LNI 输入会拒绝。只支持本表字段，不支持 DataA/DataB 和自定义父对象链。
- 增加等级不自动生成遗漏的父技能数据；继承机制和每级技能效果需要地图作者验证。

完整类型表和实现入口见 [编译器说明](../../tools/object-data/README.md)。

## 按钮与布局

把 `map/lib/ui.lua` 复制到自己项目的 `lib/ui.lua`，或者直接使用示例 12 自带的副本。项目依赖必须随项目一起复制。

```lua
local d3d = require "jass.d3d"
local ui = require "lib.ui"

-- 在 D3D 已就绪后的初始化阶段调用。
local context = assert(ui.new())
local panel = assert(context:column {
    position = function(w, h) return w - 340, h - 220 end,
    padding = 12, spacing = 8,
})
local row = assert(panel:row { spacing = 10 })
local button = assert(row:button {
    text = 'Click', width = 160, height = 40,
    on_click = function(self, event)
        self:set_text('Clicked locally')
    end,
})

button:set_enabled(false)
button:set_hidden(true)
-- 离开界面时：assert(context:destroy())
```

所有坐标都是 War3 客户区像素，左上原点。顶层节点可固定 `x`/`y` 或设置 `position(w,h)`，窗口大小变化时重新计算。行排列累计宽度、列排列累计高度，支持 `spacing`、`padding` 和嵌套；隐藏节点不占流式布局空间。显式容器尺寸不会自动拉伸、裁剪子节点。

按钮支持 normal / hover / pressed / disabled 颜色、标签、启用与隐藏。禁用时仍命中并消耗输入，但不调用 `on_click`；隐藏时关闭可见性和命中。点击资格、按下捕获和拖出松手由原生 D3D SDK 处理。

`destroy()` 幂等，组件只取消自身订阅并按依赖顺序释放 Text、Texture、Font。Context 同时取消窗口 resize 订阅。用户回调中可销毁按钮或整个 Context；创建失败会回收已分配资源；原生释放失败可通过下一次 destroy 重试。不会调用 `d3d.shutdown()` 影响其他界面。

输入回调属于本地客户端，示例只修改展示状态。多人玩法状态必须另行同步；本轮没有提供同步通道。当前不包含文字测量、自动换行、滚动、裁剪或键盘焦点。

更多 API 和真实输入标记见 [UI 示例说明](../../examples/12-ui-components/README.md)。

## 验证入口

```powershell
# 离线：物编验证、真实 w3x2lni 解码、保留基座对象
powershell -NoProfile -ExecutionPolicy Bypass -File tests\object-data\run.ps1

# 离线 mock：实际 UI 库与示例流程，不代表真实渲染或输入
.\tools\w3x2lni\bin\w3x2lni-lua.exe tests\ui\run.lua
.\tools\w3x2lni\bin\w3x2lni-lua.exe tests\ui\example_contract.lua

# 两个示例：静态、打包、串行实机
.\tools\verify-examples.ps1 -Filter '11|12' -Live -Timeout 160
```

示例 11 在游戏里核对真实自定义单位、技能等级、SLK 数据。示例 12 由 `tools/drive-ui-components.ps1` 驱动真实窗口点击和 resize，顺序为禁用点击 → 启用点击 → 窗口变化 → 新位置点击；只有全部完成并回收资源后才输出成功汇总。日志与结果入口见 [STATUS](../STATUS.md)，未在此把离线 mock 当作实机通过。

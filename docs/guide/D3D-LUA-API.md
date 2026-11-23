# jass.d3d API 参考

> 适用：War3 1.27a + 本项目 proxy（`newD3d9.dll`）+ `yd_japi.dll` 内嵌 Lua 5.4。
> 状态：D3D Lua SDK 于 2026-11-15 记录为「可用」（发布产物可溯源到提交 `d151fd7` 的 clean 构建，见
> [STATUS.md](../STATUS.md) 与设计文档 14.4）；未进入稳定承诺的部分见文末“当前限制”。
> SDK 版本号为 `0.5.0`（`d3d.version()`），原生 ABI 版本 `d3d.abi_version()`。
> 本文件只描述**已实机验收**的行为；未验收的能力见文末“当前限制”。

```lua
local d3d = require "jass.d3d"
```

坐标一律是 **War3 客户区像素**（左上原点，正 y 向下）。颜色是 32 位整数，用
`d3d.rgba(r, g, b[, a])` 生成（`a` 默认 255，内部 ARGB）。`z` 越小越先画；同 `z` 按创建顺序。
文字与贴图共用同一条渲染队列。

---

## 1. 模块函数

| 函数 | 返回 | 说明 |
|---|---|---|
| `d3d.is_available()` | boolean | ABI 协商成功且未 `shutdown` |
| `d3d.version()` | string | Lua SDK 版本，当前 `"0.5.0"` |
| `d3d.abi_version()` | integer | 原生 ABI 版本（未就绪为 0） |
| `d3d.capabilities()` | table | 能力位，见下 |
| `d3d.status()` | table | 会话/设备诊断，见下 |
| `d3d.stats()` | table 或 `nil, err` | 资源与缓存计数 |
| `d3d.window_size()` | width, height 或 `nil, err` | 当前客户区像素尺寸 |
| `d3d.rgba(r, g, b[, a])` | integer | 生成 ARGB；通道越界抛错 |
| `d3d.on(event, callback)` | Subscription 或 `nil, err` | 模块级生命周期订阅（见 §6） |
| `d3d.shutdown()` | boolean | 幂等批量清理同一 session 的资源与订阅 |

`capabilities()` 的键：`session`、`generation_handles`、`resource_counts`、
`core_properties`、`text_alpha`、`unified_render_queue`、`asset_memory`、
`input_hit_stack`、`device_state`、`lifecycle_events`、`subscriptions`。

`status()` 的键：

| 键 | 类型 | 说明 |
|---|---|---|
| `available` | boolean | 与 `is_available()` 同义 |
| `shutdown` | boolean | 是否已显式 shutdown |
| `session_id` | integer | 当前原生 session |
| `pending_callbacks` | integer | 待分发的输入事件队列长度 |
| `error` | string | 初始化失败原因（成功时为空串） |
| `device_ready` | boolean | 设备是否可用（仅 available 时） |
| `device_generation` | integer | 每次成功的 device reset 自增，起始 1 |
| `state` | string | `"active"` / `"lost"` / `"closed"` / `"unavailable"` |

`stats()` 的键：`session_id`、`fonts`、`texts`、`textures`、`subscriptions`、
`device_ready`、`device_generation`、`asset_cache`（`{ entries, bytes }`）。

---

## 2. Font

```lua
local font, err = d3d.Font.new { face = "Arial", height = 16, weight = 400 }
```

| 构造字段 | 默认 | 约束 |
|---|---|---|
| `face` | `"Arial"` | 字体名 |
| `height` | `16` | > 0 |
| `width` | `0` | >= 0（0 表示按 height 自动） |
| `weight` | `400` | 0..1000 |
| `italic` | `false` | boolean |

方法：`get_face()` / `set_face(s)`、`get_height()` / `set_height(n)`（1..）、
`get_width()` / `set_width(n)`（0..）、`get_weight()` / `set_weight(n)`（0..1000）、
`get_italic()` / `set_italic(b)`、`is_destroyed()`、`destroy()`。
调 `__tostring` 得到 `jass.d3d.Font(handle=..., destroyed=...)` 之类的调试串。

Font 被 Text 强引用：仍有 Text 活着时 `font:destroy()` 报错；销毁 Text 后可以销毁 Font。

---

## 3. Text

```lua
local text, err = d3d.Text.new {
    font = font, text = "HP 420", x = 24, y = 120,
    color = d3d.rgba(255, 255, 255), z = 100, ttl = 3.0, visible = true,
}
```

| 构造字段 | 默认 | 说明 |
|---|---|---|
| `font` | 必填 | `Font` 对象 |
| `text` | `""` | UTF-8 字符串，可含中文 |
| `x`, `y` | `0` | 客户区像素 |
| `color` | `0xFFFFFFFF` | ARGB |
| `visible` | `true` | |
| `z` | `0` | |
| `ttl` | 无限 | **> 0 才生效**，单位秒；到期后由原生帧循环释放 |

方法：`get_text()` / `set_text(s)`、`get_position()` / `set_position(x, y)`、
`get_ttl()` / `set_ttl(秒)`、`get_color()` / `set_color(argb)`、
`get_visible()` / `set_visible(b)`、`get_z()` / `set_z(n)`、
`get_font()` / `set_font(font)`、`is_alive()`（销毁/过期后返回 false，不抛错）、
`is_destroyed()`、`destroy()`。

TTL 语义：`get_ttl()` 对无限生命返回 `nil`；设置 `ttl <= 0` 等于取消 TTL。
到期不是 Lua 主动删除，而是原生侧释放资源——所以 Lua 侧下一次访问
（`get_text()` 等）会抛 `... is destroyed or belongs to a closed session`，
`is_destroyed()` 返回 true，`d3d.stats().texts` 同步回落。Text 使用 D3DXFont 逐字形绘制，
因此 0% / 50% / 100% alpha 都真实生效。

---

## 4. Texture

```lua
local texture, err = d3d.Texture.new {
    source = "asset://war3map_preview.blp",   -- 或 game://...、或裸路径
    x = 0, y = 0, width = 64, height = 64,
    color = d3d.rgba(255, 255, 255), z = 0, visible = true, hit_test = true,
}
```

| 构造字段 | 默认 | 说明 |
|---|---|---|
| `source` | 必填 | 资源 URI，见 §5 |
| `x`, `y` | `0` | |
| `width`, `height` | `0` | 显示尺寸（客户区像素）。**0 等于不绘制**，需要原始像素尺寸时先 `pixel_size()` 或在创建前自己量 |
| `color` | `0xFFFFFFFF` | 顶点色（achromatic 置灰/染色） |
| `rotation` | `0` | 角度（度），绕贴图中心 |
| `z` | `0` | |
| `visible` | `true` | |
| `hit_test` | `true` | 参与光标命中与订阅分发 |

方法：`get_source()` / `set_source(uri)`（失败返回 `nil, err` 且保留旧资源）、`reload()`、
`state()`（`"ready"` / `"lost"`）、`error()`（当前恒 nil，预留给将来诊断）、
`get_rect()` / `set_rect(x, y, w, h)`、`get_source_rect()` / `set_source_rect(l, t, r, b)`、
`get_color()` / `set_color(argb)`、`get_rotation()` / `set_rotation(deg)`、
`get_z()` / `set_z(n)`、`get_visible()` / `set_visible(b)`、
`get_hit_test()` / `set_hit_test(b)`、`pixel_size()`（图片原始像素宽高，与显式
`width/height` 无关）、`contains(x, y)`（考虑旋转后的几何判定）、`on(event, cb[, opts])`、
`is_destroyed()`、`destroy()`。

同一 `source` 的字节流共享 CPU cache：重复创建不会重复解码，`stats().asset_cache` 可观察。

---

## 5. 资源 URI 与 MPQ 导入

| 形式 | 搜索链 | 用途 |
|---|---|---|
| `asset://path/file.blp` | 当前地图 MPQ（含导入文件） | 地图作者自己的素材 |
| `game://path/file.blp` | 游戏安装目录资源链 | 游戏内置贴图/图标 |
| `path/file.blp`（无 scheme） | 等同 `asset://` | 兼容写法 |

规则与错误（构造/换源返回 `nil, err`，`err` 就是下列文本）：

- `D3D asset URI rejected: file:// is disabled` —— `file://` 永久禁用。
- `D3D asset URI rejected: unsupported URI scheme` —— 只支持 asset/game。
- `D3D asset URI rejected: <uri>` —— 空路径、绝对路径、盘符、`..` 穿越、含 `:`。
- `D3D asset not found: <uri>` —— MPQ 里没有该文件。
- `D3D asset size rejected: <uri>` —— 0 字节或超过 64 MiB。
- `D3D asset allocation failed: <uri>` / `D3D asset loader unavailable: <uri>`。

导入素材：用你惯用的 MPQ 工具（本项目 `tools/pack.ps1` 走 w3x2lni）把文件放进地图，
运行时用 `asset://` 引用相对路径。已实机验证 PNG、BLP1（含 1.27a 的索引调色板）、
游戏内 BLP，以及 BLP2 的 raw BGRA / 索引调色板 / DXT1 三种编码。BLP 只走内存解码
（`asset://`/`game://`）；用文件路径换源时仍只支持 D3DX 可读格式（BMP/PNG/JPG/TGA/DDS）。

---

## 6. 事件与订阅

### 6.1 贴图事件

```lua
local sub, err = texture:on("click", function(event) ... end, {
    button = d3d.mouse.LEFT,   -- 鼠标事件过滤
    key    = d3d.key.Q,        -- 键盘事件过滤（WARK 码）
    hover_only  = true,        -- 默认 true：要求光标在贴图内
    propagate   = false,       -- 默认 false：命中即停，不再向下层贴图传递
    keep_on_error = false,     -- 默认 false：回调报错后自动取消订阅
})
```

事件名：`enter`、`leave`、`mouse_down`、`mouse_up`、`click`、`key_down`、`key_up`。

`click` = 在贴图内按下并在位移 ≤ 6px 内松开；拖拽超过阈值只产生 `mouse_down`/`mouse_up`。
按下时命中的贴图会获得 pointer capture，因此拖到贴图外松开仍能收到 `mouse_up`。

事件表字段（**只读**，写入抛 `D3D event tables are read-only`）：

| 字段 | 说明 |
|---|---|
| `type` | 事件名 |
| `target` | 触发订阅的 Texture 对象 |
| `x`, `y` | 客户区像素坐标 |
| `local_x`, `local_y` | 相对贴图（含旋转）的局部坐标 |
| `timestamp` | 秒（GetTickCount64） |
| `button` | 鼠标事件专用，0..4（见 `d3d.mouse`） |
| `key` | 键盘事件专用，WARK 码（见 `d3d.key`） |

`d3d.mouse`：`LEFT=0`、`RIGHT=1`、`MIDDLE=2`、`X1=3`、`X2=4`。
`d3d.key` 直接暴露 `WARK_*` 码（`d3d.key.Q == 0x51`、`d3d.key.F2 == 0x301`、
`d3d.key.SHIFT == 0x00`），与 `jass.message` 的键盘码一致。

### 6.2 模块级生命周期事件

```lua
d3d.on("resize",       function(event) --[[ event.width, event.height ]] end)
d3d.on("device_reset", function(event) --[[ event.generation ]] end)
d3d.on("device_lost",  function(event) --[[ event.generation ]] end)
```

事件表字段：`type`、`timestamp`，`resize` 额外带 `width`/`height`，
`device_lost`/`device_reset` 额外带 `generation`。同样只读。

### 6.3 Subscription 对象

`is_active()` → boolean；`cancel()` → 取消（幂等，重复调用不报错）。
被取消或所属贴图/会话销毁后 `is_active()` 为 false。
Subscription 也走 `__close`，可配合 `local sub <close> = texture:on(...)`。

---

## 7. 生命周期与销毁规则

1. **显式销毁优先**：`object:destroy()` 幂等；之后 `is_destroyed()` 为 true。
2. **GC 兜底**：丢弃最后一个强引用并 GC 后，原生资源同样被回收（Text 使用独立弱表
   helper frame，不阻止回收）。也可以 `__close` 让作用域结束即释放。
3. **依赖**：Font → Text 是强引用；Texture 的销毁会连带取消它的全部订阅。
4. **use-after-destroy**：任何业务方法都会抛
   `jass.d3d Text:... is destroyed or belongs to a closed session` 之类错误，
   不会静默命中新对象。
5. **shutdown**：`d3d.shutdown()` 清空同一 session 的 SDK 资源与旧 bridge 资源，
   之后构造返回 `nil, err`（`D3D SDK ... unavailable`），旧句柄全部失效。
6. **换图自动重置**：重新进图/重开一局时，注入层会关闭旧 Lua VM 并重建，然后加载新地图的
   `war3map.lua`；VM 关闭会走 context GC（`end_session`），所以旧 session 的对象全部失效，新脚本拿到
   新的 `session_id`。不要跨地图缓存 userdata。
7. **context GC**：Lua 上下文回收时自动 cancel 全部订阅并 `end_session`。

---

## 8. device 丢失/重建

- `status().device_generation` 每次成功的 reset +1（起始 1）；`stats()` 同步。
- reset 只重建 default-pool 抱有的 GPU 资源；**逻辑句柄、属性、订阅保持稳定**，
  不需要重建对象（2026-11-15 实测连续 20 次窗口尺寸变化：20 次 reset，句柄/文本/位置/
  尺寸/订阅全部保持）。
- 设备丢失期间的原始输入不入队（避免跨 generation 重放）；`status().state` 会短暂为
  `"lost"`，但 1.27a 窗口模式下 lost→reset 同帧完成，`device_lost` 事件通常观测不到。
- `Texture:state()` 返回 `"ready"` / `"lost"`，可在绘制前做防御性判断。

---

## 9. 错误处理

两种风格：

- **构造/换源/订阅**返回 `nil, err`（不抛异常），所以可以直接
  `local obj, err = d3d.Text.new{...}`。
- **方法调用**出错直接抛 Lua 错误（`luaL_error`），所以要么让错误冒泡，
  要么 `pcall` 包住。

原生失败文本形如 `D3D SDK operation failed (code N): ...`；加上 §5 的资产错误。
回调内部报错被 SDK 隔离：默认取消该订阅并记
`[D3D SDK] subscription N cancelled after callback error` 到 `japi_debug.txt`。

---

## 10. 当前限制

- `device_lost` 事件不可观测（见 §8）。
- 地图级重置只在**重新载入地图**时发生（重新进图/重开一局）；单局游戏内没有“重启本图”的入口，
  需要重开就重新进图，此时旧 VM、旧 session 和旧 HUD 会一起消失。
- `jass.globals` 的数组元素依赖打包器注入的预分配（`tools/pack.ps1` 默认给每个声明的数组生成
  `JapiForceAllocArrays`，在 `LoadScript` 之前调用）：默认打包出的图可以写任意合法下标（0–8191）并读 `#arr`；
  用 `-NoArrayPrealloc` 打包时，从未被 JASS 触碰过的数组 `index>0` 写入无效、读回 `nil`。
- `Texture:error()` 恒为 nil（保留接口）。
- `file://` 禁用；单文件上限 64 MiB；BLP 只走内存解码路径（`asset://`/`game://`），实机证据覆盖 BLP1/PNG
  与 BLP2 的 raw BGRA / 调色板 / DXT1（BLP2 的 JPEG 编码不支持，会报 `texture asset is invalid`）。
- 输入事件依赖窗口前台；GameUI 分发在 1.27a 游戏内只送键盘消息，鼠标按键来自 Win32 窗口消息。
- D3D 兼容 handler 面已被回归夹具全部触达（54/54），但 54 是兼容名字数、164 是回归用例总数，
  都不是“164 个 API 都可用”；触达也不等于每个 handler 的全部参数边界都被覆盖。

---

## 11. 相关文档

- 五分钟上手：[D3D-LUA-QUICKSTART.md](D3D-LUA-QUICKSTART.md)
- 从旧接口迁移：[D3D-LUA-MIGRATION.md](D3D-LUA-MIGRATION.md)
- 设计与验收标准：[../planning/D3D-LUA-SDK-DESIGN.md](../planning/D3D-LUA-SDK-DESIGN.md)
- 项目当前状态：[../STATUS.md](../STATUS.md)

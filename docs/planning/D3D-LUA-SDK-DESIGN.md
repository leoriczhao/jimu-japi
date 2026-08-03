# D3D Lua SDK 与完整生命周期设计

> 状态：P0/P1 已闭环，P2 Font/Text/Texture 公共对象层已实现并实机通过；P3-P6 与完整生命周期待实现。
>
> 本文是面向地图作者的 D3D Lua SDK 实现契约和验收标准。底层 proxy 的加载、转发、部署与历史验证仍见
> [D3D-PROXY-DESIGN.md](D3D-PROXY-DESIGN.md)；项目当前完成度只以
> [STATUS.md](../STATUS.md) 为准。

## 1. 背景与结论

当前代码已经打通 D3D9 proxy、<code>EndScene</code> 绘制、bridge handler、贴图命中和键盘回调，
但这只证明底层链路可工作，不能等价于“用户可用 SDK”。

2026-07-31 审计基线进一步限定了这条结论：<code>api.cpp</code> 注册 53 个 D3D handler，
<code>test_d3d.lua</code> 的 29 个 RPC 名中只有 25 个属于该集合，仍有 28 个 D3D handler 未被触达。
日志中的 120/120 是普通基线 108 项与 D3D fixture 12 项的累计结果，不是 D3D API 数量，也不是
53 个 handler 的完整行为覆盖率。

2026-08-03 的 P0 修复把兼容面固化为 54 个名字（历史 53 个加恢复的
<code>GetTextureSrcRect</code>）：D3D proxy 注册 49 个，canonical message/EX owner 注册 5 个；
fixture 触达 27/54。普通回归为 108/108，D3D fixture 13 项，累计 121/121。注册冲突、WARK 共用映射、
SrcRect Hrect ABI 和完整 state-block 已修复并通过实机，提交 <code>8bba4ae</code> 的 detached clean
worktree 构建、部署 DLL 与 sidecar hash 已一致；幂等安装/验证/卸载和 P1 原生 session 也已闭环。

2026-08-03 的 P2 实现新增正式 <code>jass.d3d</code> 模块、Font/Text/Texture 强类型 userdata、基础属性、
显式幂等销毁、GC/<code>__close</code>、Font 强引用/依赖拒绝和显式 session shutdown。公共 SDK fixture
不调用 hashtable、<code>UnitId</code> 或手写 spec，实机 7 组通过；与底层 bridge 合计后的完整日志为
128/128（108 普通 + 6 SDK 功能 + 13 bridge + 1 shutdown），不是 D3D API 数。P3 asset/render queue、
P4 Subscription、P5 自动地图/VM 生命周期与 device reset、P6 文档/最终验收仍未完成。

当前 P2 用户已经可以只通过 <code>jass.d3d</code> 创建、修改和销毁基础字体、文字或贴图，不再需要复制
私有 RPC helper。与此同时，
<code>jass.message.texture_*</code> 又维护一套不参与真实渲染的逻辑矩形。两套入口的对象身份、事件和生命周期
并不统一，且文字缺少主动销毁入口。这不是可以交付给地图作者的 API。

本阶段的目标不是再增加几个 bridge handler，而是交付一个稳定、可诊断、可清理、可写进用户文档的
<code>jass.d3d</code> SDK。只有本文第 15 节的所有完成门槛同时满足后，D3D Lua SDK 才能标记为“可用”。

## 2. 目标与非目标

### 2.1 必须交付

1. 用户只需 <code>require "jass.d3d"</code>，不得接触 hashtable、spec 字符串或 <code>UnitId</code>。
2. 提供 <code>Font</code>、<code>Text</code>、<code>Texture</code>、<code>Subscription</code> 四类 Lua userdata。
3. 每类资源支持显式 <code>:destroy()</code> 或 <code>:cancel()</code>，并有 <code>__gc</code> 和
   Lua 5.4 <code>__close</code> 兜底。
4. 资源在 D3D device lost/reset、窗口尺寸变化、Lua VM 关闭和地图会话结束时具有确定行为。
5. 真实渲染贴图和输入事件使用同一个 <code>Texture</code> 身份，不再存在两套“texture id”。
6. 支持地图 MPQ 内资源和常用图片格式，地图发布后不依赖开发机绝对路径。
7. 所有公开 API 有稳定的错误语义、类型校验、版本号、能力查询和资源计数诊断。
8. 所有面向用户的验收测试只调用 <code>jass.d3d</code>；内部 RPC 只能保留在底层兼容测试中。
9. Overlay 每帧绘制前后完整恢复 Warcraft 的 D3D9 状态，不得改变单位、地形或 UI 的原始渲染。
10. 提供安全、幂等、可验证的 proxy 安装、更新、检查和卸载入口。

### 2.2 v1 不提供

- 不向 Lua 暴露原始 <code>IDirect3DDevice9*</code>、任意 render state、shader 或 COM 指针。
- 不承诺支持 Warcraft III 1.28+ 或 Reforged；v1 目标仍是 1.27a、32 位 D3D9。
- 不提供通用 3D 世界渲染 API；v1 是 client-area 屏幕空间 2D overlay。
- 不把测试专用诊断函数当作稳定业务 API；诊断字段可以增加，但不得改变既有字段语义。

## 3. 当前实现差距

| 能力 | 当前状态 | SDK 闭环要求 |
|---|---|---|
| Lua 入口 | P2 已注册 <code>jass.d3d</code>；proxy 缺失时模块仍可加载并报告 unavailable | 补齐 Subscription、状态/错误与发布文档后作为唯一用户入口 |
| Lua 对象 | Font/Text/Texture 已为强类型 userdata，校验 session/type/generation | 增加 Subscription；完成全部跨类、陈旧对象和失败路径矩阵 |
| 字体生命周期 | 显式销毁、GC/<code>__close</code>、Text 强引用与依赖拒绝已通过 | 自动地图/VM 清理与 device reset 状态机 |
| 文字生命周期 | 显式销毁、GC、依赖释放与基础属性已通过 | TTL 到期状态同步、跨类型队列、文字 alpha、自动会话清理 |
| 贴图生命周期 | 会话所有权、基础属性、旋转几何命中、显式销毁/GC 已通过 | asset 状态/失败原因、Subscription、缓存释放和 reset |
| 事件 | 真实贴图 JASS 事件和 <code>jass.message</code> 逻辑矩形并存 | 单一事件注册中心和单一 Texture 身份 |
| 资源来源 | 主要依赖游戏目录文件 | MPQ asset URI、BLP/常用图片、开发文件模式 |
| 错误语义 | 多数失败返回 0 或空值 | <code>nil, error</code>、参数错误、结构化诊断 |
| device lost/reset | 释放/尝试重载 | 句柄稳定、状态迁移、失败可见、事件不重复 |
| 会话结束 | 显式 <code>d3d.shutdown()</code> 可幂等批量清理 SDK/bridge 混合资源 | Lua VM/地图自动关闭、同进程新会话和旧回调隔离 |
| 渲染隔离 | 已修复一次状态泄漏 | 自动状态一致性计数 + 实机视觉回归 |
| Handler 覆盖 | manifest 已固化 54 个名字和唯一 owner；fixture 触达 27/54，27 个未调用 | 继续为未测项补行为测试；未测项不能标为完成 |
| 注册冲突 | D3D 已移除 5 个 canonical 重名注册，<code>ShowConsole</code> 真实显隐通过 | 后续边界必须明确命名/版本化，禁止依赖覆盖语义 |
| 键码兼容 | <code>SetKeyboard</code> 与 message API 已共用唯一 <code>wark_to_vk</code> | 实现完成；发布前保留全键组静态/行为回归 |
| SrcRect 兼容 | <code>(IHrect;)V</code> 与 <code>(I)Hrect;</code> 已按真实 handle ABI 实机往返 | 实现完成；保留兼容回归 |
| 产物溯源 | 提交 <code>8bba4ae</code> 的干净构建、部署和 sidecar hash 已一致 | 后续每个发布提交继续执行同一 provenance 门禁 |
| 安装后清理 | proxy、探针、sidecar 的幂等安装/验证/卸载、未知文件保护和卸载后普通启动已通过 | 发布时继续执行同一 hash/provenance 门禁 |
| 测试对象 | 公共 SDK 7 组与底层 bridge 13 组已分离；SDK fixture 无裸 RPC | 扩展 asset、事件、reset、同进程生命周期和 soak |

## 4. 核心设计原则

以下原则是实现约束，不是建议：

1. **公开 API 与内部传输分离**：用户 API 不泄漏 JASS bridge 的参数槽位和签名字符串。
2. **一个资源只有一个身份**：渲染、属性、命中和事件都引用同一代际 handle。
3. **会话拥有资源**：每个 Lua VM 对应一个 SDK session；任何资源必须属于且只能属于一个 session。
4. **销毁幂等**：重复销毁不得崩溃、重复释放或复活资源。
5. **陈旧 handle 必须失败**：释放后复用的 slot 必须通过 generation 检测，不能误操作新对象。
6. **逻辑对象与 GPU 对象分离**：device lost 只释放 GPU/GDI 资源，不销毁 Lua 对象或其属性。
7. **回调不重入消息钩子**：输入 hook 只入队，Lua 回调在安全调度点执行。
8. **失败可观测**：资源 pending、ready、lost、failed、destroyed 状态和最后错误必须可查询。
9. **关闭优先于泄漏**：VM 关闭、地图切换和 DLL 卸载均有批量清理路径。
10. **渲染状态零污染**：overlay 返回游戏前必须恢复完整 D3D state，失败时跳过 overlay。
11. **验收只认公共入口**：内部 handler 全绿不能替代用户 SDK 验收。

## 5. 分层架构

~~~text
地图 Lua
  require "jass.d3d"
        |
        v
yd_japi.dll
  libs_d3d.cpp
  - Lua userdata / 参数校验 / 错误转换
  - session 生命周期
  - Lua callback 与 Subscription 注册表
  - 安全事件队列
        |
        v
版本化 C ABI: D3DSdkApiV1
  - 纯 C POD 与函数指针
  - ABI version / struct size / capability flags
  - session-aware resource operations
        |
        v
newD3d9.dll
  ResourceManager
  - generation handle
  - Font/Text/Texture registry
  - asset cache
  - device generation / lost / reset
  - diagnostics and resource counters
        |
        v
Renderer
  - unified z-order render queue
  - ID3DXFont text
  - D3D texture sprites
  - complete state capture/restore
        |
        v
CDirect3DDevice9 -> system d3d9.dll
~~~

### 5.1 为什么新增版本化 C ABI

现有兼容面 54 个名字（D3D proxy 49 个、canonical owner 5 个）受 JASS 32 位类型和 string id 约束，适合兼容
旧 JASS 包装器，但不适合承担 Lua SDK 的所有权、错误字符串、会话和批量销毁。

Proxy 新增稳定导出：

~~~cpp
extern "C" bool __cdecl GetD3DSdkApi(
    uint32_t requested_version,
    D3DSdkApiV1* out_api);
~~~

<code>D3DSdkApiV1</code> 只允许固定宽度整数、C POD 描述结构、调用方提供的错误缓冲区和函数指针；
不得跨 DLL 传递 STL、C++ 异常、COM 智能指针或由另一侧释放的内存。

结构必须包含：

- <code>abi_version</code>；
- <code>struct_size</code>；
- <code>capabilities</code>；
- session begin/end；
- Font/Text/Texture 创建、查询、修改、销毁；
- hit test、窗口信息、device 状态；
- diagnostics 和 last-error 复制；
- test-only 能力必须由独立 capability 标记，发布构建可关闭。

ABI 不匹配时 <code>require "jass.d3d"</code> 仍可成功，但 <code>d3d.is_available()</code> 返回
<code>false</code>，构造函数返回明确的版本错误，不能回退到未验证的结构布局。

### 5.2 旧 bridge 的位置

- 现有 JASS <code>CreateFont</code>、<code>CreateText</code>、<code>CreateTexture</code> 等函数保留兼容。
- 旧 handler 改为调用同一个 <code>ResourceManager</code>，不得继续维护第二份资源容器。
- Lua SDK 不调用 hashtable/UnitId；底层 bridge 测试可以继续验证兼容入口。
- 原有 <code>GetD3DStatus</code> 保留，但 SDK 使用结构化 <code>d3d.status()</code>。
- 维护一份机器可读的 handler manifest，记录 54 个兼容名字的 owner、签名、public/internal/deprecated
  分类、实现状态和测试 ID；注册表与测试覆盖统计必须从 manifest 生成或校验。
- bridge 注册函数不得静默覆盖同名 handler。<code>ShowConsole</code>、<code>ShowFpsText</code> 和
  <code>SetKeyboard</code> 属于 canonical EX/message 兼容能力，不属于 D3D 资源 SDK；D3D 初始化不得再次
  注册这些名字。若确需替换，必须显式声明 owner、签名一致并在启动日志中记录。
- <code>SetKeyboard(IB)V</code> 必须先执行 WARK→Win32 VK 转换，并与
  <code>libs_message.cpp::wark_to_vk</code> 共用唯一实现；测试至少覆盖 Shift/Ctrl/Alt、方向键、F1/F12、
  OEM、数字键盘、字母/主键盘数字和无效码。当前 TextureAddEvent 的真实 Shift 回调不能替代该测试，
  因为它验证的是输入 hook，不是按键注入。
- JASS 兼容层必须提供 <code>SetTextureSrcRect(IHrect;)V</code> 和
  <code>GetTextureSrcRect(I)Hrect;</code>；四浮点内部方法可保留为 C ABI 私有操作，但不得占用内置 JASS 名称。

## 6. 公共 Lua API

### 6.1 模块入口

~~~lua
local d3d = require "jass.d3d"

assert(d3d.is_available())
print(d3d.version())       -- SDK semantic version
print(d3d.abi_version())   -- native ABI integer

local width, height = d3d.window_size()
local yellow = d3d.rgba(255, 255, 0, 255)
~~~

模块始终可以加载。Proxy 缺失、ABI 不匹配或 device 尚未创建时，通过状态与构造函数错误报告，不允许
因为 <code>require</code> 失败而破坏不使用 D3D 的地图逻辑。

模块级 API：

| API | 语义 |
|---|---|
| <code>d3d.is_available()</code> | Proxy、ABI 和必要 capability 是否可用 |
| <code>d3d.version()</code> | Lua SDK semantic version |
| <code>d3d.abi_version()</code> | 当前 native ABI 版本 |
| <code>d3d.capabilities()</code> | 只读 capability 表 |
| <code>d3d.status()</code> | device/session/错误和状态隔离诊断 |
| <code>d3d.stats()</code> | 当前 session 与全局资源计数 |
| <code>d3d.window_size()</code> | client-area 像素宽高 |
| <code>d3d.rgba(r,g,b,a)</code> | 返回 0 到 <code>0xFFFFFFFF</code> 的 ARGB/RGBA 规范颜色值 |
| <code>d3d.on(event, callback)</code> | 订阅 resize/device_lost/device_reset |
| <code>d3d.shutdown()</code> | 显式关闭当前 session；幂等，之后禁止创建资源 |

### 6.2 Font

~~~lua
local font, err = d3d.Font.new {
    face = "Arial",
    height = 28,
    width = 0,
    weight = 700,
    italic = false,
}
assert(font, err)
~~~

方法：

- <code>font:get_face()</code> / <code>font:set_face(value)</code>
- <code>font:get_height()</code> / <code>font:set_height(value)</code>
- <code>font:get_width()</code> / <code>font:set_width(value)</code>
- <code>font:get_weight()</code> / <code>font:set_weight(value)</code>
- <code>font:get_italic()</code> / <code>font:set_italic(value)</code>
- <code>font:is_destroyed()</code>
- <code>font:destroy()</code>

修改字体属性后，字体原生对象在下次绘制前惰性重建；引用该字体的所有 Text 自动使用新属性。

### 6.3 Text

~~~lua
local text, err = d3d.Text.new {
    font = font,
    text = "Hello",
    x = 72,
    y = 72,
    color = d3d.rgba(255, 255, 0, 255),
    ttl = nil,       -- nil = 无限
    visible = true,
    z = 100,
}
assert(text, err)
~~~

方法：

- <code>text:get_text()</code> / <code>text:set_text(value)</code>
- <code>text:get_position()</code> / <code>text:set_position(x, y)</code>
- <code>text:get_color()</code> / <code>text:set_color(value)</code>
- <code>text:get_ttl()</code> / <code>text:set_ttl(seconds_or_nil)</code>
- <code>text:get_visible()</code> / <code>text:set_visible(value)</code>
- <code>text:get_z()</code> / <code>text:set_z(value)</code>
- <code>text:get_font()</code> / <code>text:set_font(font)</code>
- <code>text:is_alive()</code> / <code>text:is_destroyed()</code>
- <code>text:destroy()</code>

Text 使用 <code>ID3DXFont</code> 或等价的 D3D 字形缓存绘制，必须支持颜色 alpha。不得继续使用忽略 alpha
且无法统一 z-order 的 GDI backbuffer <code>DrawText</code> 作为最终实现。

### 6.4 Texture

~~~lua
local texture, err = d3d.Texture.new {
    source = "asset://war3mapImported/panel.blp",
    x = 72,
    y = 136,
    width = 256,
    height = 192,
    color = d3d.rgba(255, 255, 255, 255),
    rotation = 0,
    z = 200,
    visible = true,
    hit_test = true,
}
assert(texture, err)
~~~

方法：

- <code>texture:get_source()</code> / <code>texture:set_source(uri)</code>
- <code>texture:get_rect()</code> / <code>texture:set_rect(x, y, width, height)</code>
- <code>texture:get_source_rect()</code> / <code>texture:set_source_rect(left, top, right, bottom)</code>
- <code>texture:get_color()</code> / <code>texture:set_color(value)</code>
- <code>texture:get_rotation()</code> / <code>texture:set_rotation(degrees)</code>
- <code>texture:get_z()</code> / <code>texture:set_z(value)</code>
- <code>texture:get_visible()</code> / <code>texture:set_visible(value)</code>
- <code>texture:get_hit_test()</code> / <code>texture:set_hit_test(value)</code>
- <code>texture:pixel_size()</code>
- <code>texture:state()</code>，返回 pending/ready/lost/failed/destroyed
- <code>texture:error()</code>
- <code>texture:reload()</code>
- <code>texture:contains(x, y)</code>
- <code>texture:on(event, callback, options)</code>
- <code>texture:is_destroyed()</code>
- <code>texture:destroy()</code>

### 6.5 Subscription

所有模块级和 Texture 事件订阅都返回 Subscription userdata：

~~~lua
local subscription = texture:on("click", function(event)
    print(event.local_x, event.local_y)
end, {
    button = d3d.mouse.LEFT,
})

subscription:cancel()
~~~

方法：

- <code>subscription:is_active()</code>
- <code>subscription:cancel()</code>

<code>cancel()</code>、<code>__gc</code> 和 <code>__close</code> 均幂等。Texture 销毁时必须先取消其全部订阅。

## 7. 坐标、颜色与绘制顺序

1. 默认坐标是 War3 client-area 物理像素，原点在左上角，允许小数。
2. <code>d3d.window_size()</code> 返回当前 client-area 尺寸；resize 事件在尺寸稳定后触发一次。
3. 颜色公开格式为 32 位 <code>0xAARRGGBB</code>，Lua 侧使用非负整数表达；SDK 负责和 JASS signed
   integer 兼容层转换。
4. Text 和 Texture 进入同一 render queue，按 <code>z</code> 从小到大绘制；相同 z 按创建序稳定排序。
5. rotation 以对象中心为原点，单位为角度，顺时针为正。
6. Texture hit test 必须执行逆旋转后的矩形判断，不能只检查未旋转 AABB。
7. v1 的 hit test 是几何命中，不承诺逐像素 alpha 命中。
8. <code>source_rect</code> 使用源图片像素；空值表示完整图片。

每帧 overlay 绘制必须：

1. 捕获 <code>D3DSBT_ALL</code>；
2. 设置 SDK 绘制状态；
3. 绘制统一队列；
4. 恢复 state block；
5. 查询关键 render/texture/FVF 状态并累计 <code>state_restore_failures</code>；
6. 捕获或恢复失败时跳过本帧 overlay，不得带着部分状态返回 Warcraft。

## 8. Asset 与贴图加载

### 8.1 URI

| URI | 用途 | 发布默认 |
|---|---|---:|
| <code>asset://path/in/map.blp</code> | 从当前地图 MPQ/虚拟文件系统读取 | 允许 |
| <code>game://ReplaceableTextures/...</code> | 从 Warcraft 资源搜索链读取 | 允许 |
| <code>file://D:/...</code> | 开发机文件 | 默认禁止，仅测试/开发开关允许 |

不带 scheme 的相对路径按 <code>asset://</code> 处理。Asset 路径统一斜杠、拒绝绝对路径和
<code>..</code> 穿越。错误中返回规范化 URI，不泄漏不必要的系统路径。

### 8.2 格式和缓存

v1 必须支持：

- BLP1 与目标版本实际使用的 BLP2 子集；
- BMP、PNG、JPG、TGA、DDS；
- 从内存创建 D3D texture，不要求把 MPQ 资源落地到磁盘。

实现使用共享 asset cache：

- key 为规范化 URI、解码选项和资源版本；
- cache entry 保存可重建设备资源所需的 CPU 数据或可重新读取的 source 描述；
- Texture 持有引用计数；
- session 结束或最后一个引用释放后回收；
- device reset 不改变 Lua Texture handle，只重建 GPU 对象；
- 加载/解码失败保存稳定错误码和文本，不创建半有效对象。

## 9. 完整生命周期

### 9.1 Session

每个 Lua 主状态首次加载 <code>jass.d3d</code> 时调用 <code>begin_session()</code>，获得非零 session id。
所有 native resource 和 subscription 都记录 session id。

Session 状态：

~~~text
unavailable -> active -> closing -> closed
~~~

- Proxy 缺失时处于 unavailable，模块可查询但不能创建资源。
- <code>d3d.shutdown()</code>、Lua VM close 或地图卸载把 active 转为 closing。
- closing 阶段停止接受新资源和新回调，清空事件队列，取消订阅，按依赖顺序销毁资源。
- 清理完成后调用 native <code>end_session(session_id)</code>，最终进入 closed。
- 重复 shutdown 不做第二次释放。
- 新地图的新 Lua VM 必须获得新 session，不能看到上一个 session 的对象。

### 9.2 Resource 状态

~~~text
create
  |
  +--> pending --device ready/load success--> ready
  |       |                                  |
  |       +--load failure-----------------> failed
  |                                          |
  +---------------- device lost <-------------+
                         |
                        lost
                         |
              reset success / failure
                    ready / failed

pending|ready|lost|failed --destroy/session close/GC--> destroyed
~~~

规则：

- Font 通常可在 device 创建前保持 pending。
- Text 的逻辑属性可先创建，但其 Font 必须属于同一 session 且未销毁。
- Texture 加载失败进入 failed，保留 source 与错误；<code>reload()</code> 可以重试。
- device lost 不触发 Lua <code>destroy</code>，handle、属性、订阅和依赖保持不变。
- reset 成功后对象恢复 ready；单个资源重建失败只让该对象 failed，不拖垮其他资源。
- destroyed 是终态；任何业务 getter/setter 对 destroyed userdata 抛出明确的 use-after-destroy 错误。

### 9.3 Handle

Native handle 使用 32 位非零 generation handle：

- slot index 定位 registry 项；
- generation 防止 slot 复用后陈旧 userdata 命中新对象；
- type tag 防止把 Font handle 当作 Texture；
- 每次操作同时校验 session、type、generation 和 alive；
- 0 永远表示无效；
- handle 可以用于诊断，但公共构造函数和方法不接受用户提供的裸整数 handle。

### 9.4 所有权与依赖

- Lua userdata 拥有 native resource 的一个 session 引用。
- Text 的 userdata uservalue 强引用 Font userdata；native Text 同时记录 Font generation handle。
- 显式销毁仍被存活 Text 引用的 Font 时返回 <code>nil, "font is in use"</code>，不做延迟的隐式销毁。
- Texture 销毁先取消全部 Subscription，再释放 GPU 和 asset cache 引用。
- Subscription 强引用目标 Texture，防止事件仍有效时 Texture 被意外 GC。
- TTL 到期的 Text 在 native 侧失效；Lua userdata 下次访问时同步为 expired/destroyed，不允许复活。
- <code>__gc</code> 是兜底，不作为正常业务流程；示例和文档要求显式销毁长期对象。
- Lua 5.4 <code>__close</code> 与显式销毁等价，支持 to-be-closed 变量。

### 9.5 Device lost/reset 与进程退出

- <code>on_device_lost</code> 释放 default-pool texture、D3DXFont 和 state block，不清空逻辑 registry。
- <code>on_device_reset</code> 增加 device generation，按 asset cache 重建资源。
- reset 期间不派发 Texture 输入事件。
- Proxy <code>DLL_PROCESS_DETACH</code> 只做不依赖 Lua 的最终 native 清理；正常 Lua 引用必须更早由
  session close 释放。
- 所有跨 DLL 调用不得抛出 C++ 异常；SEH/错误码在 ABI 边界内转换。

## 10. 事件模型

### 10.1 支持事件

Texture v1 支持：

- <code>enter</code>
- <code>leave</code>
- <code>mouse_down</code>
- <code>mouse_up</code>
- <code>click</code>
- <code>key_down</code>
- <code>key_up</code>

模块支持：

- <code>resize</code>
- <code>device_lost</code>
- <code>device_reset</code>

鼠标按钮至少包含 LEFT、RIGHT、MIDDLE、X1、X2。键盘使用公开枚举，不要求用户传 Win32 virtual-key。

### 10.2 命中与分发

1. 输入 filter 只收集原始消息、当前 client 坐标和时间戳，不直接调用 Lua。
2. 安全调度点读取当帧 render snapshot，按 z 从高到低命中 visible 且 hit_test enabled 的 Texture。
3. 默认只向最上层对象分发；<code>options.propagate=true</code> 才继续向下。
4. mouse_down 后建立 pointer capture；对应 mouse_up 发给同一对象。
5. click 要求同一按钮的 down/up 且位移未超过阈值。
6. enter/leave 根据连续帧 hover 集合差异产生，隐藏、销毁或关闭 hit test 必须产生一次 leave。
7. key_down/key_up 默认只在鼠标位于 Texture 内时触发；可由 <code>options.hover_only=false</code> 改为
   session 全局键盘订阅。

回调收到只读 event 表：

~~~lua
{
    type = "click",
    target = texture,
    x = 320,
    y = 240,
    local_x = 12,
    local_y = 18,
    button = d3d.mouse.LEFT,
    key = nil,
    timestamp = 123.456,
}
~~~

### 10.3 回调安全

- 回调通过 <code>pcall</code> 和 traceback 隔离，错误不得穿过消息 hook 或破坏游戏循环。
- 默认发生一次未处理错误后自动取消该 Subscription，并写同步日志；可用
  <code>options.keep_on_error=true</code> 显式保留。
- 回调内部允许取消自己、销毁目标、创建新对象或关闭 session。
- 分发使用 snapshot 和两阶段删除；本轮新增订阅从下一条输入事件开始生效。
- session closing 后队列中尚未派发的用户回调全部丢弃。

## 11. 错误语义与诊断

### 11.1 错误约定

- 参数类型错误、数值越界、跨 session 对象和 use-after-destroy 属于程序错误，直接抛 Lua error。
- Proxy 不可用、ABI 不匹配、资源不存在、图片解码失败、device 暂不可用等运行错误返回
  <code>nil, error</code>。
- <code>:destroy()</code>、<code>:cancel()</code> 和 <code>d3d.shutdown()</code> 幂等；重复调用返回
  <code>true</code>。
- 不允许用 0、空字符串或静默 no-op 混淆成功与失败。
- Native 错误同时包含稳定 code 和用户可读文本；Lua 默认返回文本，诊断表保留 code。

### 11.2 status 与 stats

<code>d3d.status()</code> 至少返回：

~~~lua
{
    available = true,
    sdk_version = "1.0.0",
    abi_version = 1,
    proxy_loaded = true,
    device_state = "ready",
    device_generation = 3,
    session_state = "active",
    state_restore_failures = 0,
    pending_callbacks = 0,
    last_error = nil,
}
~~~

<code>d3d.stats()</code> 至少返回：

~~~lua
{
    session = { fonts = 1, texts = 2, textures = 3, subscriptions = 4 },
    global = { fonts = 1, texts = 2, textures = 3, sessions = 1 },
    asset_cache = { entries = 2, bytes = 123456 },
}
~~~

资源计数是生命周期验收的主要证据；进程内存只能作为辅助证据。

## 12. 兼容与迁移

1. 现有 JASS bridge 名称继续工作，并改为复用同一个 ResourceManager。
2. 新建 <code>jass.message.region_*</code> 表达纯逻辑输入区域。
3. 现有 <code>jass.message.texture_*</code> 暂时作为 <code>region_*</code> 的 deprecated alias，
   首次调用写一次警告；公共文档和新测试不得使用。
4. 真实渲染事件只通过 <code>d3d.Texture:on</code> 或 JASS 兼容
   <code>TextureAddEvent</code> 注册，二者共享底层 hit test 和 event registry。
5. 补齐旧 bridge 的 <code>DestroyText</code>、visible getter/setter、italic getter 和 source-rect getter，
   但这些补齐不能替代 SDK userdata 验收。
6. <code>map/tests/test_d3d.lua</code> 拆分为：
   - <code>test_d3d_bridge.lua</code>：低层兼容合同；
   - <code>test_d3d_sdk.lua</code>：唯一用户 API 功能验收；
   - <code>test_d3d_lifecycle.lua</code>：GC/session/reset/压力验收。

## 13. 部署与发布

新增独立工具 <code>tools/d3d-proxy.ps1</code>：

~~~powershell
.\tools\d3d-proxy.ps1 -Install
.\tools\d3d-proxy.ps1 -Verify
.\tools\d3d-proxy.ps1 -Uninstall
~~~

要求：

- install/upgrade 继续使用 sidecar SHA-256 所有权检查；
- verify 同时检查文件 hash、PE 导出、位数和目标 D3DX 依赖；
- uninstall 只删除 sidecar 证明属于本项目且 hash 匹配的 proxy、视觉探针及其 sidecar；
- uninstall 必须幂等；未知或被外部修改的文件拒绝删除并返回明确错误；成功后再次 verify 必须报告
  “未安装”，普通非 D3D 地图仍能启动；
- 安装、升级、卸载都必须拒绝 War3 仍加载目标 proxy 时直接替换/删除；工具需先报告占用进程，
  由调用者显式结束会话后重试；
- 任一未知 <code>d3d9.dll</code> 都必须拒绝覆盖和删除；
- <code>deploy.ps1 -InteractiveD3D</code> 复用该工具，不再复制一份部署逻辑；
- Map 包必须包含 Lua SDK binding 所需的 <code>yd_japi.dll</code>，但 proxy 仍是显式外部安装项；
- SDK 不可用时给地图作者明确安装提示，不让非 D3D 地图崩溃。

发布产物必须带构建 provenance：source commit、dirty=false、构建配置、proxy SHA-256 和部署时间。
验收只接受由该 commit 的干净工作区构建出的 DLL；工作区构建与游戏目录 DLL、proxy sidecar 三者 hash
必须一致。本批提交 <code>8bba4ae</code> 从 detached clean worktree 构建并实际部署，proxy 与 sidecar
hash 均为 <code>CD3896606FE2F20861F34A1406457972F982D2A72ED8F4B9173606F4FCCF101C</code>；
普通 108/108 与 D3D 121/121 均使用该 clean worktree 的 DLL 通过。

发布材料必须包含：

- 5 分钟 quickstart；
- 完整 API reference；
- 资源路径与 MPQ 导入示例；
- 生命周期和销毁规则；
- device reset 与错误处理示例；
- 从 <code>jass.message.texture_*</code> 和裸 RPC 迁移说明。

## 14. 实施阶段

| 阶段 | 内容 | 阶段完成条件 |
|---|---|---|
| P0（完成） | 审计阻断项：54-name manifest、禁止注册覆盖、WARK 键码、SrcRect 兼容、state-block 提交与干净产物溯源、卸载/会话清理合同 | manifest/注册/WARK/SrcRect/state-block、SUPPLY provenance 与真实游戏目录 DEPLOY 卸载/重装均已通过；STATUS 仍只写底层链路基本跑通 |
| P1（完成） | 版本化 C ABI、session、generation ResourceManager | ABI/handle/session 原生合同及 1000 轮资源计数归零通过；自动地图结束钩子仍属于 P5 |
| P2（完成） | <code>jass.d3d</code> userdata 与 Font/Text/Texture 基础 API | 用户无需 RPC 即可创建、修改、销毁；公共 7 组实机通过 |
| P3 | 统一 render queue、D3DXFont、asset URI/MPQ/BLP | 地图内资源可发布使用，文字 alpha 与跨类型 z 正确 |
| P4 | Subscription 与统一输入事件 | 键盘、鼠标、enter/leave/click 全部走真实 Texture |
| P5 | GC、TTL、session close、device lost/reset、错误诊断 | 生命周期矩阵和压力测试通过 |
| P6 | 安装/验证/卸载、迁移、API 文档、最终实机验收 | 第 15 节全部通过并记录证据 |

阶段不能跨越完成门槛。例如 P2 的对象能显示，不代表 P5 生命周期完成。

P1 实际导出为 <code>GetD3DSdkApi</code> ABI v1。P2 在不改变 v1 最小前缀的前提下追加
<code>D3D_SDK_CAP_CORE_PROPERTIES</code> 和基础属性函数表；原生合同覆盖 ABI size/capability、全部基础属性、
长字符串 buffer-too-small、旋转局部坐标命中、参数范围、Font 依赖、显式 session 清理及 1000 轮归零。
Lua 层覆盖重复 require 的 session 稳定性、三类 userdata、Font 强引用、幂等销毁、use-after-destroy、GC、
Font <code>__close</code> 和显式 shutdown。该结果仍不包含 Subscription、asset、统一 render queue、
TTL/device reset、自动地图/VM 关闭或完整失败路径，不能作为 P3-P6 或用户 SDK 完成证据。

P1 源码提交 <code>b3f4da8</code> 已从 detached clean worktree 完整构建。clean proxy SHA-256 为
<code>8D7089B68B9028A05C1DB1DAFB70D95B7974049A707EAF91C358633772225035</code>，clean
<code>yd_japi.dll</code> SHA-256 为
<code>BEE52977457FFB3BD5DEC7B11F75B1CCF894134C5E0E61DD6170F5CEB4309D8B</code>；实际游戏目录 proxy 与
sidecar 匹配该 hash，并使用同一 clean build 完成普通 108/108、D3D 121/121 与原生 ABI 合同测试。

P2 工作区构建已通过普通 108/108、D3D 128/128 和原生 ABI 合同；提交态 detached clean worktree 的
hash、部署和复验将在 P2 提交后记录，完成前不得把工作区 DLL 当作发布产物。

### 14.1 P2 验收边界

P2 已提供 API-02 的公共边界证据，并完成 API-01 中 Font/Text/Texture 部分；FONT-01、TEXT-01、TEX-02
的属性往返已通过，但 Font 变更视觉、文字 alpha、asset 加载和统一 z 属于 P3。LIFE-01 的三类资源幂等销毁、
LIFE-04、LIFE-07 以及 LIFE-09 的显式无事件资源清理已通过；LIFE-02 尚未穷举每个业务方法，LIFE-08 目前只
实测 Font，LIFE-09/LIFE-12 仍缺自动地图/VM 与同进程新会话。EVENT-04 的旋转几何命中基元已通过，
但在 P4 Subscription 分发完成前不能把 EVENT-04 标为完整事件验收。

## 15. 验收标准

### 15.1 构建与静态合同

| ID | 验收项 | 成功条件 |
|---|---|---|
| BUILD-01 | Win32 Release | <code>yd_japi.dll</code>、<code>newD3d9.dll</code> 无编译/链接错误 |
| SUPPLY-01 | 源码到产物 | provenance 指向明确 commit 且 dirty=false；干净构建 DLL、游戏目录 DLL 与 proxy sidecar SHA-256 一致 |
| ABI-01 | Proxy 导出 | <code>Direct3DCreate9</code>、<code>InitializeD3DAPI</code>、<code>GetD3DSdkApi</code> 未修饰导出存在 |
| ABI-02 | ABI 协商 | version/size/capability 匹配成功；错误版本明确拒绝 |
| API-01 | Lua 注册 | <code>require "jass.d3d"</code> 成功，返回的类和方法完整 |
| API-02 | 公共边界 | SDK 功能测试中不存在 <code>UnitId</code>、<code>japi_ht</code> 或手写 spec |
| COVER-01 | Handler manifest | 54 个兼容名字均有唯一 owner、准确签名、分类、实现状态和稳定测试 ID；未测项不能标为完成 |
| COVER-02 | 统计语义 | 报告分别列累计测试数、D3D fixture 测试数和 handler 覆盖数，禁止把 121/121 表述为 D3D API 数 |
| COMPAT-01 | 注册冲突 | D3D 初始化不覆盖 canonical <code>ShowConsole</code>/<code>ShowFpsText</code>/<code>SetKeyboard</code>；重复名字默认拒绝并记录 owner |
| COMPAT-02 | WARK 键码 | <code>SetKeyboard</code> 与 message API 共用唯一 WARK→VK 映射；修饰键、方向键、F 键、OEM、数字键盘和无效码均通过 |
| COMPAT-03 | SrcRect JASS ABI | <code>SetTextureSrcRect(IHrect;)V</code> 与 <code>GetTextureSrcRect(I)Hrect;</code> 按内置 wrapper 往返，旧四浮点实现不占用同名入口 |

### 15.2 功能验收

| ID | 验收项 | 成功条件 |
|---|---|---|
| FONT-01 | Font | 所有公开属性 set/get 往返；属性变更影响现有 Text |
| TEXT-01 | Text | 内容、位置、颜色 alpha、TTL、visible、z、font 往返 |
| TEXT-02 | 主动销毁 | 无限 TTL Text 可主动销毁，下一帧消失，计数减少 |
| TEX-01 | MPQ 资源 | <code>asset://</code> BLP 和 PNG 均能从地图包加载 |
| TEX-02 | Texture 属性 | rect、source rect、颜色、旋转、z、visible、hit test 往返 |
| TEX-03 | 加载失败 | 缺失/损坏资源返回稳定错误，不增加存活资源计数 |
| LAYER-01 | 跨类型 z | Text 与 Texture 按统一 z 顺序绘制 |
| COLOR-01 | Alpha | 文字和贴图 0%、50%、100% alpha 视觉结果正确 |

### 15.3 生命周期验收

| ID | 验收项 | 成功条件 |
|---|---|---|
| LIFE-01 | 幂等销毁 | 每类对象连续 destroy/cancel 两次均不崩溃、不重复释放 |
| LIFE-02 | use-after-destroy | 所有业务方法明确报错，不能命中新对象 |
| LIFE-03 | generation | slot 重用后旧 userdata 被拒绝 |
| LIFE-04 | Font 依赖 | Text 存活时 Font 显式销毁失败；Text 销毁后成功 |
| LIFE-05 | Texture 依赖 | Texture 销毁自动取消全部 Subscription |
| LIFE-06 | TTL | Text 到期后消失、状态更新、计数归零 |
| LIFE-07 | GC | 丢弃最后一个 userdata 并强制两轮 GC 后 native 计数归零 |
| LIFE-08 | <code>__close</code> | to-be-closed 作用域结束后资源立即释放 |
| LIFE-09 | Session close | 混合资源和事件全部批量清理，旧对象不能跨地图使用 |
| LIFE-10 | 压力循环 | 1000 轮创建/修改/销毁后各资源计数回到基线 |
| LIFE-11 | 失败路径 | 构造中途失败、回调报错、reset 失败均无 handle/Lua ref/cache 泄漏 |
| LIFE-12 | 同进程新会话 | 关闭旧 VM/地图后创建新 session；旧回调不触发、旧 handle 失败、全局和 session 计数回到基线 |

### 15.4 Device 与渲染隔离

| ID | 验收项 | 成功条件 |
|---|---|---|
| DEV-01 | Proxy 缺失 | 模块可加载，available=false，非 D3D 108 项不回归 |
| DEV-02 | Device pending | device 创建前对象 pending，创建后自动 ready |
| DEV-03 | 真实 reset | 连续 20 次窗口 resize/reset，handle/属性/订阅保持，贴图和文字恢复 |
| DEV-04 | 单资源重建失败 | 仅目标资源 failed，其他对象继续绘制 |
| STATE-01 | D3D state | <code>state_restore_failures == 0</code> |
| STATE-02 | Warcraft 原画面 | Overlay 显示/隐藏前后，单位、地形和 UI 无半透明、失光、Z 错误或模型状态污染 |
| STATE-03 | 捕获失败降级 | state-block 创建或 Capture 失败时跳过对应 overlay pass，绝不带着未恢复状态返回游戏 |
| PERF-01 | 帧开销 | 100 Text + 100 Texture 时 overlay CPU p95 不高于 1.5 ms |
| PERF-02 | 热路径分配 | 资源稳定后正常绘制帧不做无界容器增长或每帧资源创建 |

### 15.5 事件验收

| ID | 验收项 | 成功条件 |
|---|---|---|
| EVENT-01 | enter/leave | 进入、离开、隐藏、销毁均产生确定且不重复的状态变化 |
| EVENT-02 | 鼠标按钮 | LEFT/RIGHT/MIDDLE/X1/X2 down/up/click 正确 |
| EVENT-03 | 键盘 | hover-only 和 session-global 两种模式正确 |
| EVENT-04 | 旋转命中 | 旋转 Texture 使用局部坐标命中，不使用未旋转 AABB |
| EVENT-05 | z 命中 | 重叠 Texture 默认只触发最上层，propagate 模式按 z 分发 |
| EVENT-06 | pointer capture | down 后移出再 up 的目标与 click 规则正确 |
| EVENT-07 | 回调内销毁 | 回调取消自己/销毁 Texture/关闭 session 均不崩溃、不二次回调 |
| EVENT-08 | 回调错误 | traceback 被记录，游戏继续运行，默认取消出错 Subscription |
| EVENT-09 | Lua/JASS 一致性 | Lua Subscription 和 JASS TextureAddEvent 使用相同 hit test 与对象状态 |

### 15.6 部署、文档与实机

| ID | 验收项 | 成功条件 |
|---|---|---|
| DEPLOY-01 | 安装/升级 | 已知文件可幂等更新，未知 d3d9.dll 拒绝覆盖 |
| DEPLOY-02 | 检查 | hash、PE、位数、依赖和安装路径全部可读 |
| DEPLOY-03 | 卸载所有权 | 只删除 sidecar 证明属于本项目且当前 hash 匹配的 proxy、探针及其 sidecar；未知/已修改文件拒绝删除 |
| DEPLOY-04 | 卸载闭环 | 安装→验证→结束 War3 会话→卸载→再次卸载均结果确定；verify 报未安装，普通非 D3D 地图可启动且目录无项目 D3D 残留 |
| DOC-01 | Quickstart | 新用户只按文档即可显示一段文字和一张 MPQ 贴图 |
| DOC-02 | API reference | 每个公开 API 有参数、返回、错误和生命周期说明 |
| DOC-03 | Migration | 裸 RPC 和 message.texture 迁移示例可运行 |
| REAL-01 | 普通回归 | 当前普通套件全部通过 |
| REAL-02 | SDK 实机 | public SDK 功能、生命周期和事件套件全部通过 |
| REAL-03 | 视觉证据 | 真实窗口同时显示正确 overlay 与未受污染的单英雄火枪手 |
| SOAK-01 | 稳定性 | 30 分钟创建/销毁/输入/resize 循环无崩溃，计数无单调增长 |

### 15.7 验收入口

最终至少提供以下可重复命令：

~~~powershell
.\src\build.bat
.\tools\d3d-proxy.ps1 -Verify
.\tools\deploy.ps1
.\tools\deploy.ps1 -InteractiveD3D -NoKill
.\tools\deploy.ps1 -D3DStress
.\tools\d3d-proxy.ps1 -Uninstall
.\tools\d3d-proxy.ps1 -Verify
.\tools\d3d-proxy.ps1 -Install
.\tools\d3d-proxy.ps1 -Verify
~~~

<code>-InteractiveD3D</code> 必须运行 <code>test_d3d_sdk.lua</code>，不能再以低层 RPC 测试作为主验收。
<code>-D3DStress</code> 必须无人值守完成生命周期、GC、generation 和资源计数压力测试；真实鼠标与视觉项
仍由交互模式完成。

不使用固定“测试总数达到 N”作为唯一完成标准；以上每个稳定 ID 都必须有通过记录，新增测试不能通过减少
总数掩盖失败。

## 16. 最终完成定义

D3D Lua SDK 只有同时满足以下条件才可在 <code>STATUS.md</code> 标记为“可用”：

1. <code>jass.d3d</code> 是唯一文档化的 Lua D3D 入口。
2. Font/Text/Texture/Subscription 均为强类型 userdata，并完成显式销毁、GC 和 <code>__close</code>。
3. Session、generation handle、依赖关系和批量清理全部实现。
4. MPQ BLP/PNG 资源能够在发布地图中直接使用。
5. Lua 与 JASS 事件共享真实 Texture、hit test 和生命周期。
6. device lost/reset 后资源和事件恢复，失败可诊断。
7. Warcraft D3D state 零污染，自动计数和真实视觉均通过。
8. 用户 SDK 测试不使用裸 RPC，低层 bridge 测试与 SDK 测试职责分离。
9. 安装、验证、会话结束、卸载、卸载后普通启动和重新安装均有 hash 保护并完成实机验证。
10. 第 15 节全部稳定 ID 有证据，普通回归不下降。
11. Quickstart、API reference、生命周期和迁移文档齐全。
12. <code>STATUS.md</code> 记录命令、日期、测试结果和仍然存在的真实限制。
13. 发布 DLL 可追溯到明确 commit 的干净构建，且构建、部署和 sidecar hash 一致。

任何一项未满足时，只能写“底层链路基本跑通”或“SDK 开发中”，不得写“D3D 可用”。

# 迁移到 `jass.d3d`

> 面向两类旧代码：① 用 `jass.message.texture_*` 的逻辑矩形 + 事件表；② 直接走 `UnitId`+hashtable
> 手写 spec 调 D3D bridge（`TextureCreate`/`TextureSetRect`/…）。
> 新接口只有一套对象身份、真实渲染和真实输入，见 [API 参考](D3D-LUA-API.md)。

## 1. 一句话总结

| 旧 | 新 |
|---|---|
| `jass.message.texture_create(x, y, w, h)`（0..1 归一化） | `d3d.Texture.new { x, y, width, height, source = ... }`（客户区像素） |
| `message.texture_add_event(id, keycode, press, release)` | `texture:on("key_down"/"key_up"/"mouse_down"/"mouse_up"/"click", fn, opts)` |
| 逻辑矩形（不参与渲染） | 真实 D3D9 贴图，参与渲染队列与命中 |
| 返回值是整数 id | 强类型 userdata（`is_destroyed()`、`destroy()`、`__gc`） |
| 手写 `UnitId` + hashtable RPC | 直接调 Lua 模块，无 RPC |

## 2. `jass.message.texture_*` → `jass.d3d`

旧接口（`src/src/lua_engine/lua_engine/libs_message.cpp`，签名见其注释）：

```lua
local id = message.texture_create(x, y, w, h)        -- 归一化 0..1 逻辑矩形
message.texture_set_visible(id, visible)
message.texture_set_trigger(id, enabled)             -- 是否参与命中
message.texture_set_rect(id, x, y, w, h)
local event = message.texture_add_event(id, keycode, press_fn, release_fn)
message.texture_remove_event(id, event)
message.texture_destroy(id)
```

新写法：

```lua
local d3d = require "jass.d3d"

local texture = assert(d3d.Texture.new {
    source = "game://ReplaceableTextures\\CommandButtons\\BTNRifleman.blp",
    x = client_x, y = client_y, width = 64, height = 64,
})

texture:set_visible(false)     -- 等价 texture_set_visible
texture:set_hit_test(false)    -- 等价 texture_set_trigger(false)
texture:set_rect(x, y, w, h)   -- 等价 texture_set_rect

local down = texture:on("mouse_down", function(ev) ... end, { button = d3d.mouse.LEFT })
local up   = texture:on("mouse_up",   function(ev) ... end, { button = d3d.mouse.LEFT })
down:cancel(); up:cancel()     -- 等价 texture_remove_event
texture:destroy()              -- 等价 texture_destroy，并自动取消其全部订阅
```

迁移注意点：

1. **坐标系不同**：旧接口是 0..1 归一化，新接口是客户区像素。用
   `local w, h = d3d.window_size()` 换算。
2. **旧接口不渲染**：它只维护命中矩形，屏幕上看不到任何东西。要可见必须换成新的
   `d3d.Texture` 并提供真实 `source`。
3. **按键码**：旧接口用 Win32 VK（`message.keyboard` 里那张表）；新接口用 WARK 码
   （`d3d.key`，例如 `d3d.key.F2 == 0x301`）。这是本项目里最常见的踩坑点。
4. **鼠标按键**：旧接口的 `keycode = -1` 约定在 1.27a 游戏内**收不到**——CGameUI 分发只送
   键盘消息。新接口的鼠标事件来自窗口 `WM_*` + 异步按键状态，已在实机验收。
5. **回调形态**：旧的 press/release 是两个函数（也接受 JASS code 引用）；新的是一个函数配
   事件名，需要成对订阅时就订阅两次。

## 3. 裸 `UnitId` / hashtable RPC → `jass.d3d`

旧写法（不推荐，仅用于对照）：

```lua
-- 拼 spec + 哈希表槽位，把参数写进 JASS 全局/哈希表，再 UnitId("TextureCreate")
local spec = jass.code(...)          -- 手写 ABI
jass.globals.udg_japi_arg1 = x
jass.japi.D3D_SetRect(handle, x, y, w, h)
```

新写法：

```lua
texture:set_rect(x, y, w, h)
```

对应的 JASS 侧 bridge 名字（`TextureAddEvent`、`TextureRemoveEvent`、
`GetTextureEventCount` 等）仍然可用，用于 JASS 地图兼容；新代码不要再依赖它们。

## 4. 从 JASS code 回调迁到 Lua 闭包

旧：`TextureAddEvent(texture_id, keycode, jass_code_press, jass_code_release)`
新：`texture:on("key_down", fn, { key = d3d.key.Q })` / `texture:on("key_up", ...)`。

如果业务逻辑必须留在 JASS，仍可用 `jass.japi` 注册 unitId handler 供 JASS 调用，
或在 Lua 里用 `jass.code(fn)` 生成 code 交给 JASS native。

## 5. 迁移检查清单

- [ ] 所有 `message.texture_*` 调用已删除或换成 `d3d.Texture`。
- [ ] 归一化坐标已换算成客户区像素，且避开了 War3 顶栏/单位面板（顶部约 110px）。
- [ ] 按键码从 VK 换成 `d3d.key`（WARK）。
- [ ] 事件回调改为闭包；需要释放的地方调用 `sub:cancel()` 或 `texture:destroy()`。
- [ ] 字体对象比使用它的 Text 活得久；不再需要时显式 `destroy()`。
- [ ] 地图退出/重开路径调用 `d3d.shutdown()`（或依赖 context GC）。
- [ ] 用 `d3d.status()` / `d3d.stats()` 做自检，而不是读内部哈希表。

## 6. 兼容性说明

- `jass.message` 不会移除：键盘、命令卡、选择单位等接口仍在用，只是**不要**再用它的
  `texture_*` 做 D3D 显示或鼠标事件。
- 旧的 `TextureAddEvent` JASS bridge 在 `test_d3d.lua` 里仍有回归（hi-jack 需要），
  属于兼容面；新功能一律走 `jass.d3d`。
- 具体验收边界见 [../STATUS.md](../STATUS.md) 与
  [../planning/D3D-LUA-SDK-DESIGN.md](../planning/D3D-LUA-SDK-DESIGN.md) §14.3。

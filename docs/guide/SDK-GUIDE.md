# japi SDK 模块指南（作者向）

> 目标读者：已经能把一张地图打包并跑起来的 Lua 作者（还没跑通请先读 [SDK-QUICKSTART.md](SDK-QUICKSTART.md)）。
> 本文是 **12 个 `jass.*` 模块的逐模块 how-to**：每个模块「能做什么 / 最小用法 / 坑」三段。
> 函数签名不在这里抄第二份：显示层看 [D3D-LUA-API.md](D3D-LUA-API.md)，
> JASS 方言与 native 声明规则看 [../planning/JASS-NATIVE-DECLARATIONS.md](../planning/JASS-NATIVE-DECLARATIONS.md)，
> 现成配方见 [SDK-COOKBOOK.md](SDK-COOKBOOK.md)。

| 项 | 值 |
|---|---|
| 文档 | SDK-GUIDE.md（作者向模块指南） |
| 适用游戏版本 | Warcraft III 1.27a（`1.27.0.52240`） |
| SDK 版本 | `0.4.0`（`jass.d3d.version()`，钉在 `src/src/lua_engine/lua_engine/libs_d3d.cpp:35`） |
| 文档日期 | 2026-11-16 |
| 证据基础 | 仓库 `map/` 实机回归 **122 passed / 0 failed / 122 total**（2026-11-16，DLL SHA-256 `87C83BA1CE0E6E413CEA7B9D6018E9A289259EC9C2F01EE02E7827DAF6661908`）；模块行为逐条对照 `src/src/lua_engine/lua_engine/libs_*.cpp` |
| 验证标注 | 每个模块末尾的「坑」表里，凡**没有**出现在实机回归里的行为都写了「源码可读、未在回归覆盖」 |

---

## 0. 先建立心智模型

### 0.1 谁在什么时候跑

```
war3map.j main()
  └─ initializePlugin(  )                      ← 基座地图自带（reference/empty-map/war3map.j:59）
       ├─ StartCampaignAI(Player(PLAYER_NEUTRAL_AGGRESSIVE), "callback")   ← 从 MPQ 里 loadfile 出 DLL
       └─ UnitId(I2S(GetHandleId(japi_ht)))     ← 把桥接哈希表交给 DLL
  └─ call SaveStr(japi_ht, japi__key, 0, "()V") ← pack.ps1 注入
  └─ call UnitId("LoadScript")                  ← pack.ps1 注入：首次调用才创建 Lua VM
       └─ 创建 lua_State → 加载 MPQ 里的 script\war3map.lua（= pack 合并产物）
            └─ 你的 war3map.lua 顶层代码在这一刻开始跑
```

所以：**顶层代码运行时，地图 `main()` 还没跑完**。要等开局稳定（一般 1 秒多）再碰命令/相机/D3D 之类的东西，
仓库里的做法是统一用一个 `after(seconds, fn)` 定时器包一层，见 `map/game/demo.lua` 的 `M.run()`。

### 0.2 三层 API

| 层 | 入口 | 方向 | 你用它做什么 |
|---|---|---|---|
| 引擎 native 直调 | `jass.common` | Lua → 游戏 | 一切游戏操作：CreateUnit、CreateTimer、GetUnitState…… |
| 扩展 native | `jass.japi` + `UnitId` 桥 | 双向 | 把 Lua 逻辑暴露成 JASS 能调的名字；JASS 侧再包一层 wrapper 就成了触发器可用的函数 |
| 拦截 | `jass.hook` | Lua 改写既有 native | 改引擎行为：改返回值、加日志、拦参数 |

另外三组是**辅助设施**：`jass.globals`（读写 JASS 全局）、`jass.message`（输入）、`jass.runtime` / `jass.sleep`（运行时开关）。
数据/调试类：`jass.slk`、`jass.storm`、`jass.debug`、`jass.debugger`。显示：`jass.d3d`。

### 0.3 五个必须记住的不变量

| 不变量 | 具体表现 | 违反后的现象 |
|---|---|---|
| native 只在 "gaming" 时可调 | `jass.common` 的 `__index` 在非 gaming 状态直接返回 `nil`（`libs_common.cpp:61-65`） | `attempt to call a nil value` |
| handle 默认是 userdata | `runtime.handle_level` 默认 `2`：0=整数、1=轻量 userdata、2=userdata（`libs_runtime.cpp:16`，`test_suite.lua:581-601` 实机覆盖） | 拿 handle 和数字比较永远不等 |
| 数组全局要先预分配 | pack.ps1 插 `JapiForceAllocArrays()`，对每个数组做 `set arr[8191] = arr[8191]`（每数组 32 KB） | 读未分配的数组、写不进去（`-NoArrayPrealloc` 时回归里少了 1 项，就是这个坑） |
| `sleep` 需要三道门都开 | `runtime.sleep = true` + 当前在协程里 + 线程类型是 trigger/action | `sleep() must be called from a coroutine` |
| 一张地图一个 war3 进程 | 游戏本身单实例（另一份在跑时启动会 `unable to initialize`） | 部署脚本卡在等结果，或 DLL 根本没进新进程 |

### 0.4 三个版本号别搞混

| 版本 | 怎么读 | 含义 |
|---|---|---|
| SDK | `require("jass.d3d").version()` → `"0.4.0"` | Lua SDK 版本，见 [../../CHANGELOG.md](../../CHANGELOG.md) |
| 运行时 | `require("jass.runtime").version` → `"1.0.0.0"` | 引擎侧适配层版本（跟 SDK 版本无关，读的是另一个常量） |
| DLL 文件 | `(Get-FileHash src/build/bin/Release/yd_japi.dll).Hash` | 你到底跑的是哪个二进制 |

---

## 1. `jass.common` — 调 JASS native

### 能做什么

- `jass.AnyNativeName(...)`：元表 `__index` 自动分发。命中引擎 native 表就返回一个可调用闭包（`libs_common.cpp:49-59`）。
- `jass.call("NativeName", args...)`：显式按名字分发，先查引擎 native、再查 japi 注册的 native；查不到直接报 `unknown native: <name>`（`libs_common.cpp:147-159`）。
- `jass.code(fn)`：把 Lua 函数变成 JASS `code` 值（`libs_common.cpp:163-168`）。其实直接传函数也能用（`map/war3map.lua:102` 就是这么写的），`jass.code` 是显式版。
- 读 JASS 全局变量：native 表查不到的名字会退化成读全局；数组全局返回 `jarray` userdata（`libs_common.cpp:67-90`）。
- `pairs(jass)` 遍历 native 表。

### 最小用法

```lua
local jass = require "jass.common"

-- 1) 元表直调
local player = jass.GetLocalPlayer()
print("player id = " .. jass.GetPlayerId(player))

-- 2) 显式分发（函数名拼在字符串里时用这个，拼错会报错而不是静默 nil）
local unit = jass.call("CreateUnit", jass.Player(0), jass.FourCC("hfoo"), 0.0, 0.0, 270.0)

-- 3) Lua 函数变 JASS code：给定时器/触发器用
local timer = jass.CreateTimer()
jass.TimerStart(timer, 1.0, false, jass.code(function()
    jass.DestroyTimer(timer)
    print("tick")
end))
```

`jass.code` + `TriggerAddAction` 的往返在实机回归里覆盖过（`test_suite.lua:496-504`，`jass.code trampoline` 一节）。

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| native 名字拼错 | `__index` 不会报错，而是当成「读一个不存在的 JASS 全局」→ `nil` → 调用时报 `attempt to call a nil value` | 名字来自字符串时用 `jass.call`，它报 `unknown native: <name>` |
| 以为 `jass.MyJapiNative()` 一定可用 | `__index` 只查引擎 native 表，**不查 japi 注册表**（`libs_common.cpp:53`） | japi 注册的 native 用 `jass.call("MyJapiNative", ...)` 或在 Lua 侧用 `japi.MyJapiNative(...)` |
| handle 当数字比 | `jass.GetLocalPlayer() == 0` 永远 false（userdata） | `runtime.handle_level = 0`，或用 `jass.debug.h2i(h)`，或统一走 `__eq` |
| 顶层脚本里立刻调 | 那时 `is_gaming()` 可能还没成立，拿到 `nil` | 用 `after(1.0, ...)` 挪到开局后（`map/war3map.lua:94-107` 的注释解释了为什么用 1.0 秒而不是 0.01 秒） |
| `UnitId` 桥返回的是哈希表槽位 | 直接调 japi native 的返回值在 JASS 侧要 `LoadInteger` 取 | 见第 3 节和 [../planning/JASS-NATIVE-DECLARATIONS.md](../planning/JASS-NATIVE-DECLARATIONS.md) |

---

## 2. `jass.globals` — 读写 JASS 全局变量

### 能做什么

- 标量：`globals.udg_xxx = 1`、`local v = globals.udg_xxx`。
- 数组：返回 `jarray`，可 `arr[i] = v` / `v = arr[i]` / `#arr`（**开局后** `#` 恒为 8192，`test_suite.lua:567-571` 实机覆盖；脚本加载期是 0，见下面的时序小节）。
- `pairs(globals)` 遍历。

### 最小用法

```lua
local globals = require "jass.globals"

globals.udg_lua_test_value = 12345        -- 写标量
print(globals.udg_lua_test_value)         -- 读标量

globals.udg_lua_test_array[0] = 7          -- 写下标 0
globals.udg_lua_test_array[8191] = 99      -- 写下标 8191（预分配出来的最后一个合法下标）
print(#globals.udg_lua_test_array)         -- 8192
```

`map/war3map.lua:44` 用一行 `globals.udg_lua_japi_alive = 1` 当「DLL 活着」的探针，
因为脚本只有 DLL 起来之后才会被加载。

### 时序：数组只能在「地图初始化完成」之后用

这是本模块最容易踩的不对称：**标量**在脚本加载期就能读写，**数组**要到开局后才可用。

| 时机 | `globals.udg_x`（标量） | `globals.some_array` 的元素 / `#arr` |
|---|---|---|
| `war3map.lua` 顶层（加载期） | 正常读、正常写 | `#arr == 0`；读元素得 `nil`；写元素**被静默丢弃**（不报错） |
| 开局后（一次性 timer 1.0 秒就够） | 正常读、正常写 | `#arr == 8192`（`pack.ps1` 预分配过），读写正常 |

```lua
local jass = require "jass.common"
local globals = require "jass.globals"

-- 加载期：标量可以，数组不行
globals.udg_lua_japi_alive = 1                 -- OK：DLL 存活探针（map/war3map.lua:44 就是这么写的）
print(#globals.udg_lua_test_array)             -- 0，不是 8192
globals.udg_lua_test_array[5] = 77             -- 被丢弃，没有任何报错
print(globals.udg_lua_test_array[5])           -- nil

-- 开局后：数组才可用
local timer = jass.CreateTimer()
jass.TimerStart(timer, 1.0, false, function()
    jass.DestroyTimer(timer)
    print(#globals.udg_lua_test_array)         -- 8192
    globals.udg_lua_test_array[5] = 77
    print(globals.udg_lua_test_array[5])       -- 77
end)
```

实机证据（2026-11-16，探针地图 `build\scratch\arrprobe`，日志 `build\scratch\arrprobe-deploy.log`）：

```text
load                len=0    idx5=nil
load-after-write    len=0    idx5=nil
1.0s                len=8192 idx5=0
1.0s-after-write    len=8192 idx5=909
```

也就是说：加载期写数组是**静默失败**，最坑的是它不报错——`map/tests/test_suite.lua` 的 globals 段全绿，是因为它在 1.0 秒后才跑；
`examples/06-globals` 之前踩的正是这个坑，现已按同一规则改写成「加载期只写标量、数组 I/O 放进 1.0 秒 timer」，可以直接拿它当可运行版本。

> 还有一个只跟字符串数组有关的细节：即使开局后，**从没写过的字符串槽读出来是 `nil`**（JASS 的空字符串），而整数槽读出来是 `0`。
> 所以字符串槽永远「先写后读」，否则拼字符串时会报 `attempt to concatenate a nil value`。

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 数组没预分配 | 读出来全是 0/写不进 | 用默认 `pack.ps1`（会插 `JapiForceAllocArrays()`）；`-NoArrayPrealloc` 只给回归用 |
| 整个数组赋值 | `globals.arr = {}` 被忽略，日志里 `[jass.globals] assignment to whole array ignored: ...`（最多打 4 次） | 逐个下标写 |
| JASS 侧没声明这个全局 | 读 `nil`、写静默无效 | 全局必须在 `war3map.j` 的 `globals` 块里声明；要自己加全局就加在基座地图里 |
| **加载期读写数组** | `#arr == 0`、元素读 `nil`、写被**静默丢弃**；同一时刻标量完全正常 | 数组 I/O 放进 `TimerStart(..., 1.0, ...)`，见上面「时序」小节 |
| 字符串数组槽没写过就读 | 开局后也是 `nil`（不是 `""`），拼接时报 `attempt to concatenate a nil value` | 先写后读 |
| 非 gaming 期间读写标量 | 读返回 `nil`、写无效（`libs_globals.cpp`） | 挪到开局后 |
| 下标越界 | 8192 个槽（0..8191） | 用 8191 以内的下标，或改用 hashtable/Lua 表 |

---

## 3. `jass.japi` — 注册自己的 native

### 能做什么

- `japi("Name", "signature", handler)` 注册一个 bridge handler：同时进 Lua 侧 native 表（`japi.Name(...)`）和 `UnitId("Name")` 桥。
- `pairs(japi)` 遍历已注册的 handler。
- 签名用 JASS 类型串：`()V`、`(II)I`、`(R)R`、`(SS)S`、`(Hplayer;)Hplayer;`……返回值和参数都走哈希表槽位。

### 最小用法

```lua
local japi = require "jass.japi"

-- Lua 侧：注册 + 直接调
japi("TestAdd", "(II)I", function(a, b) return a + b end)
print(japi.TestAdd(10, 32))       -- 42

-- JASS 侧：war3map.j 里已经有 wrapper 的话直接 call；没有就只能走 UnitId 桥
--   call JapiCallBridge()        ← wrapper 里最终是 UnitId("TestAdd")
```

JASS→Lua 的完整链路（哈希表槽位约定：**槽 0 放签名 / 返回值，槽 1..n 放参数**）在
`map/tests/bridge_preflight.lua:42-56`，实机回归 `bridge preflight` 一节覆盖。

```lua
japi("LuaBridgeProbe", "(II)I", function(a, b) return a + b end)
```

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 重名注册 | `japi: <name> is already registered` | 先 `pairs(japi)` 查一遍 |
| 与已有 bridge handler 撞名 | `japi: <name> conflicts with an existing bridge handler` | 换名字 |
| 以为 JASS 里能 `call` 任意新名字 | 地图脚本能声明的只有引擎表里**已存在**的名字（`SetHeroLevels` 这类 AI 方言名字），声明全新名字会让整局脚本编译失败、静默回主菜单 | 新功能走 `UnitId` 桥或 `tools/gen-jass-wrappers.ps1` 生成的 wrapper，见 [../planning/JASS-NATIVE-DECLARATIONS.md](../planning/JASS-NATIVE-DECLARATIONS.md) R1/R2/R3 |
| `nil` 参数 | `(I)I` 参数传 `nil` 当 0 处理（`test_suite.lua:173-177`） | 别依赖「nil 表示缺省」做分支 |
| 32 位整数溢出 | `japi.TestAdd(0x7FFFFFFF, 1) == -0x80000000`（`test_suite.lua:164`） | 需要的宽数值走 real 或 Lua 侧算完再传 |

---

## 4. `jass.hook` — 拦截既有 native

### 能做什么

- `hook.hook(name, fn)`：拦截 native。回调签名是 `function(参数..., orig)`——**原函数作为最后一个参数**传给你。
- `hook.unhook(name)`：还原。
- 元表式：`hook.Name = fn` 安装、读 `hook.Name` 拿到已装函数、`hook.Name = nil` 卸载。
- 拦截后 **`jass.call` 和 `jass.X()` 两条路都走你的函数**（`libs_hook.cpp:48-59`）。

### 最小用法

```lua
local jass = require "jass.common"
local hook = require "jass.hook"

-- 拦 GetPlayerId：所有调用方都 +100（实机回归 test_suite.lua:253-266 同款）
hook.hook("GetPlayerId", function(p, orig)
    return orig(p) + 100
end)

local lp = jass.GetLocalPlayer()
print(jass.GetPlayerId(lp))       -- 原始值 + 100
print(jass.call("GetPlayerId", lp)) -- 同样 +100

hook.unhook("GetPlayerId")
print(jass.GetPlayerId(lp))       -- 还原
```

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 回调忘了收 `orig` | 参数错位，`orig` 变成 nil，调用崩 | 永远把 `orig` 写在最后一位形参 |
| 重复 hook | `hook: '<name>' is already hooked` | 先 `hook.unhook` 或先判断 |
| 名字不存在 | `hook: unknown native <name>` | 只有引擎 native 表和 japi 注册表里的名字能 hook |
| 安装失败 | `hook: failed to install on '<name>'` | 多半是进程版本不匹配，别忽略这个错 |
| 卸载时把别人的 hook 一起摘了 | 只还原你自己那次 | `unhook` 前确认当前 hook 的是你的函数 |

---

## 5. `jass.message` — 输入系统

### 能做什么

| 入口 | 返回 | 说明 |
|---|---|---|
| `message.mouse()` | `x, y` | **世界坐标**（`libs_message.cpp:216-231`） |
| `message.mouse_screen()` | `x, y` | 归一化到 `[0,1]` 的屏幕比例（`libs_message.cpp:968` 附近） |
| `message.button(x, y)` | `ability_id, order_id, target_type` | 命令卡格坐标，`x` ∈ 0..3、`y` ∈ 0..2；空格子返回空（`libs_message.cpp:233-256`） |
| `message.selection()` | handle | 当前选中单位；1.27a 有 offset 问题，仓库改用 `GroupEnumUnitsSelected`（`map/lib/util.lua`） |
| `message.keyboard[vk]` | boolean | 按键状态读写（`test_suite.lua:304-321` 实机覆盖） |
| `message.set_keyboard(vk, down)` / `message.click_keyboard(vk)` | boolean | 用 `PostMessage` 合成按键 |
| `message.show_console(show)` | boolean | 近似实现（找 `ConsoleWindowClass` 子窗口 `ShowWindow`），可能返回 false |
| `message.order_immediate` / `order_point` / `order_target` | boolean | 1.24e+ 才有；**要求当前已选中单位**，否则直接 false |
| `message.hook = function(msg) ... end` | — | 装输入过滤器；赋 `nil` 卸载（`libs_message.cpp:913-950`） |

`msg` 表字段：`type`（`key_down`/`key_up`/`mouse_down`/`mouse_up`/`mouse_ability`）、`code`、`state`（键盘）、`x`/`y`（鼠标，世界坐标）、`ability`/`order`（命令卡）。

### 最小用法

```lua
local jass = require "jass.common"
local message = require "jass.message"

local KEY_Q = 0x51        -- message.keyboard 用的是 WARK 键码，不是 Win32 VK
local KEY_F2 = 0x301      -- WARK_F2；Win32 的 F2 是 0x71，这里不一样

message.hook = function(msg)
    if msg.type == "key_down" and msg.code == KEY_Q then
        print("Q pressed at " .. tostring(msg.x) .. "," .. tostring(msg.y))
        return false      -- 吞掉，游戏收不到
    end
    return true           -- 放行
end
```

返回值语义（`libs_message.cpp:592-603`）：**真值 = 放行给游戏，假值/没写 return = 吞掉**。
仓库里 `map/game/demo.lua` 的 `on_message` 就是这么用的：拦到 Q 返回 `false`，其他一律返回 `true`。

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 回调没写 `return` | 所有按键被吞，游戏像死了一样 | 每条路径都显式 `return true` |
| 窗口不在前台 | 按键/鼠标事件收不到（过滤器挂在游戏窗口的消息流上） | 手动点一下游戏窗口，或用 `-Hold` + `tools/drive-interactive-d3d.ps1` 驱动 |
| 拿 Win32 VK 当 `code` | Q 能撞上，F2 对不上 | 用 `message.keyboard`/`message.key` 常量，F2 = `0x301` |
| `message.mouse()` 以为是屏幕像素 | 得到的是世界坐标 | 屏幕比例用 `message.mouse_screen()` |
| `message.selection()` 拿到错单位 | 1.27a 的已知 offset 问题 | 抄 `map/lib/util.lua` 的 `GroupEnumUnitsSelected` 版本 |
| `message.button` 在空格子 | 什么都不返回（不是报错） | 判断 `if ability_id == nil then return end` |

---

## 6. `jass.runtime` — 运行时开关

### 能做什么

| 字段 | 读写 | 含义 |
|---|---|---|
| `runtime.handle_level` | 读写 | 0=整数、1=轻量 userdata、2=userdata（默认 2） |
| `runtime.error_handle` | 读写 | 给一个 `function(message)`，Lua 侧未捕获错误会送进来 |
| `runtime.console` | 读写 | true 打开 Win32 控制台窗口（调试用，关掉要重启游戏） |
| `runtime.sleep` | 读写 | `jass.sleep` 的总开关 |
| `runtime.can_sleep` | 只读 | `sleep == true` 且当前可让出 |
| `runtime.debugger` | 读写 | 赋一个端口号即启动 DAP 调试器（只首次生效） |
| `runtime.catch_crash` | 读写 | 是否捕获 Lua 崩溃（默认 true） |
| `runtime.version` | 只读 | `"1.0.0.0"`，运行时适配层版本，不是 SDK 版本 |
| `runtime.perftrace()` | 调用 | 返回一段计时字符串，并清零计数器 |

### 最小用法

```lua
local runtime = require "jass.runtime"

runtime.error_handle = function(message)
    print("[lua error] " .. tostring(message))
end

local old = runtime.handle_level
runtime.handle_level = 0                     -- 临时把 handle 当整数用
local id = jass.GetPlayerId(jass.GetLocalPlayer())
runtime.handle_level = old
```

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 字段名拼错 | 静默无效：`jass_runtime_set` 对未知名字直接返回，不报错 | 对着上表抄；怀疑时读回来打印 |
| `runtime.console = true` | 打开一个真窗口，且 **禁用了关闭按钮** | 只在需要时开 |
| `runtime.debugger = port` | 只第一次生效（`debugger == LUA_NOREF` 才进） | 想换端口先重启地图 |
| 以为 `runtime.version` 是 SDK 版本 | 永远 `"1.0.0.0"` | SDK 版本用 `jass.d3d.version()` |
| `handle_level` 改完没还原 | 后续所有 handle 类型都变了 | `local old = ...` 存旧值再还原（`test_suite.lua:581-601` 就是这么写的） |

---

## 7. `jass.sleep` — 协程睡眠

### 能做什么

- `sleep(seconds)`：**全局函数**，同时也能 `require "jass.sleep"` 拿到 `.sleep`。
- 内部走 `TriggerSleepAction`，让 Lua 协程在 JASS 动作线程上真正挂起/恢复。
- `seconds <= 0` 按 0.001 处理。

### 最小用法

```lua
local jass = require "jass.common"
local runtime = require "jass.runtime"
local sleep = require("jass.sleep").sleep

runtime.sleep = true                       -- 总开关

local trigger = jass.CreateTrigger()
jass.TriggerAddAction(trigger, jass.code(function()
    print("stage 1")
    sleep(0.30)                            -- 只在 trigger/action 线程里能恢复
    print("stage 2")
end))
jass.TriggerRegisterTimerEvent(trigger, 0.10, false)
```

这段结构就是 `map/tests/bridge_preflight.lua:67-101` 的实测版本（回归里 `Lua sleep resumes in a JASS trigger action` 通过）。

### 实测：一次等待可靠，多段串联不可靠

`sleep()` 的语义是「在这个 JASS 动作线程上挂起一会儿，再从原地继续」。2026-11-16 用 6 个独立探针地图在 1.27a 实机实测（同一份 DLL，SHA-256 `87C83BA1CE0E6E413CEA7B9D6018E9A289259EC9C2F01EE02E7827DAF6661908`；探针在 `build\scratch\probe-*`，不随仓库发布）：

| 探针形态 | 实测结果 |
|---|---|
| `sleep(0.05)` ×2，无守卫 | 第一段 0.075 s 恢复，整条链 0.167 s 走完 ✅ |
| `sleep(0.30)` ×2，无守卫 | 第一段 @0.433 s 恢复；action 又被进入 5 次（约 0.45 s 一次）；`stage3` @3.549 s ✅ |
| 同上 + 加载期悬挂协程 | `stage3` @2.570 s ✅（悬挂协程单独不致命） |
| 同上 + 加载期 `pcall(sleep)` | `stage3` @3.100 s ✅ |
| 同上 + **action 顶部一次性守卫** | 第一段照常恢复（`stage 2` @0.433 s）；entry #2 @0.879 s 被守卫挡掉；**之后 15 s 无恢复，`stage` 永远停在 2** ❌ |
| 状态机推进（无守卫） | `step 1` 之后 **15 s 没恢复** ❌ |
| `map/tests/bridge_preflight.lua` 形态（**一段** `sleep(0.30)`） | 每次 122/122 回归都通过 ✅ |

三条结论：

1. **精度够用，但别当计时器**：恢复耗时 ≈ 参数 + 0.1 s 左右（0.05 → 0.075 s、0.30 → 0.433 s），分辨率约 0.1 s。要精确节奏（节拍、逐帧演出）仍用 `CreateTimer` + `TimerStart`。
2. **多段 `sleep` 串联不可靠**：同一条两连 `sleep` 的探针，一次 3.5 s 跑完、另一次 15 s 都没恢复；而且 action 会被从头重入（某次 3.8 秒内进入 6 次，每次把 `stage` 重置回 1）。→ 多段编排用 timer 链，`sleep` 只用于「等一次再继续」。
3. **不要给 sleeping action 加一次性守卫**（最容易凭直觉写错的一条）：探针 p6 加上 `if state.started then return end` 之后，第一段恢复、第二段永不恢复（15 s 不动）。挂起后的续跑依赖 action 再次被进入，守卫等于把它掐死。

可靠形态就是 `map/tests/bridge_preflight.lua:67-101`（仓库每次回归都跑它）：

```lua
local jass = require "jass.common"
local runtime = require "jass.runtime"

runtime.sleep = true
local state = { stage = 0 }

local trig = jass.CreateTrigger()
jass.TriggerAddAction(trig, jass.code(function()
    state.stage = 1
    sleep(0.30)              -- 一个 action 里只等一次
    state.stage = 2
end))
jass.TriggerRegisterTimerEvent(trig, 0.10, false)

-- 判定放在独立定时器里轮询：见到 1 记「挂起过」、见到 2 判「恢复了」、3 秒兜底判失败
local watch, ticks = jass.CreateTimer(), 0
jass.TimerStart(watch, 0.02, true, jass.code(function()
    ticks = ticks + 1
    if state.stage == 2 or ticks > 150 then
        print(string.format('[sleep] %s after %d ticks', state.stage == 2 and 'resumed' or 'TIMEOUT', ticks))
        jass.PauseTimer(watch)
        jass.DestroyTimer(watch)
        runtime.sleep = false
    end
end))
```

要点：**一个 action 里只 `sleep` 一次**；进度用状态字段表达；判定/自检放在**独立定时器**里轮询；多段节奏用 timer 链（在 `TimerStart` 回调里排下一段），不要连写两个 `sleep`。

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 没开 `runtime.sleep` | `TriggerSleepAction is not available` | 先 `runtime.sleep = true` |
| 在协程里但不在 trigger/action 线程 | `sleep() must be called from a coroutine` 或永不恢复 | 用 trigger action 承载（不要用裸 timer 回调） |
| 忘了关 | 一局游戏里一直挂着 sleep 通道 | 用完 `runtime.sleep = false`（`bridge_preflight.lua:58-63`） |
| `sleep` 当计时器用 | 恢复耗时 ≈ 参数 + 0.1 s（实测 0.05→0.075 s、0.30→0.433 s），分辨率约 0.1 s | 精确节拍用 `CreateTimer` + `TimerStart`；`sleep` 只表达「等一会儿」 |
| 一个 action 里连写多个 `sleep` | 同一形态一次 3.5 s 跑完、另一次 15 s 没恢复；action 还会被从头重入（某次 3.8 s 内进 6 次，`stage` 被重置回 1）（2026-11-16，6 个探针地图） | 一个 action 只 `sleep` 一次；多段用 timer 链；进度写状态字段，见上面「实测」小节 |
| **给 sleeping action 加一次性守卫** | 加了 `if state.started then return end` 后第一段恢复、第二段永不恢复（实测 15 s 不动）——续跑依赖 action 被重新进入 | 不要加守卫；用状态字段 + 独立定时器轮询判定 |

---

## 8. `jass.slk` — 游戏数据表

### 能做什么

- 七张表懒加载：`slk.ability` / `slk.buff` / `slk.unit` / `slk.item` / `slk.upgrade` / `slk.doodad` / `slk.destructable`（注意 `doodad` 是单数、`destructable` 沿用 War3 拼写）。
- `slk.ability["AHbz"].code` → 字段值，**统一是 Lua 字符串**；字段名大小写不敏感。
- `pairs(slk.unit)` 遍历全部行。

### 最小用法

```lua
local slk = require "jass.slk"

print(slk.ability["AHbz"].code)      -- "AHbz"（暴风雪）
print(slk.unit["hpea"].race)          -- "human"（农民）
print(slk.item["rat3"].class)        -- 物品分类

local n = 0
for id in pairs(slk.unit) do n = n + 1 end
print("unit rows: " .. n)
```

上面三条断言在实机回归 `jass.slk` 一节逐条跑过（`test_suite.lua:415-453`）。

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 查不到的对象 | 返回 `nil`，日志里 `[slk] MISS ...`（只打前 6 次） | 用 `if row then` 判空；MISS 日志是唯一的线索 |
| 以为是数字 | 字段值全变字符串（`to_string()`） | 用 `tonumber(row.field)` 再算 |
| 以为和物编一致 | SLK 是**基础数据**，地图里的物编改动不会体现 | 要读地图改动得走 `EXGetUnit...` 一类扩展 native |
| 表名写 `destructable` 之外 | `slk.destructible` 是 `nil` | 抄原文拼写 |
| 首次访问慢 | 每张表第一次访问才解析 | 开局预热一次，别在战斗循环里第一次碰 |

---

## 9. `jass.storm` — 读 MPQ 里的文件

### 能做什么

- `storm.load("war3map.w3i")`：整文件读成 string，失败 `nil`。
- `storm.has("path")`：boolean。

### 最小用法

```lua
local storm = require "jass.storm"

if storm.has("war3map.w3i") then
    local w3i = storm.load("war3map.w3i")
    print("w3i bytes: " .. #w3i)
end
print(storm.has("no-such-file.bin"))     -- false
```

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 路径分隔符 | 用 `/` 或 `\\` 都能读到一部分文件，但和 MPQ 内部拼写不完全一致时就是 nil | 先 `storm.has` 探一下 |
| 以为能读任意游戏文件 | 只读到**当前地图 MPQ + 游戏 MPQ** 里存在的条目 | 读不到先确认文件在不在包里 |
| 大文件整读进内存 | 几百 KB 还行，几十 MB 会卡 | 别拿它当流式 IO |

---

## 10. `jass.debug` — 内省

### 能做什么

| 入口 | 返回 |
|---|---|
| `debug.functiondef(fn)` | `{[1]=返回类型, [2..n]=参数类型}` |
| `debug.globaldef(name)` | 类型串，如 `"i"`、`"i[]"` |
| `debug.handledef(h)` | `{reference=<int>, type="<4 字符>"}` |
| `debug.currentpos()` | 当前 JASS 函数名, 语句偏移 |
| `debug.handlemax()` / `debug.handlecount()` | handle 表容量 / 活跃 handle 数 |
| `debug.h2i(h)` / `debug.i2h(i)` | handle ↔ integer |
| `debug.handle_ref(h)` / `debug.handle_unref(h)` | 手动增减引用计数 |
| `debug.jass_func_address(name)` | native 地址（整数，找不到 0） |
| `debug.func_bind_lookup(addr)` / `func_bind_count()` / `func_bind_clear()` | code 地址 ↔ 名字表 |
| `debug.save_func_addr()` | 保存当前 code 地址 |

### 最小用法

```lua
local jass = require "jass.common"
local debug = require "jass.debug"

local lp = jass.GetLocalPlayer()
print(string.format("handle=0x%X", debug.h2i(lp)))       -- handle 当整数看
print(debug.handlecount() .. " / " .. debug.handlemax()) -- 活跃/容量
local addr = debug.jass_func_address("GetPlayerId")
if addr ~= 0 then print("GetPlayerId @ " .. string.format("0x%X", addr)) end
```

`jass_func_address` 在实机回归里单独覆盖过（`test_suite.lua:723`）。

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 拿 `h2i` 的值跨局保存 | handle 表会重新分配 | 只在同一局内用 |
| `handle_ref` 加引用后忘了 `handle_unref` | handle 泄漏，`handlecount` 一直涨 | 成对调用 |
| 以为 `jass_func_address` 能拿 Lua 函数地址 | 它查的是 native 名字 | Lua 函数用 `jass.code(fn)` 拿 code 索引 |
| `gchash()` | 已经是空实现，别依赖 | — |

---

## 11. `jass.debugger` — DAP 调试器

### 能做什么

- `debugger.listen(host, port)`：启动 DAP 服务，默认 `127.0.0.1:4278`；host 只接受 `127.0.0.1`/`localhost`。
- `debugger.connected()`：boolean。
- `debugger.close()`。
- 第一次启动会把 MPQ 里 `debugger\manifest.txt` 列出的文件解到 `<war3 目录>\japi-debugger\`，再 `loadfile("script/debugger.lua")` 并启动。**这要求地图是用 `pack.ps1 -WithDebugger` 打的**。

### 最小用法

```lua
local runtime  = require "jass.runtime"
local debugger = require "jass.debugger"

for _, port in ipairs({ 4278, 4279, 4280 }) do
    runtime.debugger = port            -- 只首次生效
    if debugger.connected() then
        print("[dbg] listening on 127.0.0.1:" .. port)
        break
    end
end
```

这段就是 `map/war3map.lua:59-73` 的原文（换了变量名）。VS Code 侧装 `actboy168.lua-debug`，
attach `127.0.0.1:4278`，断点打在 `<war3 目录>\japi-debugger\script\war3map.lua`。

### 坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 忘了 `-WithDebugger` | 日志 `debugger\manifest.txt not in MPQ (pack with -WithDebugger)` | 重新打包加开关 |
| 端口被占 | `jass.debugger: failed to start (resources missing or port busy)` | 换端口（`map/war3map.lua` 就依次试 4278/4279/4280） |
| 绑到 0.0.0.0 想在别的机器上调试 | 报 `jass.debugger: only 127.0.0.1 is allowed` | 老老实实本机 |
| 断点打在自己项目目录 | 调试器加载的是 `japi-debugger\script\war3map.lua` 这个副本 | 在副本上打断点，或调好后重打包 |

---

## 12. `jass.d3d` — 显示

只做入口指引，签名去 API 文档看，不要在这里抄第二份。

| 需求 | 去哪 |
|---|---|
| 五分钟做出一个 HUD | [D3D-LUA-QUICKSTART.md](D3D-LUA-QUICKSTART.md) |
| 逐函数签名、事件、生命周期、限制 | [D3D-LUA-API.md](D3D-LUA-API.md) |
| 从旧画法迁过来 | [D3D-LUA-MIGRATION.md](D3D-LUA-MIGRATION.md) |
| 可用性判据 | `d3d.is_available()`；false 时看 `d3d.status().error` |

一个模块内部约定值得先知道：`jass.d3d` 的 **`version()` 永远可用**（返回常量 `"0.4.0"`，
`libs_d3d.cpp:1984`），即使游戏目录没装 d3d9 proxy——所以拿它当 SDK 版本印在日志里是安全的。
真要看能不能画，才用 `is_available()`。

---

## 13. 速查表

| 模块 | 一句话 | 入口 | 最容易踩的坑 |
|---|---|---|---|
| `jass.common` | 调 JASS native | `jass.X()` / `jass.call` / `jass.code` | 拼错名字静默 nil |
| `jass.globals` | 读写 JASS 全局 | `globals.udg_x` | 数组必须先预分配 |
| `jass.japi` | 注册自己的 native | `japi(name, sig, fn)` | JASS 里不能 `call` 全新名字 |
| `jass.hook` | 拦 native | `hook.hook(name, fn)` | 回调最后一位是 `orig` |
| `jass.runtime` | 运行时开关 | `runtime.sleep` 等 | 字段名拼错静默无效 |
| `jass.sleep` | 协程睡眠 | `sleep(seconds)` | 要在 trigger/action 线程里 |
| `jass.message` | 输入 | `message.hook` | 回调不 `return true` 会吞掉所有输入 |
| `jass.slk` | 数据表 | `slk.unit["hfoo"]` | 值是字符串不是数字 |
| `jass.storm` | 读 MPQ | `storm.load` | 路径不存在就 nil |
| `jass.debug` | 内省 | `debug.h2i` 等 | `handle_ref` 要配对 |
| `jass.debugger` | DAP 调试 | `debugger.listen` | 要 `-WithDebugger` 打包 |
| `jass.d3d` | 显示 | `d3d.is_available()` | 窗口不在前台收不到事件 |

---

## 14. 下一步

| 想去哪 | 读什么 |
|---|---|
| 还没跑通第一张地图 | [SDK-QUICKSTART.md](SDK-QUICKSTART.md) |
| 想要现成配方（HUD+键位、选单位、SLK 表、bridge、sleep 演出……） | [SDK-COOKBOOK.md](SDK-COOKBOOK.md) |
| 想看可运行的最小工程 | [examples/](../../examples/)（01-hello-jass … 10-getfunc-addr，每个目录一个 `war3map.lua`） |
| 想看版本变更 | [../../CHANGELOG.md](../../CHANGELOG.md) |
| 想发一个版本 | [../RELEASE.md](../RELEASE.md) |
| 想知道每个模块的验证强度 | [../STATUS.md](../STATUS.md) |

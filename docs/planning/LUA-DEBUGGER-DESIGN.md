# Lua 调试器（jass.debugger / 127.0.0.1:4278）详细设计

> 状态：**P0/P1/P2 已完成**（结论与方案调整见附录 A/B，验证记录见附录 C），P3–P5 实施中  
> 依据：`docs/re-builtin-japi/03-yd-lua-engine.md`（全新逆向）、`reference/YDWE/.../libs_debugger.cpp`（YDWE 实现）、actboy168/lua-debug 仓库与官方 VSIX（附录 A）、本仓库当前代码

---

## 1. 背景与目标

### 1.1 内置 JAPI 的做法（逆向事实）

yd_lua_engine.dll 在首次 ExecuteFunc 惰性初始化时的执行序列中，于注册 15 个 `jass.*` 模块之后、执行用户 chunk 之前，固定执行：

```lua
(require 'jass.debugger').listen('127.0.0.1', 4278)
```

即：**调试器是引擎的标准组件**，通过 TCP 监听本机 4278 端口，等待调试客户端（IDE）接入。其 `jass.debugger` 是一个 Lua 模块（经 `_PRELOAD` 注册），底层必然有 C 侧 socket 支持（Lua 本身无网络能力）。

### 1.2 YDWE 的做法（源码事实）

`libs_debugger.cpp`：在用户机器上找最新版 VS Code 扩展 **`actboy168.lua-debug`**，读出它的 `script/debugger.lua`，注入一个定制 `package.loadlib` 后执行：

```lua
local dbg = init_debug(PATH)
dbg:start("127.0.0.1:"..PORT)
```

即 YDWE **直接复用 actboy168/lua-debug 的调试器核心**（DAP 协议），VS Code 作为客户端。注意 YDWE 从**磁盘上的扩展目录**加载——那是编辑器场景；我们是地图内嵌场景，应把调试器资源**打包进 MPQ**（单地图自包含）。

### 1.3 我们的现状

- `src/src/lua_engine/lua_engine/libs_runtime.cpp:10`：`debugger::open(L, port)` 是空 stub。
- `runtime.debugger = LUA_NOREF` 配置槽已存在（libs_runtime.cpp:17）。
- 引擎已具备全部前置条件：惰性初始化、`fix_baselib`、safe_call、trampoline 回调链、60/60 测试基线。

### 1.4 目标

1. 提供与内置 JAPI 形状一致的调试入口：`(require "jass.debugger").listen("127.0.0.1", 4278)`。
2. 支持 VS Code 连接，实现：断点、单步（over/into/out）、暂停、调用栈、变量查看（局部/upvalue/表）、表达式求值。
3. 默认关闭，只在开发期启用；单机调试用途（联机会冻结同步，明确声明）。

---

## 2. 方案选型

| 方案 | 协议 | 客户端 | 工作量 | 风险 |
|---|---|---|---|---|
| **A. 复用 actboy168/lua-debug 调试器核心** | DAP | VS Code（现成） | 中 | 其依赖闭包（是否有 native 组件、5.4 兼容）需 P0 验证 |
| B. mobdebug.lua（ZeroBrane 核心） | mobdebug 私有协议 | ZeroBrane / VS Code 插件 | 中低 | 纯 Lua + luasocket，依赖闭包清晰；但协议客户端生态弱于 DAP |
| C. 自研最小行协议 | 私有文本协议 | 需自写 | 低（协议侧） | 无 IDE 生态，变量查看/断点管理都要自写，长期成本高 |

**推荐：A 为主、B 兜底、C 不做。**

理由：内置 JAPI 与 YDWE 都指向 actboy168/lua-debug 生态（YDWE 是直接用它的源码；内置 JAPI 的 `jass.debugger.listen` 形状与其 `dbg:start` 高度相似）；DAP 意味着 VS Code 零自研客户端。actboy168/lua-debug 是 MIT 协议，可嵌入分发。

**P0 必须先验证的事实**（决定 A/B 走向）：

1. actboy168/lua-debug 的 `script/debugger.lua` 依赖闭包：是否含 native 组件（如 `remotedebug`/`luadebug` C 库）？若有，其职责（socket？hook 管理？）能否用我们的 C 侧替代或其源码可直接编译进 yd_japi.dll？
2. 对 Lua 5.4 的兼容版本要求。
3. 若闭包不可行 → 转方案 B（mobdebug.lua 单文件 + 我们提供 `socket.core` C 模块）。

---

## 3. 总体架构

```
VS Code (DAP 客户端)
   │  TCP 127.0.0.1:4278
   ▼
┌──────────────────────────── yd_japi.dll ───────────────────────────┐
│  C++ 层：libs_debugger.cpp（新）                                     │
│    ├─ winsock2 传输：listen/accept/recv/send（全非阻塞）              │
│    ├─ jass.debugger 模块注册（package.preload）                     │
│    └─ 调试事件循环驱动（lua_sethook count hook 轮询）                 │
│  Lua 层（打包进 MPQ：script\debugger\…）                             │
│    ├─ socket shim：把 C 传输适配成调试核心期望的 socket 接口           │
│    └─ 调试核心：actboy168 debugger.lua（方案A）或 mobdebug.lua（B）   │
└────────────────────────────────────────────────────────────────────┘
   ▲ lua_sethook（line/count）+ lua_getstack/lua_getlocal 等 Debug API
   │
war3map.lua 用户代码（被调试对象）
```

### 3.1 组件划分

| 组件 | 位置 | 职责 |
|---|---|---|
| `libs_debugger.cpp` | `src/src/lua_engine/lua_engine/`（新增，登记进 CMakeLists 与 `open_lua_engine.cpp` 的 preload 清单） | winsock2 封装；`jass.debugger` C 模块；count hook 轮询器 |
| socket shim（Lua） | `map/lib/debugger/socket_shim.lua`（或 C 侧直接实现该接口，二选一，见 3.4） | 统一 socket 接口：`connect/listen/accept/send/recv/select`，全部非阻塞 |
| 调试核心（Lua） | `map/lib/debugger/core/…`（随打包注入 MPQ `script\debugger\`） | DAP 协议状态机、断点表、栈/变量检查（复用第三方，不自研） |
| 打包集成 | `tools/pack.ps1` 增加 `-WithDebugger` 开关 | 把调试器 Lua 资源复制进 `build/work/script/debugger/` 并更新 listfile |
| runtime 配置 | `libs_runtime.cpp` | `runtime.debugger` 语义定型（见 3.3） |

### 3.2 C++ 传输层设计（libs_debugger.cpp）

- 依赖：仅 `winsock2`（`ws2_32.lib`，Windows 系统库，游戏进程已加载——直接 `GetProcAddress` 或链接导入均可，选链接导入，简单）。
- 模块面（`require "jass.debugger"` 返回的表）：

| 函数 | 语义 |
|---|---|
| `listen(host, port) → true/nil,err` | 创建监听 socket（非阻塞），SO_REUSEADDR；只接受 127.0.0.1 |
| `close()` | 关闭监听与已接入连接 |
| `connected() → boolean` | 是否已有调试客户端接入 |
| `accept() → conn/nil` | 非阻塞接受（select 0 超时） |
| `conn:send(str)` / `conn:recv(maxlen) → str/nil` | 非阻塞读写，读不到返回 nil（不等待） |
| `poll() → event?` | 内部使用：在 count hook 中驱动"接受连接/收包" |

- 线程模型（**本设计最关键约束**）：
  - **不创建任何工作线程**。全部 socket 操作非阻塞，由两个轮询点驱动：
    - `lua_sethook(LUA_HOOKCOUNT, N)`：每 N 条 Lua 指令触发一次 → poll socket（接受连接、把收到的字节喂给调试核心）。
    - 断点/暂停命中时：在 line hook 内进入**调试暂停循环**——循环 poll socket、执行调试核心命令，直到收到 continue/step 才返回。此时游戏画面冻结（断点语义的正确体现；联机会掉线，文档声明单机专用）。
  - N 建议 1000（可配 `runtime.debugger_poll_interval`）；调试核心未激活时 count hook 不安装，零开销。
- 崩溃防护：所有 socket 调用包 SEH；`WSACleanup` 不需要（进程级借用）；端口占用时 `listen` 返回错误而非异常。

### 3.3 Lua API 与 runtime 配置

对齐内置 JAPI 调用形状 + 我们的 runtime 惯例：

```lua
-- 形状 1：与内置 JAPI 完全一致
(require "jass.debugger").listen("127.0.0.1", 4278)

-- 形状 2：runtime 配置（推荐用户用法，war3map.lua 顶部）
local runtime = require "jass.runtime"
runtime.debugger = 4278        -- 端口号；nil/false 关闭（默认）
-- 引擎在 war3map.lua 加载完成后检查 runtime.debugger，非空则自动 listen
```

`runtime.debugger` 的语义从当前的 `LUA_NOREF` 占位改为**端口号（number）**，`false` 显式关闭。实现点：`lua_loader::load_script()` 执行完 war3map.lua 后读取该值并调用 `jass.debugger.listen`。

### 3.4 调试核心接入（方案 A 主线）

1. P0 验证后，将 actboy168/lua-debug 的 `script/` 下**纯 Lua 部分**复制到 `map/lib/debugger/core/`（保留其 license 头）。
2. 其 socket 依赖由 3.2 的 C 传输层经 shim 满足：shim 暴露与调试核心期望一致的函数表（若核心要求 luasocket 接口，则 shim 实现 `socket.core` 的子集：`tcp()/bind/listen/accept/send/receive/select/setnonblock`）。
3. 若核心含 native 组件：评估其源码（同 MIT）直接编进 yd_japi.dll，或用 Lua 等价物替换；不可行则落方案 B。
4. 入口对齐：

```lua
-- jass.debugger.listen 的内部实现（C 调 Lua）
local core = require "debugger.core.debugger"  -- MPQ 内路径经 package.path 注入
core:start("127.0.0.1:" .. port)
```

`package.path` 在 `open_lua_engine` 初始化时加入 `script\debugger\?.lua`（走 jass.storm 的 MPQ 读取——需要给 `package.searchers` 注册一个 MPQ loader，这本身就是顺带产出的通用能力）。

### 3.5 打包集成

- `tools/pack.ps1 -WithDebugger`：把 `map/lib/debugger/**` 复制到 `build/work/script/debugger/**` 并更新 `(listfile)`（默认关，避免给发布地图带调试面）。
- 无需改 war3map.j。

### 3.6 安全

- 只绑定 127.0.0.1（硬编码校验 host 参数）。
- 默认关闭（runtime.debugger 默认 nil；pack 默认不带资源）。
- `JAPI_DEBUG` 编译宏外再加 `JAPI_ENABLE_DEBUGGER` 宏（默认开），发布构建可整体剔除 C 模块。

---

## 4. 分阶段实施计划

| 阶段 | 内容 | 验收 | 预估 |
|---|---|---|---|
| **P0** | 调研 actboy168/lua-debug 依赖闭包（native 组件有无/职责、5.4 兼容、MIT 头），定 A/B | 结论写入本文档附录 | 0.5d |
| **P1** | `libs_debugger.cpp`：winsock 传输 + `jass.debugger` 模块（listen/accept/send/recv）+ count hook 轮询；echo 自测（nc 连 4278 收发） | 自测通过 + 60/60 不回归 | 0.5–1d |
| **P2** | socket shim + MPQ package loader；调试核心装入 MPQ 并完成 DAP handshake（VS Code attach 成功） | VS Code 连接成功 | 1–2d |
| **P3** | 断点、单步 over/into/out、暂停/继续 | war3map.lua 里打断点可停可续 | 1–2d |
| **P4** | 调用栈、局部/upvalue/表查看、表达式求值 | IDE 面板数据正确 | 1d |
| **P5** | `-WithDebugger` 打包开关、runtime.debugger 配置、文档与 AGENT.md 更新 | 全流程走通 | 0.5d |

每阶段结束跑 `deploy.ps1` 保证 60/60 基线不回归。

---

## 5. 风险与开放问题

1. **断点冻结与网络同步**：暂停循环冻结游戏帧——战网/局域网必然掉线，**仅单机调试**。文档必须在用户面声明。
2. **hook 性能**：count hook 每 N 指令一次回调，N 过小会明显拖慢；激活调试时接受该开销，未激活零开销。
3. **重入**：调试暂停循环运行在 JASS→Lua trampoline 回调栈内，期间若游戏再次进入 Lua（不可能——单线程，hook 内不返回即冻结），无重入；但调试核心自身 error 必须 pcall 隔离，防止把 hook 状态弄炸。
4. **Lua 5.4 差异**：第三方调试核心对 5.4 的 `lua_Debug` 字段/尾调用语义兼容性，P0 确认版本。
5. **actboy168 核心 native 依赖**：若 socket 之外的 native（如 C 侧 hook 管理）不可替代，方案 B（mobdebug）兜底，验收标准不变。
6. **MPQ package loader 是新增通用能力**：要留意与 `jass.storm` 的缓存/释放语义一致（load_file/unload_file 配对）。

---

## 6. 验证方法

- P1：`deploy.ps1` 后 `Test-NetConnection 127.0.0.1 -Port 4278` + 手工收发。
- P2+：VS Code 安装 `actboy168.lua-debug`，`launch.json` 用 `attach` + `127.0.0.1:4278`；测试地图的 war3map.lua 里下断点。
- 回归：每阶段 60/60。

---

## 附录 A：P0 调研结论（2026-07-28，已定稿）

### A.1 依赖闭包（实证）

actboy168/lua-debug（MIT，仓库 master @ 2026-06-16，官方 VSIX 实证）的调试端依赖 = **1 个 native 核心 + 1 棵纯 Lua 脚本树**：

1. **`luadebug.dll`（native，必须）**：官方 VSIX 提供 `extension/runtime/win32-ia32/lua54/luadebug.dll`（561KB，2026-06-16 构建）。
   - 导出 15 个符号：`init`、`luaopen_luadebug`、`luaopen_luadebug_{hookmgr,stdio,utility,visitor}`、`luaopen_bee_{channel,epoll,filesystem,platform,select,socket,sys,thread,windows}`。
   - 导入：WS2_32/USER32/dbghelp/ntdll/MSVCP140/VCRUNTIME140/api-ms-win-crt-*——**不依赖 lua54.dll**（master VM 由 onelua 内嵌）。
   - 与 Lua 版本的解耦方式：`init` 通过 `GetProcAddress(调用方模块, "lua_newstate")` 自动定位宿主 Lua API（`src/luadebug/rdebug_init.cpp` / `rdebug_win32.cpp` 实证）。
2. **`extension/script/`（纯 Lua，必须）**：`debugger.lua`（入口）、`backend/{bootstrap,worker,master/**}`、`common/{socket,net,protocol,json,ipc,log}`、`frontend/`、`bootstrap.lua`。无任何额外 native 依赖（socket 由 luadebug.dll 的 bee 模块提供）。
3. **Lua 5.4 支持**：`debugger.lua` 有 lua54 运行时分支；worker 含 `disassemble/lua54.lua`。✓

### A.2 线程模型（与设计假设的核对）

master（网络 IO + DAP 状态机）运行在 luadebug.dll 内部的**独立 OS 线程 + 独立 Lua VM**；worker（hook 回调、栈/变量检查）运行在游戏线程的宿主 VM 内。网络阻塞 IO 从不发生在游戏线程；断点暂停 = worker hook 回调内等待 master 消息，冻结即断点语义。**与我们单线程引擎兼容，不需要自建 winsock 层。**

### A.3 关键路线决策：B1（预编译二进制）+ 导出宿主 Lua API

1. yd_japi.dll **导出 Lua C API**（.def 列出 `lua_*`/`luaL_*`）——luadebug.dll 的 `init` 即可自动找到我们静态内嵌的 Lua 5.4（这正是 YDWE 当年走通的路径）。
2. `luadebug.dll` 已入库 `tools/debugger/`（MIT，附 `LICENSE.lua-debug`）；运行时经 MPQ 提取到游戏目录后 `package.loadlib`（wenhao_plugin 资源提取模式）。
3. `extension/script/` 已入库 `tools/debugger/script/`，打包时注入 MPQ `script\debugger\`。
4. B2（把 `src/luadebug` 源码编进 yd_japi）留作后续硬化选项：去除二进制依赖，但需移植 luamake 构建（bee + onelua + thunk），工作量大，暂不投入。

### A.4 对原计划的调整（第一次调整）

- **原 P1（自建 winsock 传输 + jass.debugger 模块 + echo 验证）作废**——luadebug.dll 的 bee 已提供全部传输能力，自建是重复劳动。
- **新 P1**：yd_japi 导出 Lua API（.def）→ MPQ 携带并运行时提取 luadebug.dll → `libs_debugger.cpp` 完成 loadlib + `init` + `dbg:start("listen:127.0.0.1:4278")` 接线 → deploy 后端口监听可连（Test-NetConnection）+ 60/60 不回归。
- P2 随之简化为：script 资源的 MPQ 路径解析（`package.cpath` 推导 root 的 bootstrap.lua 需要磁盘路径前缀，设计 MPQ searcher 与 LUA_DEBUG_PATH 的映射）+ DAP handshake。
- P3–P5 不变。

### A.5 A 方案遗留风险（P2/P3 处理）

- worker 的 `filesystem.lua` 按**磁盘路径**读源文件做断点校验；我们的源在 MPQ 里——P3 需设计 source 映射（断点挂到 `script\war3map.lua` 的 chunk 名，或让 worker 读 MPQ）。
- `bootstrap.lua` 从 `package.cpath` 反推 root，要求 cpath 里是磁盘路径——luadebug.dll 提取到磁盘后自然满足，但 MPQ 内 script 树需要 package.path 注入（P2）。
- MSVCP140/VCRUNTIME140 依赖：开发机有；用户机器依赖 VS 2015-2022 redist（普遍已装），发布说明中标注。

---

## 附录 B：第二次方案调整（P2 期间，2026-07-28）

**原计划 P2 的"MPQ 路径解析"工作项作废。** 理由：P1 采用的"先从 MPQ 整体提取到 `<war3>/japi-debugger/` 磁盘目录、再从磁盘加载"的设计，使 debugger.lua 的 root 推导（`selfsource` → `root/script/?.lua`）与 master 线程的全部文件读取**原生工作在磁盘上**——不再需要 MPQ package searcher 注入，也不需要 LUA_DEBUG_PATH 映射。MPQ 在此方案中只承担"运输容器"角色（与 wenhao_plugin 的 .rsrc 资源模式同构）。

实施中发现的另一个修正点：`os.getenv` 读取的是 **CRT 环境**而非 Win32 环境，`SetEnvironmentVariableA` 对其无效，`LUA_DEBUG_CORE` 必须用 `_putenv_s` 注入（`libs_debugger.cpp`）。

## 附录 C：验证记录

| 阶段 | 验证项 | 结果 |
|---|---|---|
| P1 | `objdump yd_japi.dll` 导出含 `lua_newstate`/`luaL_newstate` | ✓ |
| P1 | MPQ 提取 52/52 文件到 `japi-debugger\`；`dbg:start` 无错 | ✓（首次失败=_putenv 问题，已修） |
| P1 | 游戏存活期间 `netstat`：`TCP 127.0.0.1:4278 LISTENING` | ✓ |
| P1 | 60/60 测试不回归 | ✓ |
| P2 | `tools/dap_probe.py 4278 handshake`：`initialize` 响应含完整 capabilities | ✓ |
| P2 | `... attach`：`initialized` 事件 + `attach` success + `configurationDone` success | ✓ |

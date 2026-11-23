<div align="center">

# jimu-japi

**面向 Warcraft III 1.27a 的自包含 Lua 5.4 引擎、底层 JAPI 运行时与地图开发者 SDK**

[![Version](https://img.shields.io/badge/version-v0.6.0-blue.svg)](CHANGELOG.md)
[![Target](https://img.shields.io/badge/War3-1.27a%20(6374)-orange.svg)](docs/STATUS.md)
[![Stack](https://img.shields.io/badge/stack-C%2B%2B%20%7C%20Rust%20%7C%20Lua%205.4-brightgreen.svg)](AGENTS.md)
[![License](https://img.shields.io/badge/license-GPL--3.0%20%2F%20Notices-lightgrey.svg)](THIRD-PARTY-NOTICES.md)

[快速开始](#快速开始) · [核心特性](#核心特性) · [代码示例](#代码示例) · [架构与生态](#架构与生态) · [模块速查](#模块速查) · [文档导航](#文档导航) · [维护者构建](#维护者构建)

</div>

---

`jimu-japi` 通过纯 MPQ 单文件（`japi.tga`）为 Warcraft III 1.27a 地图注入完整的 Lua 5.4 运行时与底层扩展能力，并提供零依赖 Rust 开发者命令行工具 `japi.exe`、自动 Tree-Shaking 的 `std.*` 标准库以及通用的响应式 `DzFrame` UI 框架，与 WE / YDWE / KKWE / KKAPI 宿主生态安全共存。

## 核心特性

- **纯地图自包含（单文件 `japi.tga`）**：无需玩家额外安装客户端插件；自动生成兼容 WE / YDWE / KKWE 重新保存的 `war3map.imp` 与引导触发器，不丢资源、不破坏原有触发器。
- **零依赖单文件 CLI（`japi.exe`）**：Rust 静态编译，一条命令完成 `doctor` / `new` / `check` / `build` / `run` / `kill`，内置静态 `require` 循环/缺失校验与 1.27a 进程 `DENY-DACL` 安全回收。
- **高性能 Lua 5.4 与联机帧同步确定性**：
  - `luaL_newstate2` 绑定 War3 `SetRandomSeed` 全局同步种子，确定性 `table.sort` 与 `math.random` 路由。
  - C++ ↔ Lua 热路径栈上 16 槽零堆分配 + native 闭包缓存 + 预解析 `fast_spec` 分发；1.27a 实机 `20,000` 次 `GetUnitX` 仅 **`4.66 ms`（~233 ns/次）**，`5,000` 次 `EXGetObject` 仅 **`2.31 ms`（~462 ns/次）**。
- **原生 1.27a `CStatBar` 血蓝条（16 API）**：纯 `CStatBar` 虚表钩子实现单位 / 单位类型 / 玩家三级血条染色、缩放、显隐与零延迟原生蓝条，并内置 `EXSetOffscreenBarCull` 修复离屏贴边与幽灵血条残留。
- **自动 Tree-Shaking `std.*` 标准库 & 通用响应式 `DzFrame` UI**：
  - `japi build` 按实际 `require` 自动裁切打包，项目本地 `std/xxx.lua` 优先覆盖。
  - 3 层通用 UI 架构（`std.signal` → `std.frame` → `std.ui`）：零业务假设、零写死皮肤，自动发现宿主 KKAPI `DzFrame*`，固定事件槽零 trampoline 泄漏，支持 `Show` / 池化 `For` / `component` / `provide` & `use`。
- **零重启 D3D9 渲染 & 完整 1.27a 扩展面**：
  - 支持 `AttachInProcessD3D9` 首局零重启渲染与传统 `d3d9.dll` 代理，支持 `asset://` / `game://` BLP1/BLP2/PNG 内存加载与输入事件订阅。
  - 19 个内置 `jass.*` 模块：含 41+ 真 EX* JASS native、`jass.ai`（124 个 `common.ai` native）、`jass.slk` 物编合并、`jass.storm` 路径替换、`jass.map_event`（`brokenNetwork`）、Storm#279 内存命令卡图标、`objects.lua` 代码化物编与 DAP 断点调试器（`127.0.0.1:4278`）。

## 快速开始

地图开发者直接解压发行版 SDK 包（零外部依赖，仅需本机已有 War3 1.27a）：

```powershell
# 1. 检查本机 War3 1.27a 与工具链状态
.\japi.exe doctor

# 2. 创建干净的新地图工程
.\japi.exe new MyMap --path D:\maps

# 3. 静态校验 require 依赖（支持循环/缺失检查）
.\japi.exe check D:\maps\MyMap --strict-requires

# 4. 自动 Tree-Shaking std.* 并打包为单 TGA 地图
.\japi.exe build D:\maps\MyMap

# 5. 部署到 War3 1.27a 并启动运行
.\japi.exe run D:\maps\MyMap
```

> 详细图文入门、目录约定与排障见 [SDK-QUICKSTART.md](docs/guide/SDK-QUICKSTART.md)。

## 代码示例

下面是一段完整的地图脚本：启用原生 1.27a 蓝条与离屏血条修复，并用 `std.ui` 挂载一个细粒度响应式的 `DzFrame` 面板（仅更新变化的文本节点，无虚拟 DOM 重建）：

```lua
local StatBar = require "std.statbar"
local Timer   = require "std.timer"
local UI      = require "std.ui"

-- 1. 启用原生 1.27a CStatBar 蓝条 + 离屏/幽灵血条清理
StatBar.apply_theme("rpg")

-- 2. 响应式状态（仅驱动绑定属性，零整树重绘）
local gold  = UI.state(100)
local label = UI.computed(function()
    return "Gold: " .. tostring(gold:get())
end)

-- 3. 声明式 DzFrame UI（自动对接宿主 KKAPI DzFrame*）
UI.mount(
    UI.Box {
        anchor = "TOPRIGHT", x = -0.02, y = -0.04, w = 0.16, h = 0.08,
        UI.Column {
            gap = 0.006, padding = 0.008,
            UI.Text   { text = label, w = 0.14, h = 0.024 },
            UI.Button {
                text = "+50 Gold", w = 0.14, h = 0.028,
                on_click = function()
                    gold:set(gold:peek() + 50)
                end,
            },
        },
    }
)

-- 4. 池化零泄漏定时循环
Timer.loop(1.0, function()
    gold:update(function(v) return v + 1 end)
end)
```

更多完整可打包示例位于 [`examples/`](examples/)（共 12 个独立工程，覆盖输入 hook、D3D HUD、单位命令、SLK、代码化物编、JASS wrapper 与 UI 组件）。

## 架构与生态

```text
war3map.j（标准 JASS，兼容 WE / YDWE / KKWE 保存）
  └→ JapiBootstrap
       ├→ StartCampaignAI(Player(12), "callback")
       │    └→ 加载单文件 japi.tga (yd_japi.dll)
       │         ├→ inline hook UnitId（预解析 fast_spec 哈希表 RPC）
       │         ├→ table_hook ExecuteFunc（惰性启动 Lua 5.4 VM + 同步随机种子）
       │         ├→ 注册 EX* native / CStatBar 钩子 / Storm#279 内存图标 / 进程内 D3D9
       │         └→ 同进程换图时自动关闭旧 VM 与 D3D session
       └→ jass.japi 动态扫描活 native 表
            └→ 自动发现 KKWE / KKAPI 注册的 DzFrame* / Dz* / KK*，由 std.frame / std.ui 驱动
```

| 生态组件 | 与 `jimu-japi` 的关系 |
|---|---|
| **YDWE** | 底层 C++ 核心源码谱系来源（`yd_core` / `base` / `slk` / `lua_engine` / 部分 `ex_natives` / `PasButton`，改编为游戏内 callback 模式，遵循 GPL-3.0） |
| **KKWE / KKAPI** | 宿主平台插件。`jass.japi` 自动发现宿主注册的 `DzFrame*`/`Dz*`/`KK*` 接口；与宿主 `yd_jass_api.dll` / `yd_lua_engine.dll` / `jass.dll` 安全共存 |
| **builtin-japi / UjAPI** | 1.27a 运行时行为与 EX* native 签名参考 |

## 模块速查

### 内置引擎模块 `jass.*`（19 个）

| 分类 | 模块 |
|---|---|
| **核心桥接** | `jass.common`、`jass.globals`、`jass.japi`、`jass.ai`、`jass.hook`、`jass.runtime`、`jass.debug` |
| **数据与资源** | `jass.slk`、`jass.storm`、`jass.ydwe`、`jass.selector`、`jass.bignum` |
| **交互与渲染** | `jass.message`、`jass.d3d`、`jass.map_event`、`jass.sleep` |
| **开发调试** | `jass.debugger`（DAP）、`jass.console`、`jass.log` |

### 自动 Tree-Shaking 标准库 `std.*`（14 个）

| 分类 | 模块 |
|---|---|
| **通用响应式 UI** | `std.signal`、`std.frame`、`std.ui`（以及备用 D3D9 渲染版 `std.d3d_ui`） |
| **游戏逻辑原语** | `std.util`、`std.timer`、`std.event`、`std.player`、`std.unit`、`std.group`、`std.effect`、`std.statbar`、`std.tween`、`std.init` |

## 维护者构建

仓库采用 `mise.toml`（Node 24 + Rust stable）+ Visual Studio 2022 Win32 Build Tools 统一编排：

```powershell
mise run setup      # 拉取锁定版本的 w3x2lni 脚本与数据并检查环境
mise run build      # 编译 Win32 Release DLL (yd_japi.dll + newD3d9.dll) + Rust japi.exe
mise run test       # 运行全部 9 套离线测试（cli / pack / object-data / selector / ui / std / ydwe-compat / d3d-contract / examples）
mise run release    # clean detached worktree 构建并产出纯净开发者 SDK 包 (build/sdk/<ver>-<sha7>/map-inject-sdk-<ver>.zip)
mise run clean      # 清理 build/ 及临时 worktree
```

实机回归（需本机 War3 1.27a）：

```powershell
node tools/dev/cli.ts test live              # 主引擎实机回归
node tools/dev/cli.ts test demo              # 波次防守 demo 实机回归
node tools/dev/cli.ts test conformance       # 原生接口一致性测试台
node tools/dev/cli.ts test examples --live   # 12 个示例实机回归
```

## 文档导航

| 文档 | 内容 |
|---|---|
| [docs/guide/SDK-QUICKSTART.md](docs/guide/SDK-QUICKSTART.md) | 地图作者快速上手：安装检查、建工程、打包、运行与排障 |
| [docs/guide/SDK-GUIDE.md](docs/guide/SDK-GUIDE.md) | `jass.*` 与 `std.*` 逐模块开发指南与常见陷阱 |
| [docs/guide/SDK-COOKBOOK.md](docs/guide/SDK-COOKBOOK.md) | 可直接套用的常见玩法配方 |
| [docs/guide/OBJECT-DATA-UI.md](docs/guide/OBJECT-DATA-UI.md) | `objects.lua` 代码化物编与 UI 实践 |
| [docs/guide/D3D-LUA-API.md](docs/guide/D3D-LUA-API.md) | `jass.d3d` 完整 API 与生命周期参考 |
| [docs/STATUS.md](docs/STATUS.md) | 当前实现完成度、实机基准、已知边界与剩余缺口（唯一状态权威） |
| [CHANGELOG.md](CHANGELOG.md) | 版本演进记录（当前 `v0.6.0`） |
| [docs/RELEASE.md](docs/RELEASE.md) | clean worktree 可溯源发版流程 |
| [AGENTS.md](AGENTS.md) | 仓库目录结构与开发协作规范 |

## 开源许可与声明

- `yd_japi.dll`（及内嵌生成的 `japi.tga`）包含提取并改编自 **YDWE（GNU GPL v3.0）** 的核心模块；对外分发源码或二进制须遵循 **GNU GPL v3.0** 协议要求。
- 全部第三方开源组件（YDWE、w3x2lni、Lua 5.4、bee.lua、lua-debug、udis86、pjass、Rust crates）与专有运行时（`D3DX9_42.dll`）的详细版权及合规说明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
- *Warcraft III* 为 Blizzard Entertainment, Inc. 的注册商标；本项目为非官方社区技术工具。

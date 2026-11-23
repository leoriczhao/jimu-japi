# map-inject — WAR3 1.27a 地图注入引擎与开发者 SDK

## 项目目标

面向 Warcraft III 1.27a，通过 callback exploit 在纯 MPQ 地图中注入自包含运行时（单文件 `japi.tga`），提供高性能 Lua 5.4 引擎、联机帧同步确定性、EX* 与 `CStatBar` 等底层扩展、零重启 D3D9 渲染、代码化物编、自动 Tree-Shaking `std.*` 标准库与通用响应式 `DzFrame` UI 框架，并与 KKWE / KKAPI / YDWE 宿主插件安全共存。

## 参考项目与宿主生态关系

```
┌───────────────────────────────────────────────────────────────────┐
│                    我们的项目 (map-inject v0.6.0)                  │
│                                                                   │
│  目标：纯 MPQ 地图自带的 Lua 5.4 引擎 + 完整 1.27a JAPI & 开发者 SDK │
│  底层谱系：从 YDWE 提取核心模块并面向游戏进程改编适配（GPL-3.0）      │
│  宿主共存：自动发现 KKWE/KKAPI 注册的 DzFrame*/Dz*/KK* native       │
└──────┬───────────────────┬──────────────────┬─────────────────────┘
       │                   │                  │
       ▼                   ▼                  ▼
  ┌─────────┐       ┌──────────────┐   ┌────────────────┐
  │  YDWE   │       │ builtin-japi │   │ KKWE / KKAPI   │
  │(源码基础)│       │(wenhao_plugin)│  │(平台 DzFrame)  │
  └─────────┘       └──────────────┘   └────────────────┘
```

| 角色 | 说明 |
|------|------|
| **YDWE** | 源码谱系来源。`yd_core`、`base`、`slk`、`lua_engine`、部分 `ex_natives` 与 `PasButton` 从 YDWE 提取并改编为 callback 模式（详见 `THIRD-PARTY-NOTICES.md` 的 GPL-3.0 声明） |
| **builtin-japi (`wenhao_plugin`)** | 游戏内运行时行为参考（逆向报告：`reference/builtin-japi/wenhao_plugin逆向分析报告.html`） |
| **UjAPI** | EX* 系列 native 函数签名参考（`reference/ujapi/UjAPI_Native参考手册.html`、`UjAPI.j`） |
| **KKWE / KKAPI** | 宿主平台插件。KKAPI 向 War3 活 native 表注册 `DzFrame*`/`Dz*`/`KK*` 等接口，我们的 `jass.japi` 自动发现它们并由 `std.frame`/`std.ui` 驱动；若宿主已加载 `yd_jass_api.dll`/`yd_lua_engine.dll`/`jass.dll`，我们的 `yd_japi.dll` 自动共存不冲突 |

## 模块总览

> 当前完成度、验证强度与剩余缺口统一维护在 `docs/STATUS.md`；本节仅列模块职责。

### 1. 内置 `jass.*` 引擎模块（19 个，`open_lua_engine.cpp`）

| 模块 | 用途 |
|------|------|
| `jass.common` | JASS 标准 native 调用（零堆分配栈缓冲 + 闭包缓存） |
| `jass.globals` | JASS 全局标量与数组读写（打包器自动预分配数组） |
| `jass.japi` | 扩展 native / bridge handler / 宿主 KKAPI (`DzFrame*` 等) 自动发现与调用，支持 Lua 侧注册与 `info`/`counts` 诊断 |
| `jass.ai` | 124 个 `common.ai` 原生 AI native 调用 |
| `jass.hook` | native hook / unhook（含安全卸载保护与闭包缓存同步） |
| `jass.runtime` | 运行时配置（`sleep`、`console`、`handle_level`、`error_handle`、`catch_crash` 等） |
| `jass.message` | 输入消息过滤（`CGameUI` 虚表 +0x10）、鼠标/选择/本地命令/命令卡按钮 |
| `jass.debug` | JASS 函数地址、`SaveFunc`/`func_bind` 标签表与调试辅助 |
| `jass.slk` | 游戏 SLK 与地图物编合并查询（支持字符串与整数 rawcode、`slk.misc`） |
| `jass.sleep` | 协程 sleep（TriggerSleepAction 集成） |
| `jass.storm` | MPQ 文件读取、保存与路径替换（`replace_path`/`clear_replace_paths`） |
| `jass.debugger` | DAP 调试器（`127.0.0.1:4278`，`actboy168/lua-debug` MIT） |
| `jass.d3d` | D3D9 渲染 SDK（Font/Text/Texture、Subscription、TTL、设备重置；支持零重启 `AttachInProcessD3D9`） |
| `jass.console` | 调试控制台输出 |
| `jass.log` | 日志输出 |
| `jass.bignum` | 大数运算 |
| `jass.map_event` | 地图/网络事件（含 `brokenNetwork` 断线切换表钩子） |
| `jass.selector` | 单位选择器扩展 |
| `jass.ydwe` | YDWE 扩展 `UnitState` 等兼容层 |

### 2. 地图开发标准库 `std.*`（14 个，`std/`，自动 Tree-Shaking）

由 `japi build` 按实际 `require` 静态分析自动打入 `war3map.lua`，项目本地同名 `std/xxx.lua` 优先覆盖：

- **通用响应式 `DzFrame` UI（3 层）**：`std.signal`（细粒度信号）→ `std.frame`（宿主 `DzFrame*` 封装，固定事件槽零 trampoline 泄漏）→ `std.ui`（声明式基础控件、布局、`Show`/`For` 池化列表、`component`、`provide`/`use`）；另保留 `std.d3d_ui` 作为 D3D9 备用。
- **游戏逻辑原语**：`std.util`、`std.timer`（池化 + 共享 33Hz `frame`）、`std.event`（惰性桥接原生事件与伤害数据）、`std.player`、`std.unit`（同句柄单例 + `u.data` 自动清理）、`std.group`（零泄漏查询）、`std.effect`、`std.statbar`（原生 1.27a `CStatBar` 血蓝条预设）、`std.tween`、`std.init`。

## 项目结构

```
map-inject/
├── AGENTS.md                   # 项目协作与架构说明（本文件）
├── THIRD-PARTY-NOTICES.md      # 第三方开源组件与 GPL-3.0 合规声明
├── CHANGELOG.md                # 版本变更日志（当前 v0.6.0）
├── mise.toml                   # 维护者统一任务入口（Node 24 + Rust stable）
│
├── src/                        ← C++ DLL 源码（Win32 Release）
│   ├── CMakeLists.txt
│   ├── build.bat               # 编译 yd_japi.dll（单 TGA 内嵌 newD3d9/D3DX9_42）与 newD3d9.dll
│   ├── src/
│   │   ├── base/               # hook 框架（IAT/EAT/inline，源自 YDWE）
│   │   ├── yd_core/            # JASS VM 布局、native 注册、udis86（源自 YDWE）
│   │   ├── slk/                # SLK / 物编解析器（源自 YDWE SlkLib）
│   │   ├── lua_engine/         # Lua 5.4 引擎、bridge_dispatch、19 个 jass.* 模块
│   │   ├── extensions/         # dllmain、EX* native、CStatBar、BuiltinCompat、brokenNetwork
│   │   ├── d3d9/               # D3D9 proxy、进程内 AttachInProcessD3D9、SDK ABI
│   │   └── image/              # BLP 解码/编码与 YDWE PasButton 图标生成
│   └── vendor/                 # lua-5.4 (MIT)、bee-lua (MIT)
│
├── cli/                        ← Rust 零依赖地图开发者 CLI（japi.exe）
│   ├── Cargo.toml
│   └── src/                    # doctor / new / check / build / run / test / proxy / kill / emit-manifest
│
├── std/                        ← 自动 Tree-Shaking 的地图开发 Lua 标准库（14 模块）
├── examples/                   ← 12 个纯净地图作者示例工程
├── map/                        ← 内部引擎回归夹具与波次防守 demo（game/ + tests/）
├── tests/                      ← 离线与一致性测试台（conformance / object-data / selector / std / ui / ydwe-compat）
│
├── tools/                      ← 维护者编排脚本与打包依赖
│   ├── dev/                    # Node 24 原生 TypeScript 维护者 CLI（cli.ts / suites.ts / release-sdk.ts 等）
│   ├── object-data/            # objects.lua 代码化物编编译器
│   ├── ydwe-compat/            # JASS UnitState 迁移工具
│   ├── callback                # StartCampaignAI 加载的 exploit 脚本
│   ├── pjass.exe               # JASS 语法校验
│   ├── debugger/               # actboy168/lua-debug (MIT)
│   └── w3x2lni/                # 地图格式转换（GPL-3.0；脚本与数据由 mise run setup 拉取）
│
├── docs/                       ← STATUS.md（唯一状态权威）、RELEASE.md、guide/、planning/
└── reference/                  ← empty-map/ 默认空白基座 + 仅作参考的 YDWE / builtin-japi / ujapi（不入 SDK 包）
```

## 运行时架构

```
war3map.j（干净的标准 JASS，兼容 WE / YDWE / KKWE 保存）
  └→ JapiBootstrap / initializePlugin()
       ├→ StartCampaignAI(Player(12), "callback")  ← 加载 exploit
       │    └→ callback 提取并加载单文件 japi.tga (yd_japi.dll) 的 Initialize()
       │         ├→ inline hook UnitId → 哈希表 RPC 分发（预解析 fast_spec）
       │         ├→ table_hook ExecuteFunc（惰性启动）+ AbilityId/Cheat exec-lua
       │         ├→ 注册真实 EX* native / CStatBar 虚表钩子 / Storm#279 内存图标
       │         ├→ 若未装 d3d9.dll 代理，从 PE .rsrc 释放并 AttachInProcessD3D9（零重启）
       │         └→ 同进程换图时 on_map_boot 彻底关闭旧 VM 与 D3D session
       ├→ UnitId(I2S(GetHandleId(japi_ht)))        ← 交付桥接表句柄
       └→ ExecuteFunc("japiDoNothing")             ← 首次触发：
            luaL_newstate2（绑定 War3 同步随机种子）+ 加载 war3map.lua + message_dispatch
```

## Callback 模式适配要点

| YDWE 原始机制 | 问题 | 改编方案 |
|---|---|---|
| `nf_register.cpp` hook StormAlloc | VM 已初始化，hook 不触发 | `nf_register::flush_add_only()` 直接触发 `nfunction_add` |
| `lua_loader.cpp` hook `war3map.j` | `war3map.j` 已执行 | `table_hook ExecuteFunc`，首次调用惰性创建 `luaL_newstate2` 并加载 `war3map.lua` |
| `yd_jass_api` 依赖编辑器信号 | 信号不会触发 | 41+ EX* 同时注册为真 JASS native 与 UnitId bridge handler，并由 `jass.japi` 自动发现宿主扩展 |
| JASS→Lua 运行时注册新 native 声明 | 地图脚本在插件加载前编译 | `UnitId` + 哈希表 RPC、自动生成 JASS wrapper，或复用引擎隐藏 native（如 `SetHeroLevels`） |
| `SetWindowLongPtr` WndProc 截输入 | 看不到游戏内消息分发 | `message_dispatch::add_filter`（`CGameUI` 虚表 +0x10）+ 窗口鼠标状态机去重 |

## 构建、测试与发布（双工具链）

### 引擎维护者（`mise.toml` + `tools/dev/cli.ts`）

```powershell
mise run setup      # 拉取锁定版本的 w3x2lni 脚本与数据并检查环境
mise run build      # 编译 C++ DLL (yd_japi.dll + newD3d9.dll) + Rust japi.exe
mise run build:dll  # 仅编译 C++ DLL (src/build.bat)
mise run build:cli  # 仅编译 Rust japi.exe (Release)
mise run test       # 运行全部 9 套离线测试（cli/pack/object-data/selector/ui/std/ydwe-compat/d3d-contract/examples）
mise run release    # clean detached worktree 构建并产出纯净开发者 SDK 包 (build/sdk/<ver>-<sha7>/map-inject-sdk-<ver>.zip)
mise run clean      # 清理 build/ 及残留 worktree
```

实机回归快捷入口：

```powershell
node tools/dev/cli.ts test live         # 主引擎实机回归
node tools/dev/cli.ts test demo         # 波次防守 demo 实机回归
node tools/dev/cli.ts test conformance  # 原生接口一致性测试台实机回归
node tools/dev/cli.ts test examples --live  # 12 个示例实机回归
```

### 地图开发者（零依赖单文件 `japi.exe`）

```powershell
.\japi.exe doctor                       # 检查 War3 1.27a 与工具链状态
.\japi.exe new MyMap --path D:\maps     # 生成纯净地图工程脚手架
.\japi.exe check D:\maps\MyMap --strict-requires
.\japi.exe build D:\maps\MyMap          # 自动 Tree-Shaking std.* + 打包单 TGA 地图
.\japi.exe run   D:\maps\MyMap          # 部署到 War3 1.27a 并启动
.\japi.exe kill                         # 安全关闭带 DACL 保护的 war3.exe
```

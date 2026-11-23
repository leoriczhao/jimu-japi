# map-inject 当前状态

> 本文件是仓库中唯一的当前完成状态来源（single source of truth）。
> `docs/planning/` 下的文件保留方案演进、阶段拆分和历史验收记录，其中的状态标记不代表当前状态。

- 最后更新：2026-11-24
- 当前版本：**`v0.6.0`**（锚点提交 `d11e9db`，已打 tag 并产出 clean SDK 包 `map-inject-sdk-0.6.0.zip`）
- 支持版本：Warcraft III 1.27a（`GetGameVersion()` = `6374`，当前偏移与实机验收版本）
- 离线工程测试台（`mise run test`，2026-11-24）：**9/9 套件全通过**（`cli` Rust 单元测试、`pack` 单 TGA/WE 兼容诊断、`object-data` 物编往返、`selector`、`ui`、`std` 13/13、`ydwe-compat` 4 步、`d3d-contract` 54/54、`examples` 12/12 静态+打包），且 Rust Release 编译零警告
- `v0.6.0` 新增能力实机验证（2026-11-24，War3 1.27a / KKWE）：
  - **C++↔Lua 热路径基准**：20,000 次 `GetUnitX` = `4.66 ms`（~233 ns/次），5,000 次 `EXGetObject` = `2.31 ms`（~462 ns/次）
  - **通用响应式 `DzFrame` UI（`std.signal` + `std.frame` + `std.ui`）**：KKWE War3 1.27a 实机 `8 passed, 0 failed`
- `v0.5.0` 新增能力实机验证（2026-11-23，War3 1.27a）：
  - 原生 1.27a `CStatBar` 血蓝条（16 API）+ `EXSetOffscreenBarCull` 离屏/幽灵血条清理、YDWE/内置 JAPI 7 项 1.27a 对齐（`luaL_newstate2` 确定性、`AbilityId("exec-lua:...")`、`UnitState` 13 个真 native + `EXGetObject`、`jass.ai` 124 native、`brokenNetwork`、零重启进程内 D3D9 `AttachInProcessD3D9`、`jass.storm.replace_path`）全部在 War3 1.27a 实机通过
- 历史全量实机基线（最近一次全套实机复跑记录，架构重构前/0.4.0–0.5.0 期间）：
  - 普通引擎实机回归：`122 passed, 0 failed, 122 total`（含 JASS↔Lua bridge、数组预分配 `jass.globals`、`SaveFunc`/`func_bind`）
  - JASS wrapper / GetFuncAddr 回归：`125/125`（`--with-jass-wrappers`）、`126/126`（`--with-get-func-addr`）
  - 原生接口一致性测试台（`tests/conformance`）：`199 passed, 0 failed, 4 skipped`（2026-11-17）
  - D3D 实机交互回归：`170 passed, 0 failed, 170 total`（普通基线 122 + D3D 48，54/54 handler 覆盖 + 20 次真实 resize reset）
  - 地图级 VM 重启回归：`10 passed, 0 failed, 10 total`（同进程换图 + 事件重入删除清理）
  - 波次防守 demo 回归：`27 passed, 0 failed, 27 total`（2026-11-22，引擎原生头顶血条）
  - 12 个示例实机回归：10 例基础示例（2026-11-16 全部 `0 failed`）+ 例 11 物编 `4/4` / 例 12 UI `3/3`（2026-11-18）
- 默认测试场景：64×64 平坦空图（`reference/empty-map/`），无基地/野怪/树木，仅保留 1 个 10 级英雄火枪手 `Hrif`
- 验收入口：先运行 `mise run build`，再按第 4 节选择离线套件或实机回归

## 1. 总览

| 功能域 | 实现状态 | 验证状态 | 结论 |
|---|---:|---:|---|
| callback 注入、单 TGA 加载、VM 惰性启动与地图级重置 | 完成；`yd_japi.dll` PE `.rsrc` 内嵌 `newD3d9.dll` + `D3DX9_42.dll` 合并为单文件 `japi.tga`；自动写 WE/KKWE 兼容 `war3map.imp`/`wtg`/`wct` | 离线 `pack` 诊断 + War3 1.27a 实机 + 同进程换图 10/10 | **可用** |
| Lua 引擎模块（`jass.*`） | **19/19**（`common`/`globals`/`japi`/`hook`/`runtime`/`message`/`debug`/`slk`/`sleep`/`storm`/`debugger`/`d3d`/`console`/`log`/`bignum`/`map_event`/`selector`/`ydwe`/`ai`） | 离线 + 实机 + conformance A–N 组 + 0.5.0 实机复核 | **可用** |
| 联机帧同步确定性与热路径性能 | `luaL_newstate2` 绑定 War3 `SetRandomSeed` + 确定性 `table.sort` + `math.random` 路由 War3 RNG；`call_param` 栈上 16 槽零堆分配 + native 闭包缓存 + `bridge_dispatch` 预解析 `fast_spec` + `lightuserdata` handle 键 | 1.27a 实机热路径基准（20k `GetUnitX` = 4.66 ms，5k `EXGetObject` = 2.31 ms） | **可用**（2–4 人联机长局压力实测待补） |
| 原生 1.27a `CStatBar` 血蓝条（16 API） | 纯 `CStatBar` 虚表钩子实现单位/类型/玩家级血条染色、缩放、显隐与零延迟原生蓝条 + `EXSetOffscreenBarCull` 离屏/幽灵血条清理 | War3 1.27a 实机通过（0.5.0） | **可用** |
| YDWE / 内置 JAPI / KKAPI 1.27a 兼容 | 41+ EX* 注册为真 JASS native + 80+ bridge handler；`AbilityId`/`Cheat("exec-lua:...")`；`jass.ai` 124 native；`brokenNetwork` 断线钩子；`jass.storm.replace_path`；Storm#279 内存虚拟图标；`jass.japi` 自动发现宿主 KKAPI `DzFrame*`/`Dz*`/`KK*` 并与宿主插件安全共存 | 离线 `ydwe-compat` 4 步 + 1.27a 实机（0.5.0）+ KKWE `DzFrame` 实机 8/8（0.6.0）；命令卡动态换图视觉实机待补 | **可用** |
| D3D9 渲染 SDK（`jass.d3d`） | 支持传统 `d3d9.dll` proxy 与**零重启进程内 `AttachInProcessD3D9`**；提供 Font/Text/Texture、统一渲染队列、D3DXFont alpha、`asset://`/`game://` BLP1/BLP2/PNG 内存加载、Subscription 统一输入、TTL、`resize`/`device_reset` 生命周期 | 原生 ABI 1000 轮 + `d3d-contract` 54/54 + 实机 D3D 170/170 + 0.5.0 零重启实机通过 | **可用**（保留限制见 §3） |
| 地图开发标准库 `std.*`（14 模块） | `std.util`/`timer`/`event`/`player`/`unit`/`group`/`effect`/`statbar`/`tween`/`d3d_ui`/`init` + 3 层响应式 `DzFrame` UI（`std.signal`/`std.frame`/`std.ui`）；`japi build` 自动按需 Tree-Shaking，项目本地同名 `std/xxx.lua` 优先覆盖 | 离线 `std` 13/13 + KKWE 1.27a 实机 `std.ui` 8/8（0.6.0） | **可用** |
| Lua DAP 调试器（`jass.debugger`） | `actboy168/lua-debug`（MIT），P0–P5 完成（`127.0.0.1:4278`） | attach、断点、单步、栈、变量、求值实测 | **可用**（需 `--with-debugger`） |
| 代码化物编（`objects.lua`） | `tools/object-data` 按真实元数据生成 `.w3u`/`.w3a`，保留基座记录，声明文件不进游戏 Lua | 离线 `object-data` 往返 + 例 11 实机 4/4 | **可用**（覆盖单位/技能明确字段子集） |
| 零依赖开发者 CLI 与纯净 SDK 包 | Rust 静态单文件 `japi.exe`（`doctor`/`new`/`check`/`build`/`run`/`test`/`proxy`/`kill`）；`mise run release` clean worktree 产出纯净 `map-inject-sdk-0.6.0.zip`（11.2 MB，零测试可执行程序/零断言脚手架/12 示例/阶梯文档/第三方许可声明） | 离线 `cli` + `pack` + `examples` 12/12 + 0.6.0 clean SDK 包生成与审计 | **可用** |
| 可玩垂直切片（波次防守 demo） | `map/game/wave.lua` + `demo.lua`：5 波进攻、基地血量、胜负与 `R` 重开、暴风雪 `Q`、D3D HUD、引擎原生头顶血条、伤害数字 | 实机 27/27（2026-11-22） | **可用，作为玩法样板** |
| 外来地图接入 / Wrapper / GetFuncAddr | 自动 bootstrap 注入 + `pjass` 校验；`japi.exe` 支持 `--with-jass-wrappers` 与 `--with-get-func-addr`（`SetHeroLevels` 隐藏 native 取址） | 外来图 11/11；wrapper 125/125；GetFuncAddr 126/126 | **可用**（opt-in） |

## 2. 已交付功能

### 2.1 工具链与加载架构（v0.5.0 – v0.6.0）

- **双工具链分离**：
  - 引擎维护者：`mise.toml` 锁定 Node 24 + Rust stable，`node tools/dev/cli.ts` 统一驱动 `setup`、`build`、`test`（9 套离线测试）、`release`（detached clean worktree 构建 + SHA-256 + zip）、`clean`。
  - 地图开发者：零依赖单文件 `japi.exe`，支持 `doctor`、`new`、`check`、`build`、`run`、`proxy`、`kill`（内置 War3 1.27a DENY-DACL 修复与 Job Object 收尸）。
- **单文件 `japi.tga` 与 WE/KKWE 兼容**：`yd_japi.dll` 在构建时通过 PE `.rsrc` 内嵌 `newD3d9.dll` 与 `D3DX9_42.dll`，打包到地图只需单个 `japi.tga`；同步写入 `war3map.imp` 与 `war3map.wtg/wct` 引导触发器，用 WE / YDWE / KKWE 重新保存地图不会丢脚本或资源。
- **Lua 打包器与自动 Tree-Shaking**：`cli/src/lua_bundler.rs` 基于标准 `package.preload`，支持任意缩进/括号/条件 `require`、循环依赖与缺失模块检测（`--strict-requires`），并自动从 SDK `std/` 按需打包被 `require` 的标准库模块（项目本地 `std/` 同名文件优先覆盖）。
- **纯净 SDK 发行包**：`sdk/bin/` 不包含任何 C++ 测试可执行文件，`japi new` 产出干净空白工程，`examples/` 12 个示例不含内部断言 harness，`sdk/` 附带 `CHANGELOG.md` 与 `THIRD-PARTY-NOTICES.md`。

### 2.2 引擎核心、性能优化与 1.27a 对齐

- **19 个内置 `jass.*` 模块**：在原有 15 模块基础上补齐 `jass.map_event`（含 `brokenNetwork` 断线切换表钩子）、`jass.selector`、`jass.ydwe`（47 个 YDWE 扩展 `UnitState` 兼容）与 `jass.ai`（124 个 `common.ai` native）。
- **联机帧同步确定性**：使用 `luaL_newstate2` 绑定 War3 `SetRandomSeed` 全局同步种子，`table.sort` 采用确定性枢轴，`math.random`/`math.randomseed` 路由到 War3 RNG。
- **C++ ↔ Lua 热路径零堆分配优化（v0.6.0）**：
  - `jass::call_param` 使用 `kInlineCap = 16` 栈上内联缓冲，消除常规 native 调用的 `std::vector` 堆分配。
  - `jass.common` / `jass.japi` / `jass.ai` 首次查找后缓存 CClosure 到模块表（与 `jass.hook` 同步失效/更新）。
  - `bridge_dispatch` 注册时预解析扁平 `fast_spec` 并用稳定指针 upvalue 直达，`class_handle` 改用 `lightuserdata` 注册表键。
  - War3 1.27a 实测：20,000 次 `GetUnitX` 耗时 `4.66 ms`（~233 ns/次），5,000 次 `EXGetObject` 耗时 `2.31 ms`（~462 ns/次）。
- **原生 1.27a `CStatBar`（16 API）**：纯虚表钩子实现单位/单位类型/玩家三级血条染色、缩放、显隐与原生零延迟蓝条；`EXSetOffscreenBarCull` 修复 1.27a 离屏血条贴边与幽灵血条残留。
- **宿主生态共存**：`jass.japi` 动态查找 War3 活 native 表，自动发现 KKWE/KKAPI 注入的 `DzFrame*`/`Dz*`/`KK*` 接口；与宿主 `yd_jass_api.dll` / `yd_lua_engine.dll` / `jass.dll` 共存时不冲突。
- **零重启 D3D9**：既支持游戏目录 `d3d9.dll` 代理，也支持在未预装代理时由 `AttachInProcessD3D9` 就地挂钩当前进程的 `Reset`/`EndScene`，首局即可使用 `jass.d3d` 与传统 D3D handler。
- **内存虚拟图标与 `storm.replace_path`**：`EXDclareButtonIcon` / `EXBlendButtonIcon` 通过 Storm#279（`SFileLoadFile`）IAT detour 内存供图，支持同局刷新，地图重启时自动清空状态；`jass.storm.replace_path` 支持运行时资源路径重定向。
- **JASS 侧通道与诊断**：支持数组全局预分配（`JapiForceAllocArrays`）、`SaveFunc` / `func_bind_trigger_name`、JASS 五部曲 wrapper 自动生成、`SetHeroLevels` 隐藏 native 取址、`jass.japi.info/counts` 活注册表诊断与 `jass.hook.unhook` 安全卸载。

### 2.3 地图开发标准库 `std.*` 与通用响应式 `DzFrame` UI（v0.6.0）

- **基础游戏原语**：`std.util`、`std.timer`（池化零泄漏 + 共享 33Hz `frame`）、`std.event`（惰性桥接 War3 原生事件与伤害改写）、`std.player`、`std.unit`（同句柄单例 + `u.data` 自动清理）、`std.group`（零泄漏范围查询）、`std.effect`、`std.statbar`（`CStatBar` 高层预设）、`std.tween`。
- **3 层通用响应式 `DzFrame` UI 框架**：
  - `std.signal`：`state` / `computed` / `effect` / `batch` / `untrack` / `scope`，精确依赖追踪与自动清理。
  - `std.frame`：自动绑定宿主 KKAPI `DzFrame*` native，为每类事件维护固定 `jass.code` 槽，回调热替换零 trampoline 泄漏。
  - `std.ui`：零业务耦合、零硬编码皮肤；提供基础控件（`Box`/`Text`/`Image`/`Button`/`Model`/`Input`/`Raw`）、布局容器（`Row`/`Column`/`Grid`/`Scroll`/`Overlay`）、响应式控制流（`Show`、`For` 池化槽）、`component` 与 `provide`/`use` 上下文依赖注入。
  - D3D9 渲染版 UI 保留为独立可选模块 `std.d3d_ui`。

## 3. 已知边界与当前缺口

| 项目 | 当前证据与边界 | 后续完成条件 |
|---|---|---|
| 多人联机（2–4 人 LAN / KK 对战平台）实测 | 已实现 `luaL_newstate2` 同步随机种子、确定性 `table.sort`、`math.random` 路由与 `brokenNetwork` 钩子 | 尚未进行多人 30 分钟长局不同步（desync）压力测试 |
| 命令卡动态图标实机视觉验收 | `EXDclareButtonIcon` / `EXBlendButtonIcon` 内存供图（Storm#279 detour）与 `tests/ydwe-compat` 4 步离线测试全过 | 需在 War3 1.27a 实机复核命令卡换图显示与缓存刷新 |
| 0.6.0 全量历史套件一次性复跑 | 0.6.0 已通过 9/9 离线套件 + 1.27a 热路径基准 + KKWE `std.ui` 8/8；0.5.0 已实机验收 `CStatBar` 与 7 项对齐；122/170/199/12 例历史全套实机基线尚未在 `0.6.0` 单提交上重跑一遍 | 发 `1.0.0` 或大版本前在 `HEAD` 上一次性复跑 `live` / `conformance` / `demo` / `examples --live` |
| LuaLS `@meta` 智能提示声明 | 文档指南完整，尚无面向 VS Code LuaLS 的 `jass.*` / `std.*` `.lua` `@meta` 类型标注包 | 补充 `meta/` 类型定义并打入 SDK 包 |
| JASS 运行时声明新 native 限制 | 1.27a 地图脚本在插件加载前编译，不能凭空声明引擎表里不存在的 `native Foo` | 已知架构边界：走 UnitId RPC、wrapper 生成或复用隐藏 native（见 [JASS-NATIVE-DECLARATIONS.md](planning/JASS-NATIVE-DECLARATIONS.md)） |
| 协程 `sleep()` 边界 | 仅在 `runtime.sleep = true` 的 trigger action 线程单次 wait 可靠；多段串联不可靠且 action 会重入 | 多段编排统一使用 `std.timer` / timer 链（见 [SDK-GUIDE.md](guide/SDK-GUIDE.md)） |
| D3D9 保留限制 | 1.27a 窗口模式下 `device_lost` 与 `reset` 同帧完成不可观测；`ShowFpsText` 为弱断言；BLP 仅内存解码路径支持 | 已知平台限制，记录在 [D3D-LUA-SDK-DESIGN.md](planning/D3D-LUA-SDK-DESIGN.md) §15.8.4 |
| 对外开源分发许可证边界 | `yd_japi.dll` 包含从 YDWE（GPL-3.0）提取改编的模块，`vendor/w3x2lni/` 为 GPL-3.0，构建可选嵌入的 `D3DX9_42.dll` 为微软专有分发件 | 已整理 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)；公开二进制分发须遵守 GPL-3.0 源码提供义务且不得违约随包捆绑微软 `D3DX9_42.dll` |

## 4. 验证与构建入口

### 4.1 维护者日常构建与离线门禁（不启动 War3）

```powershell
mise run setup      # 首次/换机器：拉取锁定版本的 w3x2lni 脚本与数据
mise run build      # 编译 C++ DLL (yd_japi.dll + newD3d9.dll) + Rust japi.exe
mise run test       # 运行全部 9 套离线测试（cli / pack / object-data / selector / ui / std / ydwe-compat / d3d-contract / examples）
```

也可单独运行指定离线套件：

```powershell
node tools/dev/cli.ts test cli           # Rust CLI 单元测试
node tools/dev/cli.ts test pack          # 单 TGA / war3map.imp / wtg-wct / SDK 布局诊断
node tools/dev/cli.ts test std           # std.* 标准库与响应式 DzFrame UI 离线测试（13/13）
node tools/dev/cli.ts test object-data   # objects.lua 编译 + w3x2lni 往返
node tools/dev/cli.ts test ydwe-compat   # Python + Lua + C++ + CLI 四步兼容测试
node tools/dev/cli.ts test d3d-contract  # D3D 54 handler 合同与覆盖校验
node tools/dev/cli.ts test examples      # 12 个示例静态 + 打包校验
```

### 4.2 实机回归入口（需本机 War3 1.27a）

> 运行时 DLL 固定写日志到 `C:\ProgramData\japi_debug.txt`（占用时回退 `japi_debug_<pid>.txt`）。`japi.exe` 内置 1.27a 进程 DENY-DACL 修复与 Job Object 自动清理，无需管理员权限。

```powershell
node tools/dev/cli.ts test live               # 主引擎实机回归
node tools/dev/cli.ts test demo               # 波次防守 demo 实机回归
node tools/dev/cli.ts test conformance        # 原生接口一致性测试台（改 src/ 注册表后先跑 node tests/conformance/gen-manifest.mjs）
node tools/dev/cli.ts test examples --live    # 12 个示例串行实机回归
node tools/dev/cli.ts foreign-map             # 生成无 japi 痕迹的外来地图夹具 build/foreign-map
```

### 4.3 发布纯净开发者 SDK 包（clean worktree 可溯源构建）

```powershell
mise run release                              # 等价于 node tools/dev/cli.ts release --sdk-bundle
# 产物：build/sdk/<version>-<sha7>/map-inject-sdk-<version>.zip + SHA256SUMS.txt + manifest.json
```

历史发布产物溯源锚点：
- `0.4.0`（2026-11-15）：`d151fd7`（首个 D3D SDK 可用发布版）
- `0.5.0`（2026-11-23）：`632ffac`（单 TGA + Rust `japi.exe` + 原生 `CStatBar` + 1.27a 全量对齐 + 纯净 SDK）
- `0.6.0`（2026-11-24）：`d11e9db`（热路径零堆分配 + `std.*` 自动 Tree-Shaking + 通用响应式 `DzFrame` UI）

### 4.4 地图开发者入口（零依赖 `japi.exe`）

```powershell
.\japi.exe doctor
.\japi.exe new MyMap --path D:\maps
.\japi.exe check D:\maps\MyMap --strict-requires
.\japi.exe build D:\maps\MyMap
.\japi.exe run   D:\maps\MyMap
```

## 5. 演进里程碑

1. **基础桥接与开局样板（2026-10）**：UnitId RPC、Lua 5.4 VM、`jass.globals`、`jass.code`、trigger-action sleep、外来地图 bootstrap 注入与波次防守垂直切片跑通。
2. **D3D9 Lua SDK P0–P6 与 `v0.4.0`（2026-11-15，`d151fd7`）**：typed Font/Text/Texture userdata、统一队列与 alpha、`asset://`/`game://` BLP1/BLP2/PNG 内存解码、Subscription 统一输入、TTL/device reset 生命周期、同进程换图 VM 重置、54/54 handler 覆盖、三份作者指南与 clean-worktree 发布溯源闭环。
3. **JASS 侧通道与诊断体系（2026-11-15 – 2026-11-18）**：数组预分配、`SaveFunc`/`func_bind`、JASS 五部曲 wrapper 自动生成、`SetHeroLevels` 隐藏 native `GetFuncAddr`、`tests/conformance` 一致性测试台（199 断言）、`jass.japi.info/counts`、`jass.hook.unhook`、代码化物编 `objects.lua` 与 YDWE 兼容层。
4. **单 TGA、Rust CLI、原生 `CStatBar` 与 `v0.5.0`（2026-11-23，`632ffac`）**：全面用 `mise.toml` + Node 24 TypeScript + Rust `japi.exe` 取代早期 PowerShell 脚本；合并为单文件 `japi.tga` 并兼容 WE/KKWE 保存；实现 16 API 原生 1.27a `CStatBar` 与离屏/幽灵血条清理；补齐 YDWE/内置 JAPI 7 项 1.27a 对齐（`luaL_newstate2` 联机确定性、`AbilityId("exec-lua:...")`、`UnitState` 真 native + `EXGetObject`、`jass.ai` 124 native、`brokenNetwork`、零重启 `AttachInProcessD3D9`、`jass.storm.replace_path`）；发布零测试残留的纯净开发者 SDK 包。
5. **性能优化、标准库与通用 `DzFrame` UI — `v0.6.0`（2026-11-24，`d11e9db`）**：完成 C++↔Lua 四项热路径零堆分配优化；上线自动 Tree-Shaking 的 14 模块 `std.*` 标准库与 3 层通用响应式 `DzFrame` UI 框架（`std.signal` / `std.frame` / `std.ui`），KKWE 1.27a 实机验收通过并发布 `map-inject-sdk-0.6.0.zip`。

## 6. 文档职责

| 文档 | 职责 |
|---|---|
| `docs/STATUS.md` | 当前实现、验证强度、已知边界与演进里程碑（唯一权威状态） |
| `AGENTS.md` | 仓库架构、模块职责、宿主关系与维护者/开发者命令速查 |
| `THIRD-PARTY-NOTICES.md` | 第三方开源代码、工具与专有运行时的版权及 GPL-3.0 合规声明 |
| `CHANGELOG.md` | SDK 版本策略、版本暴露面与逐版本变更（当前 `0.6.0`） |
| `docs/RELEASE.md` | clean worktree 构建、校验与发布 SDK 包的标准流程 |
| `docs/guide/SDK-QUICKSTART.md` | 地图作者从零跑通：`doctor` / `new` / `check` / `build` / `run` 与常见排障 |
| `docs/guide/SDK-GUIDE.md` | 地图作者按模块查用法：`jass.*` 与 `std.*` 核心不变量与陷阱 |
| `docs/guide/SDK-COOKBOOK.md` | 地图作者可直接套用的玩法配方集 |
| `docs/guide/OBJECT-DATA-UI.md` | 代码化物编 `objects.lua` 与 UI 使用指南 |
| `docs/guide/YDWE-COMPAT.md` | YDWE `UnitState` 迁移与命令卡图标兼容说明 |
| `docs/guide/D3D-LUA-QUICKSTART.md` / `D3D-LUA-API.md` / `D3D-LUA-MIGRATION.md` | `jass.d3d` 入门、API 参考与旧接口迁移 |
| `docs/guide/MINIMAL-GAME-LOOP.md` | 波次防守最小游戏循环拆解 |
| `docs/planning/` | 历史方案设计、路线演进与逆向分析存档（不代表当前状态） |
| `tests/conformance/README.md` | 原生接口一致性测试台说明 |

# map-inject 当前状态

> 本文件是仓库中唯一的当前完成状态来源（single source of truth）。
> `docs/planning/` 下的文件保留方案演进、阶段拆分和历史验收记录，其中的状态标记不代表当前状态。

- 最后更新：2026-08-03
- 支持版本：Warcraft III 1.27a（当前偏移与实机验收版本）
- 普通实机回归：`108 passed, 0 failed, 108 total`（2026-08-03）
- LocalPoint 交互回归：`109 passed, 0 failed, 109 total`（真实前台 Q 键，2026-07-30）
- UI 交互回归：`110 passed, 0 failed, 110 total`（真实鼠标悬停 + 命令卡显隐，2026-07-30）
- D3D 实机回归：`128 passed, 0 failed, 128 total`（普通基线 108 项 + 公共 Lua SDK 6 组 + 底层 bridge 13 组 + SDK shutdown 1 组；兼容面仍为 27/54 触达，不是 128 个 API，2026-08-03）
- 默认测试场景：64×64 平坦空图，无基地、野怪、树木或预放物件；最终仅保留 1 个 10 级英雄火枪手 `Hrif`（2026-07-31）
- 验收入口：先运行 `src\build.bat`，再按第 4 节选择普通或交互模式

## 1. 总览

| 功能域 | 实现状态 | 验证状态 | 结论 |
|---|---:|---:|---|
| callback 注入、DLL 加载、Lua VM 启动 | 完成 | War3 1.27a 端到端 | 可用 |
| Lua 引擎模块 | 12/12（含开发中的 `jass.d3d`） | 自动回归 + 实机 | 非 D3D 模块可用；`jass.d3d` 见下行限制 |
| 核心 runtime 能力 | 7/7 功能目标 | 自动回归 + 实机 | 可用 |
| Lua DAP 调试器 | P0-P5 完成 | attach、断点、单步、栈、变量、求值实测 | 可用，需 `-WithDebugger` |
| 非 D3D bridge native | 67/67 注册 | 普通 108/108 + 两套真实交互回归 | 已实现并验收 |
| D3D 底层 proxy/bridge | proxy、注册、部署、诊断、绘制和 code 回调链基本跑通；P0/P1 兼容、部署和原生 session 基座已闭环 | 普通 108/108 + 累计 D3D 128/128 + 真实视觉/鼠标/Shift 交互 | **底层链路基本跑通，不是整体可用** |
| D3D Lua SDK 与生命周期 | P2 已注册 `jass.d3d`，提供 Font/Text/Texture 强类型 userdata、基础属性、显式销毁、GC/`__close` 和显式 session shutdown；尚无 Subscription、MPQ asset、统一跨类型队列、device/reset 状态机和自动地图/VM 会话钩子 | 公共 SDK 7 组（6 功能 + 1 shutdown）实机通过；原生 ABI 1000 轮通过 | **SDK 开发中，不可作为完整用户 SDK 交付** |
| 空白测试场景 | 64×64 空图 + 单个 10 级英雄火枪手确定性复位 | 普通 108/108 + D3D 128/128 + 真实窗口检查 | 可用；默认基座 |
| JASS wrapper 自动生成（E4） | 未实现 | 无 | 可选后续 |
| SaveFunc / func_bind | 仅 `open_code_run_logs` stub | 无完整验收 | 未完成/可选 |

## 2. 已交付功能

### 2.1 加载与工具链

- callback exploit 从地图 MPQ 提取并加载 `yd_japi.dll`。
- `UnitId` + hashtable RPC 完成 JASS/Lua bridge 分发。
- Lua VM 惰性创建并从 MPQ 加载合并后的 `script\war3map.lua`。
- `pack.ps1` 默认使用可提交的 `reference/empty-map/` 源地图，也支持显式传入 `.w3m` / `.w3x` 或其他源目录；完成 Lua 合并、DLL/debugger 资源注入与地图重打包。
- `deploy.ps1` 部署并启动真实 War3，按本次进程的新日志等待 `Results:`。
- `war3map.w3u.ini` 定义真正的英雄单位 `Hrif`（英雄父类 + 火枪手模型/图标/声音/弹道）；打包时自动生成二进制对象数据。
- `lib.scene` 在初始化与测试结束时清空单位，创建唯一的可受伤 10 级英雄火枪手，并在最终画面选中它。

### 2.2 Lua 模块（12/12）

`jass.common`、`jass.globals`、`jass.japi`、`jass.hook`、`jass.runtime`、
`jass.message`、`jass.debug`、`jass.slk`、`jass.sleep`、`jass.storm`、`jass.debugger`、`jass.d3d`。

其中 `jass.d3d` 当前是 P2 开发接口：模块在 proxy 缺失时也能安全加载并报告 unavailable，但尚未达到本文件第 3 节所列的完整 SDK 发布门槛。

### 2.3 核心 runtime 功能

- Lua -> JASS native 调用与 integer/real/string/handle/code 类型转换。
- `jass.code(function)` -> JASS code，已通过 `TriggerAddAction` 往返测试。
- 真 JASS string 转换、SEH 调用保护。
- 协程 sleep 调度器。
- native hook/unhook 与 `orig` 闭包。
- handle level 0/1/2、userdata 与 GC。
- Lua 沙箱。

### 2.4 非 D3D native（67/67 注册）

- 单位数据 12 个。
- 技能/Buff 数据 14 个。
- 物品数据 2 个。
- 特效控制 13 个。
- 伤害事件 2 个。
- 地图/版本/脚本/Hex/显示信息。
- CGameUI：聊天状态、FPS、控制台、小地图位置。
- 鼠标、选择、本地无目标/点目标/单位目标命令、当前目标、技能按钮显示。

### 2.5 D3D9 proxy

- 以游戏目录 `d3d9.dll` 代理启动，真实 D3D9 只从 Windows system directory 的绝对路径加载。
- `yd_japi` 显式注册 D3D bridge；代理缺失时只记录日志，不影响非 D3D 初始化。
- 字体、文字、贴图属性和 JASS string ABI 已完成 API 往返验证。
- `SetHeroLevels(code)` 取址通道和 `TextureAddEvent` / `TextureRemoveEvent` 的 JASS timer 回调链已接通。
- `GetD3DStatus` 提供加载、注册、wrapper、device、帧和贴图的进程内诊断位。
- `-InteractiveD3D` 完成 hash 保护部署、视觉探针、真实渲染和鼠标命中验收。
- Overlay 的贴图、文字和 FPS 完整绘制过程现在统一由 D3D9 state block 保存/恢复；Capture 失败时跳过整个 overlay pass。该修复消除了 blend、Z、lighting、texture stage 和 FVF 泄漏导致的“灵魂体”，已纳入提交 `8bba4ae`，普通 108/108 与真实窗口均确认游戏画面正常。
- [handler_manifest.json](../src/src/d3d9/handler_manifest.json) 固化 54 个兼容名字：D3D proxy 唯一注册 49 个，message/EX canonical owner 注册 5 个；当前 D3D fixture 触达 27/54，尚有 27 个未触达。`verify_contract.ps1` 会检查名字、签名、owner、重复注册和 fixture 映射。
- D3D proxy 不再注册 `GetMouseVectorX/Y`、`ShowConsole`、`ShowFpsText`、`SetKeyboard`，不依赖后注册覆盖语义。`ShowConsole` 的真实隐藏/恢复断言在普通回归中通过。
- `SetKeyboard` 由 message bridge 唯一拥有，Lua API 与 bridge handler 共用 `warcraft3::input::wark_to_vk`；修饰键、方向键、F 键、OEM、数字键盘与无效码的代表性映射由编译期断言保护。
- `SetTextureSrcRect` 已恢复 `(IHrect;)V`，新增 `(I)Hrect;` 的 `GetTextureSrcRect`；bridge 按 `SaveRectHandle` / `LoadRectHandle` 的真实 handle ABI 往返，实机测试验证四个边界值。

P2 已把版本化 `GetD3DSdkApi` 绑定为正式模块名 `jass.d3d`，Font/Text/Texture 不再要求用户操作
hashtable、`UnitId` 或手写 spec；三类对象使用强类型 userdata、generation handle、显式幂等销毁、GC/`__close`
和 Font 依赖。`d3d.shutdown()` 可批量清理同一 session 内由 SDK 与旧 bridge 创建的混合资源。
但 `jass.message.texture_*` 仍是另一套逻辑命中区域，Subscription/统一事件、MPQ asset、跨类型 z、文字 alpha、
device reset 状态机、自动地图/VM session close 和同进程新地图验收均未完成。完整设计与验收标准见
[D3D-LUA-SDK-DESIGN.md](planning/D3D-LUA-SDK-DESIGN.md)。

## 3. 重点验收与当前缺口

| 项目 | 当前证据 | 状态 / 完成条件 |
|---|---|---|
| `EXGetEventDamageData` / `EXSetEventDamage` | 真实 `EVENT_UNIT_DAMAGED` 中读取来源/目标/类型，20 点伤害改写为 7，并以 `GetEventDamage`、生命差和原生 7 点对照命中闭环验证；2 项自动测试通过 | **完成** |
| `LocalPointOrder` | bridge ABI 调用安全；真实前台 Q 键进入 `message.hook`（code 81），共享 submit 提交 `blizzard` 点命令并返回 `true`；`EVENT_UNIT_SPELL_EFFECT` 触发且技能 id 为 `AHbz`；清理诊断代码并重编译后交互套件为 `109/0/109` | **完成**；普通右键移动走 smart-click 包，不是该 API 的 point-order 契约，详见逆向记录 08 §7.3 |
| `GetTargetObject` | `-InteractiveUi` 固定镜头创建敌方城镇大厅；真实鼠标点击/悬停后返回 handle `1050778`，与夹具 handle `1050778` 精确一致 | **完成** |
| `SetUnitAbilityButtonShow` | 大法师 `AHbz` 命令卡槽从显示 `(0,2)` 变为隐藏 `nil,nil`，10 秒后自动恢复 `(0,2)`；真实窗口截图同时确认紫色暴风雪图标消失，交互套件为 `110/0/110` | **完成** |
| D3D proxy 加载/注册/部署 | PE 导出包含未修饰的 `Direct3DCreate9`、`InitializeD3DAPI`、`GetD3DSdkApi`，且 proxy 不导入自身 `d3d9.dll`；`yd_japi` 在进程内完成 handler 注册；`d3d-proxy.ps1` 以 sidecar SHA-256 保护安装、验证和卸载；实测状态位达到 `0x7F` | **运行链基本跑通**；提交态产物溯源与 proxy 部署生命周期已闭环，自动地图/VM 会话边界未闭环 |
| D3D bridge 字体/文字/贴图与命中 | 字体和文字属性、JASS string ABI、贴图尺寸/像素尺寸、trigger 开关均通过；真实 War3 窗口显示标题和高对比棋盘，鼠标移入/移出命中正确 | **已选底层子链通过；不是完整 bridge 或用户 SDK** |
| D3D bridge `TextureAddEvent` / `TextureRemoveEvent` | `SetHeroLevels(C)V` 捕获 code；事件保留独立按下/弹起 JASS timer；回调中 `GetExpiredTimer()` 对应父键的 `0xFE–0x101` 上下文全部命中；真实鼠标位于贴图内时按下/弹起 Shift，并在回调内移除事件；该底层 fixture 为 13 组 | **底层 JASS 输入回调链跑通；Lua Subscription 未闭环** |
| D3D handler 合同与覆盖 | manifest 固化 54 个名字、49 个 proxy owner、5 个 canonical owner；验证器通过；底层 fixture 触达 27/54，未触达 27 个；`128/128` 是累计测试总数 | **结构合同完成，行为覆盖未完成**；未测项不得视为已完成 |
| D3D P0 兼容性 | D3D 不再注册 5 个 canonical 重名；`ShowConsole` 真实显隐通过；`SetKeyboard` 共用 WARK→VK；SrcRect Hrect getter/setter 实机往返通过 | **本批修复完成**；后续新增实现必须使用明确命名/版本化边界，不依赖覆盖 |
| D3D 渲染隔离与产物溯源 | state-block 修复提交为 `8bba4ae`；P1 源码提交 `b3f4da8` 再次从 detached clean worktree 构建并实际部署，proxy 与 sidecar hash 为 `8D7089B68B9028A05C1DB1DAFB70D95B7974049A707EAF91C358633772225035`，clean `yd_japi.dll` hash 为 `BEE52977457FFB3BD5DEC7B11F75B1CCF894134C5E0E61DD6170F5CEB4309D8B`；同一 clean build 通过普通 108/108、D3D 121/121 和原生 ABI 合同 | **P1 提交态产物闭环完成**；主工作区仍保留用户的非 D3D 修改，不影响 detached commit provenance |
| D3D 卸载与会话清理 | 独立工具已在隔离目录验证幂等安装/验证/卸载、未知文件保护，并在真实游戏目录完成卸载→再次卸载→未安装验证→普通 108/108→从干净提交产物重装→hash 验证；原生 ABI 的显式 `end_session` 已验证三类资源批量归零和同进程旧 handle 失效，但仍无真实地图切换/VM 关闭钩子 | **部署生命周期与显式 native session 完成，自动会话生命周期未完成**；不能据此宣称 SDK 可用 |
| D3D Lua SDK | `require "jass.d3d"` 返回 Font/Text/Texture 类；基础属性、任意长度字符串、旋转局部坐标命中、强类型/代际 handle、Font 强引用与依赖拒绝、三类幂等销毁、use-after-destroy、GC、Font `__close`、重复 require 的 session 稳定性和显式 shutdown 已通过公共 fixture；fixture 源码不调用裸 RPC | **P2 基础对象层完成，SDK 仍在开发**；Subscription、asset、统一渲染、完整生命周期/device 和文档门槛仍未完成 |
| 默认空白地图 | `reference/empty-map/` 的对象层为 0 个 doodad、0 个预放单位（仅保留起始点）；无 Melee 初始化；`Hrif` 继承英雄类型并在运行时设为 10 级；真实窗口确认中央仅 1 个英雄火枪手；普通 `108/108`、D3D `128/128` | **完成并设为默认** |
| D3D 后续主线 | P3 MPQ asset/统一 render queue/文字 alpha；P4 Subscription 与统一事件；P5 自动 session、TTL、device lost/reset 和完整压力/失败路径；P6 文档与最终验收 | **未完成，属于当前主线而非可选项** |

## 4. 验证入口

普通实机回归（无人值守，当前结果为 108/108）：

```powershell
.\tools\deploy.ps1
```

LocalPoint 真实交互回归（War3 获得前台焦点后按 Q；默认保留一小时等待手测）：

```powershell
.\tools\deploy.ps1 -InteractivePoint
```

交互模式的成功条件不只是 hook 被调用或 submit 返回 `true`，还要求测试大法师实际触发
`EVENT_UNIT_SPELL_EFFECT`，且 `GetSpellAbilityId()` 必须等于 `AHbz`。当前结果为 109/109。

鼠标目标与技能按钮 UI 回归（鼠标指向/点击镜头中央的敌方城镇大厅；显示阶段按一次 Q，
隐藏保持 10 秒后自动恢复）：

```powershell
.\tools\deploy.ps1 -InteractiveUi
```

成功条件是 `GetTargetObject` 返回值与城镇大厅 handle 精确相等，并且 `AHbz` 在命令卡中
依次呈现 `(0,2) -> nil,nil -> (0,2)`。当前结果为 110/110。

D3D proxy 实机回归（鼠标移入棋盘后按一次 Shift，再移到棋盘外；成功后脚本自动读取日志并关闭 War3）：

```powershell
.\tools\deploy.ps1 -InteractiveD3D
```

需要保留最终画面人工检查时额外传入 `-NoKill`。

该入口先运行只调用 `jass.d3d` 的公共 SDK fixture，再运行底层兼容 fixture。成功条件包括三类 userdata 的属性、
依赖、销毁、GC/`__close`、显式混合资源 shutdown，以及进程内状态位、JASS bridge、真实渲染、鼠标和 Shift 回调。
当前结果为累计 128/128：普通基线 108 项 + 公共 SDK 功能 6 组 + 底层 bridge 13 组 + SDK shutdown 1 组；
54 个兼容名字中底层 fixture 仍只触达 27 个，不能解释为 128 个 D3D API 或完整覆盖。由于目标 War3 以提权进程运行，非提权部署进程
无法读取模块列表；该限制不作为成功证据，加载结论由进程内状态、API 往返和真实渲染共同确认。最终窗口同时应显示
平坦空场和唯一的 10 级英雄火枪手（最终被选中并显示英雄界面），不应出现基地、野怪、树木或测试夹具残留。

P1 原生 ABI/session 合同（不启动 War3）：

```powershell
.\src\build\bin\Release\d3d_sdk_contract_test.exe
```

成功条件包括 ABI version/size/capability 协商、错误版本拒绝、session 隔离、三类 type/generation handle、
Font 依赖、全部 P2 基础属性、长字符串 size/buffer 合同、旋转命中、数值校验、显式 session 批量清理、
旧 handle 跨 session 失效、last-error 和 1000 轮生命周期后资源计数归零。

## 5. 下一阶段顺序

1. P3：实现 `asset://`/MPQ BLP/PNG、统一 Text/Texture render queue 和文字 alpha，完成加载失败与跨类型 z 验收。
2. P4：实现 Subscription 与统一鼠标/键盘/enter/leave/click 事件，替代两套 texture 身份。
3. P5：补齐 Lua VM/地图自动 session 清理、TTL、device lost/reset、同进程新会话、失败路径和压力/soak 验收。
4. P6：完成 quickstart、API reference、迁移文档和全部 §15 门槛；在此之前状态保持“SDK 开发中”。
5. 之后再评估 JASS wrapper 自动生成和 SaveFunc/func_bind。

## 6. 文档职责

| 文档 | 职责 |
|---|---|
| `docs/STATUS.md` | 当前实现、验证强度、缺口和下一阶段；唯一权威状态 |
| `docs/planning/ROADMAP.md` | 核心 runtime 的历史路线和方案取舍 |
| `docs/planning/EX-NATIVES-PLAN.md` | EX/native 批次设计和历史 DoD |
| `docs/planning/LUA-DEBUGGER-DESIGN.md` | 调试器设计、方案调整和验收记录 |
| `docs/planning/D3D-PROXY-DESIGN.md` | D3D proxy 底层加载、部署安全策略和历史实测记录 |
| `docs/planning/D3D-LUA-SDK-DESIGN.md` | 用户级 D3D Lua SDK、对象模型、完整生命周期和最终验收合同 |
| `docs/planning/JASS-LUA-BRIDGE.md` | UnitId + hashtable RPC 的设计说明 |
| `docs/re-builtin-japi/` | 逆向证据与实现依据，不承担项目状态维护 |

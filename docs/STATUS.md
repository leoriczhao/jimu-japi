# map-inject 当前状态

> 本文件是仓库中唯一的当前完成状态来源（single source of truth）。
> `docs/planning/` 下的文件保留方案演进、阶段拆分和历史验收记录，其中的状态标记不代表当前状态。

- 最后更新：2026-08-03
- 支持版本：Warcraft III 1.27a（当前偏移与实机验收版本）
- 普通实机回归：`108 passed, 0 failed, 108 total`（2026-08-03）
- LocalPoint 交互回归：`109 passed, 0 failed, 109 total`（真实前台 Q 键，2026-07-30）
- UI 交互回归：`110 passed, 0 failed, 110 total`（真实鼠标悬停 + 命令卡显隐，2026-07-30）
- D3D 底层链路实机回归：`121 passed, 0 failed, 121 total`（普通累计基线 108 项 + D3D fixture 13 项；兼容面 54 个名字中 fixture 触达 27 个，不代表 Lua SDK 已完成，2026-08-03）
- 默认测试场景：64×64 平坦空图，无基地、野怪、树木或预放物件；最终仅保留 1 个 10 级英雄火枪手 `Hrif`（2026-07-31）
- 验收入口：先运行 `src\build.bat`，再按第 4 节选择普通或交互模式

## 1. 总览

| 功能域 | 实现状态 | 验证状态 | 结论 |
|---|---:|---:|---|
| callback 注入、DLL 加载、Lua VM 启动 | 完成 | War3 1.27a 端到端 | 可用 |
| Lua 引擎模块 | 11/11 | 自动回归 + 实机 | 可用 |
| 核心 runtime 能力 | 7/7 功能目标 | 自动回归 + 实机 | 可用 |
| Lua DAP 调试器 | P0-P5 完成 | attach、断点、单步、栈、变量、求值实测 | 可用，需 `-WithDebugger` |
| 非 D3D bridge native | 67/67 注册 | 普通 108/108 + 两套真实交互回归 | 已实现并验收 |
| D3D 底层 proxy/bridge | proxy、注册、部署、诊断、绘制和 code 回调链基本跑通；P0 注册冲突、WARK 映射、SrcRect、state-block 和提交态产物溯源已闭环，仍缺卸载与会话清理 | 普通 108/108 + 累计 D3D 121/121 + 真实视觉/鼠标/Shift 交互 | **底层链路基本跑通，不是整体可用** |
| D3D Lua SDK 与生命周期 | 未实现 `jass.d3d`；当前只有裸 RPC 和两套未统一的 texture/event 入口 | 无公共 SDK、GC/session/reset/资源压力验收 | **未完成，不可作为用户 SDK 交付** |
| 空白测试场景 | 64×64 空图 + 单个 10 级英雄火枪手确定性复位 | 普通 108/108 + D3D 121/121 + 真实窗口检查 | 可用；默认基座 |
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

### 2.2 Lua 模块（11/11）

`jass.common`、`jass.globals`、`jass.japi`、`jass.hook`、`jass.runtime`、
`jass.message`、`jass.debug`、`jass.slk`、`jass.sleep`、`jass.storm`、`jass.debugger`。

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

以上只表示底层 proxy/bridge 可工作。当前没有正式 `jass.d3d` Lua 模块；用户只能复制测试夹具中的
hashtable + `UnitId` RPC。Proxy 已提供版本化 `GetD3DSdkApi`、显式 session、generation handle 和
资源计数的 P1 原生基座，但尚未绑定到 Lua VM/地图结束事件。`jass.message.texture_*` 仍是另一套逻辑命中区域，
`DestroyText` 公共 userdata、GC/`__close`、device reset 保持和自动 session close 均未完成。完整设计与验收标准见
[D3D-LUA-SDK-DESIGN.md](planning/D3D-LUA-SDK-DESIGN.md)。

## 3. 重点验收与当前缺口

| 项目 | 当前证据 | 状态 / 完成条件 |
|---|---|---|
| `EXGetEventDamageData` / `EXSetEventDamage` | 真实 `EVENT_UNIT_DAMAGED` 中读取来源/目标/类型，20 点伤害改写为 7，并以 `GetEventDamage`、生命差和原生 7 点对照命中闭环验证；2 项自动测试通过 | **完成** |
| `LocalPointOrder` | bridge ABI 调用安全；真实前台 Q 键进入 `message.hook`（code 81），共享 submit 提交 `blizzard` 点命令并返回 `true`；`EVENT_UNIT_SPELL_EFFECT` 触发且技能 id 为 `AHbz`；清理诊断代码并重编译后交互套件为 `109/0/109` | **完成**；普通右键移动走 smart-click 包，不是该 API 的 point-order 契约，详见逆向记录 08 §7.3 |
| `GetTargetObject` | `-InteractiveUi` 固定镜头创建敌方城镇大厅；真实鼠标点击/悬停后返回 handle `1050778`，与夹具 handle `1050778` 精确一致 | **完成** |
| `SetUnitAbilityButtonShow` | 大法师 `AHbz` 命令卡槽从显示 `(0,2)` 变为隐藏 `nil,nil`，10 秒后自动恢复 `(0,2)`；真实窗口截图同时确认紫色暴风雪图标消失，交互套件为 `110/0/110` | **完成** |
| D3D proxy 加载/注册/部署 | PE 导出包含未修饰的 `Direct3DCreate9`、`InitializeD3DAPI`，且 proxy 不导入自身 `d3d9.dll`；`yd_japi` 在进程内完成 handler 注册；`d3d-proxy.ps1` 以 sidecar SHA-256 保护安装、验证和卸载；实测状态位达到 `0x7F` | **运行链基本跑通**；提交态产物溯源与 proxy 部署生命周期已闭环，会话资源清理未闭环 |
| D3D bridge 字体/文字/贴图与命中 | 字体和文字属性、JASS string ABI、贴图尺寸/像素尺寸、trigger 开关均通过；真实 War3 窗口显示标题和高对比棋盘，鼠标移入/移出命中正确 | **已选底层子链通过；不是完整 bridge 或用户 SDK** |
| D3D bridge `TextureAddEvent` / `TextureRemoveEvent` | `SetHeroLevels(C)V` 捕获 code；事件保留独立按下/弹起 JASS timer；回调中 `GetExpiredTimer()` 对应父键的 `0xFE–0x101` 上下文全部命中；真实鼠标位于贴图内时按下/弹起 Shift，并在回调内移除事件；累计套件为 `121/0/121` | **底层 JASS 输入回调链跑通；Lua 事件未闭环** |
| D3D handler 合同与覆盖 | manifest 固化 54 个名字、49 个 proxy owner、5 个 canonical owner；验证器通过；fixture 触达 27/54，未触达 27 个；`121/121` 是累计测试总数 | **结构合同完成，行为覆盖未完成**；未测项不得视为已完成 |
| D3D P0 兼容性 | D3D 不再注册 5 个 canonical 重名；`ShowConsole` 真实显隐通过；`SetKeyboard` 共用 WARK→VK；SrcRect Hrect getter/setter 实机往返通过 | **本批修复完成**；后续新增实现必须使用明确命名/版本化边界，不依赖覆盖 |
| D3D 渲染隔离与产物溯源 | state-block 修复提交为 `8bba4ae`；P1 源码提交 `b3f4da8` 再次从 detached clean worktree 构建并实际部署，proxy 与 sidecar hash 为 `8D7089B68B9028A05C1DB1DAFB70D95B7974049A707EAF91C358633772225035`，clean `yd_japi.dll` hash 为 `BEE52977457FFB3BD5DEC7B11F75B1CCF894134C5E0E61DD6170F5CEB4309D8B`；同一 clean build 通过普通 108/108、D3D 121/121 和原生 ABI 合同 | **P1 提交态产物闭环完成**；主工作区仍保留用户的非 D3D 修改，不影响 detached commit provenance |
| D3D 卸载与会话清理 | 独立工具已在隔离目录验证幂等安装/验证/卸载、未知文件保护，并在真实游戏目录完成卸载→再次卸载→未安装验证→普通 108/108→从干净提交产物重装→hash 验证；原生 ABI 的显式 `end_session` 已验证三类资源批量归零和同进程旧 handle 失效，但仍无真实地图切换/VM 关闭钩子 | **部署生命周期与显式 native session 完成，自动会话生命周期未完成**；不能据此宣称 SDK 可用 |
| D3D Lua SDK | Proxy 已导出 `GetD3DSdkApi` ABI v1，具备 session、type/generation handle、Font 依赖、资源计数/批量清理和 last-error；原生合同含 1000 轮创建/销毁归零验证；仍无 `require "jass.d3d"`、强类型 userdata、GC/`__close`、统一事件和 MPQ asset 合同 | **P1 原生基座完成，用户 SDK 未完成**；必须通过 [SDK 设计 §15](planning/D3D-LUA-SDK-DESIGN.md#15-验收标准) 的全部稳定验收 ID |
| 默认空白地图 | `reference/empty-map/` 的对象层为 0 个 doodad、0 个预放单位（仅保留起始点）；无 Melee 初始化；`Hrif` 继承英雄类型并在运行时设为 10 级；真实窗口确认中央仅 1 个英雄火枪手；普通 `108/108`、D3D `121/121` | **完成并设为默认** |
| D3D 后续主线 | 公共 `jass.d3d`、session/generation、资源销毁与 GC、device reset、鼠标按钮/enter/leave/click、MPQ BLP、统一 z-order、卸载和压力验证均纳入 SDK 设计 | **未完成，属于当前主线而非可选项** |

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

该底层 fixture 的成功条件是进程内状态位覆盖加载、注册、真实 DLL、wrapper、device、帧和贴图（`0x7F`），
已选取的字体/文字/贴图属性测试通过，Shift 的按下/弹起 JASS 回调上下文和事件移除通过，真实窗口的标题依次进入
`VISUAL PASS`、`HOVER PASS`、`EVENT PASS` 和 `VISUAL + HOVER + EVENT PASS`。当前结果为累计 121/121，构成为普通基线 108 项加 D3D fixture 13 项；54 个兼容名字中该 fixture 触达 27 个，不能解释为 121 个 D3D API 或完整覆盖。由于目标 War3 以提权进程运行，非提权部署进程
无法读取模块列表；该限制不作为成功证据，加载结论由进程内状态、API 往返和真实渲染共同确认。最终窗口同时应显示
平坦空场和唯一的 10 级英雄火枪手（最终被选中并显示英雄界面），不应出现基地、野怪、树木或测试夹具残留。

P1 原生 ABI/session 合同（不启动 War3）：

```powershell
.\src\build\bin\Release\d3d_sdk_contract_test.exe
```

成功条件包括 ABI version/size/capability 协商、错误版本拒绝、session 隔离、三类 type/generation handle、
Font 依赖、显式 session 批量清理、旧 handle 跨 session 失效、last-error 和 1000 轮生命周期后资源计数归零。

## 5. 下一阶段顺序

1. 实现 P2 `jass.d3d` 强类型 userdata 和 Font/Text/Texture 基础属性，不允许用户接触裸 RPC。
2. 补齐 Lua VM/地图自动 session 清理入口，并通过同进程新会话验证旧 userdata 与旧回调失效；继续实现 MPQ asset、统一事件和 device lost/reset/GC 清理。proxy/探针/sidecar 的独立部署生命周期已完成，不再重复实现。
3. 只有 SDK 设计 §15 的全部稳定验收 ID 通过后，才能把 D3D 从“底层链路基本跑通”升级为“用户 SDK 可用”。
4. 之后再评估 JASS wrapper 自动生成和 SaveFunc/func_bind。

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

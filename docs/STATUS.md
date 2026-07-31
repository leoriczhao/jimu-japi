# map-inject 当前状态

> 本文件是仓库中唯一的当前完成状态来源（single source of truth）。
> `docs/planning/` 下的文件保留方案演进、阶段拆分和历史验收记录，其中的状态标记不代表当前状态。

- 最后更新：2026-07-31
- 支持版本：Warcraft III 1.27a（当前偏移与实机验收版本）
- 普通实机回归：`108 passed, 0 failed, 108 total`（2026-07-31）
- LocalPoint 交互回归：`109 passed, 0 failed, 109 total`（真实前台 Q 键，2026-07-30）
- UI 交互回归：`110 passed, 0 failed, 110 total`（真实鼠标悬停 + 命令卡显隐，2026-07-30）
- D3D 实机回归：`115 passed, 0 failed, 115 total`（proxy 加载、API 往返、真实渲染和鼠标移入/移出，2026-07-31）
- 验收入口：先运行 `src\build.bat`，再按第 4 节选择普通或交互模式

## 1. 总览

| 功能域 | 实现状态 | 验证状态 | 结论 |
|---|---:|---:|---|
| callback 注入、DLL 加载、Lua VM 启动 | 完成 | War3 1.27a 端到端 | 可用 |
| Lua 引擎模块 | 11/11 | 自动回归 + 实机 | 可用 |
| 核心 runtime 能力 | 7/7 功能目标 | 自动回归 + 实机 | 可用 |
| Lua DAP 调试器 | P0-P5 完成 | attach、断点、单步、栈、变量、求值实测 | 可用，需 `-WithDebugger` |
| 非 D3D bridge native | 67/67 注册 | 普通 108/108 + 两套真实交互回归 | 已实现并验收 |
| D3D proxy、字体/文字/贴图 | proxy 加载、注册、部署和诊断链已完成 | 普通 108/108 + D3D 115/115 + 真实视觉/鼠标交互 | 本阶段可用；事件回调等兼容项见缺口 |
| JASS wrapper 自动生成（E4） | 未实现 | 无 | 可选后续 |
| SaveFunc / func_bind | 仅 `open_code_run_logs` stub | 无完整验收 | 未完成/可选 |

## 2. 已交付功能

### 2.1 加载与工具链

- callback exploit 从地图 MPQ 提取并加载 `yd_japi.dll`。
- `UnitId` + hashtable RPC 完成 JASS/Lua bridge 分发。
- Lua VM 惰性创建并从 MPQ 加载合并后的 `script\war3map.lua`。
- `pack.ps1` 完成 Lua 合并、DLL/debugger 资源注入与地图重打包。
- `deploy.ps1` 部署并启动真实 War3，按本次进程的新日志等待 `Results:`。

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
- `GetD3DStatus` 提供加载、注册、wrapper、device、帧和贴图的进程内诊断位。
- `-InteractiveD3D` 完成 hash 保护部署、视觉探针、真实渲染和鼠标命中验收。

## 3. 重点验收与当前缺口

| 项目 | 当前证据 | 状态 / 完成条件 |
|---|---|---|
| `EXGetEventDamageData` / `EXSetEventDamage` | 真实 `EVENT_UNIT_DAMAGED` 中读取来源/目标/类型，20 点伤害改写为 7，并以 `GetEventDamage`、生命差和原生 7 点对照命中闭环验证；2 项自动测试通过 | **完成** |
| `LocalPointOrder` | bridge ABI 调用安全；真实前台 Q 键进入 `message.hook`（code 81），共享 submit 提交 `blizzard` 点命令并返回 `true`；`EVENT_UNIT_SPELL_EFFECT` 触发且技能 id 为 `AHbz`；清理诊断代码并重编译后交互套件为 `109/0/109` | **完成**；普通右键移动走 smart-click 包，不是该 API 的 point-order 契约，详见逆向记录 08 §7.3 |
| `GetTargetObject` | `-InteractiveUi` 固定镜头创建敌方城镇大厅；真实鼠标点击/悬停后返回 handle `1050778`，与夹具 handle `1050778` 精确一致 | **完成** |
| `SetUnitAbilityButtonShow` | 大法师 `AHbz` 命令卡槽从显示 `(0,2)` 变为隐藏 `nil,nil`，10 秒后自动恢复 `(0,2)`；真实窗口截图同时确认紫色暴风雪图标消失，交互套件为 `110/0/110` | **完成** |
| D3D proxy 加载/注册/部署 | PE 导出包含未修饰的 `Direct3DCreate9`、`InitializeD3DAPI`，且 proxy 不导入自身 `d3d9.dll`；`yd_japi` 在进程内完成 handler 注册；部署以 sidecar SHA-256 保护未知文件；实测状态位达到 `0x7F` | **完成** |
| D3D 字体/文字/贴图与命中 | 字体和文字属性、JASS string ABI、贴图尺寸/像素尺寸、trigger 开关均通过；真实 War3 窗口显示黄色标题和高对比棋盘，鼠标移入后变为绿色 `HOVER PASS`，移出后显示绿色最终通过标题；套件为 `115/0/115` | **完成** |
| D3D 后续兼容项 | `TextureAddEvent` / `TextureRemoveEvent` 的 JASS code 回调、MPQ 内 BLP 解码、`rect` handle 裁剪尚未实现 | **未完成 / 不属于本阶段 proxy 交付** |

## 4. 验证入口

普通实机回归（无人值守，当前结果为 108/108）：

```powershell
.\tools\deploy.ps1 -BaseMap .\reference\base.w3m
```

LocalPoint 真实交互回归（War3 获得前台焦点后按 Q；默认保留一小时等待手测）：

```powershell
.\tools\deploy.ps1 -BaseMap .\reference\base.w3m -InteractivePoint
```

交互模式的成功条件不只是 hook 被调用或 submit 返回 `true`，还要求测试大法师实际触发
`EVENT_UNIT_SPELL_EFFECT`，且 `GetSpellAbilityId()` 必须等于 `AHbz`。当前结果为 109/109。

鼠标目标与技能按钮 UI 回归（鼠标指向/点击镜头中央的敌方城镇大厅；显示阶段按一次 Q，
隐藏保持 10 秒后自动恢复）：

```powershell
.\tools\deploy.ps1 -BaseMap .\reference\base.w3m -InteractiveUi
```

成功条件是 `GetTargetObject` 返回值与城镇大厅 handle 精确相等，并且 `AHbz` 在命令卡中
依次呈现 `(0,2) -> nil,nil -> (0,2)`。当前结果为 110/110。

D3D proxy 实机回归（启动后把鼠标移入棋盘，再移到棋盘外；`-NoKill` 保留最终画面供检查）：

```powershell
.\tools\deploy.ps1 -BaseMap .\reference\base.w3m -InteractiveD3D -NoKill
```

成功条件是进程内状态位覆盖加载、注册、真实 DLL、wrapper、device、帧和贴图（`0x7F`），
字体/文字/贴图属性测试通过，真实窗口的标题依次进入 `VISUAL PASS`、`HOVER PASS` 和
`VISUAL + HOVER PASS`。当前结果为 115/115。由于目标 War3 以提权进程运行，非提权部署进程
无法读取模块列表；该限制不作为成功证据，加载结论由进程内状态、API 往返和真实渲染共同确认。

## 5. 下一阶段顺序

1. 视兼容需求补齐 D3D 事件回调、MPQ BLP 和 `rect` handle 裁剪。
2. 视需要实现 JASS wrapper 自动生成和 SaveFunc/func_bind。

## 6. 文档职责

| 文档 | 职责 |
|---|---|
| `docs/STATUS.md` | 当前实现、验证强度、缺口和下一阶段；唯一权威状态 |
| `docs/planning/ROADMAP.md` | 核心 runtime 的历史路线和方案取舍 |
| `docs/planning/EX-NATIVES-PLAN.md` | EX/native 批次设计和历史 DoD |
| `docs/planning/LUA-DEBUGGER-DESIGN.md` | 调试器设计、方案调整和验收记录 |
| `docs/planning/D3D-PROXY-DESIGN.md` | D3D proxy 本阶段架构、部署安全策略和实测记录 |
| `docs/planning/JASS-LUA-BRIDGE.md` | UnitId + hashtable RPC 的设计说明 |
| `docs/re-builtin-japi/` | 逆向证据与实现依据，不承担项目状态维护 |

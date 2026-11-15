# map-inject 当前状态

> 本文件是仓库中唯一的当前完成状态来源（single source of truth）。
> `docs/planning/` 下的文件保留方案演进、阶段拆分和历史验收记录，其中的状态标记不代表当前状态。

- 最后更新：2026-11-16
- 支持版本：Warcraft III 1.27a（当前偏移与实机验收版本）
- 普通实机回归：`122 passed, 0 failed, 122 total`（2026-11-15 复跑；含 8 项 JASS↔Lua bridge 回归、数组全局预分配后的 `jass.globals` 用例，以及 6 项 `SaveFunc` / `func_bind_trigger_name` 回归）
- JASS wrapper 回归：`125 passed, 0 failed, 125 total`（2026-11-15；`deploy.ps1 -WithJassWrappers` 为 115 个 bridge handler 生成五部曲 wrapper 后跑 122 项基线 + 3 项 wrapper 断言；默认打包仍为 `122/122`，第 8c 节打印 `[SKIP]`）
- GetFuncAddr 回归：`126 passed, 0 failed, 126 total`（2026-11-16；`deploy.ps1 -WithGetFuncAddr` 注入内置 JAPI 的 `native SetHeroLevels takes code f returns nothing` + `GetFuncAddr(code)` 后跑 122 项基线 + 4 项断言：JASS 函数地址非零且稳定、地址经 `UnitId` 桥进 `func_bind_trigger_name`、进 `SaveFunc` 锚点、地址交给 `TriggerAddAction` 后函数体真的执行；实测同一函数两次取值都是 19、另一函数是 20；默认打包下第 8d 节打印 `[SKIP]`）
- LocalPoint 交互回归：`109 passed, 0 failed, 109 total`（真实前台 Q 键，2026-07-30，旧 108 基线；本次未重跑）
- UI 交互回归：`110 passed, 0 failed, 110 total`（真实鼠标悬停 + 命令卡显隐，2026-07-30，旧 108 基线；本次未重跑）
- D3D 实机回归：`164 passed, 0 failed, 164 total`（2026-11-15；普通基线 116 项 + D3D 48 项：公共 SDK 功能 8 组 + 底层 bridge 13 组 + P4 Subscription 真实输入 1 组 + P5 生命周期 7 项 + shutdown 1 组 + §15.8 覆盖补齐 17 项（handler 往返 10 + 事件回调 3 + 交互期探针 3 + BLP2 实机 1）；handler 兼容面 54/54 已全部触达，仍不等于 164 个 API）
- 波次防守 demo 回归：`23 passed, 0 failed, 23 total`（2026-11-16；`deploy.ps1 -Demo` 跑 `map/game/wave.lua` + `map/game/demo.lua` 的 23 条断言：世界构建、波次循环、伤害/击杀/计分、HUD 跟随、败北/胜利、restart、脚本移动命令、Q 施法事件与 CD 门槛、选择可读；真实 OS 级键鼠由 `tools/drive-demo.ps1` 驱动 `-Demo -Hold` 会话复核，同一构建下真 Q 施法、真 R 重开在日志里生效；1.27a 窗口模式的鼠标按钮不进 `message.hook`，所以移动用引擎自带左键命令，`message.order_point` 的落点必须落在当前镜头内）
- 地图级 VM 重启回归：`9 passed, 0 failed, 9 total`（2026-11-15；同一进程内换图后旧 Lua VM 关闭、新图脚本重载、旧 session 资源归零；新增断言证明 `SaveFunc` 锚点与 `func_bind` 标签表随地图启动被清空）
- D3D 发布产物溯源：提交 `d151fd7`（SDK 0.4.0）的 detached clean worktree 构建（HEAD 精确一致、tracked diff 为零）用同一产物实跑交互 `164/164`、普通 `116/116`、地图级 VM 重置 `8/8`，游戏目录 proxy 与 sidecar 回读等于 clean proxy hash（2026-11-15；交互回归使用夹具修正提交 `65bceb5`，见第 4 节）
- 默认测试场景：64×64 平坦空图，无基地、野怪、树木或预放物件；最终仅保留 1 个 10 级英雄火枪手 `Hrif`（2026-07-31）
- 验收入口：先运行 `src\build.bat`，再按第 4 节选择普通或交互模式

## 1. 总览

| 功能域 | 实现状态 | 验证状态 | 结论 |
|---|---:|---:|---|
| callback 注入、DLL 加载、Lua VM 启动与地图级重置 | 完成 | War3 1.27a 端到端 + 同进程换图 8/8 | 可用 |
| Lua 引擎模块 | 12/12（含 `jass.d3d`） | 自动回归 + 实机 | 全部可用；`jass.d3d` 的保留限制见下方 D3D 行与设计文档 15.8.4 |
| 核心 runtime 能力 | 7/7 功能目标 | 自动回归 + 实机 | 可用 |
| Lua DAP 调试器 | P0-P5 完成 | attach、断点、单步、栈、变量、求值实测 | 可用，需 `-WithDebugger` |
| 非 D3D bridge native | 历史批次 67/67 注册，2026-11-15 追加 `SaveFunc (I)V` 与 `func_bind_trigger_name (IS)V` | 普通 122/122 + 两套真实交互回归（旧 108 基线） | 已实现并验收 |
| D3D 底层 proxy/bridge | proxy、注册、部署、诊断、绘制、code 回调链与 device 状态/世代已跑通；P0/P1 兼容、部署和原生 session 基座已闭环 | 普通 116/116 + 累计 D3D 164/164 + 真实视觉/鼠标/Shift 交互 | **可用**（SDK 约束见下行） |
| D3D Lua SDK 与生命周期 | P2–P5 已提供 Font/Text/Texture 强类型 userdata、统一跨类型队列、D3DXFont alpha、`asset://`/`game://` 内存资源、共享 CPU cache、显式销毁、GC/`__close`、reload、显式 session shutdown，Subscription（enter/leave/mouse_down/mouse_up/click/key_down/key_up、pointer capture、6px 点击阈值、`hover_only`/`propagate`/`keep_on_error`、只读 event 表），以及 P5 生命周期：Text `ttl` 到期释放、`d3d.on("resize"/"device_lost"/"device_reset")` 模块级订阅、`device_generation` 世代号、`d3d.status()` 的 `state`/`device_generation` 诊断和失败不泄漏合同；真实鼠标键盘由窗口 `WM_*` 消息 + 异步按键状态驱动，因为 1.27a 游戏内 CGameUI 分发只送键盘消息；地图级 VM 重置已闭环：换图时 `lua_close` 旧 VM、重载新图脚本，session 随 VM 关闭自动 `end_session`（`-TestReboot` 8/8） | 公共 SDK 功能 8 组 + Subscription 真实输入 + 生命周期 7 项 + shutdown 1 组实机通过（交互 D3D 164/164，其中真实窗口 20 次 resize 触发 20 次 device reset，句柄/属性/订阅全部保持）；handler 兼容面 54/54 与 BLP2 内存解码（raw/palette/DXT1）实机通过；原生 ABI 1000 轮通过 | **可用**（2026-11-15：P0–P6 闭环；发布产物来自提交 `d151fd7`（SDK 0.4.0）的 detached clean 构建，构建/部署/sidecar hash 一致，见 §4 与设计文档 14.4）；保留限制见 [设计文档](planning/D3D-LUA-SDK-DESIGN.md) 15.8.4 |
| 空白测试场景 | 64×64 空图 + 单个 10 级英雄火枪手确定性复位 | 普通 116/116 + D3D 164/164 + 真实窗口检查 | 可用；默认基座 |
| 可玩垂直切片（`-Demo`） | 波次防守小游戏：一个 10 级英雄、5 波进攻、基地血量、胜负与 `R` 重开、暴风雪（`Q`，按镜头内光标落点）、引擎自带左键移动、CD/蓝耗、D3D HUD（血量条/计时/比分/提示）、相机锁定英雄；只用 `jass.common`/`jass.message`/`jass.d3d`；自带 23 条断言 | `deploy.ps1 -Demo` 23/23 + `drive-demo.ps1` 真实键鼠复核 23/23 | **可用，作为地图作者开工样板** |
| 外来地图接入（bootstrap 注入） | 对无 japi 痕迹的 `war3map.j` 自动注入 globals + `JapiBootstrap()` + `main()` 调用；repack 前用 pjass 校验 | `build\foreign-map` 夹具 `-Demo` 11/11 | **完成（JASS 地图）**；vJass 需 `-SkipJassCheck` |
| JASS wrapper 自动生成（E4） | `tools/gen-jass-wrappers.ps1` 读三处注册表（EX native、message bridge、D3D manifest）生成 115 个五部曲 wrapper；`pack.ps1 -WithJassWrappers` 把它们插到 `endglobals` 之后，并在 `LoadScript` 之后挂一支 2 秒 timer 探针 | `-WithJassWrappers` 125/125（int/string/real/boolean 往返）；默认 122/122 | **可用（opt-in）**；给地图新增功能的唯一出口仍是 wrapper（native 声明只能复用引擎已有的名字，见下行） |
| GetFuncAddr（JASS 函数取址） | `pack.ps1 -WithGetFuncAddr` 在脚本最前面声明引擎隐藏 native `SetHeroLevels (C)V`（`Scripts\common.ai` 的 AI 方言 native，签名本来就是 `(C)V`）并注入 builtin 同款 `GetFuncAddr(code)`；DLL 的 `japi_add` 覆写该节点函数指针，把 code 值写进共享哈希表槽 0 | `-WithGetFuncAddr` 126/126（4 项，含 `TriggerAddAction` 执行身份证明）；默认 122/122 且第 8d 节 `[SKIP]` | **可用（opt-in）**；声明规则见 [JASS-NATIVE-DECLARATIONS.md](planning/JASS-NATIVE-DECLARATIONS.md) |
| SaveFunc / func_bind | `SaveFunc (I)V` 存锚点、`func_bind_trigger_name (IS)V` 存地址→UTF-8 标签，`jass.debug` 暴露查询/清理 API，崩溃消息回退查表，地图启动清表 | 普通 122/122（6 项）+ VM 重置 9/9 | 已实现；JASS 函数地址来源已由 `-WithGetFuncAddr` 打通（见上行） |

## 2. 已交付功能

### 2.1 加载与工具链

- callback exploit 从地图 MPQ 提取并加载 `yd_japi.dll`。
- `UnitId` + hashtable RPC 完成 JASS/Lua bridge 分发。
- Lua VM 惰性创建并从 MPQ 加载合并后的 `script\war3map.lua`。
- `pack.ps1` 默认使用可提交的 `reference/empty-map/` 源地图，也支持显式传入 `.w3m` / `.w3x` 或其他源目录；完成 Lua 合并、DLL/debugger 资源注入与地图重打包。
- 打包器默认对所有声明的数组全局做预分配（`JapiForceAllocArrays`，见 §4），使 `jass.globals` 从第一个地图开始就能写任意合法下标；`-NoArrayPrealloc` 可关闭。
- `gen-jass-wrappers.ps1` 从 C++ 注册表生成 JASS 五部曲 wrapper（`Save*` 填槽 → `SaveStr` 槽 0 写 spec → `UnitId(name)` → `Load*` 读返回），`pack.ps1 -WithJassWrappers` 把它们注入 `endglobals` 之后，见 §4。
- `deploy.ps1` 部署并启动真实 War3，按本次进程的新日志等待 `Results:`。
- `war3map.w3u.ini` 定义真正的英雄单位 `Hrif`（英雄父类 + 火枪手模型/图标/声音/弹道）；打包时自动生成二进制对象数据。
- `lib.scene` 在初始化与测试结束时清空单位，创建唯一的可受伤 10 级英雄火枪手，并在最终画面选中它。

### 2.2 Lua 模块（12/12）

`jass.common`、`jass.globals`、`jass.japi`、`jass.hook`、`jass.runtime`、
`jass.message`、`jass.debug`、`jass.slk`、`jass.sleep`、`jass.storm`、`jass.debugger`、`jass.d3d`。

其中 `jass.d3d` 当前是 P3 完成后的开发接口：模块在 proxy 缺失时也能安全加载并报告 unavailable，但尚未达到本文件第 3 节所列的完整 SDK 发布门槛。

### 2.3 核心 runtime 功能

- Lua -> JASS native 调用与 integer/real/string/handle/code 类型转换。
- `jass.code(function)` -> JASS code，已通过 `TriggerAddAction` 往返测试。
- 真 JASS string 转换、SEH 调用保护。
- 协程 sleep 调度器；2026-10-26 起用真实 trigger action 验证 suspend→resume（不是裸 timer callback）。
- native hook/unhook 与 `orig` 闭包。
- handle level 0/1/2、userdata 与 GC；0/1/2 往返和 level 2 GC 已纳入回归。
- JASS -> Lua 的 UnitId 桥：`jass.japi` 注册时同时进入 native 表和 UnitId 分发；整数/字符串/布尔、`(Hplayer;)Hplayer;` 句柄、`()V` 回调和错误路由均已实测。
- `jass.globals` 标量与数组读写已实测（含 `index` 0/1/8191、`#arr` 长度、从未被 JASS 触碰过的整数/字符串数组）；`runtime.error_handle` 能接住 JASS 调 Lua handler 的错误。

- `SaveFunc` / `func_bind_trigger_name` bridge handler、地址→标签表与 `jass.debug` 的 `jass_func_address`/`save_func_addr`/`func_bind_lookup`/`func_bind_count`/`func_bind_clear` 已实测；`jass.code(fn)` 能把 Lua 函数变成 VM 真正会执行的 code 地址。
- 内置 JAPI 的 `GetFuncAddr` 已在 JASS 侧复刻（`pack.ps1 -WithGetFuncAddr`）：声明引擎隐藏 native `SetHeroLevels (C)V` + `GetFuncAddr(code)`，JASS 函数地址变成整数后可进 `func_bind_trigger_name` / `SaveFunc`，也可直接交给 `TriggerAddAction` 执行；该 native 的出处是 `Scripts\common.ai`（AI 方言），参数是 AI 英雄管理线程的 code 回调，与地图侧的 `SetHeroLevel(unit, level, showEyeCandy)` 无关。规则与证据见 [JASS-NATIVE-DECLARATIONS.md](planning/JASS-NATIVE-DECLARATIONS.md)。
- 崩溃消息在 `jass_function_name` 之外回退查 `func_bind` 标签表，地图启动（含同进程换图）时清空锚点与标签。

当前边界：**运行时新注册**的名字（`native Foo` + `jass.japi` 注册）不能作为 JASS 调用目标；能声明的只有引擎 native 表里已存在的名字（如 `SetHeroLevels`），而且声明必须排在第一个函数之前——详见 [JASS-NATIVE-DECLARATIONS.md](planning/JASS-NATIVE-DECLARATIONS.md)。给地图新增功能请走 UnitId 桥、`tools/gen-jass-wrappers.ps1` 生成的 wrapper 或 `jass.code`。`sleep()` 只在 `runtime.sleep = true` 且当前线程是 trigger/action thread 时可用；裸 timer callback 与纯 Lua 协程没有恢复路径。

### 2.4 非 D3D native（历史批次 67/67 注册；2026-11-15 追加 `SaveFunc` 与 `func_bind_trigger_name`）

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
- 文字按 UTF-8 优先、系统 ANSI 回退解码后用 `DrawTextW` 绘制。此前走 `DrawTextA`，UTF-8 的中文（Lua 源码、w3x2lni 写出的对象/触发器字符串）会渲染成乱码；GBK 来源（游戏 MPQ）仍走回退分支。实机截图中 `步兵` 正常显示。
- `SetHeroLevels(code)` 取址通道和 `TextureAddEvent` / `TextureRemoveEvent` 的 JASS timer 回调链已接通。
- `GetD3DStatus` 提供加载、注册、wrapper、device、帧和贴图的进程内诊断位。
- `-InteractiveD3D` 完成 hash 保护部署、视觉探针、真实渲染和鼠标命中验收。
- Overlay 的贴图、文字和 FPS 完整绘制过程现在统一由 D3D9 state block 保存/恢复；Capture 失败时跳过整个 overlay pass。该修复消除了 blend、Z、lighting、texture stage 和 FVF 泄漏导致的“灵魂体”，已纳入提交 `8bba4ae`，普通 108/108 与真实窗口均确认游戏画面正常。
- [handler_manifest.json](../src/src/d3d9/handler_manifest.json) 固化 54 个兼容名字：D3D proxy 唯一注册 49 个，message/EX canonical owner 注册 5 个；当前 D3D fixture 触达 54/54，0 个未触达（2026-11-15 补齐，逐项 `test_id` 见设计文档 15.8.1）。`verify_contract.ps1` 会检查名字、签名、owner、重复注册和 fixture 映射。
- D3D proxy 不再注册 `GetMouseVectorX/Y`、`ShowConsole`、`ShowFpsText`、`SetKeyboard`，不依赖后注册覆盖语义。`ShowConsole` 的真实隐藏/恢复断言在普通回归中通过。
- `SetKeyboard` 由 message bridge 唯一拥有，Lua API 与 bridge handler 共用 `warcraft3::input::wark_to_vk`；修饰键、方向键、F 键、OEM、数字键盘与无效码的代表性映射由编译期断言保护。
- `SetTextureSrcRect` 已恢复 `(IHrect;)V`，新增 `(I)Hrect;` 的 `GetTextureSrcRect`；bridge 按 `SaveRectHandle` / `LoadRectHandle` 的真实 handle ABI 往返，实机测试验证四个边界值。

P2 已把版本化 `GetD3DSdkApi` 绑定为正式模块名 `jass.d3d`，Font/Text/Texture 不再要求用户操作
hashtable、`UnitId` 或手写 spec；三类对象使用强类型 userdata、generation handle、显式幂等销毁、GC/`__close`
和 Font 依赖。`d3d.shutdown()` 可批量清理同一 session 内由 SDK 与旧 bridge 创建的混合资源。
P3 已把 Text 改为 D3DXFont alpha 绘制，把 Text/Texture 放入同一稳定 render queue，并实现 `asset://` 当前地图、
`game://` 游戏搜索链、MPQ 内存读取、BLP1/常用图片解码、共享 CPU asset cache 和失败不泄漏合同；跨类型 `z`、同 `z`
创建顺序、文字 0%/50%/100% alpha、地图内 PNG/BLP1 和游戏资源均由真实窗口验证。`file://` 默认拒绝，失败的
`set_source` 保留旧贴图。P4 已实现 Subscription 与统一输入事件：贴图订阅提供 enter/leave/mouse_down/mouse_up/click/
key_down/key_up，带 pointer capture、6px 点击阈值、`hover_only`/`propagate`/`keep_on_error` 和只读 event 表，
事件分发对 Lua 错误隔离。事件源不依赖 CGameUI 分发——游戏内 1.27a 只送键盘消息，鼠标按钮改由窗口 `WM_*` 消息与
异步按键状态提供，两条源经同一状态机去重，所以一次物理按键只产生一次事件。
P5 已补 TTL（`Text` 的 `ttl` 由原生帧时间递减，到期释放并让 Lua 侧句柄同步为已销毁）、device 状态诊断
（`device_generation` 随每次 reset 自增、`lost_count`、`d3d.status().state`）和模块级生命周期事件
`d3d.on("resize"|"device_lost"|"device_reset", cb)`；实机 20 次窗口尺寸变化产生 20 个 `resize` 事件与 20 次
device reset（generation 1→21），过程中 Font/Text/Texture 句柄、文本内容、位置、尺寸和订阅全部保持。
`device_lost` 在 1.27a 窗口模式下不可观测（lost 与 reset 在同一帧完成，0.05s 轮询只能看到 reset），因此该事件
通道保留但不由实机证明。
地图级 VM 重置已闭环：换图时 `callback` 会再次调用 `Initialize()`，`lua_loader::on_map_boot()` 先丢弃 Lua 侧
bridge handler、清 message/D3D 分发状态，再 `lua_close` 旧 `lua_State` 并复位加载标志；新图首次
`ExecuteFunc` 时重建 VM 并加载新 `war3map.lua`。`lua_close` 触发 `__gc` → `context_gc` → `end_session`，
所以 D3D session 与地图同生共死。完整设计与验收标准见
[D3D-LUA-SDK-DESIGN.md](planning/D3D-LUA-SDK-DESIGN.md)。

## 3. 重点验收与当前缺口

| 项目 | 当前证据 | 状态 / 完成条件 |
|---|---|---|
| `EXGetEventDamageData` / `EXSetEventDamage` | 真实 `EVENT_UNIT_DAMAGED` 中读取来源/目标/类型，20 点伤害改写为 7，并以 `GetEventDamage`、生命差和原生 7 点对照命中闭环验证；2 项自动测试通过 | **完成** |
| JASS↔Lua 基础桥接 | `jass.japi` 注册同时进入 native 表和 UnitId 分发；JASS `main` 实测 `()V` 回调、`(II)I`=42、`(Hplayer;)Hplayer;` 句柄往返和错误进 `runtime.error_handle`；`jass.globals` 标量/数组写、handle level 0/1/2、level 2 GC、trigger-action sleep 均通过；普通回归 `122/122` | **完成（UnitId / trigger action 路线）**；JASS 侧 `native Foo` + 运行时注册在 callback 模式不可用（可声明的只有引擎已有的名字，见 [JASS-NATIVE-DECLARATIONS.md](planning/JASS-NATIVE-DECLARATIONS.md)）；sleep 不适用于裸 timer callback/纯 Lua 协程。数组策略：JASS VM 只在首次写入时分配数组块，且没有公开分配器，所以由打包器在 `LoadScript` 之前插入 `JapiForceAllocArrays()`（对每个数组 `set arr[8191] = arr[8191]`，每个数组 32 KB），此后 `jass.globals` 的 `index>0` 写入、`#arr` 与字符串数组都可靠；万一仍有未分配数组，`jarray_newindex` 会写一条 `[jass.globals] write ignored` 日志而不是静默丢弃 |
| `SaveFunc` / `func_bind_trigger_name` | 两个名字按内置地图的线上契约实现为 bridge handler（`(I)V` 存锚点、`(IS)V` 存地址→UTF-8 标签）；仓库内没有任何脚本能产生 Action 地址，所以夹具用 `jass.code(function() ... end)` 生成真实 trampoline 地址，再用 `TriggerAddCondition` + `TriggerEvaluate` 证明该地址确实被 VM 执行，标签/rebind/clear/锚点替换逐项断言（含中文标签字节精确）；普通回归 6 项通过、VM 重置新增 1 项证明表随地图启动清空，日志可见 `[FuncBind] bind 0x0012ABD0 -> reboot-should-drop` 与 `[FuncBind] clearing 1 binding(s) on map boot` | **完成**：`jass.code(Lua 函数)`、native 名与 JASS 侧 `GetFuncAddr(function f)` 三个来源均已打通；最后一个由 `-WithGetFuncAddr` 提供（内置同款 `native SetHeroLevels takes code f returns nothing` + `GetFuncAddr(code)`，126/126 里 4 项断言证明地址非零稳定、能进标签表/锚点、交给 `TriggerAddAction` 真的执行函数体）。声明规则见 [JASS-NATIVE-DECLARATIONS.md](planning/JASS-NATIVE-DECLARATIONS.md) |
| JASS wrapper 自动生成（E4） | `gen-jass-wrappers.ps1` 从 `ex_natives/Initialize.cpp`（57 条）、`libs_message.cpp` 的 bridge 表（12 条）与 `d3d9/handler_manifest.json`（54 条）生成五部曲 wrapper，去重后 115 个注入 `war3map.j` 的 `endglobals` 之后；`-WithJassWrappers` 打包后实机 `125/125`（3 项断言：`GetGameVersion` int 与 Lua 直连一致、`Hex(255)`/`GetPluginVersion` 字符串一致、`SetLittleMapX`+`GetLittleMapX` 的 0.01 实数往返与 `GetChatState` 布尔一致），默认打包 `122/122` 时第 8c 节打印 `[SKIP]` | **可用（opt-in）**：callback 模式下脚本在插件注册之前编译，运行时新注册的名字声明不了（只有引擎已有的名字可声明），wrapper 仍是 JASS 作者调用新增功能的主要入口；跳过 5 个（`GetPlayerSelectedUnit`/`GetTargetObject` 这类 H 返回，1.27a 无 int→handle 转换；`GetMouseX`/`GetMouseY`/`EXExecuteScript` 地图自己已定义）。探针必须走 2 秒 timer：加载画面上取 `GetLittleMapX` 会挂住整局 |
| `LocalPointOrder` | bridge ABI 调用安全；真实前台 Q 键进入 `message.hook`（code 81），共享 submit 提交 `blizzard` 点命令并返回 `true`；`EVENT_UNIT_SPELL_EFFECT` 触发且技能 id 为 `AHbz`；清理诊断代码并重编译后交互套件为 `109/0/109` | **完成**；普通右键移动走 smart-click 包，不是该 API 的 point-order 契约，详见逆向记录 08 §7.3 |
| `GetTargetObject` | `-InteractiveUi` 固定镜头创建敌方城镇大厅；真实鼠标点击/悬停后返回 handle `1050778`，与夹具 handle `1050778` 精确一致 | **完成** |
| `SetUnitAbilityButtonShow` | 大法师 `AHbz` 命令卡槽从显示 `(0,2)` 变为隐藏 `nil,nil`，10 秒后自动恢复 `(0,2)`；真实窗口截图同时确认紫色暴风雪图标消失，交互套件为 `110/0/110` | **完成** |
| D3D proxy 加载/注册/部署 | PE 导出包含未修饰的 `Direct3DCreate9`、`InitializeD3DAPI`、`GetD3DSdkApi`，且 proxy 不导入自身 `d3d9.dll`；`yd_japi` 在进程内完成 handler 注册；`d3d-proxy.ps1` 以 sidecar SHA-256 保护安装、验证和卸载；实测状态位达到 `0x7F` | **运行链基本跑通**；提交态产物溯源与 proxy 部署生命周期已闭环，地图级 VM 重置已闭环（同进程换图 8/8） |
| D3D bridge 字体/文字/贴图与命中 | 字体和文字属性、JASS string ABI、贴图尺寸/像素尺寸、trigger 开关均通过；真实 War3 窗口显示标题和高对比棋盘，鼠标移入/移出命中正确 | **已选底层子链通过；不是完整 bridge 或用户 SDK** |
| D3D bridge `TextureAddEvent` / `TextureRemoveEvent` | `SetHeroLevels(C)V` 捕获 code；事件保留独立按下/弹起 JASS timer；回调中 `GetExpiredTimer()` 对应父键的 `0xFE–0x101` 上下文全部命中；真实鼠标位于贴图内时按下/弹起 Shift，并在回调内移除事件；该底层 fixture 为 13 组 | **底层 JASS 回调链与 P4 Lua Subscription 均已实机跑通** |
| D3D handler 合同与覆盖 | manifest 固化 54 个名字、49 个 proxy owner、5 个 canonical owner；验证器通过，且要求 fixture 触达集合与 manifest 的 `test_id` 集合完全相等；底层 fixture 触达 54/54，未触达 0 个（2026-11-15 补齐）；`164/164` 是累计测试总数 | **结构合同与 fixture 覆盖完成**；覆盖数不等于每个 handler 的全部参数边界（设计文档 15.8.4） |
| D3D P0 兼容性 | D3D 不再注册 5 个 canonical 重名；`ShowConsole` 真实显隐通过；`SetKeyboard` 共用 WARK→VK；SrcRect Hrect getter/setter 实机往返通过 | **本批修复完成**；后续新增实现必须使用明确命名/版本化边界，不依赖覆盖 |
| D3D 渲染隔离与产物溯源 | state-block 修复提交为 `8bba4ae`；P3 源码提交 `5dbcfd4` 从 detached clean worktree 以 Win32 Release 完整构建并实际部署。clean proxy、游戏目录 proxy 与 sidecar hash 均为 `CE3775261DDAE7DF1A6B6820E78EC47F8D7D9506E9368F4DD74084F0102BD13E`；clean `yd_japi.dll` hash 为 `8E5D7B18E18DC0667C33EF8C2025C39FA09CB45A6F7EE50AB592EED7D44E5AF4`；同一 clean build 通过 ABI/1000 轮、handler、普通 108/108、D3D 130/130 与真实视觉/鼠标/Shift | **提交态产物溯源闭环完成**：P3 为 `5dbcfd4`，P6 为 `d151fd7`（SDK 0.4.0；clean proxy `0564A518…`、clean `yd_japi.dll` `3A4C8CD1…`，游戏目录 proxy 与 sidecar 回读一致，并用 clean 产物复跑 164/164、116/116、8/8，见 §4 与设计文档 14.4）；主工作区的非 D3D 修改未进入 detached commit |
| D3D 卸载与会话清理 | 独立工具已在隔离目录验证幂等安装/验证/卸载、未知文件保护，并在真实游戏目录完成卸载→再次卸载→未安装验证→普通 108/108→从干净提交产物重装→hash 验证；原生 ABI 的显式 `end_session` 已验证三类资源批量归零和同进程旧 handle 失效；地图级 VM 重置后由 `lua_close` 收尾，`-TestReboot` 在同进程内换图验证 8/8（旧 session 资源归零、旧 handle 失效、新 VM 收到事件） | **部署生命周期、显式 native session 与自动会话生命周期完成**；handler 覆盖与 BLP2 证据已于 2026-11-15 补齐（设计文档 15.8） |
| D3D Lua SDK | `require "jass.d3d"` 返回 Font/Text/Texture 类；P2 对象层与 P3 统一渲染、alpha、asset URI/MPQ、共享 cache、reload 和失败合同均通过公共 fixture、原生合同与真实窗口；fixture 源码不调用裸 RPC；P4 Subscription 与真实鼠标/键盘/enter/leave/click、P5 TTL/device 世代/生命周期订阅已于交互回归通过（164/164），handler 54/54 与 BLP2 内存解码实机通过 | **可用**（2026-11-15 提交态产物溯源闭环）；三份用户文档与 §15.8 门槛结论均已交付 |
| 默认空白地图 | `reference/empty-map/` 的对象层为 0 个 doodad、0 个预放单位（仅保留起始点）；无 Melee 初始化；`Hrif` 继承英雄类型并在运行时设为 10 级；真实窗口确认中央仅 1 个英雄火枪手；普通 `116/116`（2026-10-26）、D3D `164/164`（2026-11-15） | **完成并设为默认** |
| D3D P3 渲染与资源 | Text 使用动态加载的 D3DXFont 绘制 ARGB；Text/Texture 按 `z`、创建序进入同一队列；真实窗口验证 alpha/z。`asset://` PNG、BLP1 与 `game://` BLP 均从 MPQ/资源搜索链以字节缓冲加载；缺失、损坏、穿越和禁用 `file://` 返回稳定错误，失败不增加 handle/cache，失败的换源保留原对象。提交 `5dbcfd4` 的 detached clean build、ABI/handler、普通 108/108、D3D 130/130 和安装 hash 均通过 | **P3 完成**；BLP2 解码（raw/palette/DXT1）已于 2026-11-15 由 `asset://` 内存路径实机验证，但 BLP 只走内存解码，`SetTexture` 路径贴图仍只支持 D3DX 可读格式 |
| D3D 后续主线 | P4 已完成（Subscription + 统一输入，含真实鼠标键盘验收）；P5 已完成（TTL、device 世代/lost/reset 事件、`d3d.on`、`status()/stats()` 诊断、LIFE-11 失败不泄漏与 DEV-03 二十次 reset 后句柄稳定，交互 164/164）；地图级 VM 重置已完成（换图关闭并重建 Lua VM，`-TestReboot` 8/8）；P6 已完成（三份用户文档 + §15.8 门槛结论） | **P6 完成（2026-11-15）**；保留限制：`device_lost` 在 1.27a 窗口模式不可观测、`ShowFpsText` 为弱断言 |

## 4. 验证入口

普通实机回归（无人值守，当前结果为 116/116）：

```powershell
.\tools\deploy.ps1
```

打包器会给每个声明的数组全局生成并在 `main()` 里调用 `JapiForceAllocArrays`（位置在
`initializePlugin()` 之后、`UnitId("LoadScript")` 之前，因为 JASS 的 `InitGlobals()` 晚于
`LoadScript`，而数组块只能由 JASS store 分配）。每个数组固定占 8192×4 = 32 KB；
不需要这批预分配时加 `-NoArrayPrealloc`（例如给内存敏感的地图打补丁）。

D3D handler 合同与覆盖校验（静态，不启动 War3；要求 manifest、注册点与 `test_d3d.lua` 触达集合严格一致）：

```powershell
.\src\src\d3d9\verify_contract.ps1
```

当前输出 `D3D contract PASS: surface=54, proxy=49, canonical=5, fixture=54/54, untested=0`。

可玩垂直切片（波次防守：一个英雄、5 波进攻、基地血量、胜负与重开、D3D HUD，自带断言，结果 23/23）：

```powershell
.\tools\deploy.ps1 -Demo          # 自动跑完 23 条断言后关闭游戏
.\tools\deploy.ps1 -Demo -NoKill  # 留在游戏里继续手玩
.\tools\deploy.ps1 -Demo -Hold    # 自检后保持会话，供真实键鼠驱动（下面的脚本用这个）
.\tools\drive-demo.ps1            # 前台真左键点击 + 真 Q + 真 R，并截 build\demo-live-*.png
```

操作：`Q` 在当前镜头内的光标落点放暴风雪（CD 6 秒、蓝耗 75），左键用引擎自带命令移动英雄
（1.27a 窗口模式的鼠标按钮不进 `message.hook`，所以点击直接放行给游戏），`R`/`F2` 重开一局，
相机锁定英雄。它只用 `jass.common`、`jass.message`、`jass.d3d` 三组公开入口，不碰 hashtable、
`UnitId` 或手写 spec，所以它同时是"地图作者能否直接开工"的样板；玩法与自检的拆法和踩坑见
[MINIMAL-GAME-LOOP.md](guide/MINIMAL-GAME-LOOP.md)。

外来地图接入（地图 JASS 里完全没有 japi 痕迹时，打包器自动注入 bootstrap）：

```powershell
.\tools\make-foreign-map.ps1                       # 生成 build\foreign-map 夹具
.\tools\deploy.ps1 -Demo -BaseMap build\foreign-map
```

注入内容：`japi_ht` / `japi__key` 全局、`JapiBootstrap()` 函数（StartCampaignAI 载入 DLL、
交付哈希表句柄、`UnitId("LoadScript")`）以及 `main()` 末尾的调用。打包在 repack 前用
`tools\pjass.exe` + 1.27.1 的 Common.j/Blizzard.j 校验补丁后的 `war3map.j`；vJass 地图可加
`-SkipJassCheck` 跳过。

JASS wrapper 自动生成（E4）：把每个 bridge handler 以内置 JAPI 的五部曲形状注入 `war3map.j`，JASS 地图直接 `call EXGetUnitAbility(...)`（`-WithJassWrappers` 时 125/125，默认打包 122/122 且第 8c 节打印 `[SKIP]`）：

```powershell
.\tools\deploy.ps1 -WithJassWrappers                            # 打包 + 部署 + 全量回归
.\tools\pack.ps1 -WithJassWrappers                              # 只打包，人工看 build\work\war3map.j
.\tools\gen-jass-wrappers.ps1 -OutFile build\jass-wrappers.j    # 只生成 wrapper 文本
```

生成器读三处注册表（EX native、message bridge 表、D3D manifest），排除 `LoadScript` / `SimulateMapBoot` /
`open_code_run_logs` / `SaveFunc` / `func_bind_trigger_name`（这些不是给 JASS 作者的入口），跳过地图已定义的同名
函数与 H 返回的 handler，输出按分组名排序以保证可复现。注入点在 `endglobals` 之后、`main` 之前；callback 模式下
脚本在插件注册之前编译，所以只能生成 wrapper 函数，不能声明运行时才出现的 `native`（可声明的只有引擎 native 表里已有的名字，见下面的 GetFuncAddr 块）。探针是一支 2 秒 timer：它把 int/string/real/boolean
返回值写进 `udg_lua_wrapper_*`，第 8c 节再用 Lua 直连 bridge 比对；real 用 `GetLittleMapX`/`SetLittleMapX` 的 0.01 往返
（`GetFps` 是实时帧率，两次采样不可比），并必须延后到计时器里执行——加载画面上调 UI 系 handler 会让整局挂住。

GetFuncAddr（内置 JAPI 的 JASS 函数取址链，`126/126`，默认打包下第 8d 节打印 `[SKIP]`）：

```powershell
.\tools\deploy.ps1 -WithGetFuncAddr       # 打包 + 部署 + 全量回归
.\tools\pack.ps1 -WithGetFuncAddr         # 只打包，人工看 build\work\war3map.j
```

`pack.ps1` 在脚本**最前面**（`globals` 之前）插 `native SetHeroLevels takes code f returns nothing`，在 `endglobals` 之后插 `GetFuncAddr(code)`；基座地图带 `udg_lua_getfunc_*` 探针全局时再挂一支 2.20 秒 timer，取三个 code 地址并用内联 `UnitId` 调 `func_bind_trigger_name`（`(IS)V`）与 `SaveFunc`（`(I)V`）。`map/war3map.lua` 入口写 `globals.udg_lua_japi_alive = 1`，JASS 探针先查它——DLL 没起来时调用 `SetHeroLevels` 会跳到 NULL。实测 `addr=19 addr2=20 addr3=19`，第 8d 节用 `TriggerAddAction` + `TriggerExecute` 证明该整数是 VM 认可的 code。声明规则、失败现象与证据见 [planning/JASS-NATIVE-DECLARATIONS.md](planning/JASS-NATIVE-DECLARATIONS.md)。

地图级 VM 重置回归（同一进程内换图：父图建资源 → 6 秒后 `UnitId("SimulateMapBoot")` → 旧 VM 关闭 → 子脚本接管；结果 9/9，含 `func_bind` 标签表随启动清空的断言）：

```powershell
.\tools\deploy.ps1 -TestReboot
```

`-TestReboot` 额外把 `map/tests/reboot_child.lua` 打进 `script\reboot_child.lua`，并在 `war3map.j` 里插入
`JapiRebootProbe`（`call UnitId("SimulateMapBoot")`，6 秒后触发）。断言：旧 VM 确实跑过、`jass.globals` 通道仍可用、
新 session 存活且 id 变化、旧 session 资源归零、旧 Lua handler 被丢弃、新 VM 能建销资源并收到 `resize` 事件。

LocalPoint 真实交互回归（War3 获得前台焦点后按 Q；默认保留一小时等待手测）：

```powershell
.\tools\deploy.ps1 -InteractivePoint
```

交互模式的成功条件不只是 hook 被调用或 submit 返回 `true`，还要求测试大法师实际触发
`EVENT_UNIT_SPELL_EFFECT`，且 `GetSpellAbilityId()` 必须等于 `AHbz`。上次结果为 109/109（旧 108 基线；本次未重跑）。

鼠标目标与技能按钮 UI 回归（鼠标指向/点击镜头中央的敌方城镇大厅；显示阶段按一次 Q，
隐藏保持 10 秒后自动恢复）：

```powershell
.\tools\deploy.ps1 -InteractiveUi
```

成功条件是 `GetTargetObject` 返回值与城镇大厅 handle 精确相等，并且 `AHbz` 在命令卡中
依次呈现 `(0,2) -> nil,nil -> (0,2)`。上次结果为 110/110（旧 108 基线；本次未重跑）。

D3D proxy 实机回归（鼠标移入棋盘后按一次 Shift，再移到棋盘外；成功后脚本自动读取日志并关闭 War3）：

```powershell
.\tools\deploy.ps1 -InteractiveD3D
```

需要保留最终画面人工检查时额外传入 `-NoKill`。

交互模式需要真实输入，无人值守会停在等待提示。自动驱动：

```powershell
.\tools\deploy.ps1 -InteractiveD3D -Hold      # 后台起会话，等待测试结果
.\tools\drive-interactive-d3d.ps1             # 按夹具 [WAIT] 标记自动操作
New-Item -ItemType File build\war3.kill        # 让 -Hold 收尾并关闭游戏
```

`drive-interactive-d3d.ps1` 用 `EnumWindows` 按 pid + 类名 `Warcraft III` 找窗口（`MainWindowHandle` 会挑错窗口），
把窗口提到 `HWND_TOPMOST` 后用合成鼠标/键盘依次驱动三道闸门：悬停棋盘 + Shift + 点击 + 按住拖出、外部松开并
按 Q、24 次窗口 resize；结束时还原 `HWND_NOTOPMOST` 并打印 `Results:` 行。

该入口先运行只调用 `jass.d3d` 的公共 SDK fixture，再运行底层兼容 fixture。成功条件包括三类 userdata 的属性、
依赖、销毁、GC/`__close`、地图 MPQ PNG/BLP1 与游戏 BLP、共享 cache/失败合同、显式混合资源 shutdown，以及
进程内状态位、JASS bridge、真实渲染、鼠标和 Shift 回调，以及 P4 Subscription 的真实鼠标/键盘/enter/leave/click
（交互模式下需要真人手感操作，无人值守会停在等待提示；等待期间需把 War3 窗口置前并按夹具提示点击/按键，
再用 SetWindowPos 改变窗口尺寸 20 次以触发 device reset）。上次结果为累计 164/164：普通基线 116 项 + D3D 48 项
（公共 SDK 功能 8 组 + 底层 bridge 13 组 + Subscription 真实输入 1 组 + P5 生命周期 7 项 + shutdown 1 组 + §15.8 覆盖补齐 17 项）。
其中 P5 证据：TTL 0.15s 的 Text 在跑帧下自动释放且 `stats().texts` 回落、LIFE-11 二十次失败创建不增计数、
`resize=20 (target 20) lost=0 reset=20`、以及二十次 reset 后 Font/Text/Texture 的句柄、内容、位置、高度、rect
与 lifecycle 订阅全部保持。P3 视觉面板还要求 low text 被同 z 后创建贴图遮住、high text
可见，并且 100%/50%/0% 文字分别为不透明、半透明和不可见，同时显示直接来自地图包的棋盘 PNG。54 个兼容名字
中底层 fixture 已触达全部 54 个（2026-11-15 补齐）；164 仍是累计测试数，不能解释为“164 个 D3D API”，也不代表每个 handler 的全部参数边界都被覆盖。由于目标 War3 以提权进程运行，非提权部署进程
无法读取模块列表；该限制不作为成功证据，加载结论由进程内状态、API 往返和真实渲染共同确认。最终窗口同时应显示
平坦空场和唯一的 10 级英雄火枪手（最终被选中并显示英雄界面），不应出现基地、野怪、树木或测试夹具残留。

P1 原生 ABI/session 合同（不启动 War3）：

```powershell
.\src\build\bin\Release\d3d_sdk_contract_test.exe
```

成功条件包括 ABI version/size/capability 协商、错误版本拒绝、session 隔离、三类 type/generation handle、
Font 依赖、全部 P2 基础属性、长字符串 size/buffer 合同、旋转命中、数值校验、P3 alpha/z 与 asset-memory
capability、损坏内存拒绝、失败换源保留旧 source、asset cache 计数、显式 session 批量清理、旧 handle 跨
session 失效、last-error 和 1000 轮生命周期后资源计数归零。

P3 发布候选产物保存在忽略目录 `build\d3d\5dbcfd4-newD3d9.dll` 与
`build\d3d\5dbcfd4-yd_japi.dll`。`src\build.bat` 当前固定切换到主工作区路径，不能直接作为 detached
worktree 的 provenance 命令；本次 clean 构建因此在该 worktree 内使用等价的 MSVC Win32
`cmake -S . -B build-clean` / `cmake --build build-clean --config Release`，且在构建前确认 HEAD 为
`5dbcfd4`、tracked diff 为零。Proxy SHA-256 为
`CE3775261DDAE7DF1A6B6820E78EC47F8D7D9506E9368F4DD74084F0102BD13E`，`yd_japi.dll` SHA-256 为
`8E5D7B18E18DC0667C33EF8C2025C39FA09CB45A6F7EE50AB592EED7D44E5AF4`。

P6 发布候选产物保存在忽略目录 `build\d3d\d151fd7-newD3d9.dll` 与
`build\d3d\d151fd7-yd_japi.dll`，来自提交 `d151fd7`（`chore(d3d): pin the Lua SDK version at 0.4.0`）。
上一版候选 `04f6b7e` 报 `d3d.version()` = `0.3.0-dev`，与「可用」口径矛盾；版本号进入 DLL 字节，所以
溯源改在钉住 `0.4.0` 的提交上重算（`libs_d3d.cpp:35`，`test_d3d_sdk.lua:33` 断言精确字符串）。clean worktree
为 `git worktree add --detach build\clean-d151fd7 d151fd7`：构建前 HEAD 精确为该提交、`git status --porcelain`
为空、tracked diff 为零。构建同样用等价的 MSVC Win32 命令：

```powershell
git worktree add --detach build\clean-d151fd7 d151fd7
cd build\clean-d151fd7\src
cmd /c ""D:\vs2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat" >nul && cmake -S . -B build-clean -G "Visual Studio 17 2022" -A Win32 && cmake --build build-clean --config Release"
```

该 worktree 只用于复核构建：回读 hash 与五组验证完成后即 `git worktree remove --force build/clean-d151fd7`
删除（`build\clean-*` 合计约 200 MB），需要再次复核时按上面命令从提交重建；发布候选 DLL 留在忽略目录
`build\d3d\`，不依赖 worktree 存在。

Clean proxy SHA-256 为 `0564A518EB3CB2F91CD65D0BDC766B9FC5B8709335CFFE5274C1FED24727834B`，clean
`yd_japi.dll` SHA-256 为 `3A4C8CD11E54C3E357236468AA7A18D447E3578F98376071AAF3DB366510D53B`，
`d3d_sdk_contract_test.exe` 为 `87EBB317E9E94AB0F0A333CA55F3F11A384AB937258A68ECF7FFC74A1A2304B6`。
用这两份 clean DLL 部署后：原生 ABI 合同（stress=1000）、`verify_contract.ps1`
（`surface=54, proxy=49, canonical=5, fixture=54/54, untested=0`）、普通 116/116、交互 D3D 164/164
（含 BLP2 raw/palette/DXT1 与 resize=20 生命周期项，日志 `build\p6-164-d151fd7.log`）、地图级 VM 重置 8/8（当时夹具 8 项；此后新增 `func_bind` 清理断言，现为 9 项）
全部通过；游戏目录 `d3d9.dll` 与 `.japi_d3d_proxy.sha256` 回读均为 clean proxy hash，探针 sidecar 为
`952B23437A15F2C65AA9C114920533E63D278D1765B70DA0EC5E709D153EAE6B`。运行时 `yd_japi.dll` 来自地图负载
（`pack.ps1` 把 `-DllPath` 打进地图，日志打印 clean 路径），游戏目录里那份旧文件不参与运行。

交互验证的夹具竞态（前台抢占失败导致 gate 1 重试多一次点击、`TextureRemoveEvent` 绝对基线、合成键重发
间隔过长）由提交 `65bceb5` 修正，只改驱动与地图测试，不含 DLL 改动；修正后用同一份 clean 产物得到
164/164。

注意：在游戏目录直接跑 `tools\d3d-proxy.ps1 -Verify` 会以
`D3DX9_42.dll is required: <game dir>\D3DX9_42.dll` 失败，因为该脚本要求游戏目录内有本地 D3DX9_42.dll，
而 `deploy.ps1` 从 SysWOW64/System32 解析运行时依赖；本次回读因此使用 `Get-FileHash` 加 sidecar 文件。
该差异不影响运行（游戏照常加载代理，进程内状态位达到 `0x7F`）。细节见设计文档 14.4。

## 5. 下一阶段顺序

0. JASS↔Lua 基础桥接（2026-10-26 完成）：UnitId Lua handler、错误路由、整数/字符串/句柄 ABI、globals 写、handle 级别/GC、trigger-action sleep 已纳入普通回归 116/116；JASS 侧运行时声明 native 的路线不纳入支持面。
0b. 开工样板（2026-10-26 完成）：`-Demo` 垂直切片 11/11，外来地图 bootstrap 注入 + pjass 校验通过；下一步是把这条切片扩成真实地图玩法，并补上「任意地图一行命令打包」的文档。
0c. 波次防守 demo（2026-11-16 完成）：把 11 项的垂直切片扩成可玩的一局——`map/game/wave.lua`（游戏循环：5 波、基地血量、伤害/击杀/计分、CD/蓝耗、败北/胜利/重开、HUD 与相机）加 `map/game/demo.lua`（23 条自检），`tools/drive-demo.ps1` 用真实键鼠复核同一构建（日志里真 Q 施法、真 R 重开生效）。`deploy.ps1 -Demo` 23/23，普通回归 122/122、VM 重置 9/9 未受影响。
1. P3（完成）：统一 render queue、D3DXFont/文字 alpha、`asset://`/`game://`、MPQ BLP1/PNG、共享 cache、加载失败合同与提交态 provenance 均已闭环。
2. P4（完成，2026-11-15）：Subscription 与统一鼠标/键盘/enter/leave/click 事件已替代两套 texture 身份；真实输入由窗口 `WM_*` + 异步按键状态提供（游戏内 1.27a 的 CGameUI 分发只送键盘消息），交互回归 141/141 通过。
3. P5（完成，2026-11-15）：TTL、device 世代/lost/reset 事件、`d3d.on` 模块级订阅、`status()/stats()` 诊断、
   LIFE-11 失败不泄漏与 DEV-03 二十次真实 reset 后句柄/属性/订阅稳定已验收（交互 164/164）；`device_lost` 事件在
   1.27a 窗口模式下不可观测，记入已知缺口。
4. 地图级 VM 重置（完成，2026-11-15）：换图时 `callback` 重入 `Initialize()` → 丢弃 Lua handler、清 message/D3D
   分发状态 → `lua_close` 旧 VM → 新图首次 `ExecuteFunc` 重建 VM 并加载新 `war3map.lua`；session 随 VM 关闭自动
   `end_session`，同进程换图回归 9/9（夹具随后新增 `func_bind` 清理断言）；对应 LIFE-09/LIFE-12 的自动部分。
5. P6（完成，2026-11-15）：quickstart、API reference、迁移指南已落地在 `docs/guide/`（见 §6）；§15 两项门槛
   已闭合——D3D handler 兼容面由 fixture 触达 54/54（`verify_contract.ps1` 要求 manifest、注册点与
   `test_d3d.lua` 触达集合严格相等），BLP2 raw/palette/DXT1 与坏编码由 4 个夹具在 `asset://` 内存路径实机验证；
   逐项证据与保留限制见 [D3D-LUA-SDK-DESIGN.md](planning/D3D-LUA-SDK-DESIGN.md) 15.8。`device_lost` 在 1.27a
   窗口模式下仍不可观测，`ShowFpsText` 只有弱断言，覆盖数不等于每个 handler 的全部参数边界。发布产物
   溯源（§16 第 13 项）随后闭环：提交 `d151fd7`（SDK 0.4.0）的 detached clean worktree 重建与 hash 回读已完成（第 4 节、
   设计文档 14.4），因此总览里该行改为「可用」。
6. 数组全局预分配（完成，2026-11-15）：打包器在 `LoadScript` 之前调用 `JapiForceAllocArrays`，对每个声明的
   数组全局做一次 `[8191]` 自赋值，从而把「JASS VM 惰性分配数组块」这件事挡在地图作者视野之外；
   `jass.globals` 的 `index>0` 写入、`#arr` 长度和字符串数组都进了普通回归（116/116），未分配时的静默丢写
   改为一条 `[jass.globals] write ignored` 日志。同时修掉 `class_array.cpp` 的 `__len` 空指针（读取不存在的
   upvalue, `#arr` 会让游戏挂起）。
7. SaveFunc / func_bind（完成，2026-11-15）：按内置地图的线上契约实现 `SaveFunc (I)V` 与
   `func_bind_trigger_name (IS)V` 两个 bridge handler、地址→标签表、`jass.debug` 的
   `jass_func_address`/`save_func_addr`/`func_bind_lookup`/`func_bind_count`/`func_bind_clear`，
   并让崩溃消息在 native 名之后回退查标签表；地图启动（含同进程换图）时清表。普通回归 `122/122`
   （含 6 项新用例：`jass.code(fn)` 生成的真实 code 地址被 `TriggerEvaluate` 执行、中文标签字节精确、
   rebind 覆盖、clear 清空、锚点替换），VM 重置 `9/9`。当时判定的限制是「callback 模式无法在脚本里声明 native」，
   于是内置 `GetFuncAddr` → 脚本 Action 地址被记为没有通道。该结论已在第 10 项证伪并补上 JASS 侧地址来源。
8. JASS wrapper 自动生成（E4）（完成，2026-11-15）：`tools/gen-jass-wrappers.ps1` 从三处 C++ 注册表生成
   内置同形的五部曲 wrapper，`pack.ps1 -WithJassWrappers`（`deploy.ps1` 透传）把 115 个 wrapper 插到
   `endglobals` 之后，并在 `LoadScript` 之后挂一支 2 秒 timer 探针。实机 `125/125`（122 基线 + 3 项：
   int 与 `GetGameVersion` 一致、`Hex(255)`/`GetPluginVersion` 字符串一致、`SetLittleMapX`+`GetLittleMapX`
   的 0.01 实数往返与 `GetChatState` 布尔一致），默认打包仍 `122/122` 且 8c 打印 `[SKIP]`，VM 重置 `9/9` 未受影响。
   踩坑：探针最初内联在 `main()` 里调 UI 系 handler，加载画面上整局挂死（日志停在 `script\war3map.lua loaded`），
   改成 timer 后正常；`GetFps` 无法两次采样比对，故 real 改用 little-map 往返。
9. 三项遗留工程债（数组分配、E4、SaveFunc/func_bind）到此全部闭环。
10. GetFuncAddr（完成，2026-11-16）：先证伪了「callback 模式声明不了 native」的旧结论——真正的规则是
    「名字必须已存在于引擎 native 表」＋「声明必须在第一个函数之前」，违反任一条整局静默回主菜单。
    据此复刻内置 JAPI 的取址隧道：`pack.ps1 -WithGetFuncAddr` 声明引擎隐藏 native `SetHeroLevels (C)V`
    并注入 `GetFuncAddr(code)`；DLL 的 `japi_add` 覆写该节点函数指针，把 code 值写进共享哈希表槽 0。
    实机 `126/126`（122 基线 + 4 项：地址非零且稳定、进 `func_bind_trigger_name`、进 `SaveFunc`、
    交给 `TriggerAddAction` 后函数体真的执行），默认打包 `122/122` 且 8d 打印 `[SKIP]`。
    同一份 DLL 的四项组合实测：默认 `122/122`、`-WithJassWrappers` `125/125`、`-WithGetFuncAddr` `126/126`、
    `-TestReboot` `9/9`。
    规则、T2/T3/T10/T11 证据矩阵与 game.dll 里那段 `Scripts\common.ai` AI 方言 native 表见
    [planning/JASS-NATIVE-DECLARATIONS.md](planning/JASS-NATIVE-DECLARATIONS.md)。至此 §3 里「不含脚本 Action
    地址来源」的限制解除；仍保留的限制是只验证了 1.27a 与 `SetHeroLevels` 一条隧道。

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
| `docs/guide/D3D-LUA-QUICKSTART.md` | 五分钟上手：HUD、timer 更新、订阅、reset、显式关闭 |
| `docs/guide/D3D-LUA-API.md` | `jass.d3d` 完整参考：模块函数、四类对象、事件表、asset URI、错误与生命周期 |
| `docs/guide/D3D-LUA-MIGRATION.md` | 从 `jass.message.texture_*` 与裸 `UnitId`/hashtable RPC 迁移 |
| `docs/re-builtin-japi/` | 逆向证据与实现依据，不承担项目状态维护 |

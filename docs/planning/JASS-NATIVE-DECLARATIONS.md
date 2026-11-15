# JASS native 声明规则

> 适用范围：callback exploit 注入模式（StartCampaignAI → yd_japi.dll），War3 **1.27.0.52240**（本机 `D:\Warcraft III Frozen Throne 1.27a publish`）。
> 本文回答两个问题：**地图脚本能不能自己声明 native，在什么前提下能？** 以及内置 JAPI 的 `GetFuncAddr` 为什么依赖一条引擎里"看不见"的 native。
> 结论已实机验证（2026-11-16），证据见 §2，复现命令见 §7。整体完成度仍以 [`../STATUS.md`](../STATUS.md) 为准。

## 1. 规则

三条，缺一不可：

| # | 规则 | 违反后的现象 |
|---|---|---|
| R1 | 声明必须排在**第一个函数定义之前**（`globals` 块前后都行，但不能夹在任何 `function` 之后） | 整局脚本加载失败：游戏停在主菜单、没有报错弹窗、`C:\ProgramData\japi_debug.txt` 根本不生成（DLL 从未 Initialize） |
| R2 | 声明名必须**已经存在于引擎 native 表**（游戏自己注册过的名字） | 同 R1：回主菜单，无日志 |
| R3 | 声明之后、**首次调用之前**，DLL 必须已经起来并完成 `jass::japi_add` 注册 | 进程内 `0xC0000005 (ACCESS_VIOLATION) at 0023:00000000`（call 落到引擎 AI stub，非 AI 上下文里跳 NULL） |

为什么 R2 成立而"运行时新注册的名字"不行：地图脚本在插件注册任何 native **之前**就被编译完了，脚本里的声明只是给名字留了一个槽位、函数指针是 NULL；只有引擎表里已存在的名字才能被后续 `japi_add` 覆写成功（§4）。所以**不能**用声明给地图加全新 native——新功能一律走 `UnitId` 桥或 `tools/gen-jass-wrappers.ps1` 生成的 wrapper（见 [`EX-NATIVES-PLAN.md`](EX-NATIVES-PLAN.md) E4）。

R1 的手感特别差：失败是**静默**的——地图不报错，直接回主菜单。早期实验把声明放在 pack 注入的 `function JapiForceAllocArrays` **之后**，于是被误判成"callback 模式不支持任何 native 声明"（`tools/pack.ps1` 里那条已被证伪的注释就是这个产物，2026-11-16 已改）。

## 2. 证据

全部在干净进程状态下单变量跑（每个变体：`pack.ps1` → `war3.exe -window -loadfile` → 14 秒后查 `C:\ProgramData\japi_debug.txt` 与窗口截图）。除特别说明，注入点都是 `reference/empty-map/war3map.j` 的 `endglobals` 之后。

| 变体 | 注入内容 | 相对第一个函数的位置 | 结果 |
|---|---|---|---|
| T1 | 无（基线） | — | `122/122 PASS`，日志正常 |
| T2 | `native JapiFakeNothing takes nothing returns nothing` | **在** `JapiForceAllocArrays` 之后 | 存活但无日志，回主菜单 |
| T3 | `native SetHeroLevels takes code f returns nothing`（内置 JAPI 原句） | **在** `JapiForceAllocArrays` 之后 | 同 T2：无日志，回主菜单 |
| T10 | 同 T3，但加 `-NoArrayPrealloc`（pack 不再插 `JapiForceAllocArrays`） | 在第一个函数之前 | **地图正常起来**，`121 passed, 1 failed`（唯一失败是 `-NoArrayPrealloc` 的预期副作用：`jass.globals scalar and array writes` 读未分配数组） |
| T11 | `native JapiFakeNothing takes nothing returns nothing` + `-NoArrayPrealloc` | 在第一个函数之前 | 无日志，回主菜单 |
| T8 | 不改脚本，只在 DLL 初始化期 `jass::japi_add` 注册 `SetHeroLevels` 后从 JASS 调用 | — | 调用进 `SetHeroLevels_capture`（迟到注册依然生效） |
| 内置地图原样 | `reference/builtin-japi/` 不改一行直接打包运行 | 内置地图 `war3map.j:98-100` 三条 native 在 `endglobals` 后、第一个函数前 | 脚本编译通过；插件没被解出（游戏目录无 jass.dll）→ 调用处 `0xC0000005 at 0023:00000000`（R3 的反面证据） |

由 T2/T3 vs T10 反推 R1，由 T10 vs T11 反推 R2，由内置地图反推 R3。

## 3. 引擎侧的隐藏 native

`SetHeroLevels` 不是地图脚本方言（`common.j`）里的函数：`tools/w3x2lni/data/enUS-1.27.1/mpq/Scripts/Common.j` 里 `SetHeroLevels`、`TeleportCaptain`、`GetUnitGoldCost` 命中数为 0。但它在 `game.dll` 里：字符串 `SetHeroLevels` @ `0x6fa57790`、`GetUnitGoldCost` @ `0x6fa57818`（imageBase `0x6f000000`）；`JapiFakeNothing` 在 game.dll / war3.exe 都不存在——这就是 T11 必然失败的物理原因。

引擎的 native 注册是同一段代码里成批做的（`game.dll` `0x6f6fb8d4` 起：`push <签名>` / `mov edx, <名字>` / `mov ecx, 0x6f70a0c0` / `call <register>`），相邻一整段都是 **AI 脚本方言（`Scripts\common.ai`）的 native**：

| 名字 | 签名 |
|---|---|
| `SuicideUnit` | `(II)V` |
| `SuicideUnitEx` | `(III)V` |
| `Sleep` | `(R)V` |
| `StartThread` | `(C)V` |
| `GetAiPlayer` | `()I` |
| `DoAiScriptDebug` | `()B` |
| `GetHeroId` | `()I` |
| `GetHeroLevelAI` | `()I` |
| **`SetHeroLevels`** | **`(C)V`** |
| `SetNewHeroes` | `(B)V` |
| `GetUnitCount` | `(I)I` |
| `GetPlayerUnitTypeCount` | `(Hplayer;I)I` |
| `GetTownUnitCount` | `(IIB)I` |
| `GetUnitCountDone` | `(I)I` |
| `GetUpgradeLevel` | `(I)I` |

这张表不是猜的：它就是 `Scripts\common.ai`（暴雪的 AI 脚本方言，文件头 `$Id: common.ai,v 1.68 2003/05/12`）里声明的 native 集——`common.ai:45 native SetHeroLevels takes code func returns nothing`、`:21 native GetUnitGoldCost takes integer unitid returns integer`、`:108 native TeleportCaptain takes real x, real y returns nothing`、`:126 native StartThread takes code func returns nothing`。这些名字只在 AI 方言里可见，`common.j`（地图脚本方言）从不声明它们，所以普通地图代码看不见；但引擎启动时把 AI 那套 native 一起注册进同一张 native 表，地图脚本按名字声明就能命中（R2）。

证据来源：本机 `D:\Warcraft III Frozen Throne 1.27a publish\jass_temp\Scripts\common.ai`（98,429 B，与同目录 `common.j` 166,690 B、`jass_temp\war3map.j` 101,161 B、`jass_temp\war3mapSkin.txt`、`jass_temp\检测消息.txt` 同一批 2026-06-15 时间戳）。这批文件是内置插件的 `jass.dll` 把脚本集解出来自己重编译留下的（对上 `docs/re-builtin-japi/02-jass-dll.md:494-495` 里的 `jass_temp\war3map.j`、`jass_temp\Scripts\common.j` 字符串），也解释了内置地图为什么能声明那三条 native：它不走游戏自己的 `war3map.j` 编译路径。`tools/w3x2lni/data/enUS-1.27.1/mpq/Scripts/` 里只有 `Common.j` 与 `Blizzard.j`、没有 `common.ai`，所以拿 `Common.j` 搜这三个名字是搜不到的。

`SetHeroLevels` 的语义因此也清楚了：`common.ai:779 function StandardAI takes code heroes, code peons, code attacks`（`:2398 CampaignAI` 同款）里的 `heroes` 是一个 AI 线程函数，`:801` 与 `:2426` 的 `call SetHeroLevels(heroes)` 把它交给引擎去管英雄升级——**参数是一个 code 回调，不是单位 id**。它和地图侧 `common.j:1501 native SetHeroLevel takes unit whichHero, integer level, boolean showEyeCandy`（单数、收 unit 和 level）是两个不同方言里的不同函数；拿 AI 方言的名字做取址隧道安全，原因也在这：标准地图代码根本调不到它。

所以 `SetHeroLevels takes code f` 不是内置 JAPI 瞎编的签名：引擎里它本来就是 `(C)V`——**一个 code 参数、无返回值**，与"设置单位等级"无关（叫 `f` 还是叫 `func` 都只是形参名；这里只需要它"收一个 code、不做事"）。

## 4. 机制：声明 → NULL 节点 → `japi_add` 覆写

引擎 native 节点布局（`src/src/yd_core/warcraft3/jass/hook.cpp:21-37`）：`vfn(4)`、`hash(4)`、`链表(16)`、`key(+20)`、`func_address_(+24)`；表头在 `[[pJassEnv+0x14]+0x20]`。

链路：

1. 脚本声明 `native SetHeroLevels takes code f returns nothing` → 编译器在 native 表里留条目，`func_address_` 为 NULL（R1/R2 决定这一步会不会让整局失败）。
2. DLL 的 `Initialize()` 调 `jass::japi_add((uintptr_t)SetHeroLevels_capture, "SetHeroLevels", "(C)V")`（`src/src/lua_engine/lua_engine/libs_message.cpp:1498`）→ `hook.cpp:210-215` 的 `japi_table_add()` 走游戏自己的注册函数把同名节点的 `func_address_` 改写成我们的 handler（T8 证明 VM 跑起来之后这一步仍然生效：调用是现取节点 +0x1c）。
3. JASS 的 `call SetHeroLevels(f)` → 进 `SetHeroLevels_capture(jass::jcode_t code)`（`src/src/lua_engine/lua_engine/libs_message.cpp:1394-1404`）→ `jass::call("SaveInteger", ht, key, 0, code)` 把 code 值写进共享哈希表槽 0。
4. 地图侧 `function GetFuncAddr takes code f returns integer` → `return LoadInteger(japi_ht, japi__key, 0)`。

`code` 传进 handler 的值是 **VM 代码区里的索引**（JASS 的 `code` 在脚本层面就是整数），不是机器地址：它可以直接喂给 `TriggerAddAction` / `Condition` 这类收 `code` 的 native，也可以当整数塞进 `UnitId` 桥的槽位——`SaveFunc` / `func_bind_trigger_name` 要的就是这个整数。

## 5. `GetFuncAddr` 的落地形态

`tools/pack.ps1 -WithGetFuncAddr`（`tools/deploy.ps1` 同名开关转发）做四件事：

1. 在脚本**最前面**（`globals` 之前）插 `native SetHeroLevels takes code f returns nothing`；地图已声明则跳过。
2. 在 `endglobals` 之后插 `function GetFuncAddr takes code f returns integer`（builtin 同款实现）；地图已定义则跳过。
3. 若基座地图带 `udg_lua_getfunc_ready` 探针全局，再插 `JapiGetFuncAddrTarget` / `...Target2` / `JapiGetFuncAddrProbeActions`：2.20 秒一次性 timer 里先查 `udg_lua_japi_alive`（DLL 活着时 Lua 侧才会置 1），再取三个 code 地址（两个不同函数 + 同一函数取两次），并用内联 `UnitId` 调 `func_bind_trigger_name`（`(IS)V`）与 `SaveFunc`（`(I)V`）。
4. `map/war3map.lua` 入口写 `globals.udg_lua_japi_alive = 1`——DLL 死了脚本根本不会被加载，所以这个写操作等价于"bridge 可用"信号，避免在没有插件的地图上调用 `SetHeroLevels` 跳到 NULL。

实测（`deploy.ps1 -WithGetFuncAddr` → `126/126 PASS`，`map/tests/test_suite.lua` 第 8d 节）：

```
  [8d] GetFuncAddr addr=19 addr2=20 addr3=19 hits=0
  [PASS] GetFuncAddr returns stable non-zero code addresses
  [PASS] GetFuncAddr address reaches func_bind_trigger_name
  [PASS] GetFuncAddr address reaches SaveFunc
  [PASS] GetFuncAddr address runs as a JASS trigger action
```

19 / 20 就是这两个 JASS 函数在 VM 代码区里的索引；同一个函数取两次得同一个值（addr3 == addr），两个函数互不相同。最后一条是**身份证明**：把 `GetFuncAddr` 换来的整数交给 `TriggerAddAction(trig, addr)` + `TriggerExecute`，函数体里 `udg_lua_getfunc_hits` 真的 +1，说明拿到的确实是"VM 认账的 code"，不是随便一个整数。第 8d 节排在 8b 之前，因为 8b 开头会 `func_bind_clear()`，会清掉 8d 要断言的标签。

## 6. 与 `func_bind` 的关系

`src/src/extensions/ex_natives/FuncBind.h` 的三个地址来源（头注释已同步）：

| 来源 | 典型用途 |
|---|---|
| `GetFuncAddr(function f)`（JASS） | 给地图里每个 `InitTrig_*` 动作函数打人类可读标签，运行/崩溃日志能反查"是哪个动作崩了"（内置 JAPI 的「方向键左键崩溃A」就是这么来的） |
| `jass.code(lua_fn)`（Lua） | Lua 函数变成 JASS 可调用的 code（trampoline） |
| `jass.debug.jass_func_address(name)` | native 名字 → 地址 |

崩溃日志里的反查在 `src/src/lua_engine/lua_engine/common.cpp:86-105`（`safe_jass_call` 先查 `jass_function_name`，再回退 `lookup_func_name`，都没有才写 "unknown"）。

## 7. 复现

```powershell
# 只验证声明规则（改 war3map.j 后打包启动，看有没有日志）
.\tools\pack.ps1
.\tools\deploy.ps1

# 验证 GetFuncAddr 全链路
.\tools\pack.ps1 -WithGetFuncAddr
.\tools\deploy.ps1 -WithGetFuncAddr      # 期望 126/126，第 8d 节 4 条
```

同一份 DLL 跑一遍组合矩阵（2026-11-16 实测）：默认 `122/122`、`-WithJassWrappers` `125/125`、
`-WithGetFuncAddr` `126/126`、`-TestReboot` `9/9`。打包阶段 `pjass` 会先验一遍改动后的 `war3map.j`
（`JASS syntax check OK`），所以声明位置写错在打包期就能发现，不必进游戏。

不注入 `-WithGetFuncAddr` 时 8d 打印 `[SKIP] GetFuncAddr probe not injected` 且不计数（与 8c 的 wrapper 探针同一约定）。

## 8. 限制与未验证

- 只枚举到 `game.dll` 里那一段 15 条 AI native，**没有**全量导出引擎 native 表：想换别的取址隧道，得先确认名字在 game.dll 注册序列里。
- 只实测了 `SetHeroLevels`；`TeleportCaptain` / `GetUnitGoldCost` 只解析到字符串与签名，没有单独跑。
- 规则依赖游戏版本：换 1.27 以外的版本要重新确认名字存在、`japi_add` 覆写仍生效。名字清单的权威来源是各版本自己的 `Scripts\common.ai`（1.27a 的副本在游戏目录 `jass_temp\Scripts\common.ai`；`tools/w3x2lni/data` 只有 `Common.j`/`Blizzard.j`），换版本时先解这份再挑隧道。
- `GetFuncAddr` 拿到的是 VM 代码区索引，**没有**换算成 `code_table` 里的绝对地址（`src/src/yd_core/warcraft3/jass/trampoline.cpp:11-15` 那套 `offset/4` 换算）；目前用途只需要"能当 code 用 / 能当整数比大小"。
- R1 的边界是"第一个函数之前"：`globals` 块之前或之后都可以，但**不能**夹在任何 `function` 之后。将来 pack 若要在更早的位置注入别的东西，必须是纯 `globals` 或更早的声明。

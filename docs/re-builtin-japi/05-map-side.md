# 05 地图侧文件分析（builtin-japi.w3x / 内置 Japi1.34）

> 分析对象：`build/_orig_check/`（从原图 builtin-japi.w3x 原样解出）。
> 所有结论均来自对这些文件的直接读取与字节级解析，行号指 `build/_orig_check/war3map.j` 等文件中的 1-based 行号。
> 地图脚本内的中文注释为 UTF-8 编码（war3map.j、main.lua、war3map.wts 均按 UTF-8 读取无误）。

## 一、概述

这张地图是"内置 JAPI（wenhao_plugin）"插件的演示/载体图，地图名为 **内置Japi1.34**（war3map.wts STRING 4，UTF-8；war3map.j:1546 注释 `// 内置Japi1.34`，头部注释 `Map Author: 作者：问号`，`Date: Fri Jul 09 03:17:40 2021`，war3map.j:1546-1552）。

地图侧的加载与桥接结构，就事实层面可以确定为：

1. MPQ 内打包了 `callback`（JASS exploit 脚本）与 `wenhao_plugin.tga`（实为 PE32 DLL）两个导入文件（war3map.imp 声明）。
2. `war3map.j` 的 `main()` 最先调用 `JapiConstantLib_init()`（申请 32 个 8192 项整数数组，共 1 MiB）和 `initializePlugin()`（war3map.j:2186-2187）。
3. `initializePlugin()` 用 `StartCampaignAI(Player(PLAYER_NEUTRAL_AGGRESSIVE), "callback")` 执行 MPQ 中的 `callback` 文件（war3map.j:757），随后把 hashtable 句柄 id 与一个 JASS 函数地址"登记"给插件。
4. 此后地图上所有 JAPI 功能都通过一种固定约定（本文称"五部曲"）调用：参数写入 hashtable → 写入签名字符串 → `UnitId("功能名")` 分发 → 从 hashtable 读回返回值。

**注意（与事实分离的重要声明）**：仓库中 `callback` 文件的**尾部已被项目方修改**（改为导出 `japi.tga` 并调用其 `Initialize` 导出，见 §六的证据）。原版加载链中 `callback` 如何调用 `wenhao_plugin.tga`，只能凭 war3map.imp 与 wenhao_plugin.tga 的 PE 导出表推断，本文将推断明确标注为推断。

## 二、事实清单：MPQ 文件清单与导入关系

### 2.1 (listfile) 全列

`build/_orig_check/(listfile)` 共 22 行，逐行列出（证据：文件全文）：

```
callback
main.lua
war3map.doo
war3map.imp
war3map.j
war3map.mmp
war3map.shd
war3map.w3a
war3map.w3c
war3map.w3e
war3map.w3i
war3map.w3r
war3map.w3u
war3map.wct
war3map.wpm
war3map.wtg
war3map.wts
war3mapMap.blp
war3mapSkin.txt
war3mapUnits.doo
wenhao_plugin.tga
wenhao_plugin逆向分析报告.html
```

要点：

- 除标准地图文件外，混入 4 个非标准文件：`callback`、`main.lua`、`wenhao_plugin.tga`、`wenhao_plugin逆向分析报告.html`。
- **`wenhao_plugin逆向分析报告.html`（34255 字节）被原封不动打进原图 MPQ**——这是地图作者（或后续改图者）打包时混入的文件，属于事实观察；按任务规则本文不读取其内容。
- MPQ 内只有 `main.lua` 一个 Lua 文件；war3map.j:1960 引用的 `exec-lua:wenhao_texture` 对应的 `wenhao_texture.lua` **不在 listfile 中**（见存疑点 §7.4）。

### 2.2 war3map.imp

37 字节，hexdump（证据：`xxd war3map.imp`）：

```
00000000: 0100 0000 0200 0000 0d63 616c 6c62 6163  .........callbac
00000010: 6b00 0d77 656e 6861 6f5f 706c 7567 696e  k..wenhao_plugin
00000020: 2e74 6761 00                             .tga.
```

按 .imp 格式解析（DWORD 版本、DWORD 数量、随后每项 1 字节标志 + NUL 结尾路径）：

- 版本 = 1，文件数 = 2；
- 项 1：标志 `0x0d`，路径 `callback`；
- 项 2：标志 `0x0d`，路径 `wenhao_plugin.tga`。

**结论：地图声明的外部导入依赖恰好就是 `callback` 和 `wenhao_plugin.tga` 两个文件**，与 listfile 中二者存在相互印证。`main.lua` 不在 imp 中，说明它不作为"导入文件"声明，而是作为普通 MPQ 文件存在（由插件的 Lua 引擎按名读取，见 §五）。

### 2.3 (attributes)

708 字节。按属性格式解析（证据：python struct 解析输出）：

- 头部 `6400 0000 0700 0000`：版本号 100，第二 DWORD = 7；
- 其后是 25 条 × 28 字节记录（CRC32 + 8 字节时间戳 + 16 字节 MD5），25 = listfile 22 项 + (listfile)/(attributes)/(signature) 3 个内部文件；
- 其中第 4~10 条记录大面积为 0，第 10 条 MD5 只有前 8 字节非零，与头部声明的"7"不一致。

即：该 (attributes) 数据不自洽（声明数 7 ≠ 实际记录槽 25，多条记录被清零），推测地图被某个打包工具重写 MPQ 时未正确维护该文件。**仅作事实记录，不影响功能结论。**

### 2.4 (signature)

72 字节：前 8 字节全 0，后 64 字节为签名数据（证据：`xxd (signature)`：`00000000: 0000 0000 0000 0000 aba5 b4ae 3e5a af33 ...`）。为 MPQ 弱签名格式（8 字节保留 + 64 字节摘要），仅作存在性记录。

## 三、war3map.j 结构分析

全文件 2243 行，JASSHelper 编译产物（含 `// INLINED!!` 注释、vJass library 展开痕迹）。整体布局：

- 1-97 行：globals 区（vJass 各 library 的全局 + WE 触发器变量 + JASSHelper struct 全局）；
- 98-100 行：三条额外的 `native` 声明（关键，见 §3.2）；
- 104-178 行：JapiConstantLib（内存数组初始化）；
- 181-766 行：library japi（JAPI 桥 wrapper）；
- 767-865 行：library LocalActionLib（本地命令）；
- 866-1484 行：library d3d（D3D 渲染：字体/文字/贴图/事件/模拟按键/控制台 UI）；
- 1485-1543 行：library text、texture（演示代码）；
- 1559 行起：WE 生成的标准内容（InitGlobals/CreateAllItems/CreateUnits.../触发器/main/config）。

### 3.1 全局变量区（证据：war3map.j:1-97）

JAPI 桥全局：

```
hashtable japi_ht=InitHashtable()        // 第 40 行
integer japi__key=StringHash("jass")     // 第 41 行
```

同一 hashtable 被三个 vJass library 以常量别名共用，键值也相同：

- `constant hashtable LocalActionLib___ht=japi_ht`（45 行）、`constant integer LocalActionLib___key=StringHash("jass")`（46 行）；
- `constant hashtable d3d__ht=japi_ht`（50 行）、`constant integer d3d__key=StringHash("jass")`（51 行）。

即 **japi / LocalActionLib / d3d 三个库的 wrapper 全部读写同一个 hashtable 的同一个键（StringHash("jass")）**，靠槽位号（0=签名/返回值，1..n=参数）区分数据。该 hashtable 的句柄 id 会在初始化时交给插件（见 §3.4）。

JapiConstantLib 数组区（证据：4-35 行声明，140-174 行初始化）：

- 共 **32 个 `integer array`**：`i_1` … `i_32`；
- `JapiConstantLib_init_memory` 对每个数组执行 `set i_N[8191]=0`（141-172 行，逐行 32 条）。JASS 数组最大下标 8191，即每个数组撑满 **8192 项 × 4 字节 = 32768 字节**；
- **总量：32 × 32768 = 1 048 576 字节 = 1 MiB**；
- `JapiConstantLib_init` 经 `ExecuteFunc("JapiConstantLib_init_memory")` 调用（175-178 行），且是 `main()` 里的第一个调用（2186 行）。

  用途在地图脚本内没有注释说明；结合 callback 这类 JASS exploit 的通行做法，这些数组提供了大块地址稳定的 VM 内存供读写原语使用——**此用途为推断，地图侧只能证实"开局即申请 1 MiB 整数数组"这一事实**。

### 3.2 三条额外 native 声明（证据：war3map.j:98-100）

```
native SetHeroLevels takes code f returns nothing 
native TeleportCaptain takes real x, real y returns nothing
native GetUnitGoldCost takes integer unitid returns integer
```

事实要点：

- `SetHeroLevels` 不是 common.j 原生函数，此处被声明为接受 `code` 参数——它是 **GetFuncAddr 的取址通道**（§3.5）。
- `TeleportCaptain`、`GetUnitGoldCost` 是 common.j 原生函数，但在本图中被当作数据通道复用：伤害事件系统不用 UnitId 分发，而是直接调它们（证据：434-450 行，`EXGetEventDamageData` 直接 `return GetUnitGoldCost(Type)`，原版 UnitId 调用被注释保留在 435-438 行；`EXSetEventDamage` 直接 `call TeleportCaptain(Damage, 0.00)`，原版 SaveReal/SaveStr/Call 被注释在 444-446 行）。随后的 `YDWEIsEventPhysicalDamage/AttackDamage/RangedDamage/DamageType/WeaponType/AttackType`（453-479 行）全部以 `GetUnitGoldCost(1..6)` 取伤害事件数据。
- **推断**：插件 hook 了这三个 native 的实现（或注册分派），使 `SetHeroLevels(code)` 能把 JASS code 指针写回 hashtable 槽 0、`GetUnitGoldCost(n)`/`TeleportCaptain(r,0)` 变成伤害事件读写口。地图侧只能证实"用法与原生签名不符且被注释标明替代了 UnitId 版实现"，hook 的具体位置属于插件侧，见存疑点 §7.2。

### 3.3 wrapper"五部曲"约定

全图 113 个不同的 `UnitId("...")` 分发名（证据：grep 去重计数 = 113），其 wrapper 统一为如下结构（以 `EXGetUnitAbility`，war3map.j:207-213 为例）：

```
function EXGetUnitAbility takes unit u,integer abilityId returns integer
    call SaveInteger(japi_ht, japi__key, 1, GetHandleId(u))   // ① 参数1写入槽1
    call SaveInteger(japi_ht, japi__key, 2, abilityId)        // ② 参数2写入槽2
    call SaveStr(japi_ht, japi__key, 0, "(II)I")              // ③ 签名字符串写入槽0
    call UnitId(("EXGetUnitAbility")) // INLINED!!            // ④ UnitId 按名分发
    return LoadInteger(japi_ht, japi__key, 0)                 // ⑤ 从槽0读返回值
endfunction
```

五步约定总结：

1. **写参数**：`SaveInteger/SaveReal/SaveStr/SaveBoolean/SaveWidgetHandle/SaveRectHandle(ht, key, n, argN)`，槽位号 = 参数序号（1 起）；handle 参数一律先 `GetHandleId()` 转整数再 `SaveInteger`（仅 LocalTargetOrder 用 `SaveWidgetHandle`、SetTextureSrcRect 用 `SaveRectHandle`）。
2. **写签名**：`SaveStr(ht, key, 0, "(参数类型)返回类型")`，类型字母：`I`=integer，`R`=real，`S`=string，`B`=boolean，`V`=void，`Hxxx;`=handle（如 `Hunit;`、`Hitem;`、`Hdestructable;`、`Hwidget;`、`Hrect;`）。
3. **分发**：`UnitId("功能名")`。注意 common.j 原生 `UnitId` 签名是 `takes integer returns string`，这里传入字符串属于类型混用——**推断**：插件 hook 了 `UnitId`/`AbilityId` 的实现，把字符串参数解析为分发名（地图侧证据：`UnitId(("GetMouseX"))` 等 113 处字符串调用；以及 `UnitId((I2S(GetHandleId(japi_ht))))`，758 行，把 hashtable 句柄 id 转成字符串传入）。
4. 插件按槽 0 的签名解析参数、执行、把返回值写回槽 0。
5. **读返回**：`LoadInteger/LoadReal/LoadStr/LoadBoolean/LoadUnitHandle/... (ht, key, 0)`。返回 handle 的 wrapper 在调用前先 `RemoveSavedHandle(ht, key, 0)`（证据：802、811、819、827 行）。

两种书写顺序都存在：多数 wrapper 是"先参数后签名"，物品/特效一段（488-543 行）是"先签名后参数"，二者效果相同。

### 3.4 initializePlugin 逐行还原（证据：war3map.j:755-764）

```
755  function initializePlugin takes nothing returns integer
756      call ExecuteFunc("japiDoNothing")
757      call StartCampaignAI(Player(PLAYER_NEUTRAL_AGGRESSIVE), "callback")
758      call UnitId((I2S(GetHandleId(japi_ht)))) // INLINED!!
759      call SaveStr(japi_ht, japi__key, 0, "(I)V")
760      call SaveInteger(japi_ht, japi__key, 1, GetFuncAddr(function japiDoNothing))
761      call UnitId(("SaveFunc")) // INLINED!!
762      call ExecuteFunc("japiDoNothing")
763      return 0
764  endfunction
```

逐行：

| 行 | 调用 | 参数 | 作用（事实/推断） |
|---|---|---|---|
| 756 | `ExecuteFunc("japiDoNothing")` | 函数名字符串 | japiDoNothing 是空函数（685-687 行）。作用：确保该函数已被编译/可被引用（事实层面仅是一次按名调用）。 |
| 757 | `StartCampaignAI(Player(PLAYER_NEUTRAL_AGGRESSIVE), "callback")` | 玩家 + 脚本名 "callback" | **以战役 AI 脚本机制执行 MPQ 中的 `callback` 文件**——这是 JASS exploit 的标准入口（AI 脚本与地图脚本共享 VM）。这是整个加载链的起点。 |
| 758 | `UnitId(I2S(GetHandleId(japi_ht)))` | japi_ht 的句柄 id 转字符串 | 把桥用 hashtable 的句柄 id 告知插件（推断：此时 callback 已完成 hook，`UnitId` 已被劫持）。 |
| 759 | `SaveStr(japi_ht, japi__key, 0, "(I)V")` | 签名 | 五部曲第 2 步。 |
| 760 | `SaveInteger(japi_ht, japi__key, 1, GetFuncAddr(function japiDoNothing))` | 槽 1 = japiDoNothing 的 code 地址 | 五部曲第 1 步；GetFuncAddr 见 §3.5。 |
| 761 | `UnitId("SaveFunc")` | 分发名 SaveFunc | 让插件记录一个 JASS 函数地址（推断：供插件回调 JASS 使用）。 |
| 762 | `ExecuteFunc("japiDoNothing")` | 同 756 | 再次按名调用空函数；推断为验证 hook 生效/触发插件回调，**未证实**。 |
| 763 | `return 0` | | 返回值未被调用方使用（main() 2187 行直接 `call initializePlugin()`）。 |

调用顺序：`ExecuteFunc(japiDoNothing)` → `StartCampaignAI("callback")` → `UnitId(ht句柄id)` → 五部曲注册 `SaveFunc(japiDoNothing地址)` → 再 `ExecuteFunc(japiDoNothing)`。

### 3.5 GetFuncAddr 机制（证据：war3map.j:681-684）

```
function GetFuncAddr takes code f returns integer
    call SetHeroLevels(f)
    return LoadInteger(japi_ht, japi__key, 0)
endfunction
```

机制还原：

- JASS 的 `code` 类型本质是一个函数指针。`SetHeroLevels` 被声明为 `takes code f returns nothing`（98 行），**游戏原生并不存在这个 native**；
- 调用 `SetHeroLevels(f)` 后，code 值出现在 `japi_ht`/`japi__key` 槽 0，用 `LoadInteger` 读回——即 **插件侧 hook 了该调用，把 code 参数当作整数写进 hashtable 槽 0**，地图脚本从而拿到函数地址；
- 用途：`func_bind_trigger_name`（691 行）与 `TextureAddEvent`（1338-1339 行，同时取按下/弹起两个回调地址）都通过它把 JASS 函数地址交给插件。

地图侧可证实的到此为止；`SetHeroLevels` 在插件内如何被拦截属于插件/游戏侧（见存疑点 §7.2）。

### 3.6 UnitId 分发名全清单（113 个，按功能分类）

证据：`grep -o 'UnitId(("[^"]*"))' war3map.j | sort -u | wc -l` = 113；每个名字的下表含：签名串、所在 wrapper 函数、war3map.j 行号。参数写入方式除注明外均为 `SaveInteger/SaveReal/SaveStr/SaveBoolean` 按槽位写入（见 §3.3）。

**桥接/系统杂项**

| 分发名 | 签名 | wrapper（行号） | 说明（图中注释） |
|---|---|---|---|
| SaveFunc | (I)V | initializePlugin (761) | 登记 JASS 函数地址 |
| func_bind_trigger_name | (IS)V | func_bind_trigger_name (693) | 函数地址绑定名字，供运行日志反查 |
| open_code_run_logs | (B)V | open_code_run_logs (750) | 开关代码运行记录 |
| EXExecuteScript | (S)S | EXExecuteScript (643) | 执行脚本字符串（Lua） |
| EXDisplayChat | (IIS)V | EXDisplayChat (652) | 模拟聊天 |
| GetMapName | ()S | GetMapName (663) | 获取地图名字 |
| GetGameVersion | ()I | GetGameVersion (670) | 获取魔兽版本 |
| GetPluginVersion | ()S | GetPluginVersion (677) | 获取插件版本 |
| Hex | (I)S | Hex (907) | 16 进制格式化 |
| ShowConsole | (B)V | ShowConsole (1400) | 隐藏/恢复控制台 UI |
| GetLittleMapX / SetLittleMapX | ()R / (R)V | 1406 / 1414 | 小地图图形位置 X |
| GetLittleMapY / SetLittleMapY | ()R / (R)V | 1420 / 1428 | 小地图图形位置 Y |
| ShowFpsText | (B)V | ShowFpsText (846) | 显示/隐藏 FPS |
| GetFps | ()R | GetFps (852) | 获取帧数 |
| GetChatState | ()B | GetChatState (860) | 聊天框状态 |

**鼠标**

| 分发名 | 签名 | wrapper（行号） | 说明 |
|---|---|---|---|
| GetMouseX | ()R | GetMouseX (193) | 鼠标地图 X |
| GetMouseY | ()R | GetMouseY (199) | 鼠标地图 Y |
| GetMouseVectorX | ()R | GetMouseVectorX (878) | 鼠标相对魔兽窗口 X |
| GetMouseVectorY | ()R | GetMouseVectorY (885) | 鼠标相对魔兽窗口 Y |
| GetTargetObject | (V)Hunit; / (V)Hitem; / (V)Hdestructable; | GetTargetUnit (812) / GetTargetItem (820) / GetTargetDestructable (828) | 同一分发名按不同签名返回鼠标指向的单位/物品/可破坏物 |
| GetPlayerSelectedUnit | (I)Hunit; | GetPlayerSelectedUnit (804) | 玩家当前选择单位 |

**本地命令（异步，LocalActionLib）**

| 分发名 | 签名 | wrapper（行号） | 说明 |
|---|---|---|---|
| LocalOrder | (II)V | LocalOrder (777) | 本地无目标命令（order, flags） |
| LocalPointOrder | (IRRI)V | LocalPointOrder (787) | 本地坐标命令 |
| LocalTargetOrder | (IHwidget;I)V | LocalTargetOrder (796) | 本地目标命令；**参数 2 用 `SaveWidgetHandle` 写入**（794 行） |
| SetUnitAbilityButtonShow | (IIB)V | SetUnitAbilityButtonShow (839) | 显示/隐藏技能按钮 |

**技能数据**

| 分发名 | 签名 | wrapper（行号） | 说明 |
|---|---|---|---|
| EXGetUnitAbility | (II)I | EXGetUnitAbility (211) | 单位技能 handle（参数 1 = GetHandleId(u)） |
| EXGetAbilityState | (II)R | YDWEGetUnitAbilityState (223) | 技能属性 |
| EXGetAbilityDataInteger | (III)I | YDWEGetUnitAbilityDataInteger (232) | 技能数据（整数） |
| EXGetAbilityDataReal | (III)R | YDWEGetUnitAbilityDataReal (241) | 技能数据（实数） |
| EXGetAbilityDataString | (III)S | YDWEGetUnitAbilityDataString (250) | 技能数据（字符串） |
| EXSetAbilityState | (IIR)V | YDWESetUnitAbilityState (259) | 设置技能属性 |
| EXSetAbilityDataInteger | (IIII)V | YDWESetUnitAbilityDataInteger (268) | |
| EXSetAbilityDataReal | (IIIR)V | YDWESetUnitAbilityDataReal (277) | |
| EXSetAbilityDataString | (IIIS)V | YDWESetUnitAbilityDataString (286) | |
| EXSetAbilityAEmeDataA | (II)B | EXSetAbilityAEmeDataA (295) | 设置变身技能数据 A |

**单位数据**

| 分发名 | 签名 | wrapper（行号） |
|---|---|---|
| EXPauseUnit | (IB)V | EXPauseUnit (317) |
| EXGetUnitString / EXSetUnitString | (II)S / (IIS)B | 325 / 335 |
| EXGetUnitReal / EXSetUnitReal | (II)R / (IIR)B | 344 / 354 |
| EXGetUnitInteger / EXSetUnitInteger | (II)I / (III)B | 364 / 374 |
| EXGetUnitArrayString / EXSetUnitArrayString | (III)S / (IIIS)B | 384 / 395 |
| EXSetUnitFacing | (IR)V | EXSetUnitFacing (403) |
| EXSetUnitCollisionType | (BII)V | EXSetUnitCollisionType (412) |
| EXSetUnitMoveType | (II)V | EXSetUnitMoveType (420) |

**物品**

| 分发名 | 签名 | wrapper（行号） |
|---|---|---|
| EXSetItemDataString | (IIS)V | YDWESetItemDataString (493) |
| EXGetItemDataString | (II)S | YDWEGetItemDataString (500) |

**特效 / 可追踪物**

| 分发名 | 签名 | wrapper（行号） |
|---|---|---|
| EXSetEffectXY | (IRR)V | EXSetEffectXY (512)；EXSetTrackableXY (618) 复用同名 |
| EXSetEffectZ | (IRR)V | EXSetEffectZ (520) |
| EXGetEffectX / Y / Z | (I)R | 527 / 535 / 543；EXGetTrackableX/Y (626/634) 复用同名 |
| EXSetEffectSize / EXGetEffectSize | (IR)V / (I)R | 552 / 559 |
| EXEffectMatRotateX / Y / Z | (IR)V | 568 / 576 / 584 |
| EXEffectMatScale | (IRRR)V | 594 |
| EXEffectMatReset | (I)V | 601 |
| EXSetEffectSpeed | (IR)V | 609 |

**D3D 渲染：字体**

| 分发名 | 签名 | wrapper（行号） |
|---|---|---|
| CreateFont | ()I | CreateFont (915) |
| DestroyFont | (I)V | DestroyFont (922)（**未写槽 1 参数，疑原图 bug**） |
| GetFontWidth / SetFontWidth | (I)I / (II)V | 929 / 938 |
| GetFontHeight / SetFontHeight | (I)I / (II)V | 945 / 954 |
| GetFontWeight / SetFontWeight | (I)I / (II)V | 961 / 970 |
| SetFontItalic | (IB)V | 978 |
| GetFontFaceName / SetFontFaceName | (I)S / (IS)V | 985 / 994 |

**D3D 渲染：文字**

| 分发名 | 签名 | wrapper（行号） |
|---|---|---|
| CreateText | (ISRRRI)I | CreateText (1007) |
| GetTextString / SetTextString | (I)S / (IS)V | 1015 / 1024 |
| GetTextX / SetTextX | (I)R / (IR)V | 1031 / 1040 |
| GetTextY / SetTextY | (I)R / (IR)V | 1047 / 1056 |
| GetTextTime / SetTextTime | (I)R / (IR)V | 1063 / 1072 |
| GetTextColor / SetTextColor | (I)I / (II)V | 1079 / 1088 |

**D3D 渲染：贴图与事件、模拟键盘**

| 分发名 | 签名 | wrapper（行号） | 说明 |
|---|---|---|---|
| CreateTexture | (SRRRRII)I | CreateTexture (1101) | 路径,x,y,宽,高,颜色,层级 |
| DestroyTexture | (I)V | 1109 | |
| GetTextureX/Y / SetTextureX/Y | (I)R / (IR)V | 1116/1132 / 1125/1141 | |
| GetTextureWidth/Height / SetTextureWidth/Height | (I)R / (IR)V | 1148/1164 / 1157/1173 | |
| GetTextureColor / SetTextureColor | (I)I / (II)V | 1180 / 1189 | |
| GetTextureLevel / SetTextureLevel | (I)I / (II)V | 1196 / 1205 | |
| GetTextureRotation / SetTextureRotation | (I)R / (IR)V | 1212 / 1221 | |
| GetTexturePixelWidth | (I)R | 1228；GetTexturePixelHeight (1236) 也调同名（**疑原图复制粘贴 bug**） | |
| GetTextureSrcRect | (I)Hrect; | 1245 | 返回 rect handle |
| SetTextureSrcRect | (IHrect;)V | 1258 | 参数 2 用 `SaveRectHandle`（1257 行），调用前 `RemoveSavedHandle`（1254 行） |
| SetTexture | (IS)V | 1266 | 换图 |
| SetTextureShow | (IB)V | 1274 | |
| SetTextureTrigger | (IB)V | 1282 | 开关贴图事件 |
| TextureAddEvent | (IIII)I | 1340 | 参数 3/4 是 GetFuncAddr 取的回调地址（1338-1339 行） |
| TextureRemoveEvent | (II)V | 1349 | |
| SetKeyboard | (IB)V | 1357 | 模拟按键按下/弹起 |
| GetWindowWidth / GetWindowHeight | ()I | 892 / 899 | 魔兽窗口尺寸 |

合计 113 个唯一分发名。事件回调侧约定（不是 UnitId 分发，但是同一套机制的一部分）：贴图事件回调里用 `GetExpiredTimer()` 的句柄 id 作父键，从 d3d hashtable 槽 `0xff/0x100/0x101/0xfe` 读触发贴图/键位/动作/事件（证据：1373-1393 行），`GetEventIndex` 返回该 timer 句柄 id（1368-1370 行）——推断插件用"过期计时器"机制把事件参数捎带回 JASS。

### 3.7 func_bind_trigger_name 与 open_code_run_logs

**func_bind_trigger_name**（war3map.j:689-694）：

```
function func_bind_trigger_name takes code functions,string name returns nothing
    call SaveStr(japi_ht, japi__key, 0, "(IS)V")
    call SaveInteger(japi_ht, japi__key, 1, GetFuncAddr(functions))
    call SaveStr(japi_ht, japi__key, 2, name)
    call UnitId(("func_bind_trigger_name")) // INLINED!!
endfunction
```

机制：用 GetFuncAddr 把触发器动作函数的 code 地址取出，连同一个人类可读名字一起交给插件。每一个 `InitTrig_*` 末尾都有一行绑定（证据：1937、1969、2005、2036、2060、2091、2124 行，如 `call func_bind_trigger_name(function Trig_startActions , "start")`）。推断用途：插件的运行日志（见下）按地址反查触发器名。

**open_code_run_logs**（war3map.j:696-751）：

- 先用 Lua 源码字符串拼接并两次 `EXExecuteScript`（720、747 行）：
  - 第一段（698-719 行拼接）建立 `lfunc`/`lfunc_name` 两张表，把 15 个本地函数名映射为位标志：`GetLocalPlayer`(0)、`GetFps`(1)、`GetChatState`(2)、镜头目标/源位置系列(3-10)、`GetMouseX/Y`(11-12)、`GetMouseVectorX/Y`(13-14)，并定义 `save_lfunc_info`；名字带中文标注（如 `'[本地玩家]'`，UTF-8）。
  - 第二段（724-746 行拼接）定义 `get_jass_func_info`/`get_jass_func_msg`，然后 `local storm=require 'jass.storm'`、`storm.load('war3map.j')` 读入地图脚本全文，用 `gsub('function%s+([%w_]+)%s+takes(.-)endfunction', ...)` 逐函数扫描，统计每个 JASS 函数调用了哪些本地函数（位或累积到 `lfunc[name]`）。
  - **事实价值**：这两段 Lua 证明插件内嵌 Lua 引擎提供 `jass.storm` 模块（可读 MPQ 文件）并能执行任意 Lua 字符串。
- 最后五部曲调用 `UnitId("open_code_run_logs")`，签名 `(B)V`，参数为开关布尔（748-750 行）。
- 触发器"打开跟踪器1"在 0 秒时调用 `open_code_run_logs(true)`（2050-2053 行）。

### 3.8 AbilityId("exec-lua: ...") 用法

全图 2 处（证据）：

- war3map.j:1960 `call AbilityId("exec-lua:wenhao_texture")`（触发器"运行lua例子"动作，1959-1963 行）；
- war3map.j:2026 `call AbilityId("exec-lua: main")`（触发器"start"动作，2025 行注释原文：`// 原版lua引擎入口是 Cheat   内置版lua引擎入口换成AbilityId`）。

事实：

- common.j 原生 `AbilityId` 签名为 `takes integer returns string`，此处传字符串，与 `UnitId` 同属类型混用分发（同一推断：插件 hook）。
- 地图作者注释明示：**原版（YDWE 系）Lua 引擎入口是 `Cheat`，内置版改为 `AbilityId("exec-lua:模块名")`**。
- `exec-lua: main` 对应 MPQ 中的 `main.lua`（存在）；`exec-lua:wenhao_texture` 对应的 Lua 文件不在 MPQ 中（存疑点 §7.4）。
- start 触发器（2015-2029 行）在 `exec-lua: main` 之前还演示了技能数据修改：`YDWESetUnitAbilityDataReal(...,'AHbz',1,105,0.50)`（设 CD）、`YDWESetUnitAbilityDataInteger(...,104,0)`（设耗蓝），data_type 104/105 即注释表中的"魔法消耗/冷却时间"（1782/1777 行注释）。

### 3.9 main() 中的初始化时序（证据：war3map.j:2185-2205）

```
2186  call JapiConstantLib_init()
2187  call initializePlugin()
...   SetCameraBounds / 声音 / CreateAllItems / CreateAllUnits / InitBlizzard
2198  call ExecuteFunc("jasshelper__initstructs226778796")
2199  call ExecuteFunc("text___init")
2200  call ExecuteFunc("texture___init")
2202  call InitGlobals()
2203  call InitCustomTriggers()
2204  call ConditionalTriggerExecute(gg_trg_______lua______u) // INLINED!!
```

即：**内存数组 → 插件加载/登记（callback） → 演示库初始化 → 触发器初始化 → 立即执行"运行lua例子"触发器**。另注意 `text___init`（1486-1512 行）会在屏幕上写出"苟利国家生死以，岂因祸福避趋之。"（1490 行，UTF-8 中文字符串），`texture___init`（1530-1541 行）创建自定义鼠标贴图并绑定 `TextureAddEvent(mouse_texture, 'W', ...)`——它们都由 main 直接调用，属插件 D3D 能力的常驻演示。

## 四、main.lua 分析（插件 Lua 引擎能力面的实例证据）

`build/_orig_check/main.lua` 201 行，UTF-8。模块引用（1-5 行）：

```
local message = require "jass.message"
local jass = require "jass.common"
local slk = require "jass.slk"
local runtime = require "jass.runtime"
local japi = require "jass.japi"
local keyboard = message.keyboard
```

- `runtime` 被 require 但全文未使用（grep `runtime\.` 无结果）——仅证明 `jass.runtime` 模块存在。
- 由此证实插件 Lua 引擎至少提供 5 个模块：`jass.message`、`jass.common`、`jass.slk`、`jass.runtime`、`jass.japi`。

用到的 API（证据：行号）：

- `message.order_enable_debug()`（11）——注释自述"测试代码，显示本地发布的命令，一定不要在正式环境中使用"（8-10 行）。
- `message.hook(msg)` 全局回调（179-201）：拦截键盘消息；`msg.type == 'key_down'` 时遍历技能栏 4×3 格子，用 `message.button(x, y)`（188）取 `(ability, order, target_type)`，再用 `slk.ability[ability].Hotkey`（189-191）比对键码 `keyboard[hot_key] == msg.code`（192），命中则 `cast_ability` 并 `return false` 吞掉消息（注释 157/199-200 行说明返回值语义：false 丢弃、true 放行）。
- `message.selection()`（49、72、103、180）：本地当前选中单位。
- `message.mouse()`（153）：鼠标地图坐标。
- `message.order_point(order,x,y,flags)`（156）、`message.order_target(order,x,y,target,flags)`（164）、`message.order_immediate(order,flags)`（169）：本地发命令；flags 位定义在 144-149 行：`队列=1<<0`、`瞬发=1<<1`、`独立=1<<2`、`恢复=1<<5`。
- `slk.ability[ability]`（99、189）及 `slk.reqLevel`（63）：直接访问 slk 技能数据。
- `japi.EXGetUnitAbility`、`japi.EXGetAbilityDataInteger(..., level, 0x64)`（105）：Lua 侧同样暴露 JAPI（0x64=100，即技能"目标允许"数据类型，与 war3map.j 注释表对应）。
- `jass.common` 原生群：`GetOwningPlayer/IsUnitInvisible/IsUnitType/GetUnitAbilityLevel/IsUnitEnemy/IsUnitAlly/IsHeroUnitId/CreateGroup/GroupEnumUnitsInRange/FirstOfGroup/GroupRemoveUnit/GetUnitX/GetUnitY`、`UNIT_TYPE_DEAD/UNIT_TYPE_MAGIC_IMMUNE`（49-138 行）。

功能概括：main.lua 实现"按下技能快捷键 → 在本地直接对鼠标处最优目标（英雄优先、距离优先，96-142 行）瞬发技能"的演示，是插件 `jass.message` 钩子 + 本地命令 + slk 读取 + Lua 侧 JAPI 四项能力的组合实例。

## 五、地图信息与其他对象数据（附带事实）

- war3map.w3i：格式版本 25（1.27 系），地图名/描述引用 TRIGSTR_004/006/007（证据：w3i 偏移 12 起 `TRIGSTR_004\0TRIGSTR_007\0TRIGSTR_006`）；war3map.wts（UTF-8 带 BOM）中 STRING 4 = `内置Japi1.34`，STRING 6/7 = `作者：问号`，STRING 26 = `内置Japi1.34界面`。
- war3map.w3a（684 字节，证据：hexdump）：包含对 `AHtc` 的修改（alev 等字段）和一个自定义技能 **`A000`（基础技能 `AUcs`）**，字段 anam=TRIGSTR_045、aret=TRIGSTR_046、arut=TRIGSTR_047、Ytip=TRIGSTR_048、aart/arar=`x.blp`；wts STRING 45 注释为"技能： A000 （命令卡移动技能）"（wts 偏移 0xEE 起，UTF-8）。
- 版本适配：war3map.j 触发器"判断版本例子"（1900-1930 行）对 `GetGameVersion()` 返回的 6374/6387/6401/7000/7085/7205 六个值分别显示 TRIGSTR_049~054；callback 内部也有四路版本分派（见 §六）。两者共同说明该插件针对多个 1.24~1.27+ 游戏版本做适配（具体版本号对应关系未在地图侧注明，存疑）。

## 六、加载链：事实与推断

### 6.1 事实

1. war3map.imp 声明导入 `callback` 与 `wenhao_plugin.tga` 两个文件（§2.2）。
2. `initializePlugin` 用 `StartCampaignAI(Player(PLAYER_NEUTRAL_AGGRESSIVE), "callback")` 执行 callback（war3map.j:757）。
3. `wenhao_plugin.tga` 实为 PE32 DLL：e_lfanew=0xF8、机器码 0x14C（i386）、ImageBase 0x10000000、5 个节（.text/.rdata/.data/.rsrc/.reloc）（证据：python 解析 PE 头）。
4. 其导出目录：**内部名 `wenhao_plugin.tga`，导出函数仅 2 个：`call`（序号 1，RVA 0x1100）与 `get`（序号 2，RVA 0x1230）**，时间戳 0x59E23263（证据：导出目录解析，导出 RVA 0x12250 → 文件偏移 0x10E50）。
5. **callback 尾部已被项目方修改**（证据：callback 1040-1054 行）：
   - 1040-1042 行：把当前进程 id 转十进制字符串，再拼上 `.dll`（`WriteRealMemory(buffer[1]+i, 0x6c6c642e)`；0x6c6c642e 按小端存为字节 `2E 64 6C 6C` 即 ".dll"）作为落地 DLL 文件名；
   - 1044-1046 行：写入 `0x6970616A, 0x6167742E` = 小端字节 **`japi.tga`**，调 `ExportFileFromMpq(buffer[2], buffer[1])` 把它从 MPQ 导出、再 `LoadLibrary`；
   - 1050-1052 行：写入 `0x74696E49, 0x696C6169, 0x0000657A` = **`Initialize`**，经 `GetModuleProcAddress` 取地址后 `CallCdeclWith1Args(i, 0)` 调用。
   - 这与事实 4 直接矛盾：**wenhao_plugin.tga 的导出表里没有 `Initialize`，只有 `call`/`get`**——证明这段尾部是为项目方自己的 `japi.tga` 改写的，不是原版。
6. callback 前段（未被指认为修改的部分）含版本分派：1021-1028 行按读到的内存值 2586768 / 5205600 / 5276928 / 5276840 分别调用 `newInit27a / newInit26 / newInit24b / newInit24e`——即 callback 适配 1.27a/1.26/1.24b/1.24e 四个游戏版本。

### 6.2 推断（与上述事实分离）

- 原版 callback 尾部应是：从 MPQ 导出 **`wenhao_plugin.tga`** 到落地文件、LoadLibrary，然后调用其导出函数（`call` 和/或 `get`，二者之一的语义无法从地图侧确定）。
- 推断依据：imp 只声明这两个导入文件（事实 1），插件 DLL 只导出 `call`/`get`（事实 4），而现有尾部的字符串（`japi.tga`、`Initialize`）与该 DLL 不匹配（事实 5）。
- **无法证实**：原版调用的是 `call` 还是 `get`、参数是什么；现 callback 尾部把原版的哪些行替换掉了（原版尾部行数/内容不可考）。

## 七、存疑点

1. **§7.1 JapiConstantLib 1 MiB 数组的精确用途**：地图脚本只申请不使用（i_1..i_32 在初始化后无任何读写，grep 全文仅 141-172 行出现）。推断供 exploit 读写原语/稳定内存布局使用，未证实。
2. **§7.2 `SetHeroLevels`/`GetUnitGoldCost`/`TeleportCaptain` 的拦截位置**：地图侧只能证实调用约定，hook 发生在插件内（UnitId/AbilityId 字符串分发同理），具体机制需插件侧证据。
3. **§7.3 原版 callback 尾部**：`japi.tga`+`Initialize` 为项目方改写（§6.1-5 的二进制证据），原版调用 `call` 还是 `get`、参数如何，未证实。
4. **§7.4 `exec-lua:wenhao_texture`**：MPQ 中无 `wenhao_texture.lua`（listfile 无此文件），该模块可能内置于插件、或该触发器静默失败，未证实。
5. **§7.5 (attributes) 不自洽**：声明数 7 与实际 25 槽、多条清零记录不符（§2.3），原因（打包工具行为？）未证实。
6. **§7.6 `GetGameVersion` 六个数值（6374/6387/6401/7000/7085/7205）与游戏版本的对应表**：地图只给出数值与 TRIGSTR 提示串，wts 中未含 049~054 的内容（wts 仅见 STRING 2/3/4/6/7/8/26/45），对应关系未证实。
7. **§7.7 DestroyFont/GetTexturePixelHeight 两处疑似原图 bug**（DestroyFont 未写参数槽；GetTexturePixelHeight 分发名写成 GetTexturePixelWidth）：仅按字面代码记录，未验证运行时行为。

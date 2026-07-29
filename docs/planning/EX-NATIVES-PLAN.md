# EX* Natives 补全与实测——详细实现计划

> 状态：待实施  
> 依据：`docs/re-builtin-japi/05-map-side.md` §3.6（内置 JAPI 全部 113 个 UnitId 分发名分类清单）、`src/src/extensions/ex_natives/Initialize.cpp`（我方 47 个已注册 handler）、当前 60/60 测试基线  
> 范围说明：**D3D 渲染系（字体/文字/贴图/贴图事件，共 ~46 个）不在本计划**——那是独立任务（对应逆向 04 文档的 newD3d9.dll 渲染层）。本计划覆盖其余全部差距 + 已注册 handler 的真实对象实测。

---

## 1. 现状盘点

### 1.1 已注册（47 个，从未对真实游戏对象验证过）

| 类别 | 数量 | 名单 |
|---|---|---|
| 单位数据 | 12 | EXGetUnitString/EXSetUnitString、EXGetUnitReal/EXSetUnitReal、EXGetUnitInteger/EXSetUnitInteger、EXGetUnitArrayString/EXSetUnitArrayString、EXPauseUnit、EXSetUnitCollisionType、EXSetUnitMoveType、EXSetUnitFacing |
| 技能数据 | 14 | EXGetUnitAbility、EXGetUnitAbilityByIndex、EXGetAbilityId、EXGetAbilityState/EXSetAbilityState、EXGet/SetAbilityDataReal、EXGet/SetAbilityDataInteger、EXGet/SetAbilityDataString、EXSetAbilityAEmeDataA、EXGetBuffDataString/EXSetBuffDataString |
| 物品 | 2 | EXGetItemDataString、EXSetItemDataString |
| 特效 | 13 | EXSetEffectXY/EXSetEffectZ、EXGetEffectX/Y/Z、EXSet/EXGetEffectSize、EXEffectMatRotateX/Y/Z、EXEffectMatScale、EXEffectMatReset、EXSetEffectSpeed |
| 伤害事件 | 2 | EXGetEventDamageData、EXSetEventDamage |
| 显示/信息 | 4 | EXDisplayChat、GetMapName、GetGameVersion、GetPluginVersion |

**风险标记**：这些 handler 全部未经过真实对象测试。已知隐患（来自代码审查）：`EXSetUnitFacing` 对 `obj+0x28` 无 null 检查（UnitState.cpp:822）；`EXGet*String` 系存在 `create_string(from_string(create_string(...)))` 双重转换导致字符串表泄漏；`unit_property` 内存偏移表仅适配 1.27a。实测的第一目的就是把这类问题逼出来。

### 1.2 签名与内置 JAPI 的差异（实测时需裁决）

| 分发名 | 内置 JAPI | 我们 | 备注 |
|---|---|---|---|
| EXSetAbilityState | (IIR)V | (IIR)B | 我们多返回布尔，属超集 |
| EXSetItemDataString | (IIS)V | (IIS)B | 同上 |
| EXSetEffectZ | (IRR)V | (IR)V | **不一致**——内置版两个 real 参数，需核对逆向 05 文档 520 行 wrapper 语义后统一 |
| EXGetUnitAbilityByIndex / EXGetAbilityId | 无 | 有 | 我方超集，保留 |

---

## 2. 差距清单（对标 113，扣除 D3D ~46）

### 2.1 系统杂项（11 个缺失）

| 分发名 | 签名 | 实现思路 | 难度 |
|---|---|---|---|
| EXExecuteScript | (S)S | lua_loader.cpp 里已有现成实现（`EXExecuteScript` 函数当前是死代码），接成 bridge handler 即可 | 低 |
| Hex | (I)S | `snprintf("%08X")` | 低 |
| ShowConsole | (B)V | CGameUI 控制台显隐（GameInfo 系，参考 message.show_console 内部） | 中 |
| GetFps | ()R | 读游戏 FPS 值（GameInfo 内存读取） | 中 |
| ShowFpsText | (B)V | 开关 FPS 显示 | 中 |
| GetChatState | ()B | 聊天框是否打开（CGameUI 状态位） | 中 |
| GetLittleMapX / SetLittleMapX | ()R / (R)V | 小地图图像坐标（CGameUI+偏移） | 中 |
| GetLittleMapY / SetLittleMapY | ()R / (R)V | 同上 | 中 |
| SaveFunc + func_bind_trigger_name | (I)V / (IS)V | 崩溃日志/运行日志反查基础设施，依赖 GetFuncAddr 通道（内置版用 hooked SetHeroLevels）。**判定：降级为可选**——我们的 func_bind 场景（code_run_logs）已另有 stub | 高（可选） |

### 2.2 鼠标 / 本地命令 / 选择（10 个缺失）

| 分发名 | 签名 | 实现思路 | 难度 |
|---|---|---|---|
| GetMouseX / GetMouseY | ()R | 包装 `jass.message` 内部的世界坐标查询（已有） | 低 |
| GetMouseVectorX / GetMouseVectorY | ()R | 包装 message.mouse_screen 内部 | 低 |
| GetPlayerSelectedUnit | (I)Hunit; | 包装 message.selection 内部（按玩家过滤） | 低 |
| GetTargetObject | (V)Hunit;/Hitem;/Hdestructable; | 鼠标指向对象查询（CGameUI 目标对象，新内存路径，需逆向 offset） | 高 |
| LocalOrder / LocalPointOrder / LocalTargetOrder | (II)V / (IRRI)V / (IHwidget;I)V | 包装 message.order_immediate/point/target 内部（已有完整实现） | 低 |
| SetUnitAbilityButtonShow | (IIB)V | 技能按钮显隐（CGameUI 按钮层，新内存路径） | 高 |

注：jass.message 已暴露等价 Lua API（`message.mouse/order_*/selection`），本批是把同一能力对齐到内置 JAPI 的 **native 命名与签名**，让 JASS 侧 wrapper 也能用。

### 2.3 明确排除（属任务 2）

CreateFont/DestroyFont/GetFont*/SetFont*（10）、CreateText/GetText*/SetText*（11）、CreateTexture/GetTexture*/SetTexture*/TextureAddEvent 等（~23）、GetWindowWidth/Height（2）——共 ~46 个，连同 newD3d9.dll 渲染层一起做。

---

## 3. 实测设施设计（E1 的地基）

### 3.1 Fixture（测试夹具）

全部通过 `jass.*` 在 Lua 侧现场创建，不依赖地图摆放，保证确定性：

| Fixture | 创建方式 | 用途 |
|---|---|---|
| 测试单位 | `CreateUnit(Player(0), 'hfoo', x, y, 270)` + `SetUnitInvulnerable(u, true)`，放在地图角落远离野怪 | 单位数据 12 项、技能挂载点、选择/命令目标 |
| 技能 | `UnitAddAbility(u, 'AHbz')`（风暴之锤） | 技能数据 14 项（含变体系 AEmeDataA 用 'AEme' 系技能的判定） |
| 物品 | `CreateItem('rat3', x, y)`（攻击之爪） | 物品数据 2 项 |
| 特效 | `AddSpecialEffect("Abilities\\Spells\\Human\\HolyBolt\\HolyBoltSpecialArt.mdl", x, y)` | 特效 13 项（位移/缩放/旋转/速度） |
| Buff | 对单位施放 'Bpsd'（心灵火）或用 `UnitAddAbility`+施法产生 | EXGet/SetBuffDataString |
| 伤害事件 | `TriggerRegisterPlayerUnitEvent(trig, Player(0), EVENT_PLAYER_UNIT_DAMAGED)` + `jass.code` 回调 + `UnitDamageTarget` 自伤 | EXGetEventDamageData/EXSetEventDamage（**判定为 stretch 项**，见风险 R3） |

清理：每组测试结束 `RemoveUnit/RemoveItem/DestroyEffect/DestroyTrigger`，避免互染。

### 3.2 测试组织

- 新文件 `map/tests/test_ex.lua`，自带 fixture 生命周期管理；`test_suite.run` 汇总其 pass/fail 进同一行 `Results:`（deploy 判定不变）。
- 测试矩阵逐 native 一行：调用 → 断言返回值/副作用（Set 类断言"读回一致"）。
- 环境约束：base.w3m 是 Turtle Rock 近战图（有野怪营）。fixture 一律无敌 + 放角落；套件在开局 60 秒内完成，野怪不会到达。

---

## 4. 实施批次与验收

### E1：已注册 47 个的实测（预期暴露真 bug）

1. 搭 fixture 设施（§3.1）+ test_ex.lua 骨架（0.5d）
2. 单位数据 12 项测试（0.5d）→ 修 bug（重点：EXSetUnitFacing null 检查、字符串泄漏）
3. 技能数据 14 项测试（1d，data_type 取值表参考 05 文档注释：104=耗蓝、105=CD、0x64=目标允许）
4. 物品 2 + 特效 13 项测试（0.5d，**裁决 EXSetEffectZ 签名**）
5. 信息/显示 4 项 + EXDisplayChat（0.5d）
6. 验收：deploy 60+~45 全绿；已修 bug 单列记录

### E2：系统杂项 9 个（SaveFunc/func_bind 降级可选）

1. EXExecuteScript 接死代码 + Hex（0.5d）
2. GetFps/ShowFpsText/GetChatState/ShowConsole（1d，GameInfo 系内存路径）
3. GetLittleMapX/Y + Set×2（0.5d）
4. 验收：deploy 全绿 + JASS 侧 smoke（EXExecuteScript("return 1+1") == "2"）

### E3：鼠标/本地命令 8 个（GetTargetObject/SetUnitAbilityButtonShow 视难度浮动）

1. GetMouseX/Y + GetMouseVectorX/Y + GetPlayerSelectedUnit（0.5d，纯包装）
2. LocalOrder/LocalPointOrder/LocalTargetOrder（0.5d，纯包装）
3. GetTargetObject ×3（1d，新内存路径，参考 ujapi 手册语义）
4. SetUnitAbilityButtonShow（1d，CGameUI 按钮层；如超出则降级到任务 2 与 D3D 按钮系合并）
5. 验收：deploy 全绿 + 真实鼠标行为 smoke

### E4（可选）：JASS wrapper 自动生成

按注册表为每个 native 生成五部曲 wrapper 注入 war3map.j（与内置 JAPI 图的 wrapper 同形），让 JASS 地图作者直接 `call EXGetUnitAbility(...)`。独立于 E1–E3，随时可做（0.5d）。

总估：E1 ≈ 3d，E2 ≈ 2d，E3 ≈ 2–3d。每批结束 deploy 全绿 + commit。

---

## 5. 风险与对策

- **R1 内存偏移漂移**：unit_property/技能结构偏移仅适配 1.27a。对策：实测用例先行暴露；失败处回到 YDWE `UnitState.cpp`/`AbilityState.cpp` 原始定义复核，再不行用内置 japi 的 jass.dll 反汇编（02 文档）对表。
- **R2 字符串泄漏放大**：测试中高频调用 EXGet*String 会把游戏字符串表撑大。对策：E1 顺带修双重转换（UnitState.cpp:868、AbilityState.cpp:865/925/934），测试断言改为复用同一 jstring。
- **R3 伤害事件不可测**：EXGetEventDamageData 依赖游戏伤害事件上下文，Lua 侧构造需要 trigger+自伤闭环，可能踩到事件 hook 的坑。**降级为 stretch**：E1 先跳过，E3 末评估，做不出就标"已实现未实测"如实记录。
- **R4 近战图不确定性**：野怪/中立 AI 干扰 fixture。对策：无敌 + 角落 + 限时；必要时换空白基座图（reference/japi-base 的空白图可作备选 -BaseMap）。
- **R5 EXSetUnitFacing 崩溃**：已知无 null 检查。对策：E1 第一步先修，再跑测试。

---

## 6. 完成定义（DoD）

1. 非 D3D 的 113 项（67 个）中：**已注册 47 全部有实测用例并通过**；缺失 20 个中至少 17 个实现并通过（SaveFunc/func_bind_trigger_name/GetTargetObject 允许降级）。
2. deploy.ps1 一次跑完：总测试数 ≥ 100，全绿。
3. 签名差异表（§1.2）逐项有裁决记录。
4. 本文档追加实测结论附录（发现的 bug 与修法）。

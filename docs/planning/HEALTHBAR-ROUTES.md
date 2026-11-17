# 头顶血条：社区路线调研与选型（War3 1.27a）

> 状态：**方案评估，未开工**。日期 2026-11-16。
> 相关：`map/game/wave.lua`（现行 D3D 条实现）、`docs/STATUS.md`。

## 0. 问题边界

用户诉求有两条，混在一起会选错方案：

1. **位置/跟随**：「移动时跟不上」。已定位为 overlay timer 采样率（原 0.10s = 10Hz，而单位坐标按逻辑帧更新 ≈24–30Hz），已改为 0.02s 快 tick 并实机验证 33/33、像素级与原生同构。
2. **是否走「原生 UI 层」**：即让引擎自己画条，我们不再自绘。这是本文要回答的。

关键约束（已实测/已确认）：

- 我们跑在 1.27a，**没有 Frame API**（`BlzGetFrameByName`/FDF 自定义 UI 是 1.31/Reforged 才有）。
- 引擎自己的头顶条由客户端偏好项 `healthbars` 控制（`HKCU\Software\Blizzard Entertainment\Warcraft III\Gameplay`，默认 0），**启动读一次、不热生效**；打开后引擎对屏幕内**所有**单位画条（我们已用它当 oracle 把三种条的锚点校准到 ±2px）。
- 引擎条的锚点是**模型的 overhead 附着点**（Hive/GA 两地一致的说法），不是硬编码常量 —— 我们现在的 `BAR_HEAD = { creep = 88, hero = 93, base = 409 }` 只是对 demo 里三种模型拟合出来的近似值。
- 单位世界坐标每个逻辑帧才变一次（实测本图 ≈24Hz，4 个条时 0.5s 内 48 次更新）。**任何方案的「跟随时鲜度」上限都是这个逻辑帧率**，除非做插值。

## 1. 社区实测过的五条路线

### A. 引擎原生条：注入「显血」命令（Alt / `[` / `]` 等效）

- 机制：War3 把「按住 Alt 显示血条」实现为**输入命令** 274（按下）/275（抬起）进入命令队列。社区插件 WarcraftHelper 的 `showhpbar` 插件就是 inline hook 命令入队函数，每 1000ms 补发一次 274，从而常显血条。
  - 源码：<https://github.com/LoveBeforT/WarcraftHelper/blob/master/WarcraftHelper/plugin/showhpbar.cpp>
  - 该实现里 `SetCmdToQueue(cmd, 274, ...)` 的第一个参数是命令目标玩家 id（代码里把 27 映射成 7/8，具体语义未确认），274/275 是显血按下/抬起命令；同时它用 `System::IsKeyDown(VK_OEM_4)` 检查 `[` —— 社区早已知道 `[`/`]` 等价于按住 Alt。
- 版本覆盖：该插件只在 1.20e 生效（其余版本 `default: return;`），因为 1.24+ 游戏设置里已有「始终显示生命条」。**但命令机制本身在 1.27a 仍存在**，需要在 1.27a 定位等价的命令入队函数 + 确认 274/275 常量。
- 外部等价做法：AHK/`SendMessage` 模拟按住 `[` 或 Alt（war3tools 等 1.15~1.30+ 工具都这么干）。缺点是占用真实按键/Alt 状态，会和改键、聊天冲突。
- 产出：**引擎的条**，跟随天然正确、零 D3D 成本；不可定制（颜色/尺寸/宽度/范围/HUD 避让都归引擎），对所有单位生效。

### B. 引擎原生条：内存改造（改引擎条的颜色/尺寸/偏移）

- 机制：社区内存 hack DLL 直接改引擎的 HP 条绘制参数，并把它们暴露成 JASS native：
  - `SetHPCustomHPBarUnit(PlayerID, UnitID, Color, ScaleX, ScaleY)`
  - `SetHPBarColorForPlayer(PlayerID, HeroColor, UnitColor, TowerColor)`
  - `SetMPBarXScaleForPlayer(...)`、`GetLocalUnitZ(unit)` 等
  - 出处：XGM「Хак на память Warcraft3」<https://xgm.guru/p/wc3/memoryhack>、wc3edit「MemoryHackAPI」<http://forum.wc3edit.net/tutorials-cheatpacks-f80/memoryhackapi-t37416.html>、Hive「Memory hack」<https://www.hiveworkshop.com/threads/memory-hack.289508/>
- 意义：证明**引擎的条是可以被外部 DLL 精确操控的**（颜色/尺寸都能改），路线可行，但需要逆向条绘制函数与每条的单位级数据结构。
- 代价/风险：偏移量绑定具体版本（1.27a 要自己找）；改的是引擎内部状态，联机/平台检测风险最高；工作量最大。
- 产出：引擎的条 + 部分定制能力（仍无法做「按范围隐藏/HUD 避让/悬停高亮」这类玩法逻辑）。

### C. 只借「原生锚点」：查询单位血条高度

- 机制：社区 JAPI（老外 RBLv2）新增 native「**获取单位血条高度**」，用于「提升坐标转换精度，血条比较准」。
  - 出处：<http://bbs.mvprpg.com/archiver/?tid-493410.html>
- 该高度来自模型的 **overhead 附着点**：
  - Hive「Warcraft model health Bar Height」：「attached to the overhead attachment point height. If a unit does not have it, the health bar can be at weird places」
  - GA 地精研究院：改血条高度 = 调模型 **OVERHEAD 节点**的 Z
- 对我们的价值：把 `BAR_HEAD` 从「三种写死常量」升级为「按 type_id 解析 MDX 的 overhead 节点 Z × 模型缩放」，**自定义模型/飞行单位/建筑自动正确**。这属于「锚点原生」，绘制仍是我们自己的 D3D。
- 代价：需要 MDX 解析（我们已有 MPQ/Storm 与 SlkLib 基础）、需要缓存、需要兜底（无 overhead 节点时退回常量）。

### D. 地图层伪造条（纯 JASS 能做的极限）

- floating text：`CreateTextTag` + 每 0.1s 重设位置（thehelper「Hitpoints Show all the time」<https://www.thehelper.net/threads/hitpoints-show-all-the-time.25372/>）。
- bar unit / GenericBar：造一个「条模型」单位，`SetUnitAnimationByIndex(barUnit, 0~100)` 当填充，用 timer 跟随本体（Hive「GenericBar」<https://www.hiveworkshop.com/threads/genericbar.277605/>）；不平地形上高度会错。
- vJass 血条系统：Hive「Heath & Mana bar system v2.1」。
- 结论：全部依赖 timer 跟随 → 与我们修正前同样的滞后问题，且条本身是地图资源。**不选**。

### E. 1.31+/Reforged 的 Frame API

- `BlzCreateFrameByType` / FDF（如社区 `War3Mod HeroFrame` 的 `<AllyColor>`/`<EnemyColor>`）能做出真正的原生 UI 血条。
- 1.27a 无此 API，**不可用**。

## 2. 选型矩阵

| 路线 | 跟随时鲜度 | 可定制 | 工作量 | 版本/联机风险 | 结论 |
|---|---|---|---|---|---|
| 现行 D3D 自绘（已实现） | 逻辑帧（≈24–30Hz，与引擎同源数据） | 完全可控 | 已完成 | 低（纯 overlay） | **保留为主** |
| A 命令注入（Alt/274） | 引擎渲染帧 | 无 | 中（找 1.27a 入队函数 + 274 常量） | 中（改输入/常显影响全图） | 备选，用户明确要「引擎的条」再上 |
| B 引擎条内存改造 | 引擎渲染帧 | 部分（颜色/尺寸） | 高（逆向条绘制 + 单位结构） | 高 | 不做，除非要做平台级产品 |
| C 原生锚点（MDX overhead） | 同现行（只改锚点精度） | 完全可控 | 低-中 | 低 | **推荐补强** |
| D 地图层 texttag/bar unit | 慢于逻辑帧 | 受限 | 低 | 低 | 不选 |
| E Frame API | — | — | — | 1.27a 不适用 | 不选 |

## 3. 推荐方案（分三步，均不破坏现有 33/33）

1. **保持 D3D 自绘为主**（已验收）。它相对引擎条的唯一劣势是「必须自己算锚点」，而这正好被第 2 步补上；优势是可控（范围圈联动、悬停高亮、HUD 避让、按类型差异化尺寸）。
2. **锚点原生化**：新增 `native GetUnitHealthBarHeight(unit)`（DLL 侧解析该 type_id 的 MDX overhead 节点），Lua 侧 `BAR_HEAD_BY_TYPE` 改为「缓存查询 + 常量兜底」。产出：自定义模型也贴头，不再靠三种常量。社区 RBLv2 已验证这个思路的产品价值。
3. **可选平滑（如果用户仍觉得「不够顺」）**：在 D3D Present 回调里按渲染帧重绘，并对两条相邻逻辑帧的坐标做**线性插值/外推**。前提是先做实验确认「引擎是否对模型位置做过渲染帧插值」——若引擎本身也是逻辑帧位置，则插值只是把 24Hz 台阶磨平，属于观感优化而非对齐。

不做的事：A/B 两条「接管引擎条」的路线在 1.27a 都是「全单位、不可定制」，与产品方向（可定制的头顶条）冲突；保留为「如果以后要做平台级显血工具」的调研存档。

## 4. 验证计划（先观测、后改代码）

- E1（判断引擎是否插值）：healthbars=1 时，用 DLL 内 Present hook 连续两帧记录某移动单位的屏幕坐标（或外部 10ms 级连拍），看同一逻辑帧内坐标是否变化。决定第 3 步是否必要。
- E2（判断 274/275 在 1.27a 是否仍有效）：不改内存，仅用 `SendInput` 模拟按住 `[`（VK_OEM_4），看条是否常显（外部工具 war3tools 声称支持 1.15~1.30+）。若成立，A 路线成本从中降为低。
  - 状态：**未执行** —— 验证脚本已写好（`build/hpkey.ps1`：前景化窗口 → 截图 `build/hp-off.png` → keydown `[` → 截图 `build/hp-bracket.png` → keyup），但当时游戏窗口已关闭；下次部署后可直接跑。判定口径：用 `python build/greenrows.py` 数绿色 run 数量，按住 `[` 后应出现明显更多的条（>需要的 3-4 个）。
- E3（锚点正确性）：取 2–3 个自定义模型单位与 1 个飞行单位，比较 MDX overhead 推算高度 vs 原生条实际位置（现在已有 native oracle 流程，可直接复用 `build/greenrows.py` + 洋红描边法）。

## 5. 待决策

1. 是否接受「D3D 自绘 + 原生锚点」作为最终形态（推荐），还是必须让引擎自己画（A 路线）？
2. 若走 A：接受「所有单位常显、不可定制」的代价吗？
3. 平滑插值（第 3 步）是否纳入下一轮？

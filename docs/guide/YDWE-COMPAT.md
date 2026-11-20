# YDWE 地图接口兼容（单位状态 / 命令按钮图标）

> 状态（2026-11-20，工作区未提交）：**离线实现与离线验证完成，未启动 War3、未打包、未部署、未实机验证。**
> 验证入口：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\ydwe-compat\run.ps1`
> 当前结果：`YDWE compat offline: 4 step(s) passed` —— Python 迁移 25 项、`jass.ydwe` 17 项、
> C++ 图像模块 47 项、端到端图标 CLI 11 项。本文中的“可用”只表示离线代码/格式级验证，
> 不表示 1.27a 实机行为已经确认。

## 1. 兼容范围

本次验证覆盖 JASS 源码转换、Lua 接口和生成的图标文件。

| 目标 | 本轮做法 | 结论 |
|---|---|---|
| `GetUnitState` / `SetUnitState` 支持 YDWE 扩展状态 | 不 hook 原 native；离线 JASS 源码迁移 + Lua `jass.ydwe` 兼容层，复用现有 `EXGetUnitState` / `EXSetUnitState` | **离线可用**；只迁移可直接改写且状态可静态确定的调用；二进制地图不可用 |
| `EXDclareButtonIcon` / `EXBlendButtonIcon` | 真实 BLP 解码 + YDWE 禁用/合成算法 + BLP1 palette 编码 + 落盘；不拦截 Storm | **生成/合成/落盘可用**；原版“命令卡动态加载”未做，运行中的命令卡不会在本局看到生成物 |

## 2. 单位状态

### 2.1 为什么不能透明兼容

YDWE 接管了 `GetUnitState` 和 `SetUnitState` 的 JASS 入口，旧图源码可以直接通过这两个名字使用扩展状态。本项目用已有的 `EXGetUnitState (II)R` 和 `EXSetUnitState (IIR)V`，提供下面两种显式调用方式。

1. **JASS 源码迁移**：把已知扩展状态的调用点改名到 EX wrapper（本工具）。
2. **Lua SDK 兼容层**：Lua 作者显式调用 `jass.ydwe.unit_state.get/set`。

不做“把 `jass.common.GetUnitState` 赋值覆盖”的伪装：`jass.common` 的 `__newindex`
会把赋值送进 JASS 全局变量写，根本不会替换 native。

### 2.2 JASS 源码迁移工具

```powershell
# 只检查，不写文件；有待迁移调用时 exit 1
python -B tools\ydwe-compat\migrate_unit_state.py --check path\to\war3map.j

# 原地改写
python -B tools\ydwe-compat\migrate_unit_state.py --in-place path\to\jass

# 写到镜像目录，并生成机器可读报告
python -B tools\ydwe-compat\migrate_unit_state.py --out build\migrated `
    --report-json build\migrate-report.json path\to\jass
```

改写形式：

```jass
// 输入
set a = GetUnitState(u, ConvertUnitState(0x20))
call SetUnitState(u, ConvertUnitState(0x25), 1.0)
set b = GetUnitStateSwap(ConvertUnitState(0x51), u)
set c = GetUnitStatePercent(u, ConvertUnitState(0x20), UNIT_STATE_MAX_LIFE)

// 输出
set a = EXGetUnitState(GetHandleId(u), 0x20)
call EXSetUnitState(GetHandleId(u), 0x25, 1.0)
set b = EXGetUnitState(GetHandleId(u), 0x51)
set c = YDWEGetUnitStatePercent(u, 0x20, 1)
```

规则：

- **只改调用点**，按字节读写；`//` 注释、`//#` 注释、字符串、rawcode、BOM、CRLF/CR、
  GBK/UTF-8 注释字节都不动。文件编码保持原样。
- `GetUnitState` / `SetUnitState` / `GetUnitStateSwap` / `GetUnitStatePercent` 必须是
  **大小写完全一致**的标识符，且与 `(` 之间只有空格/制表符（JASS 不允许表达式内换行）。
- 状态必须是下列之一：整数字面量、`ConvertUnitState(<整数字面量>)`、在扫描到的
  `globals` 块中声明的 `constant integer` / `constant unitstate`（支持简单别名）。
  `ConvertUnitState` 会被拆掉，因为 EX wrapper 的状态参数是 `integer`。
- 字面量统一输出为小写 `0x`；`tools/pjass.exe`（打包门禁）不接受 `0X20`。
- **不改**：vanilla `0..3`、UjAPI-only `4..7`、未知值、未解析的运行时表达式、
  `SetUnitState` 的四个 no-op 状态（`0x14/0x15/0x42/0x43`）、
  全局初始化器、`constant function` 内、`config` 内、`main` 中 `initializePlugin()` 之前的调用。
  这些都会进报告的 `skips`，原因分别是 `vanilla-state`、`ujapi-only-state`、`unknown-state`、
  `set-noop-state`、`global-initializer`、`constant-function`、`early-config`、`early-main`。
- 状态表达式里的标识符若被当前函数的参数或 `local` 同名变量遮蔽，视为不可静态确定，
  跳过并报告 `shadowed-state`。
- 调用点参数里的嵌套状态读取也会被扫描（例如 `SetUnitState(u, state, GetUnitState(u, ...))`）；
  对 unit/value 参数只插入 `GetHandleId(` / `)`，不会覆盖内层改写。
- 工具**幂等**：第二次运行不会产生修改。

#### wrapper 从哪来

`EXGetUnitState` / `EXSetUnitState` 是 bridge handler，不是引擎 native；JASS 里必须先有函数 wrapper。

- 推荐：打包时加 `-WithJassWrappers`。`tools/gen-jass-wrappers.ps1` 会从
  `src/src/extensions/ex_natives/Initialize.cpp` 生成同名 wrapper。若迁移结果含 `YDWEGetUnitStatePercent`，
  还要用 `--emit-compat --no-wrappers` 生成辅助函数，放在调用者之前，避免重复定义 EX wrapper。
- 独立使用：`python -B tools\ydwe-compat\migrate_unit_state.py --emit-compat build\ydwe-unit-state.j path\to\jass`。
  生成块包含两个 wrapper 和三个 helper；把块插到 `endglobals` 之后、任何被迁移调用之前。
  若扫描范围内已经定义了同名函数，生成器会跳过它。
- **`GetUnitStatePercent` 的改写需要 `YDWEGetUnitStatePercent` helper**。`-WithJassWrappers`
  只生成 EX wrapper，不生成这个 helper；有 percent 改写的工程必须同时使用 `--emit-compat`
  （或手动插入该 helper）。`--require-wrappers` 会把缺失的 helper 一并报错。

wrapper 依赖地图的 `japi_ht` / `japi__key`（`japi__key = StringHash("jass")`）和
`initializePlugin()` 的 `UnitId` 握手。**在 `initializePlugin()` 之前调用 wrapper 会读空/旧槽位**；
工具会跳过 `config` 和 `main` 中握手前的调用，但静态分析无法覆盖所有“被提前调用的自定义函数”，
作者仍需保证迁移后的调用在插件初始化之后执行。

#### 动态状态 helper

生成的块还包含：

```jass
function YDWEGetUnitState takes unit whichUnit, unitstate whichState returns real
function YDWESetUnitState takes unit whichUnit, unitstate whichState, real value returns nothing
```

它们用 `GetHandleId(whichState)` 把 `unitstate` 转成整数，适合状态值只能在运行时确定的调用。
`unitstate extends handle` 让 pjass 接受这个转换，但 `unitstate` 并不是真正的 handle；
**`GetHandleId(unitstate)` 的 VM 运行时行为本轮没有实机验证**。直接调用点迁移不会走这条路径：
已知状态都被解析成整数字面量或整数常量。

### 2.3 Lua SDK：`jass.ydwe`

```lua
local ydwe = require "jass.ydwe"

local armor = ydwe.unit_state.get(unit, 0x20)       -- EXGetUnitState
ydwe.unit_state.set(unit, 0x25, 1.0)                -- EXSetUnitState

local hp = ydwe.unit_state.get(unit, 0)             -- 原版 GetUnitState
ydwe.unit_state.set(unit, 3, 500.0)                 -- 原版 SetUnitState

ydwe.unit_state.is_extended(0x20)                   -- true
ydwe.unit_state.name(0x20)                          -- "ARMOR"
ydwe.unit_state.values                              -- 47 项 值 -> 名称
ydwe.unit_state.names                               -- 名称 -> 值
ydwe.unit_state.set_noop[0x14]                      -- true（Set 是 no-op）
```

- vanilla `0..3`：走 `jass.GetUnitState` / `jass.SetUnitState` + `ConvertUnitState`。
- 47 个 YDWE 扩展状态（见下表）：走 `jass.japi.EXGetUnitState` / `EXSetUnitState`，
  单位先经 `GetHandleId`。
- UjAPI-only `4..7` 与未知值：**抛错**，不猜。
- `Set` 的四个 no-op 状态：**抛错**，不假装成功。
- 兼容别名：`ydwe.GetUnitState` / `ydwe.SetUnitState` / `ydwe.IsExtendedUnitState`。
- 模块不替换 `jass.common` 的任何函数，只服务显式调用它的 Lua 代码。

### 2.4 支持的状态表

数据源：`tools/ydwe-compat/unit_states.json`，与 `src/src/extensions/ex_natives/UnitState.cpp`
的 `FakeGetUnitState` / `FakeSetUnitState` 由离线测试逐项比对。vanilla `0..3` 不在表中。

| 值 | 名称 | Get | Set | 备注 |
|---|---|:---:|:---:|---|
| `0x10` | `ATTACK1_DAMAGE_DICE` | ✓ | ✓ |  |
| `0x11` | `ATTACK1_DAMAGE_SIDE` | ✓ | ✓ |  |
| `0x12` | `ATTACK1_DAMAGE_BASE` | ✓ | ✓ |  |
| `0x13` | `ATTACK1_DAMAGE_BONUS` | ✓ | ✓ |  |
| `0x14` | `ATTACK1_DAMAGE_MIN` | ✓ | — | EXSetUnitState 接受该 case 但不写（派生值）；迁移不改 Set 调用 |
| `0x15` | `ATTACK1_DAMAGE_MAX` | ✓ | — | 同上 |
| `0x16` | `ATTACK1_RANGE` | ✓ | ✓ |  |
| `0x20` | `ARMOR` | ✓ | ✓ |  |
| `0x21` | `ATTACK1_DAMAGE_LOSS_FACTOR` | ✓ | ✓ |  |
| `0x22` | `ATTACK1_WEAPON_SOUND` | ✓ | ✓ |  |
| `0x23` | `ATTACK1_ATTACK_TYPE` | ✓ | ✓ |  |
| `0x24` | `ATTACK1_MAX_TARGETS` | ✓ | ✓ |  |
| `0x25` | `ATTACK1_INTERVAL` | ✓ | ✓ |  |
| `0x26` | `ATTACK1_INITIAL_DELAY` | ✓ | ✓ |  |
| `0x27` | `ATTACK1_RANGE_BUFFER` | ✓ | ✓ |  |
| `0x28` | `ATTACK1_BACK_SWING` | ✓ | ✓ |  |
| `0x29` | `ATTACK1_TARGET_TYPES` | ✓ | ✓ | **差异**：本 port 修掉了 YDWE 缺失的 break，返回 target types；YDWE 原版会 fall through 返回 spill dist。没有复刻该 bug |
| `0x30` | `ATTACK2_DAMAGE_DICE` | ✓ | ✓ |  |
| `0x31` | `ATTACK2_DAMAGE_SIDE` | ✓ | ✓ |  |
| `0x32` | `ATTACK2_DAMAGE_BASE` | ✓ | ✓ |  |
| `0x33` | `ATTACK2_DAMAGE_BONUS` | ✓ | ✓ |  |
| `0x34` | `ATTACK2_DAMAGE_LOSS_FACTOR` | ✓ | ✓ |  |
| `0x35` | `ATTACK2_WEAPON_SOUND` | ✓ | ✓ |  |
| `0x36` | `ATTACK2_ATTACK_TYPE` | ✓ | ✓ |  |
| `0x37` | `ATTACK2_MAX_TARGETS` | ✓ | ✓ |  |
| `0x38` | `ATTACK2_INTERVAL` | ✓ | ✓ |  |
| `0x39` | `ATTACK2_INITIAL_DELAY` | ✓ | ✓ |  |
| `0x40` | `ATTACK2_RANGE` | ✓ | ✓ |  |
| `0x41` | `ATTACK2_RANGE_BUFFER` | ✓ | ✓ |  |
| `0x42` | `ATTACK2_DAMAGE_MIN` | ✓ | — | 同 `0x14` |
| `0x43` | `ATTACK2_DAMAGE_MAX` | ✓ | — | 同 `0x14` |
| `0x44` | `ATTACK2_BACK_SWING` | ✓ | ✓ |  |
| `0x45` | `ATTACK2_TARGET_TYPES` | ✓ | ✓ |  |
| `0x46` | `ATTACK2_SPILL_DIST` | ✓ | ✓ |  |
| `0x47` | `ATTACK2_SPILL_RADIUS` | ✓ | ✓ |  |
| `0x50` | `ARMOR_TYPE` | ✓ | ✓ |  |
| `0x51` | `RATE_OF_FIRE` | ✓ | ✓ |  |
| `0x52` | `ACQUISITION_RANGE` | ✓ | ✓ |  |
| `0x53` | `LIFE_REGEN` | ✓ | ✓ |  |
| `0x54` | `MANA_REGEN` | ✓ | ✓ |  |
| `0x55` | `MIN_RANGE` | ✓ | ✓ |  |
| `0x56` | `ATTACK1_SPILL_DIST` | ✓ | ✓ |  |
| `0x57` | `ATTACK1_SPILL_RADIUS` | ✓ | ✓ |  |
| `0x58` | `ATTACK1_WEAPON_TYPE` | ✓ | ✓ |  |
| `0x59` | `ATTACK2_WEAPON_TYPE` | ✓ | ✓ |  |
| `0x60` | `AS_TARGET_TYPE` | ✓ | ✓ |  |
| `0x61` | `TYPE` | ✓ | ✓ |  |

### 2.5 明确未做 / 未验证

- **没有 hook `GetUnitState` / `SetUnitState`**；未迁移的 JASS 调用继续是原版行为。
- **二进制地图 / 无源码地图**无法迁移；vJass 预处理器产物如果能还原成标准 JASS 可以处理，
  但工具不解析 vJass 语法。
- 状态值只能静态确定；`ConvertUnitState(运行时变量)` 与动态 `unitstate` 变量不迁移。
- 全局初始化器、`constant function`、`config`、`main` 握手前的调用不迁移。
- `UNIT_STATE_MAX_LIFE` / `MAX_MANA`（`0x1/0x3`）保持原版；`EXSetUnitState` 对它们有
  YDWE 的特殊直写路径，迁移**不**使用该路径。
- UjAPI-only `4..7` 未实现，不冒充支持。
- `0x29` 与 YDWE 原版的缺失 break 差异见上表，未复刻 bug。
- `RealGetUnitState` / `RealSetUnitState` 的懒解析、各扩展状态的内存读写、动态 helper 的
  `GetHandleId(unitstate)` 都只有代码/静态依据，没有本轮的实机用例。
- 迁移后的调用增加一次 `UnitId` 桥 + hashtable 往返，热路径需要自行评估。

## 3. 命令按钮图标

### 3.1 历史接口

| 名称 | 签名 | 来源 |
|---|---|---|
| `EXDclareButtonIcon`（拼写就是 Dclare） | `(S)V` | YDWE `DisableButtonBlp.cpp` / builtin-japi |
| `EXBlendButtonIcon` | `(SSS)B` | 同上 |

两个名字已按 bridge handler 注册（`Initialize.cpp`），Lua 可经 `jass.japi` 调用，
JASS 可经 `pack.ps1 -WithJassWrappers` 生成 wrapper 后调用。**没有** `jass::japi_add`、
没有 native 表改写、没有 hook。

### 3.2 本轮实现

- `EXDclareButtonIcon(path)`：经 Storm 的**合法读取 API**（`SFileLoadFileEx` / `SFileUnloadFile`，
  复用现有 `storm_dll`）读取源 BLP；解码必须是 64×64；执行 YDWE `BlpDisable` 的整数像素算法；
  编码为 BLP1 palette；写到
  `<地图目录>\japi-button-icons\ReplaceableTextures\CommandButtonsDisabled\DIS<basename>.blp`。
- `EXBlendButtonIcon(a, b, out)`：读取两张 64×64 BLP；执行 YDWE `BlpBlend`（A over B）；
  编码并写到 `<地图目录>\japi-button-icons\<out 路径>`（`out` 必须以 `.blp` 结尾）。
  读取时先试 Storm，再回退到同名 staging 文件，因此同一局里 `EXDclareButtonIcon`
  刚写出的禁用图可以作为 blend 输入。
- 算法是真实实现，不是空 stub：`src/src/image/button_icon.cpp` 与
  `reference/YDWE/.../PasButton.h` 的 4096 项 overlay 逐像素一致；`test_button_icons.py`
  用独立 Python 实现复算 raw BGRA，要求**逐像素精确相等**。
- 图像编解码独立在 `src/src/image/`：BLP1 JPEG（WIC，含 4-component CMYK→BGRA/alpha 修正）、
  BLP1 palette、BLP2 palette/raw；输出是 BLP1 palette + 8-bit alpha + 完整 mip 链。
  BLP2 DXT 输入明确拒绝。
- D3D 代理的 `src/d3d9/texture_asset.cpp` 仍保留自己的一份 WIC 解码副本。本轮**没有**改它：
  D3D `game://` 的 BLP1 JPEG 颜色/alpha 问题不在本次 YDWE 图标范围内，也未被本轮测试覆盖。

### 3.3 构建期 CLI（推荐路径）

```powershell
# 单张：生成标准 DIS 路径，并追加到 <out-root>\(listfile)
src\build\bin\Release\ydwe_button_icon.exe disable `
    path\to\BTNFoo.blp path\to\project\base-map `
    ReplaceableTextures\CommandButtons\BTNFoo.blp

# 合成到指定 map-relative 路径
src\build\bin\Release\ydwe_button_icon.exe blend `
    path\to\a.blp path\to\b.blp `
    path\to\project\base-map\ReplaceableTextures\CommandButtons\BTNMerged.blp

# 批处理清单
#   # 注释
#   disable <source.blp> [archive-path]
#   blend   <a.blp> <b.blp> <archive-output-path>
src\build\bin\Release\ydwe_button_icon.exe run icons.txt path\to\project\base-map
```

- 输出目录必须是**未打包的 base-map 源目录**（`tools\new-project.ps1` 生成的
  `<project>\base-map` 就是）。`tools/pack.ps1` 对目录型 `-BaseMap` 会递归复制整个目录，
  w3x2lni 会打包 WorkDir 里的所有文件；本轮没有改 pack/deploy 的载荷处理。
- CLI 会更新 `<out-root>\(listfile)`，避免只靠目录扫描的工具看不到新资源。直接 `blend`
  写到任意 OS 路径时不会更新 listfile；构建期批量请用 `run` 清单（它按 out-root 更新）。
- 路径会归一化并拒绝绝对路径、盘符/ADS、`..`、控制字符、Windows 设备名（CON/NUL/COM1…）。
- `disable` 只输出标准 `CommandButtonsDisabled\DIS<basename>.blp`；`blend` 输出调用者给的
  map-relative 路径（必须以 `.blp` 结尾）。
- 清单按空白分词、`#` 起注释；路径不要包含空格或 `#`。清单里的相对路径按清单文件所在目录解析。

**重要**：`tools/pack.ps1` 的每个产物都会带 `japi.tga`（DLL）、`callback`、D3D 代理。
本轮约束禁止构建含漏洞载荷的地图，因此没有运行 pack；如果只需要“无 loader 的图标资源包”，
应使用直接的 w3x2lni 打包或项目自己的 StormLib 写入器，而不是 pack.ps1。

### 3.4 运行期入口

```jass
call EXDclareButtonIcon("ReplaceableTextures\\CommandButtons\\BTNFoo.blp")
set ok = EXBlendButtonIcon("ReplaceableTextures\\CommandButtons\\A.blp", `
                           "ReplaceableTextures\\CommandButtons\\B.blp", `
                           "ReplaceableTextures\\CommandButtons\\BTNOut.blp")
```

```lua
local japi = require "jass.japi"
japi.EXDclareButtonIcon("ReplaceableTextures\\CommandButtons\\BTNFoo.blp")
local ok = japi.EXBlendButtonIcon(a, b, "ReplaceableTextures\\CommandButtons\\BTNOut.blp")
```

- 返回值：`EXDclareButtonIcon` 是 `V`（Lua 侧谓词为 `true`）；`EXBlendButtonIcon` 成功 `true`，
  失败 `false`。失败会写 `yd_japi` 日志（`[ButtonIcon] ...`），不会写半成品。
- 输入可以是地图内或游戏 MPQ 内的 BLP；路径会经过 `from_trigstring` 展开 `TRIGSTR_`。

### 3.5 原版命令卡动态加载：未做 / 未验证（重点）

YDWE 原版靠 **IAT hook `Storm.dll!SFileLoadFile` + 虚拟 MPQ**：引擎请求
`ReplaceableTextures\CommandButtonsDisabled\DIS*.blp` 时，hook 现场生成或返回
`g_virtualblp` / `g_history` 里的字节。本轮**明确禁止**移植这条链路，因此：

- **本局不会看到生成物**。游戏命令卡加载器从 MPQ 取 `DIS*.blp`，而生成物只写在地图旁的
  `japi-button-icons\` 目录；没有拦截就无法把字节供给当前会话。
- 运行期 native 的真实作用是“生成 + 落盘”，不是“已经替换了 UI”。请不要把它宣传成
  动态命令卡兼容。
- 生成物要生效，必须**构建期/下一局打包进地图 MPQ**：把 `japi-button-icons\*` 拷进项目的
  `base-map\`，或直接用 `ydwe_button_icon.exe` 输出到 `base-map\`，再走正常打包。
- 未验证项：1.27a 命令卡加载器是否接受 `alphaBits=8` 的 BLP1 palette + 完整 mip 链；
  地图目录 loose file 是否在命令卡搜索链；按钮创建后的图标缓存/刷新时机；大小写与斜杠
  归一化在引擎请求侧的行为；生成文件在地图目录只读时的失败表现。
- 输出使用 BLP1 palette，而 YDWE 原版写 BLP1 JPEG q95；像素算法相同，但最终文件字节与
  JPEG 有损结果不可能逐字节一致。palette 量化在测试 fixture 上的 RGB 误差 ≤ 40、
  alpha 逐像素精确；更严格的视觉验收仍需实机。
- mip 每级使用 box downsample；YDWE 的 writer 实际每级读取输入左上角（没有缩放），
  这一差异只影响缩小显示时的细节。
- 只支持 64×64；BLP2 DXT 输入不支持；非 64×64 直接失败。
- `PasButton` overlay 与算法来自 YDWE（GPL）。仓库内已有 `reference/YDWE`，本轮按同一
  来源复制并注明；对外分发时的许可证义务需要单独确认。

## 4. 文件与验证

新增/修改（工作区未提交）：

| 路径 | 作用 |
|---|---|
| `tools/ydwe-compat/migrate_unit_state.py` | 字节级 JASS 迁移工具（tokenizer + 改写 + compat 块） |
| `tools/ydwe-compat/unit_states.json` | 47 个扩展状态、4 个 Set no-op、UjAPI-only 4..7 的权威表 |
| `src/src/image/` | 独立 BLP 编解码 + YDWE 禁用/合成算法 + PasButton 数据 + CLI |
| `src/src/extensions/ex_natives/ButtonIcon.cpp` | 两个历史 native 的真实实现（Storm 读取 + 落盘） |
| `src/src/extensions/ex_natives/Initialize.cpp` | 注册 `(S)V` / `(SSS)B` bridge handler |
| `src/src/lua_engine/lua_engine/libs_ydwe*` | `jass.ydwe` 模块 |
| `src/src/lua_engine/lua_engine/open_lua_engine.cpp` | 注册 `jass.ydwe` |
| `src/CMakeLists.txt` | `japi_image` 静态库、`button_icon_test`、`ydwe_button_icon` |
| `tests/ydwe-compat/` | 离线测试与独立 Python BLP/像素验证器 |
| `tests/conformance/manifest.lua` | 重新生成，新增两个 bridge handler（未实机复跑） |
| `tools/pack.ps1` / `tools/deploy.ps1` | **未修改**；`jass.ydwe` 由 `open_lua_engine.cpp` 在仓库检出中自动发现。冻结的 `-SdkBundle` 静态模块清单尚未加入它，发布该包时需要单独补一行 |

验证命令：

```powershell
# 1. 构建（只编译，不启动游戏）
src\build.bat

# 2. 离线测试（不启动 War3、不打包、不部署）
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ydwe-compat\run.ps1
# 期望末行：YDWE compat offline: 4 step(s) passed
```

本轮没有运行 `tools\pack.ps1`、`tools\deploy.ps1`、`tests\conformance\run.ps1`，
也没有启动 War3；上述实机行为均未验证。

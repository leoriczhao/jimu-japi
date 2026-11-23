# 变更日志（CHANGELOG）

> 适用：War3 1.27a（`GetGameVersion()` = `6374`）+ `yd_japi.dll`（内嵌 Lua 5.4）+ `newD3d9.dll`（D3D9 proxy）。
> 版本号唯一来源：`src/src/lua_engine/lua_engine/libs_d3d.cpp:35` 的 `constexpr const char* kVersion`；
> 只有 **Lua 侧 `jass.d3d` 对外 API 变化**时才递增，工具链 / 文档 / 示例 / 脚手架改动一律不递增。
> 发布流程见 [docs/RELEASE.md](docs/RELEASE.md)；当前实现、验证强度与缺口以 [docs/STATUS.md](docs/STATUS.md) 为唯一权威。
> 最后更新：2026-11-24（发布 `0.6.0`）。

约定：

- 每条改动都带**验证状态**：`实机` = 真机跑过回归；`静态` = 只做了构建/静态合同校验；`未验证` = 只有代码或设计依据。
- 日期是**提交日期**（`git show -s --format=%ad --date=short`）或明确标出的实测日期，不是本文档的编辑日期。
- 发布产物必须可溯源到某个提交的 detached clean worktree 构建（做法见 [docs/RELEASE.md](docs/RELEASE.md) 步骤 1、6）。

---

## 版本线

| 版本 | 时间 | 锚点提交 | 状态 | 一句话 |
|---|---|---|---|---|
| `0.6.0` | 2026-11-24 | `HEAD` | **已发布**（clean 构建可溯源） | C++↔Lua 零堆分配热路径优化 + 自动 Tree-Shaking `std.*` 标准库 + 通用响应式 `DzFrame` UI 框架 |
| `0.5.0` | 2026-11-23 | `632ffac` | **已发布**（clean 构建可溯源） | 单文件 `japi.tga`、Rust `japi.exe` CLI、原生 1.27a `CStatBar` 血蓝条、YDWE/内置 JAPI 1.27a 全量对齐、纯净开发者 SDK 包 |
| `0.4.0` | 2026-11-15 | `d151fd7` | **已发布**（clean 构建可溯源） | D3D Lua SDK 记为「可用」，首个有发布产物的版本 |
| `0.3.0-dev` | 2026-11-14 → 2026-11-15 | `a9e1d21` 起 | 开发版，未发布 | P4 订阅、真实输入、P5 生命周期、VM 重置、54 handler 覆盖 |
| `0.2.0-dev` | 2026-08-03 起 | `50ebb0f` | 开发版，未发布 | 首版带 `kVersion`：版本化 ABI、typed 资源 SDK、MPQ 贴图 |
| （无版本号） | 2026-06-04 → 2026-08-03 | `7e3bac7` 起 | 早期 | 还没有 `jass.d3d` 与 `kVersion` |

> `-dev` 后缀表示「实现完成但未做发布级验收」，不承诺任何行为；`0.4.0` 是第一个去掉了 `-dev` 的版本。
> 版本号只在 **`kVersion` 字面量** 变化的提交里递增：`-S'kVersion = "'` 的完整结果是
> `50ebb0f`（`0.2.0-dev`）→ `a9e1d21`（`0.3.0-dev`）→ `d151fd7`（`0.4.0`），之后再没变过。

---

## [0.6.0] — 2026-11-24

面向 WAR3 1.27a 地图开发者的 Lua 层性能与工程化升级版本：

- **C++ ↔ Lua 引擎绑定热路径零堆分配优化（实机验证）**：
  - `jass::call_param` 改为 `kInlineCap = 16` 栈上小缓冲，消除每次 JASS native 调用的 3 次 `std::vector` 堆分配/释放；
  - `jass.common` / `jass.japi` / `jass.ai` 首次查找后缓存闭包到模块表（100% 兼容 `jass.hook`），消除每帧 CClosure GC 抖动；
  - `bridge_dispatch` 注册时预解析扁平 `fast_spec` 并用稳定指针 upvalue 直达，`class_handle` 改用 `lightuserdata` 注册表键 + `lua_rawgeti`/`lua_rawseti`；
  - 1.27a 实机热路径基准：20,000 次 `GetUnitX` 仅 4.66 ms（~233 ns/次），5,000 次 `EXGetObject` 仅 2.31 ms（~462 ns/次）。
- **地图开发标准库 `std.*`（零拷贝自动 Tree-Shaking + 本地覆盖）**：
  - `japi build` 原生解析 SDK `std/` 目录，只将实际 `require` 的模块打入 `war3map.lua`，地图项目本地同名 `std/xxx.lua` 优先覆盖；
  - 内置 `std.util`、`std.timer`（池化零泄漏 + 共享 33Hz `frame`）、`std.event`（惰性桥接 War3 原生事件与伤害数据）、`std.player`、`std.unit`（同句柄单例缓存 + `u.data` 自动清理）、`std.group`（零泄漏临时组/矩形查询）、`std.effect`、`std.statbar`（原生 1.27a `CStatBar` 预设）、`std.tween`。
- **通用声明式 + 细粒度响应式 `DzFrame` UI 框架（实机验证 8/8）**：
  - `std.signal`（`state`/`computed`/`effect`/`batch`/`untrack`/`scope`）、`std.frame`（经 `jass.japi` 自动发现宿主 KKAPI `DzFrame*`，固定事件槽零 trampoline 泄漏）、`std.ui`（零业务假设、零写死皮肤：`Box`/`Text`/`Image`/`Button`/`Model`/`Input`/`Raw`、`Row`/`Column`/`Grid`/`Scroll`/`Overlay`、`Show`/`For` 池化列表、`component`、`provide`/`use`）；
  - D3D9 渲染版 UI 保留为可选备用模块 `std.d3d_ui`。

## [0.5.0] — 2026-11-23

面向 WAR3 1.27a 地图作者的重大里程碑版本，核心改动：

- **纯净开发者 SDK 与零依赖 Rust CLI（`japi.exe`）**：
  - 彻底分离「引擎维护者测试」与「地图开发者发行包」：`sdk/bin/` 零测试程序、`japi new` 零冒烟测试脚手架、`examples/` 零引擎断言 harness、`sdk/docs/` 仅包含作者指南与变更日志，并产出独立 `map-inject-sdk-0.5.0.zip`。
  - 地图打包收口为单文件 `japi.tga`（PE `.rsrc` 内嵌 `newD3d9.dll` + `D3DX9_42.dll`），自动写入 WE/YDWE/KKWE 兼容的 `war3map.imp` 与 `war3map.wtg/wct` 引导触发器。
- **原生 1.27a `CStatBar` 头顶血条 / 蓝条 + 离屏/幽灵血条清理（16 API）**：
  - 纯 `CStatBar` 虚表钩子实现单位/单位类型/玩家级血条染色、缩放、显隐与零延迟原生蓝条。
  - `EXSetOffscreenBarCull` 零开销修复 1.27a 离开视线血条贴边不消失及屏幕外幽灵血条残留。
- **YDWE & 内置 JAPI 1.27a 完整对齐**：
  - **联机帧同步确定性**：`luaL_newstate2` 绑定 War3 `SetRandomSeed` 全局同步种子，`table.sort` 确定性枢轴，`math.random`/`math.randomseed` 路由到 War3 RNG。
  - **零重启进程内 D3D9 激活**：未预装 `d3d9.dll` 代理时由 `AttachInProcessD3D9` 就地挂钩 `Reset`/`EndScene`，首局即可使用 `jass.d3d` 与传统 D3D handler。
  - **模块与原生扩展**：新增 `jass.ai`（124 个 `common.ai` native）、`jass.map_event` `brokenNetwork` 断线事件、`AbilityId("exec-lua:...")` 与 `Cheat("exec-lua:...")`、`EXGetObject` 与 12 个 `EX*Unit*` 真实 JASS native、`jass.storm.replace_path` / `clear_replace_paths`、以及 `jass.japi` 自动发现宿主扩展 native。

## [Unreleased]（已并入 0.5.0 的历史开发记录）

### 新增：命令卡按钮图标本局即时生效（2026-11-22，离线）

- `EXDclareButtonIcon (S)V` / `EXBlendButtonIcon (SSS)B` 除 bridge handler 外注册为真实 JASS native
  （`Initialize()` 追加 `InitializeButtonIcon()`）。生成物不再只落盘：禁用态与合成 BLP1 存进内存表，
  `BuiltinCompat.cpp` 的 Storm#279（`SFileLoadFile`）IAT detour 命中即由内存供图（缓冲经 Storm#401
  `SMemAlloc` 分配，引擎可用 `SFileUnloadFile` 释放），下方 2026-11-20 条目里「运行中的命令卡不会
  在本局看到生成物」的限制就此解除。磁盘 staging（`<地图目录>\japi-button-icons\`）保留为共存模式
  （detour 不活跃）或 `JAPI_BUTTON_ICON_STAGE=1` 显式要求的回退。
- 地图 boot / `SimulateMapBoot` 重启时 `dllmain.cpp` 追加 `clear_button_icons()` 与
  `clear_builtin_compat_map_state()`，虚拟图标与兼容层状态不跨局残留。
- 验证（离线，2026-11-22）：`yd_japi.dll` Release 构建通过；`tests/conformance/manifest.lua` 重新
  生成；`tests/ydwe-compat/test_unit_state_migrate.py` 改查 `InitializeUnitState()` / `InitializeButtonIcon()`
  与 `japi_add` 登记；`map/tests/test_ex.lua` 新增 2 条断言（native/bridge 登记规格 + 虚拟 BLP 经
  `CreateImage` 可用）。**实机命令卡换图与 199 项基线未复跑**，实机口径仍以 [docs/STATUS.md](docs/STATUS.md) 为准。

### 变更：demo 头顶血条改用引擎原生条，相机不再锁定（2026-11-22，实机）

- `map/game/wave.lua` 删除整套 D3D 自绘血条（`BAR_*` 常量、三张 quad/槽位、投影跟随、hover 高亮、
  `bars()/hovered()/camera_state()` 等对外面）；`tools/pack.ps1` 不再给 demo 打 `japi-bar-white.blp`。
  头顶条改由客户端自身绘制：`deploy.ps1 -Demo` 启动前把
  `HKCU\Software\Blizzard Entertainment\Warcraft III\Gameplay\healthbars` 置 1，会话收尾还原玩家原值。
- 去掉 `SetCameraTargetController`：建世界（含 restart）只 `SetCameraPosition` 对准英雄一次，之后视角归玩家。
  新增 `wave.camera_locked()` 供自检钉住该约定。
- 自检从 33 条缩到 **27** 条：删除血条投影/锚点/悬停/hover 8 条，新增「血条归引擎、相机可自由移动」与
  「伤害确实落到单位生命」2 条；`HUD texts/textures` 断言改为只允许 1 张底板贴图。
- 验证（2026-11-22 实机）：`deploy.ps1 -Demo` → `Results: 27 passed, 0 failed, 27 total (0 skipped)`，
  截图确认所有单位与基地都显示引擎原生条（敌方红、己方绿），会话结束 `healthbars` 回到 0。
  `docs/guide/MINIMAL-GAME-LOOP.md` §4/§5/§6/§7/§10 与 `docs/STATUS.md`、两份血条规划文档同步改口径。

### 新增：YDWE 地图接口兼容（2026-11-20，工作区未提交，离线）

- **单位状态**：新增 `tools/ydwe-compat/migrate_unit_state.py`（字节级 JASS 源码迁移）与 `jass.ydwe` Lua 兼容层。复用现有 `EXGetUnitState (II)R` / `EXSetUnitState (IIR)V` bridge handler，覆盖 47 个 YDWE 扩展状态；vanilla `0..3`、UjAPI-only `4..7`、未知值、Set no-op `0x14/0x15/0x42/0x43` 不改；注释/字符串/rawcode/BOM/CRLF/GBK 字节保持原样。未 hook `GetUnitState`/`SetUnitState`，二进制地图与动态状态表达式不覆盖。
- **命令按钮图标**：新增独立 `src/src/image` 模块（BLP1/BLP2 解码、BLP1 palette 编码、YDWE `BlpDisable`/`BlpBlend`、PasButton 数据、WIC CMYK→BGRA/alpha 修正）。`EXDclareButtonIcon (S)V` / `EXBlendButtonIcon (SSS)B` 按历史名字注册为 bridge handler，真实读取 MPQ、生成/合成并写到 `<地图目录>\japi-button-icons\`；提供 `ydwe_button_icon.exe` 构建期 CLI（输出标准 `CommandButtonsDisabled\DIS*.blp` 并更新 `(listfile)`）。
- **明确未做**：没有移植 Storm `SFileLoadFile` 拦截/虚拟 MPQ，运行中的命令卡不会在本局看到生成物；图标必须在构建期打进地图。1.27a 对 `alphaBits=8` BLP1 palette + 多 mip 命令卡图标的接受度、loose file 搜索链、图标缓存刷新均未实机验证。`EXGetUnitState` 的 0x29 与 YDWE 原版缺失 break 的行为差异未复刻。
- **验证（离线，未启动 War3/未打包/未部署）**：`src\build.bat` 通过；`tests\ydwe-compat\run.ps1` 4 步全过 —— Python 迁移 25 项、`jass.ydwe` 17 项、C++ 图像模块 47 项、图标 CLI 11 项；迁移输出 + wrapper 经 `tools\pjass.exe`（1.27.1 `common.j`/`blizzard.j`）编译通过；独立 Python 逐像素复算 disabled/blend raw BGRA 精确相等；`war3mapMap.blp` 首像素 CMYK 修正为 `(53,99,142,255)`。`tests/conformance/manifest.lua` 已重新生成（bridge 80→82），实机 199 项基线未复跑。
- **未改载荷处理**：**没有修改** `pack.ps1` / `deploy.ps1`（包括其 DLL/callback/D3D 载荷段）；`jass.ydwe` 在仓库检出中由 `open_lua_engine.cpp` 自动发现，冻结的 `-SdkBundle` 静态清单未更新。PasButton/算法来自 YDWE（GPL），分发前需确认许可证义务。

### 新增：与其它 JAPI 的共存闸门（2026-11-20，工作区未提交）

- 照内置 `GetModuleHandleA("QB_inject.dll")` 的写法（jass.dll `0x1003F201`）扩成通用判断：`Initialize()` 里检测 `yd_jass_api.dll` / `yd_lua_engine.dll` / `jass.dll` / `lua_engine.dll`，命中就进共存模式；`JAPI_COEXIST=1|0` 可强制开关（测试用）。
- 共存模式下站下的侵入式动作：`GetUnitState/SetUnitState` 原生名接管、`GetUnitGoldCost`/`TeleportCaptain` 别名、`SaveGame` 补丁、`Storm#279` 消费者、`EndGame` 派发。纯粹新增的 native（`timer_*`、`ReplacePath` 登记、`GetBigMap*`…）照常注册。
- **UnitId 不做一刀切**：只有当它的代码入口已经是 `E9`/`EB`（被别人 detour 过）才让位；YDWE 的 `yd_jass_api` 从不动 UnitId，所以在 YDWE 环境下我们的 Lua 桥接照常工作。
- 验证：正常模式日志 `Coexist: no foreign JAPI; full hook set`、回归 `127/127`；`JAPI_COEXIST=1` 强开时四个闸门全部按预期关闭（日志逐条可见），且因为 UnitId 仍是原码，回归同样 `127/127`。
### 新增：地图事件总线 `jass.map_event`（2026-11-20，工作区未提交）

- 对标内置 `jass.dll` 的 `get_map_event()`（`map<string, vector<uint>>` 事件总线）：新增 Lua 模块 `jass.map_event`，`on(name, fn)` / `emit(name)` / `count(name)` / `clear(name)`；回调受保护，抛错只记日志、不影响后续订阅者。
- `EndGame` 原生名每局接管（表 hook）：先派发 `"endGame"` 订阅者，再调用原实现，日志 `MapEvent: EndGame hooked (real=0x…)`。
- 地图重开时 `on_map_boot` 调 `mapevent::reset()` 释放 registry 引用，避免悬空。
- 更正上一轮的判断：延迟 hook 队列**不是死代码**——`nf_register::initialize()`（由 `detail::async_initialize()` 触发）里已经执行 `nfunction_add()` + `nfunction_hook()`，`japi_hook`/`async_hook` 调用后会 flush；我们只是没人用。保留不动。
- 验证：新增用例 `jass.map_event subscribe / emit / clear`，回归 126 → **127/127**；日志确认 `EndGame` 被接管。
### 变更：与其它 JAPI 共存的四处保护（2026-11-20，工作区未提交）

- **落盘名改为 `japi<pid>.dll`**：原来和内置 JAPI / YDWE 的加载器都叫 `<pid>.dll`，同一进程里只能存在一个。`tools/callback` 先写 `"japi"` 再拼 PID；`sweep_stale_pid_dlls` 两种名字都认（旧的裸 `<pid>.dll` 也会清）。实测：下一次启动把上一局的 `japi49916.dll` 清掉，只剩当前进程那份。
- **`inline_hook_reassert_all` 遇到外来补丁就 stand down**：只有当前字节等于我们保存的原始字节（= 引擎把代码还原了）才重打；被别的插件改过就跳过并计数，日志变成 `inline hooks reasserted (N tracked, M re-patched, K left to another plugin)`，不再和别的 inline hook 互相覆盖。
- **`SaveGame` 补丁前检查是否已禁用**：目标首字节已是 `C3` 就保留原样（别人的补丁不备份成"原始字节"）。
- 说明：内置 `jass.dll` 对外部模块只认 `QB_inject.dll` / `dxrender.dll`（都服务于它自己的 D3D 块），没有"检测另一套 JAPI 并存"的机制——这三处是我们新增的，不是照抄。
- 验证：`hook_rollback_test` 全过；回归 **126/126**；日志确认 `sweep: removed 1 stale pid dll(s)` 与新落盘名生效。
### 变更：对齐内置 JAPI 的 native 面（2026-11-20，工作区未提交）

- **删掉自造的 EX 别名**：`EXGetUnitState` / `EXSetUnitState` 不再是 bridge 名（`EXGetUnitMaxLife` 本来就只是注释示例）。conformance manifest 与用例同步移除。
- **`GetUnitState` / `SetUnitState` 接管原生名**（内置 jass.dll `0x10033764`/`0x1003377b` 的 table_hook 做法）：`InstallUnitStateHooks()` 每局 `Initialize()` 重打，已是 fake 则跳过；日志 `UnitState: GetUnitState hooked (real=0x…)`。
- **新增内置有、我们缺的 native**（`src/src/extensions/ex_natives/BuiltinCompat.cpp` + `GameUI.cpp`）：
  * `timer_start` / `timer_end` / `timer_destroy`（`(I)R` 秒表，QPC + 8 字节堆块，不是 CTimer）
  * `GetBigMapX/Y`、`SetBigMapX/Y`、`GetConsoleUIX/Y`、`SetConsoleUIX/Y`（CGameUI frame `+0xF8/+0xFC`，与 little-map 同源）
  * `ReplacePath` `(SS)V`：整串精确匹配的路径重定向表 + **消费端已接**（照内置）：`base::hook::iat(Game.dll, "Storm.dll", ordinal 279, wrapper)`，detour 为 5 参 `__stdcall`、改第 1 参（资源路径）后原样转发其余四个。cdb 在 `Storm!Ordinal279` 上实测：`a1=units\human\Rifleman\Rifleman.mdx`、`a2/a3/a5`=调用方栈指针、`a4=1`，地图加载期被调几十次。
- **根因（之前三次崩溃）**：`stubs.cpp` 的 `pe_reader::get_directory_entry()` 返回 RVA，而 YDWE 原版返回**绝对地址**；`base/hook/iat.cpp` 直接把它当指针用 → 走到 0x19999999 一类垃圾地址（cdb 抓到的 AV 就是 `Game!GameMain+0x27f27` 读 `[eax+0x1C]`）。修好后 detour 立即正常。另外把 `base/hook/iat.cpp` + `detail/import_address_table.cpp` 真正编进了构建（此前 `iat()` 是返回 0 的 stub）。
- 诊断开关：`JAPI_STORM_IMPORTS=1` 会列出每个 Storm 导入项（序号 / IAT 槽 / 目标）。
- 验证（实机）：`srcuild.bat` 通过；回归 122 → **126/126**（新增 4 项 compat 用例：BigMap 取值、ConsoleUIY 往返、timer 三件套、ReplacePath 重定向）；ReplacePath 端到端可见——注册 `ReplacePath: "Textures\Knight.blp" -> "...BTNRifleman.blp" (1 entries)`，随后 Storm#279 命中同一路径并替换（`mapped=1`，日志无 "(N entries)" 那条）；日志显示两个 UnitState hook、两个别名、SaveGame 补丁全部落地。
### 新增：钩子补丁可回滚（2026-11-19，工作区未提交）

- `warcraft3::jass::inline_hook_info` + `inline_hook_uninstall()`：`inline_hook_install` 新增可选第 3 参，记录 target / stolen / trampoline / 原始字节；卸载时先还原字节再释放 trampoline（顺序不能反，否则路过 trampoline 的线程会跳进已释放内存）。对应内置 JAPI `0x10045C86` 的 target/backup/len/old_prot 记录。
- `base::hook::patch_guard`：备份后写字节，`restore()`/析构还原，二次 `apply` 先隐式还原；`kMaxSize` 上限 64 字节，越界/空指针直接拒绝。
- 新增 `hook_rollback_test.exe`（`src/tests/hook_rollback_test.cpp`，独立 CMake 目标）：35 项断言覆盖"装→卸→再装"的字节级可逆、trampoline 语义、幂等与非法入参。
- 钩子登记表：`inline_hook_install` 按 target 幂等（同 target + 同 detour 直接返回已有 trampoline，不再二次打补丁；detour 变了则替换）；新增 `inline_hook_reassert_all()`（地图重开时按保存的记录检查 JMP 是否还在，被引擎改写的重新打上）、`inline_hook_reset_all()`、`inline_hook_count()`。
- 地图重开路径接线：`Initialize()` 的 `Initialize() again: map boot` 分支与 `SimulateMapBoot` 回归入口都会调 `reassert_inline_hooks()`，日志 `Step 0: inline hooks reasserted (N tracked, M re-patched)`。之所以是"重新落实"而不是"先卸再装"：钩子补的是 game 代码，跨地图有效，先卸会让这一步之后的初始化拿到未打补丁的地址。
- 验证：`srcuild.bat` 通过；`hook_rollback_test` 56/56 PASS（含幂等安装、模拟引擎改写后 reassert、reset_all、detour 替换）；`-TestReboot` 10/10（日志 `SimulateMapBoot: inline hooks reasserted (1 tracked, 0 re-patched)`）；全量回归 `122/122`（`inline_hook_install` 两参调用点未改动，默认参数兼容）。

### 新增：D3D 代理随地图分发（2026-11-19，工作区未提交）

- `tools/pack.ps1`：**每张地图都携带** `newD3d9.dll` 与 `D3DX9_42.dll`（写作 `d3d9.tga` / `d3dx9_42.tga`，附 `d3d9.tga.sha256`），**没有开关**——缺代理的地图在没装代理的机器上完全没有 `jass.d3d`，代理文件缺失时打包直接报错；`-D3dxPath` 默认按 `reference\builtin-japi\extracted` → `src\build\bin\Release` → `SysWOW64` → `System32` 取第一个存在的（`*.dll` 被 gitignore，干净克隆里没有副本）。对标内置 JAPI 把 `newD3d9.dll` 嵌进 `wenhao_plugin.tga` 的做法。
- `yd_japi.dll`（`stage_d3d_proxy_from_map`）：会话里没有本项目代理时，从 MPQ 读取这两个文件写到 `war3.exe` 同目录，并写入 `.japi_d3d_proxy.sha256` 让 `tools\d3d-proxy.ps1` 仍能认领；已存在且字节不同则只记日志、不覆盖。代理只能在进程启动时绑定，因此**下一局生效**。
- `src/CMakeLists.txt`：两个 DLL 连同静态链接的 Lua 改成 **静态 CRT（`/MT`）**，与内置 JAPI 一致。原先是 `/MD`，代理只依赖 `MSVCP140` / `VCRUNTIME140`；随地图发到没装 VC++ 运行库的机器上，`d3d9.dll` 加载失败会直接带走整个游戏。
- 验证（2026-11-19 实机）：`src\build.bat` 通过，`newD3d9.dll` 依赖仅 `ole32/KERNEL32/USER32/GDI32`、`yd_japi.dll` 仅 `KERNEL32/USER32`（导出 157 项含 `lua_newstate`/`luaL_newstate`、`Initialize`）；`d3d_sdk_contract_test.exe` PASS（ABI v1 / stress=1000）；两局回归 `122/122`；`deploy.ps1 -Demo` D3D 切片 `33/33`。
- 验证（打包）：`pack.ps1` 产物解包回读含 `d3d9.tga`(90112B) / `d3dx9_42.tga`(1886208B) / `d3d9.tga.sha256`(64B)；带代理的地图回归 `122/122`。
- 验证（暂存链路，实机）：卸掉代理后跑带代理的地图 → 日志 `D3D: staged d3d9.dll from the map` / `staged D3DX9_42.dll from the map` / `proxy staged next to war3.exe; restart War3 to activate it`，同局仍报 `D3D handlers unavailable`；`d3d-proxy.ps1 -Verify` 认出 `D3D proxy=Owned`；下一局日志变为 `D3D: InitializeD3DAPI DONE`，即暂存的代理已生效；该局回归仍 `122/122`。Lua 原生 D3D API 未变，版本仍为 `0.4.0`。

### 新增：代码化物编与基础 UI（2026-11-18，工作区未提交）

- `tools/object-data`：构建专用 `unit` / `ability` 声明，使用四字符 ID、原生父对象与原始字段 ID；读取 w3x2lni 元数据验证类型、等级与冲突，追加到版本 1/2 物编并保留既有记录字节。声明时复制字段和等级表，复用 Lua 配置表不改变先前对象。`pack.ps1` 自动发现根 `objects.lua`，该文件不进入游戏模块。
- `map/lib/ui.lua`：本地像素按钮、行/列嵌套布局、padding/spacing、resize 重排、启用/隐藏与悬停/按下状态；拥有式资源释放、失败回收及回调中销毁。保持共享 D3D session，不提供网络同步。
- 示例 11/12、[使用指南](docs/guide/OBJECT-DATA-UI.md)与自动输入驱动；示例验证支持项目内 Lua 模块并检查其语法；UI 实机必须完成真实窗口输入，驱动失败或结果不完整均判失败。发布脚本读取示例 manifest，包含物编工具与 UI 副本；本轮没有创建发布包。
- 验证：物编离线 `21/21`、真实 w3x2lni 往返与既有 Hrif 保留；UI mock 5 组库测试 + 2 组示例协议回放；全部 12 例静态+打包通过；新例实机 `4/4` 与 `3/3`，真实点击与 resize 后资源计数回到基线。Lua 原生 D3D API 未变，版本仍为 `0.4.0`。

### 新增：首批 SDK 诊断与显式清理（2026-11-17，工作区未提交）

| 能力 | 实现 | 验证 |
|---|---|---|
| 接口能力诊断 | `jass.japi.info(name)` / `jass.japi.counts()`：直接读活注册表，报告 engine native / japi native / UnitId bridge 三张表的归属、spec、可达路由（`lua_common`/`lua_call`/`lua_japi`/`jass_native`/`jass_unitid`）与 `handshake`/`unitid_hook` 状态 | conformance N1–N11、N14（含双注册表 `EXGetUnitAbility` 的 effective spec、运行时 Lua handler、未知名字）；实机 `Conformance: 199 passed, 0 failed, 4 skipped` |
| 事件/回调显式清理 | `jass.hook.unhook` 返回 `true`/`false`，`hook[name] = nil` 同时清表项；hook、texture event 的回调引用改按 owner 计数释放（`callback_release`），共享闭包不误释放；`message.texture_remove_event` 返回布尔、`texture_destroy` 返回移除数量；模拟换图重置会销毁 bridge D3D 事件保留的 timer | conformance N12–N13、N15（弱表 + GC 证明释放、双 owner、`texture_destroy` 计数）；基线 122/122、VM 重置 10/10（含计时器清理重入） |
| Lua 打包依赖诊断 | `pack.ps1` 的 `require` 分类改为按匹配位置替换（保留 `local x =` 前缀，避免误改缩进/注释里的文本）；`-RequireReport` 打印每条来源与未使用文件，`-StrictRequires` 让缺失/无法内联/循环依赖在打包期失败；引擎 `jass.*` 模块从 `open_lua_engine.cpp` 动态读取 | `tests/tools/pack-diagnostics.ps1` 实跑 13/13：含注释/长字符串不误改、循环依赖、重复 require、缺失锚点及重复打包 |
| JASS 注入锚点诊断 | `pack.ps1` 在 patch 前打印 `globals`/`endglobals`/`main`/首个函数/`initializePlugin`/`LoadScript`/`native:SetHeroLevels` 的行号与探针全局；调用锚点容忍空白差异；缺失/错位时抛出带锚点摘要的错误，多重调用锚点发出告警；数组全局若最终没有 `JapiForceAllocArrays()` 调用会直接失败 | 夹具覆盖正常/空白差异/外来图/无 `main`/`native` 在函数后/缺 `endglobals`；仓库 `-WithJassWrappers` 125/125、`-WithGetFuncAddr` 126/126（pjass 通过） |

被测 DLL：640000 B，SHA256 `F2C6EB0849D07FF6ACAA97FEAB854BB58AD950014F7DC7BD0B83EA662B7EE9E4`（`src\build\bin\Release\yd_japi.dll`，
cmake Win32 Release 构建；同一份 DLL 跑完上述实机回归）。
`jass.d3d` 的 Lua 公开面没有变化，SDK 版本仍是 `0.4.0`。

本轮审查补充：拒绝注册诊断保留名 `info`/`counts`；拒绝卸载正在执行的 hook，卸载后调用保存的 `orig` 会报错；计时器清理先移出事件表以隔离重入删除。测试台补齐选中单位的 userdata 类型和选择集合前置条件，修正 `order_target` 漏传参数；conformance 启动器必须同时确认进程退出码、两条汇总与零失败，缺失结果不能算通过。

### 新增：接口一致性测试台（`tests/conformance/`，2026-11-17）

把「引擎到底实现了什么」变成一张会失败的表格 —— 一张独立最小地图，不依赖 `map\` 的 demo，也不依赖任何移植层 shim，只用引擎：

| 文件 | 作用 |
|---|---|
| `tests/conformance/war3map.lua` | 测试本体：夹具（步兵 `hfoo` + 技能 `AHbz`）+ 十三组断言（A 模块 / B `jass.common` / C handler 存在性 / D 返回类型 / E 语义往返 / F slk / G message / H storm / I 外部图的 16 个 EX 使用点 / J EX* 真 native / K console+log / L bignum / M setter 返回值） |
| `tests/conformance/gen-manifest.mjs` → `manifest.lua` | **生成物**：从 `src/` 剥注释后抽 `register_cpp_handler`（可被 Lua 调用的 handler，66 个）与 `jass::japi_add`（声明的 native，39 个）；注册表多一个 handler，C 组自动多一行 |
| `tests/conformance/run.ps1` | 一条命令：语法校验 → 独占 war3 → 打包部署 → 过滤 `[PASS]/[FAIL]/[SKIP]` → 打印两行汇总与 exit code |
| `tests/conformance/check-syntax.lua` | `w3x2lni-lua` 的 `loadfile` 校验（打包器原样拼接，语法错在游戏里只有一行 FATAL） |
| `tests/conformance/README.md` | 断言分组、怎么加用例、边界、已捕获缺陷 |

**实机结果**（`yd_japi.dll` 633856 B，`816E5F347743538A9458B49431381A8B803B011697B41E6A19557215DBD44D26`）：`Conformance: 170 passed, 0 failed, 4 skipped` / `Results: 170 passed, 0 failed, 170 total`，deploy exit 0。

### 新增：`jass.console` / `jass.log` / `jass.bignum` / `jass.storm.save` / `slk.misc`（2026-11-17）

这几个模块 builtin-japi 有、我们此前没有；外部 YDWE 谱系图全靠它们，所以补成真实现（不再靠假 shim）：

| 模块 | 实现 | 验证 |
|---|---|---|
| `jass.console` | 新 `src/src/lua_engine/lua_engine/libs_console.cpp`：`enable`/`write`/`flush`/`clear` 写 `debug_log.h` 的 `AllocConsole` 控制台并镜像 `OutputDebugString`（没有控制台时也能看见） | conformance K 组 |
| `jass.log` | 新 `libs_log.cpp`：真写 `<游戏目录>\<log.path>log-YYYYMMDD.log`，一行一次调用；路径按 UTF-16 处理（1.27a 是 ANSI 进程，脚本串是 UTF-8），默认 `logs\map\` | K 组 + 实机真的落盘 |
| `jass.bignum` | 新 `libs_bignum.cpp`：32 位 limb 大数（`new`/`bin`/`powmod`）+ 自写 SHA-1；`tostring`/`sha1` 都是小写十六进制、不补零（与上游 RSA 校验同口径） | L 组往返 |
| `jass.storm.save` | `libs_storm.cpp` 新增：把 Lua 串写进地图目录下的真实文件；`storm.load` 在 MPQ 未命中时回落读同目录 | H 组 `save → has → load` 往返 |
| `slk.misc` | `libs_slk.cpp` 第 8 张表：`ObjectManager` 的 misc 数据 + 地图 `war3mapmisc.txt` 合并（`DefenseArmor` 等） | F 组 |

### 修复：bridge 字符串返回 ABI；41 个 EX* 变成真 JASS native（2026-11-17）

| 问题 | 根因与修法 | 验证 |
|---|---|---|
| 所有 EX* 字符串 getter 返回垃圾（读 `AHbz` 的提示得到 `playerevent`） | `jass::create_string()` 返回的是 **JASS 字符串句柄索引**（实测 `create_string("Blizzard") == 0x30`），必须 `vm->string_table->get(idx)` 拿节点再 `jass::from_string()`；原实现按「`>=0x10000` 当句柄、否则当脚本 string id」猜，小值全走错。`bridge_dispatch.cpp` 新增 `resolve_string_result()`：句柄表优先、脚本 string id 回落且检查 `reverse_table::size` | conformance E 组转绿；探针打印 `203=暴风雪 / 204=…\BTNBlizzard.blp / 215=暴风雪(…)` |
| 41 个 EX* 名字在 JASS 里不存在 | 根因：`initialize_ex_natives()` 只 `register_cpp_handler`，从不调 6 个 `Initialize*` ⇒ 那些 `jass::japi_add` 全是死代码。新增 `register_real_ex_natives()` 依次调用 `InitializeAbilityState`/`ItemState`/`Effect`/`EventDamageData`/`GameInfo`/`DisplayChat` | conformance J 组；**`-WithJassWrappers` 仍 125/125**（同名 native 会与 `gen-jass-wrappers.ps1` 生成的 wrapper 撞名，实测没撞） |
| bridge 的 `V`（void）setter 返回 `nil`，与 UjAPI 的谓词语义不符 | `bridge_dispatch.cpp`：`spec.ret == 'V'` 时推 `true`（18 个 setter 受影响） | conformance M 组 |
| `EXGetUnitState`/`EXSetUnitState` 调不到 | `UnitState.cpp` 新增 `resolve_real_unit_state()`：用 `jass::jass_func("GetUnitState"/"SetUnitState")->get_address()` 填 `RealGetUnitState`/`RealSetUnitState`（原本一直是空指针），再注册两个 bridge handler | conformance E 组 |
| `EXGetAbilityString`/`EXSetAbilityString` 缺失 | 按共享的 per-type ability UI 表（`CAbilityUIDef`）实现，按 rawcode 而不是单位上的 ability handle 寻址 | conformance E 组 |
| 外来图的物编查不到（`slk.unit` 空、`slk.destructable[整数]` 崩） | `libs_slk.cpp`：7 张表改 `mgr.load(::slk::ROBJECT_TYPE::…, table)`（带地图物编合并；地图没有该表时 `ObjectManager` 自己回落基表），失败才回落原来的纯基表；`type_index` 接受数字 rawcode（大端 `'YTfb' == 0x59546662`） | conformance F 组 |
| Lua 侧调不到只经 `register_cpp_handler` 注册的 handler | 新增 `bridge::push_cpp_handler`，`libs_japi.cpp` 的 `japi_index` 在 `jass::japi_func` 取不到时回落它 ⇒ 66 个 bridge handler 全部可当 native 调用，且不动 JASS 命名空间 | conformance C 组（66 条） |

自 `0.4.0`（`d151fd7`，2026-11-15）以来的改动。**SDK 版本号仍是 `0.4.0`**：`jass.d3d` 的 Lua 侧 API 没有变化，
本轮加的是 JASS 侧通道、工具链、示例、文档与脚手架。日后若动 `jass.d3d` 的对外行为，按 `0.5.0` 递增。

### 新增：JASS 侧通道（面向 JASS 地图作者）

| 能力 | 提交 | 验证 |
|---|---|---|
| `GetFuncAddr(code)`：内置 JAPI 的 JASS 函数取址链（`SaveFunc` / `func_bind_trigger_name`） | `164ae1a` | 实机 `126 passed, 0 failed, 126 total`（`deploy.ps1 -WithGetFuncAddr`） |
| 每个 bridge handler 自动生成内置 JAPI 形状的五部曲 JASS wrapper（`EXGetUnitAbility(...)` 可直接 `call`） | `61a23c5` | 实机 `125 passed, 0 failed, 125 total`（`deploy.ps1 -WithJassWrappers`） |
| `SaveFunc` / `func_bind_trigger_name` 代码标签表 | `cb6f5cb` | 实机（含在 126/126 的 `-WithGetFuncAddr` 组里） |

默认打包不含这两批 JASS 注入，对应小节打印 `[SKIP]`：不开开关就是 `122 passed, 0 failed, 122 total`。

### 新增：Lua 侧

| 能力 | 提交 | 验证 |
|---|---|---|
| JASS 数组全局预分配（打包器插入 `JapiForceAllocArrays`，每数组 8192×4 = 32 KB），`jass.globals` 从此可在任意下标读写 | `1f07e56` | 实机（默认 `122/122`；`-NoArrayPrealloc` 时不预分配，数组写入相关断言会失败，`docs/planning/JASS-NATIVE-DECLARATIONS.md` 的 T10 记为 `121 passed, 1 failed`） |

### 工具链、示例与文档（本轮，已提交）

| 文件 | 作用 | 提交 | 验证 |
|---|---|---|---|
| `tools/release-sdk.ps1` | 从指定提交的 clean worktree 构建并打包 SDK 发布件（`yd_japi.dll` / `newD3d9.dll` / `d3d_sdk_contract_test.exe` + `SHA256SUMS.txt` + `manifest.json`） | `c4cf647` | 静态 + `-NoBuild` 冒烟实跑（见下） |
| `docs/RELEASE.md` | 发布流程 runbook（前置条件、步骤 0–7、坑表、版本号确认） | `c4cf647` | 文档，未做发布级复跑 |
| `CHANGELOG.md` | 本文件 | `c4cf647` | 文档 |
| `tools/pack.ps1` / `tools/deploy.ps1` 新开关 | `-WorkDir` 打包隔离、`-MapDir`/`-MapName` 工程目录部署、日志守卫与退出判定、`-Hold` 等 | `4d4a5eb` | 实机（`-MapDir`/`-MapName` 端到端；`-Hold` + `drive-interactive-d3d.ps1`） |
| `examples/` + `tools/verify-examples.ps1` | 10 个可直接打包的最小工程 + 静态/打包/实机三档校验脚本 | `9dc7177` | 静态 + 打包 **10/10 通过**；实机 `-Live` **10/10 全部 0 failed**（逐条数字见下） |
| `tools/new-project.ps1` | 地图脚手架：生成一个可打包、可部署的空工程（自带 9 项冒烟断言） | `87f9086` | 实机（脚手架空工程 `-MapDir build\scratch\proj\MyMap`：` Results: 9 passed, 0 failed, 9 total (0 skipped)` + `ALL CHECKS PASSED (9/9)`，2026-11-16 lead 实测） |
| `docs/guide/SDK-QUICKSTART.md` / `SDK-GUIDE.md` / `SDK-COOKBOOK.md` | 使用者文档（快速上手 / 综合指南 / 常见配方） | `0c07e6d` | 文档；数字口径以 `docs/STATUS.md` 为准 |
| `AGENT.md` 作者工作流 | 新 agent 上手：作者工作流与新增开关 | `9347b12` | 文档 |

`examples/` 的实机 `-Live` 结果（2026-11-16，同一份 `yd_japi.dll` `87C83BA1…`，`-Timeout 120`）：

| 示例 | `Results:` 行 | 示例 | `Results:` 行 |
|---|---|---|---|
| 01-hello-jass | `5 passed, 0 failed, 5 total` | 06-globals | `5 passed, 0 failed, 5 total` |
| 02-input-hook | `8 passed, 0 failed, 8 total` | 07-slk | `5 passed, 0 failed, 5 total` |
| 03-d3d-hud | `6 passed, 0 failed, 6 total` | 08-d3d-subscription | `7 passed, 0 failed, 7 total` |
| 04-create-unit-order | `5 passed, 0 failed, 5 total` | 09-jass-wrappers | `6 passed, 0 failed, 6 total` |
| 05-sleep-sequence | `6 passed, 0 failed, 6 total` | 10-getfunc-addr | `6 passed, 0 failed, 6 total` |

10 个示例**每一个都有实机 0 failed 的记录**，但没有一批把 10 个一次跑完：同一台机器上另一个会话在跑
`deploy.ps1 -Demo -Hold`，1.27a 的单实例锁加上共享的 `C:\ProgramData\japi_debug.txt` 造成两次撞车
（`war3.exe is already running`；以及 `no fresh Results line` 但该示例的 `[PASS]` 行都在——对方 deploy 的
`Remove-Item` 重建了日志，我们的 `Results:` 写进了已 unlink 的旧句柄）。判定与规避写在 `examples/README.md` 的
「`-Live` 撞车」一节，逐例的日志来源写进 `docs/STATUS.md` §4。

`release-sdk.ps1` 的 `-NoBuild` 冒烟（2026-11-16）：先在 `-Commit 498a308` 上跑通，随后在 HEAD `9347b12` 复跑，最后在本轮最后一次改动 `tools\`/`examples\` 的提交 `b2e11ab` 上复跑第三次，三次都是
exit 0、干净 worktree 自动创建并删除。`498a308` 那次包内 hash 与 `src\build\bin\Release` 源文件逐字节一致；`9347b12` 与 `b2e11ab`
两次产出 `build\sdk\0.4.0-9347b12\`、`build\sdk\0.4.0-b2e11ab\`，三份产物的 SHA-256 与独立 `Get-FileHash` 一致，且
换 HEAD 后 hash 不变——本轮改动全在 `tools\`、`examples\`、`docs\`，没有碰 DLL 与 Lua 引擎源码。
**`-NoBuild` 只用于验证脚本本身，绝不能当作发布产物**——manifest 里 `built: false`、`artifact_source: "local_worktree"`
就是给这件事留的记号。

### 新增：地图作者 SDK 分发包（`tools\release-sdk.ps1 -SdkBundle`）

| 文件 | 作用 | 提交 | 验证 |
|---|---|---|---|
| `tools/release-sdk.ps1` 的 `-SdkBundle` / `-NoVendor` | 在二进制包旁边再组装一个 `sdk\`：`docs/guide` 6 份 + `STATUS`/`RELEASE`/`planning` 2 份 + `CHANGELOG`、`examples` 10 个、8 个作者脚本 + `pjass.exe` + `callback` + `config.example.ps1`、`reference\empty-map`、3 个注册表源、`tools\w3x2lni` vendor、3 个二进制；另出 `sdk\README.md` 与 `sdk\SHA256SUMS.txt`，manifest 增 `sdk_bundle` 段 | 本轮 | 静态 + 仓库外自包含实跑（见下） |
| `tools/sdk-bundle/README.template.md` | 包内入口 README 模板（`@@VERSION@@` / `@@ARTIFACTROWS@@` / `@@TREEFILES@@` 等占位符）：包里有什么、三分钟上手、怎么验证包、脚本清单、7 条必读坑、版本与来源 | 本轮 | 文档；渲染后残留占位符会 `throw` |
| `docs/RELEASE.md` §8.5 | 出包流程补上作者包：内容来源的两个例外、注册表源为何要进包、自包含门槛、实测数字 | 本轮 | 文档 |
| `docs/guide/SDK-QUICKSTART.md`、`AGENT.md` | 入口指向 `sdk\README.md` | 本轮 | 文档 |

为什么要多这一层：`release-sdk.ps1` 原来只产出 3 个二进制 + 清单，作者拿到手还得自己找文档、示例、脚手架和 `w3x2lni` 运行时。而所有作者脚本都用 `$Root = Split-Path -Parent $PSScriptRoot` 推仓库根 —— **按同样的仓库子集布局塞进 `sdk\`，它就能当仓库根用，脚本一行不用改**。

自包含验证（2026-11-16，`build\sdk\0.4.0-1da154c\sdk\` 整个拷到 `%TEMP%\sdk-standalone-1da154c`，完全脱离仓库）：

- `tools\verify-examples.ps1`（静态+打包）：`Examples: 10 passed, 0 failed, 10 total`。首轮是 9/10 —— 示例 09（`pack.ps1 -WithJassWrappers`）报 `handler registry not found`，补上 `gen-jass-wrappers.ps1` 要扫的 3 份注册表源（`src\src\extensions\ex_natives\Initialize.cpp`、`src\src\lua_engine\lua_engine\libs_message.cpp`、`src\src\d3d9\handler_manifest.json`）后 10/10。
- `tools\new-project.ps1 -Name Smoke -Path …` → `tools\pack.ps1`：`Done -> build\Smoke.w3x`（275638 字节，`Bundled 5 Lua files`、`JASS syntax check OK`）。
- 包体积 683 文件 / 90.2 MB（vendor 615 文件 / 88.7 MB，其中 19 个 `bin\*.dll` 被 `.gitignore` 排除、由出包机本地 checkout 覆盖，manifest `sdk_bundle.vendor.overlaid_files` 记录）。`[skip] luac not found` 属预期：包里没有 Lua 源码与 gcc，打包与 `-Live` 不受影响。
- **包内实机**（2026-11-16，`build\sdk\0.4.0-c14b043\sdk\` → `%TEMP%\sdk-standalone-c14b043`）：`tools\deploy.ps1` 把脚手架生成的工程打进游戏，日志 `Results: 9 passed, 0 failed, 9 total (0 skipped)` + `ALL CHECKS PASSED (9/9)`，`deploy` exit 0（之前这一项记「未验证」是因为出包机被另一个会话的 `deploy.ps1 -Demo -Hold` 占着 1.27a 单实例锁；等对方退出后补跑）。
- 最终包 `build\sdk\0.4.0-c14b043\`（HEAD `c14b043`）整套复跑：`SHA256SUMS.txt` 683 条逐条 `Get-FileHash` 回读 **683/683 一致**、静态+打包 `10 passed, 0 failed`、脚手架打包 `build\Smoke.w3x` 275636 字节。
- **包内 `-Live` 一轮跑完 10/10**（2026-11-16，`tools\verify-examples.ps1 -Live`，仓库外）：每例 `[live] ok` —— 01 `5/5`、02 `8/8`、03 `6/6`、04 `5/5`、05 `6/6`、06 `5/5`、07 `5/5`、08 `7/7`、09 `6/6`、10 `6/6`，末行 `Examples: 10 passed, 0 failed, 10 total`。此前仓库内的 `-Live` 被另一会话的单实例锁挤成两批，这是**第一次一次跑完**，也是最强的「作者拿到包就能用」证据。

写脚本时踩到的两个坑（都真的把逻辑跑没了）：

- `release-sdk.ps1` 一旦内嵌中文就必须存成 UTF-8 **带 BOM**。它原来是纯 ASCII 无 BOM，加中文后 PS 5.1 按 ANSI 解码，解析直接报「意外的标记」；改存带 BOM 后正常（`tools\new-project.ps1` 本来就是 BOM 先例）。任何工具重写该文件都可能把 BOM 丢掉，改完确认前 3 字节是 `EF BB BF`。
- PowerShell 变量名**不区分大小写**：`[switch]$SdkBundle` 与本地 `$sdkBundle = $null` 是同一个变量，开关刚被读就被置空，Step5 整段静默跳过（首跑 summary 里连 bundle 行都没有）。改名 `$bundleInfo` 后才跑通。这是本会话第二次踩同类坑（第一次是 `verify-examples.ps1` 的 `$live` vs `[switch]$Live`）：**开关名不要当同名局部变量复用**。

### 修复：调试控制台乱码 + 关不掉的孤儿 War3

| 问题 | 修法 | 验证 |
|---|---|---|
| 控制台满屏乱码（日志文件本身是合法 UTF-8，`chcp` = 936） | `src/src/debug_log.h` 的 `init_console()`：`AllocConsole()` 后加 `SetConsoleOutputCP(CP_UTF8)`/`SetConsoleCP(CP_UTF8)`，并用 `CONSOLE_FONT_INFOEX` 把字体换成 TrueType 中文字体（光栅 Terminal 字体没有 CJK 字形）。字体名必须写成 C++ universal character names（`L"\u65b0\u5b8b\u4f53"`）：.h 是 UTF-8 而 MSVC 按 936 编译，直接写中文报 C2001 | 实机：控制台 `[log.debug] 日志系统装载完毕,向着星辰大海出击!` 正常（`a5dff44`） |
| 游戏成了孤儿进程就再也杀不掉 | 根因：1.27a 发布版的 `Game.dll` 启动时给自身进程对象装 `DENY 0x001FFFFF \Everyone`（导入表有 `AddAccessDeniedAce`/`SetSecurityInfo`），但进程 owner 隐式持有 `READ_CONTROL`+`WRITE_DAC` ⇒ 不用提权：`OpenProcess(READ_CONTROL\|WRITE_DAC)` → `SetSecurityInfo` 写回「`SYSTEM` + 当前用户 `PROCESS_ALL_ACCESS`」的 DACL → 正常 `TerminateProcess`。封装在新增的 `tools/_war3ctl.ps1`（dot-source 库，含 Toolhelp 判活、DACL 修复、Job Object），命令行入口是新增的 `tools/kill-war3.ps1`（无参数 = 关掉所有 `war3.exe`，`-DryRun` 只看能否打开）；`tools/deploy.ps1` 收尾改走 `Stop-War3Process`（先创建句柄，失败再「修复 DACL + Terminate」，逐轮重试），并新增 `-Job` 把游戏放进 `KILL_ON_JOB_CLOSE` 的 Job Object，启动器被强杀时由内核收尸 | 实机（2026-11-16，`yd_japi.dll` `26D1FA3D…`）：默认回归 `122 passed, 0 failed, 122 total`；`-Job` + `Stop-Process` 掉启动器 → 4 s 内游戏消失；无 `-Job` 强杀启动器 → 孤儿存活（`terminateAccess=False`），`tools\kill-war3.ps1` → `pid 35708 closed (dacl repair + terminate)`；外部 PowerShell 单独起的游戏同样能关 |
| `verify-examples.ps1 -Live` 可能在已有游戏运行时开跑 | 它用 `Get-Process -Name war3` 判活，而 .NET 的进程枚举会**静默跳过**拒绝访问的游戏进程（DACL 生效后正是这种情况）⇒ 4 处判活改走 `tools\_war3ctl.ps1` 的 CIM/tasklist 查询（`Get-War3ProcessId`） | 静态 `10 passed, 0 failed, 10 total`；`-Live -Filter 01-hello-jass` → `[live] ok (5/5 passed)` |
| `tools\release-sdk.ps1` 在 Windows PowerShell 5.1 下直接语法报错（`Unexpected token 'pack.ps1' + $bt ...` @ line 506） | 文件是**无 BOM 的 UTF-8**，5.1 按 ANSI（936）解码，中文串里映射不到的字节被吞成 `?`、把引号吃掉 ⇒ 加 UTF-8 BOM（与 `new-project.ps1` 一致；PowerShell 7 不受影响） | 5.1 下 `-NoBuild -SdkBundle` 跑通：685 文件 / 90.3 MB / 685 hashed，`tools` 13 个（含 `_war3ctl.ps1`、`kill-war3.ps1`） |

原「DLL exit watch」方案（`japi_install_exit_watch()` 轮询 `JAPI_EXIT_MARKER`/`JAPI_PARENT_PID` 后 `ExitProcess`）**已回滚**：给 DLL 加一个只为关进程而存在的方法并不合适，`JAPI_EXIT_*` 约定随之取消，`deploy.ps1` 不再导出这些环境变量（`src/src/extensions/dllmain.cpp` 删掉整段 watch 线程与非零退出前的 `DeleteFileA` 分支）。

⇒ **不需要用管理员权限启动 DSH**：任何以当前用户运行的进程都能修 DACL 再关游戏（owner 隐式权限恒定）。注意游戏**启动早期会二次安装 deny ACE**（实测 t=6.5 s 修好后 `OpenProcess(PROCESS_TERMINATE)` 又变 `win32=5`，到 t=10.5 s 才稳定），所以 `Stop-War3Process` 是「修复 + Terminate 紧挨着」并逐轮重试；启动完成后不会再装回（实测 10 s 后 DACL 仍是我们的两条 ALLOW）。`-Job` 是「启动器被强杀、来不及收尾」时的额外保险；`tools\kill-war3.ps1` 用于清历史孤儿或外部起的游戏。

### 验证（2026-11-16 实机，本地构建 `yd_japi.dll` = `87C83BA1CE0E6E413CEA7B9D6018E9A289259EC9C2F01EE02E7827DAF6661908`）

| 组 | 命令 | `Results:` 行 |
|---|---|---|
| 普通 | `tools\deploy.ps1` | `122 passed, 0 failed, 122 total` |
| JASS wrapper | `tools\deploy.ps1 -WithJassWrappers` | `125 passed, 0 failed, 125 total` |
| GetFuncAddr | `tools\deploy.ps1 -WithGetFuncAddr` | `126 passed, 0 failed, 126 total` |
| 交互 D3D | `tools\deploy.ps1 -InteractiveD3D -Hold` + `tools\drive-interactive-d3d.ps1` | `170 passed, 0 failed, 170 total` |
| 地图级 VM 重置 | `tools\deploy.ps1 -TestReboot` | `9 passed, 0 failed, 9 total` |

口径说明（别把两次数字混着用）：

- `170 = 122`（普通基线）`+ 48`（D3D 夹具）。`0.4.0` 当时是 `164 = 116 + 48`：D3D 夹具数没变，是普通基线长大了。
- `126` 比 `125` 多的一条就是 `GetFuncAddr` 组本身；`125` 比 `122` 多的三条属于 wrapper 组。
- 这些行目前只有 `122 / 125 / 126 / 9` 写在 [docs/STATUS.md](docs/STATUS.md) 头部表里；`170/170` 是本轮新记录，
  `docs/STATUS.md` §4 仍写着 `164/164`（0.4.0 口径），两者不矛盾，看的是不同日期的基线。

### 未完成 / 已知缺口

| 项 | 现状 | 影响 |
|---|---|---|
| `GetPluginVersion()` | 返回硬编码 `"1.0.0"`（`src/src/extensions/ex_natives/GameInfo.cpp:42`），**不跟 `kVersion` 联动** | 不能用它判断 SDK 版本，见下面「版本号对照」 |
| `jass.runtime.version` | 返回硬编码 `"1.0.0.0"`（`src/src/lua_engine/lua_engine/libs_runtime.cpp:245`），也不跟 `kVersion` 联动 | 同上 |
| `jass_temp` 的语义 | 仍是待验证假设（`498a308` 把原来的断言降级为假设） | 不要在文档里当结论引用 |
| `docs/STATUS.md` §4 的 `116/116` | 该段正文里的旧数字（同文件头部表是 `122/122`） | 引用时以头部表与本文件为准 |

---

## [0.4.0] — 2026-11-15

`chore(d3d): pin the Lua SDK version at 0.4.0`（`d151fd7`）。这是**第一个可交付的版本**：D3D Lua SDK 从「实现完成」
升为「可用」，并且发布产物能从提交重新构建出来。

### 变更

- 把 `kVersion` 从 `"0.3.0-dev"` 钉成 `"0.4.0"`（`libs_d3d.cpp:35`），`map/tests/test_d3d_sdk.lua:33` 从
  「只断言非空字符串」改成断言精确值 `assert(d3d.version() == "0.4.0")`。
  动因：上一版候选 `04f6b7e` 对外仍报 `0.3.0-dev`，却已被文档记为「可用」，口径自相矛盾；
  钉版本会改变 `yd_japi.dll` 字节，所以溯源必须在 `d151fd7` 上重算（设计文档 14.4 有完整记录）。
- 文档同步：`docs/guide/D3D-LUA-API.md` 的 `d3d.version()` 说明改为「当前 `"0.4.0"`」。

这一版之前已合入、因此包含在 `0.4.0` 里的能力（都属 `0.3.0-dev` 期间完成）：P4 真实鼠标/键盘输入与统一输入事件、
P5 生命周期（TTL / 设备状态 / 生命周期事件）、地图级 VM 重置（每次地图启动关闭并重建 Lua VM）、
54/54 兼容 handler 覆盖 + BLP2 实机解码、文字改 UTF-16、快速上手/API/迁移三份文档。

### 发布产物（clean worktree 构建，`d151fd7`）

| 产物 | 大小（字节） | SHA-256 |
|---|---:|---|
| `newD3d9.dll`（proxy） | 90112 | `0564A518EB3CB2F91CD65D0BDC766B9FC5B8709335CFFE5274C1FED24727834B` |
| `yd_japi.dll` | 544768 | `3A4C8CD11E54C3E357236468AA7A18D447E3578F98376071AAF3DB366510D53B` |
| `d3d_sdk_contract_test.exe` | 23040 | `87EBB317E9E94AB0F0A333CA55F3F11A384AB937258A68ECF7FFC74A1A2304B6` |

与 `docs/STATUS.md` §4、`docs/planning/D3D-LUA-SDK-DESIGN.md` §14.4 的表逐字一致。
注意：主工作区 / `src/build/bin/Release` 里同一提交附近构建出来的 `yd_japi.dll` **不是**这组 hash，
发布/回归一律用 clean 产物，别拿本地构建冒充。

### 验证（全部使用上面的 clean 产物）

| 组 | 结果 |
|---|---|
| 原生 ABI 合同 | `D3D SDK contract PASS: ABI v1, sessions, generation handles, dependencies, alpha/z/assets/input capabilities, failure counters, stress=1000` |
| handler 静态合同（clean worktree 内跑 `src\src\d3d9\verify_contract.ps1`） | `D3D contract PASS: surface=54, proxy=49, canonical=5, fixture=54/54, untested=0` |
| 普通回归 | `116 passed, 0 failed, 116 total` |
| 交互 D3D | `164 passed, 0 failed, 164 total`（含 `D3D SDK BLP2 memory decode (raw/palette/DXT1)`、`resize=20 (target 20) lost=0 reset=20`） |
| 地图级 VM 重置 | `8 passed, 0 failed, 8 total` |

上表是 `0.4.0` 当时的验收口径；普通回归与重启回归后来因为新增测试长成了 `122` 与 `9`（见 `[Unreleased]`）。
结论与保留限制（`device_lost` 在 1.27a 窗口模式不可观测、`ShowFpsText` 为弱断言）记录在 `docs/STATUS.md` 与设计文档 15.8.4。

---

## [0.3.0-dev] — 2026-11-14

`feat(d3d): P4 texture subscriptions and unified input events`（`a9e1d21`）把版本从 `0.2.0-dev` 推到 `0.3.0-dev`。
该版本线一直延续到 `d151fd7` 之前，期间合入：

- P4：贴图订阅（`TextureRemoveEvent` 等）与文字/贴图统一的 `enter/leave/click` 输入事件（`a9e1d21`）。
- 文字渲染从 ANSI 改 UTF-16（`1be5583`），中文不再乱码。
- P4 真实输入：窗口消息 + 异步状态（`96d90f2`）。
- P5 生命周期：TTL、设备状态、生命周期事件（`2a5b46a`）。
- 地图级 VM 重置：每次地图启动关闭并重建 Lua VM，`func_bind` 标签表随启动清空（`252d0c4`）。
- 54/54 兼容 handler 覆盖 + BLP2 raw/palette/DXT1 实机解码（`04f6b7e`）。
- 用户文档三件套：`docs/guide/D3D-LUA-QUICKSTART.md`、`D3D-LUA-API.md`、`D3D-LUA-MIGRATION.md`（`c53c005`）。

### 验证

这些改动各自的实机记录散在 `docs/STATUS.md` §3/§4 与设计文档 §14、§15.8；本版本**没有**独立发布产物
（`-dev` 后缀即此意），不建议任何人按 `0.3.0-dev` 对外承诺行为。

---

## [0.2.0-dev] — 2026-08-03

`feat(d3d): add typed Lua resource SDK`（`50ebb0f`）首次引入 `kVersion`，值为 `"0.2.0-dev"`。
同一批次（2026-08-03）合入：

- 版本化 session 资源 ABI（`D3D_SDK_ABI_VERSION_1`，`d3d.abi_version()` 返回 `1`）（`b3f4da8`）。
- typed 资源 SDK：`Context` / `Texture` / `Subscription` 三类 userdata 与 `__gc`/`__close`（`50ebb0f`）。
- 文字与贴图统一到同一条渲染队列（`49dccfc`）。
- 从 MPQ 读贴图资源（`5dbcfd4`）。

### 验证

仅当年的静态/构建校验与局部实机记录，无发布产物。**不要**把它当作可依赖的版本。

---

## 早期（无版本号）— 2026-06-04 → 2026-08-03

`7e3bac7`（2026-06-04）起的第一阶段：DLL 注入链（callback exploit）、Lua 引擎接入、`jass.common`/`globals`/
`japi`/`hook`/`runtime`/`message`/`debug`/`slk`/`sleep`/`storm` 等模块、D3D9 proxy 雏形（`ed2168f`、`cd9a9b0`）。
这段时间没有 `jass.d3d`，也没有任何版本字符串，历史行为以 `docs/STATUS.md` 与逆向文档为准。

---

## 附录 A：版本号对照（哪个才是「SDK 版本」）

| 表面 | 怎么读 | 当前值 | 代码位置 | 跟 `kVersion` 联动？ |
|---|---|---|---|---|
| SDK 版本 | `require("jass.d3d").version()` | `"0.4.0"` | `src/src/lua_engine/lua_engine/libs_d3d.cpp:35` | **是**（唯一来源） |
| D3D ABI 版本 | `require("jass.d3d").abi_version()` | `1` | `D3D_SDK_ABI_VERSION_1` | 独立编号，与 SDK 版本无关 |
| 引擎适配层 | `require("jass.runtime").version` | `"1.0.0.0"` | `src/src/lua_engine/lua_engine/libs_runtime.cpp:245`（字面量） | 否 |
| 插件 native | `GetPluginVersion()`（JASS/Lua 均可调） | `"1.0.0"` | `src/src/extensions/ex_natives/GameInfo.cpp:42`（字面量） | 否 |
| 引擎版本 | `GetGameVersion()` | `6374`（1.27a） | `src/src/extensions/ex_natives/GameInfo.cpp:33-36` | 否（War3 自己的版本） |
| 二进制身份 | `(Get-FileHash <已加载模块> -Algorithm SHA256).Hash` | 视构建而定 | 文件本身 | 间接（唯一能证明「跑的是哪份文件」） |

推论：**判断 SDK 版本只能看 `jass.d3d.version()`**。`GetPluginVersion()` 与 `jass.runtime.version` 是历史遗留的
硬编码字符串，同一份 `0.4.0` 和 `0.3.0-dev` 都会报 `"1.0.0"` / `"1.0.0.0"`，没有区分能力。
游戏内如何一步步确认，见 [docs/RELEASE.md](docs/RELEASE.md) 的「怎么确认你在跑哪个版本」。

## 附录 B：0.4.0 的构建命令（可复现）

~~~powershell
git worktree add --detach build\clean-d151fd7 d151fd7
cd build\clean-d151fd7\src
cmd /c ""D:\vs2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat" >nul && cmake -S . -B build-clean -G "Visual Studio 17 2022" -A Win32 && cmake --build build-clean --config Release"
~~~

不能直接用 `src\build.bat`：它第 3 行硬编码 `cd /d "<主工作区绝对路径>\src"`，在 detached worktree 里跑会去编译主工作区。
现在这条流程已脚本化为 `tools/release-sdk.ps1`（见 [docs/RELEASE.md](docs/RELEASE.md)）。
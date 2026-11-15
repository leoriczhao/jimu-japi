# 变更日志（CHANGELOG）

> 适用：War3 1.27a（`GetGameVersion()` = `6374`）+ `yd_japi.dll`（内嵌 Lua 5.4）+ `newD3d9.dll`（D3D9 proxy）。
> 版本号唯一来源：`src/src/lua_engine/lua_engine/libs_d3d.cpp:35` 的 `constexpr const char* kVersion`；
> 只有 **Lua 侧 `jass.d3d` 对外 API 变化**时才递增，工具链 / 文档 / 示例 / 脚手架改动一律不递增。
> 发布流程见 [docs/RELEASE.md](docs/RELEASE.md)；当前实现、验证强度与缺口以 [docs/STATUS.md](docs/STATUS.md) 为唯一权威。
> 最后更新：2026-11-16（记录 `0.4.0` 与之后的 `[Unreleased]` 改动）。

约定：

- 每条改动都带**验证状态**：`实机` = 真机跑过回归；`静态` = 只做了构建/静态合同校验；`未验证` = 只有代码或设计依据。
- 日期是**提交日期**（`git show -s --format=%ad --date=short`）或明确标出的实测日期，不是本文档的编辑日期。
- 发布产物必须可溯源到某个提交的 detached clean worktree 构建（做法见 [docs/RELEASE.md](docs/RELEASE.md) 步骤 1、6）。

---

## 版本线

| 版本 | 时间 | 锚点提交 | 状态 | 一句话 |
|---|---|---|---|---|
| `0.4.0` | 2026-11-15 | `d151fd7` | **已发布**（clean 构建可溯源） | D3D Lua SDK 记为「可用」，首个有发布产物的版本 |
| `0.3.0-dev` | 2026-11-14 → 2026-11-15 | `a9e1d21` 起 | 开发版，未发布 | P4 订阅、真实输入、P5 生命周期、VM 重置、54 handler 覆盖 |
| `0.2.0-dev` | 2026-08-03 起 | `50ebb0f` | 开发版，未发布 | 首版带 `kVersion`：版本化 ABI、typed 资源 SDK、MPQ 贴图 |
| （无版本号） | 2026-06-04 → 2026-08-03 | `7e3bac7` 起 | 早期 | 还没有 `jass.d3d` 与 `kVersion` |

> `-dev` 后缀表示「实现完成但未做发布级验收」，不承诺任何行为；`0.4.0` 是第一个去掉了 `-dev` 的版本。
> 版本号只在 **`kVersion` 字面量** 变化的提交里递增：`-S'kVersion = "'` 的完整结果是
> `50ebb0f`（`0.2.0-dev`）→ `a9e1d21`（`0.3.0-dev`）→ `d151fd7`（`0.4.0`），之后再没变过。

---

## [Unreleased]

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

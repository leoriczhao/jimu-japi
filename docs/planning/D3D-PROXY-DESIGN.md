# D3D9 Proxy 加载、注册、部署与视觉验收设计

> 本文是当前 D3D9 接入工作的实现契约。项目完成度仍只以
> [`../STATUS.md`](../STATUS.md) 为唯一权威状态；本文负责记录本阶段的架构、风险和验收方法。
>
> 阶段边界更新（2026-07-31）：本文只证明底层 proxy、bridge、部署和视觉探针链路可工作，
> 不定义或证明用户可用的 Lua SDK。`jass.d3d` 公共 API、对象所有权、GC/session、device reset、
> MPQ asset 和完整验收统一由 [D3D-LUA-SDK-DESIGN.md](D3D-LUA-SDK-DESIGN.md) 约束。
> 本文中的 120/120 是 2026-07-31 的历史累计结果；2026-08-03 当前结果为普通基线 108 项与
> D3D fixture 13 项合计 121/121。两者都不是 D3D API 数量，也不能作为 handler 全覆盖或
> Lua SDK 完成证据。

## 1. 目标与范围

本阶段交付一条可重复、可诊断、默认不覆盖第三方文件的 D3D9 链路：

1. Warcraft III 进程启动时加载本项目的 `d3d9.dll` 代理；
2. 代理加载系统真实 `d3d9.dll`，包装 `IDirect3D9` / `IDirect3DDevice9`，在 `EndScene` 绘制覆盖层；
3. 地图加载 `yd_japi.dll` 后，显式找到已加载的代理并注册 D3D bridge handler；
4. 部署工具按显式开关部署代理和视觉探针资源，并拒绝静默覆盖未知的 `d3d9.dll`；完整交付还必须
   支持所有权校验后的幂等卸载；
5. 自动测试验证注册和对象属性，真实 War3 窗口验证文字、字体、贴图及鼠标命中。

本阶段不把内置 JAPI 的 `DLL_initializeD3d9` ABI 原样复刻。内置实现是“后加载插件 + Present 地址注册”，当前项目已有代码则是“进程启动代理 + COM wrapper”；两者的加载时机和 ABI 不兼容，强行混合会得到一条不可验证的链路。

本阶段早期未承诺 `TextureAddEvent` / `TextureRemoveEvent`、MPQ 内 BLP 和 `rect` handle 裁剪；
其中 JASS code 事件回调已由 §9 完成，Hrect source rect 已由 §2.4/§8.5 完成。MPQ BLP 与用户级资源
生命周期仍属于后续 SDK 工作。

## 2. 已确认事实与当前缺口

### 2.1 运行环境事实

- 目标版本为 Warcraft III 1.27a、32 位进程。
- 当前 `Game.dll` 包含 `d3d9.dll` 和 `Direct3DCreate9` 字符串，并在运行时选择渲染后端；`War3.exe` 本身不静态导入 D3D。
- 当前游戏目录没有第三方 `d3d9.dll`，但有官方 `D3DX9_42.dll`。
- 因为 D3D9 是运行时加载，放在 `War3.exe` 同目录的代理必须在启动前就位；地图 MPQ 在游戏启动后才加载，不能承担第一次 D3D 截获。

### 2.2 实施前代码缺口（历史基线）

以下条目记录本阶段开始时的缺口，§8 记录其中已完成的部分，不代表当前状态：

- `newD3d9.dll` 当前 PE 只导出 `InitializeD3DAPI`，源码中的 `Direct3DCreate9` 没进入导出表。
- `yd_japi.dll` 当前没有定位代理，也没有调用 `InitializeD3DAPI`。
- 文字/贴图 handler 的字符串返回仍返回裸 `char*`，而 bridge 需要 JASS string id。
- 贴图加载只尝试 `d3dx9_43.dll` 和 `d3dx9_33.dll`，与目标目录现有的 `D3DX9_42.dll` 不匹配。
- 部署脚本只部署地图，不部署代理或可识别的视觉探针资源。
- 没有能区分“DLL 已加载、handler 已注册、设备已包装、帧已绘制”的状态证据。

### 2.3 2026-07-31 当前审计基线

- `src/src/d3d9/api.cpp` 注册 53 个唯一 handler。`map/tests/test_d3d.lua` 调用 29 个 RPC 名，
  其中 25 个属于这 53 个；`GetTextureEventCount`、`TextureAddEvent`、`TextureRemoveEvent` 来自
  message bridge，`SetHeroLevels` 是测试取址辅助。剩余 28 个 D3D handler 未被该 fixture 触达。
- `initialize_ex_natives()` 和 message bridge 先注册，`initialize_d3d_api()` 后注册；因此 D3D 的
  `ShowConsole(B)V` 会覆盖先前有效 handler，但 `renderer.cpp::show_console` 只是 stub。
  `test_ex.lua` 目前只检查 hide/restore 调用不崩溃，不能证明 UI 实际隐藏和恢复。
- D3D `SetKeyboard(IB)V` 把 WARK code 直接写入 `INPUT.ki.wVk`。Shift/Ctrl/Alt、方向键、F 键、
  OEM 和数字键盘等编码与 Win32 VK 不一致；`libs_message.cpp::wark_to_vk` 已提供可复用的正确映射依据。
- `SetTextureSrcRect` 当前注册为 `(IRRRR)V`，与内置 `(IHrect;)V` 不兼容；renderer 虽有
  `get_texture_src_rect`，但 bridge 未注册内置 `(I)Hrect;` 的 `GetTextureSrcRect`。
- state-block 保存/恢复修复已经解决单位“灵魂体”视觉污染并获实机确认，但 `renderer.cpp` 相对
  `f5ede8395ae39b5554ae0dfd78835029e01f9901` 仍是未提交修改。当前构建 DLL、已部署 DLL 和 sidecar
  hash 均为 `CA01703ACDB5C26251ED4D1A305910728D4844DA6408F4B0D781C07CFB6748AF`，只能证明它们
  彼此一致，不能证明产物可追溯到某个 commit。
- 当前工具已安装 proxy、视觉探针和两个所有权 sidecar，但尚无经过实机验收的完整卸载入口；
  Lua VM/地图 session 清理也尚未实现。因此当前结论只能是“底层 proxy/bridge 基本跑通”。

### 2.4 2026-08-03 P0 兼容修复现状

- 机器可读 `handler_manifest.json` 现有 54 个兼容名字：历史 53 个名字加恢复的
  `GetTextureSrcRect`。D3D proxy 注册 49 个，message/EX 的 canonical owner 注册 5 个；
  `verify_contract.ps1` 验证名字、签名、owner、D3D 禁止重名和 fixture 映射。
- D3D proxy 已移除 `GetMouseVectorX/Y`、`ShowConsole`、`ShowFpsText`、`SetKeyboard` 重名注册，
  不依赖覆盖语义。普通回归中的 `ShowConsole` 已验证控制台 frame 真实隐藏并恢复。
- `SetKeyboard` 由 message bridge 唯一注册，bridge 和 Lua message API 共用
  `warcraft3::input::wark_to_vk`；WARK 不再直接写入 Win32 `wVk`。
- `SetTextureSrcRect(IHrect;)V` 与 `GetTextureSrcRect(I)Hrect;` 已恢复。bridge 对 `Hrect;`
  使用 `SaveRectHandle` / `LoadRectHandle`，实机 fixture 对四个边界值完成往返。
- state-block 已扩展到完整 overlay pass，Capture 失败时跳过整个 pass；真实窗口中的单位、地形和 UI
  均无状态污染。实现已提交为 `8bba4ae`；从该提交的 detached clean worktree 构建、实际部署 DLL 与
  proxy sidecar hash 一致为 `CD3896606FE2F20861F34A1406457972F982D2A72ED8F4B9173606F4FCCF101C`。
- 普通回归为 108/108；D3D 单实例脚本回归为 121/121，其中 D3D fixture 13 项，兼容面触达
  27/54，仍有 27 个名字未被该 fixture 触达。
- 本批提交态产物溯源已闭环；安全幂等卸载与地图/Lua session 清理仍未实现，所以卸载闭环和用户 SDK
  生命周期仍未完成。

## 3. 选定架构

```text
进程启动
  War3/Game.dll -> LoadLibrary("d3d9.dll")
  -> 项目代理 Direct3DCreate9
  -> 绝对系统目录中的真实 d3d9.dll
  -> CDirect3D9::CreateDevice
  -> CDirect3DDevice9 -> EndScene 覆盖层

地图初始化
  callback -> yd_japi.dll!Initialize
  -> GetModuleHandle("d3d9.dll")
  -> 校验 InitializeD3DAPI 导出
  -> 传入 register_cpp_handler / jass::from_string / jass::create_string
  -> 注册 D3D bridge handler

地图测试
  Lua hashtable RPC -> UnitId("CreateFont" / "CreateText" / "CreateTexture" ...)
  -> D3D 对象状态往返
  -> EndScene 显示视觉探针
```

### 3.1 Proxy 导出与真实 DLL 加载

- 使用 `.def` 文件稳定导出未修饰名 `Direct3DCreate9` 和 `InitializeD3DAPI`，不依赖编译器名字修饰。
- `newD3d9.dll` 是构建产物名；部署时复制为游戏目录的 `d3d9.dll`。
- 真实 DLL 只从 Windows system directory 的绝对路径加载。删除“失败后再次 `LoadLibrary("d3d9.dll")`”的递归风险。
- Proxy 不再链接 `d3d9.lib`；全部真实入口都经 `GetProcAddress` 取得。

### 3.2 Handler 注册

`yd_japi.dll!Initialize` 在 EX handler 注册完成、`flush_add_only` 之前执行 D3D 注册：

1. `GetModuleHandleA("d3d9.dll")`；
2. `GetProcAddress("InitializeD3DAPI")`；
3. 调用初始化导出并传入 bridge 注册、JASS 字符串读取和创建函数；
4. 把成功或具体失败原因写入现有同步日志；
5. D3D 不可用时继续初始化非 D3D 功能，避免代理缺失拖垮普通地图。

初始化必须幂等。重复调用不得重复注册或清空已有渲染对象。

### 3.3 可诊断状态

新增只读 bridge handler `GetD3DStatus() -> integer`，返回位掩码：

| 位 | 值 | 含义 |
|---|---:|---|
| 0 | `0x01` | proxy DLL 已进入进程 |
| 1 | `0x02` | bridge API 已注册 |
| 2 | `0x04` | 系统真实 `d3d9.dll` 已加载 |
| 3 | `0x08` | `IDirect3D9` wrapper 已创建 |
| 4 | `0x10` | 游戏 D3D9 device 已包装 |
| 5 | `0x20` | 至少执行过一帧覆盖层绘制 |
| 6 | `0x40` | 至少成功加载过一张贴图 |

自动测试要求加载/注册/设备/帧位出现；贴图视觉测试还要求 `0x40`。

### 3.4 坐标与视觉探针

- 当前 renderer 使用 War3 client-area 像素坐标，原点为左上角。
- 测试文字固定在 `(72, 72)`，使用大号、加粗、黄色字体，内容包含 `JAPI D3D VISUAL PASS`。
- 测试贴图固定在文字下方，使用部署工具生成的高对比度棋盘 BMP，文件名为 `japi_d3d_visual_probe.bmp`。
- 鼠标进入贴图区域时，Lua 轮询 `GetMouseInTexture` 并把文字改为绿色 `HOVER PASS`；离开时恢复黄色。这样同时验证窗口坐标、鼠标坐标和贴图边界。
- 视觉对象只在 `-InteractiveD3D` 测试图中创建，普通回归不产生覆盖层。

## 4. 部署设计

### 4.1 开关和产物

`tools/deploy.ps1` 增加 `-InteractiveD3D`：

- 向 `pack.ps1` 传递同名开关，在 bundled Lua 前写入 `_G.__JAPI_TEST_INTERACTIVE_D3D = true`；
- 验证 `newD3d9.dll` 为 32 位且存在必要导出；
- 将其部署为 `$War3Dir\d3d9.dll`；
- 生成并部署 `$War3Dir\japi_d3d_visual_probe.bmp`；
- 默认把交互超时扩为一小时；是否保留进程仍由现有 `-NoKill` 控制。

### 4.2 覆盖保护

- 目标 `d3d9.dll` 不存在：允许部署。
- 目标存在且 SHA-256 与当前构建产物相同：允许刷新。
- 目标存在且不同，但 sidecar 记录的上次部署 hash 与目标当前 hash 相同：认定为本项目旧版本，允许升级并原子更新 sidecar。
- 目标存在且不同、又没有可信 sidecar：立即失败，打印源/目标 hash；不得自动改名、覆盖或删除。
- 视觉探针使用项目专属文件名；若目标存在且内容不同，同样失败。
- 非 D3D 部署不碰游戏目录中的 proxy；卸载采用单独、显式、只删除已知 hash 的动作，避免误删其他 wrapper。
- 完整卸载对象包括 `d3d9.dll`、`japi_d3d_visual_probe.bmp`、`.japi_d3d_proxy.sha256` 和
  `.japi_d3d_probe.sha256`。目标缺失时视为幂等成功；目标 hash 与 sidecar 不一致时拒绝删除。
- War3 仍加载 proxy 时不得替换或删除；结束会话后卸载，再验证普通非 D3D 启动和目录无项目 D3D 残留。

## 5. 验证矩阵

| 层级 | 检查 | 成功条件 |
|---|---|---|
| 构建 | Win32 Release 编译 | `yd_japi.dll`、`newD3d9.dll` 均生成 |
| PE 契约 | `objdump -p newD3d9.dll` | 未修饰导出含 `Direct3DCreate9`、`InitializeD3DAPI`；不导入 `d3d9.dll` |
| 部署 | hash 与目标路径 | 游戏目录 proxy/探针与源一致，无未知文件被覆盖 |
| 进程加载 | 模块列表或进程内状态 | 可读时确认游戏目录 proxy 和系统真实 DLL；提权边界不可读时以状态位、API 往返和真实渲染共同确认 |
| 注册 | 同步日志 + `GetD3DStatus` | `InitializeD3DAPI` 成功；状态含 `0x3F` |
| 自动 API | Lua RPC | 字体、文字、贴图属性往返和像素尺寸通过；普通 108 项无回归 |
| 视觉 | 真实 War3 窗口截图 | 黄色标题和棋盘贴图清晰可见、位置正确、无黑屏/闪退 |
| 交互 | 真实鼠标进入/离开贴图 | 标题在 `VISUAL PASS` / `HOVER PASS` 间切换，命中仅在边界内为真 |
| Handler 覆盖 | 机器可读 manifest + 测试映射 | 54 个兼容名字均有唯一 owner 和准确签名；累计测试数、fixture 数和 27/54 触达数分开报告 |
| 兼容 | ShowConsole/SetKeyboard/SrcRect 专项 | 不覆盖 canonical handler；WARK→VK 全键组正确；SrcRect JASS 签名与 getter/setter 往返 |
| 渲染隔离 | state-block 故障注入 + 实机窗口 | 捕获/恢复成功且无状态污染；捕获失败则跳过 overlay |
| 产物溯源 | commit/provenance/hash | dirty=false；干净构建、部署 DLL、sidecar hash 一致 |
| 卸载 | 安装→验证→会话结束→卸载→普通启动 | 只删除本项目已知文件，重复卸载幂等，未知文件不删除，无项目 D3D 残留 |

## 6. 实施顺序

1. 修复 PE 导出和系统 `d3d9.dll` 绝对路径转发；
2. 增加状态位和 renderer 的 D3DX9_42 / 命中检测；
3. 扩展 `InitializeD3DAPI` 字符串 ABI并在 `yd_japi` 初始化阶段注册；
4. 实现 `pack.ps1` / `deploy.ps1` 的显式 D3D 开关和覆盖保护；
5. 增加 `tests.test_d3d` 夹具；
6. 构建、PE 静态检查、普通回归；
7. 实机启动、进程加载证据、视觉捕获和鼠标交互验收；
8. 把实际证据回写到本文附录和 `docs/STATUS.md`。

## 7. 完成定义

本阶段只有在以下条件同时满足时才可把“D3D proxy 加载/注册/部署/视觉探针基础设施”标为完整闭环；
当前只达到“底层 proxy/bridge 基本跑通”。即使以下全部满足，也不能把“D3D Lua SDK”标为完成：

1. Proxy 的两项必要导出和真实 DLL 转发经 PE 检查；
2. 未安装 proxy 时普通非 D3D 功能仍可工作，D3D 注册失败只记日志；
3. `-InteractiveD3D` 能安全部署并启动测试图；
4. 自动 D3D 状态和属性测试全绿，普通回归不下降；
5. 真实窗口中字体/文字/贴图可见，鼠标进入和离开命中区产生预期变化；
6. 54-name handler manifest 清楚区分 owner 与已测/未测状态，不把累计测试总数当覆盖率；
7. `ShowConsole`、`SetKeyboard` 和 SrcRect 的兼容阻断项通过专项测试；
8. state-block 修复已提交，干净构建产物可追溯到 commit，部署 DLL/sidecar hash 一致；
9. proxy、探针和 sidecar 完成安全幂等卸载，并验证卸载后普通启动；
10. 文档记录真实命令、结果、视觉捕获证据和仍未覆盖的 API。

## 8. 实测记录

验证日期：2026-07-31；目标环境：Warcraft III 1.27a，32 位 D3D9。

### 8.1 构建与 PE 契约

- `src\build.bat` 成功生成 `yd_japi.dll` 和 `newD3d9.dll`；仅保留既有 C4819 编码警告，无编译或链接错误。
- `objdump -p src\build\bin\Release\newD3d9.dll` 确认导出未修饰名 `Direct3DCreate9`、`InitializeD3DAPI`，导入表不含 `d3d9.dll`。
- 本次 proxy SHA-256 为 `628C1B752108505E698669C20461C395B3413036F35FA550DF12F12708F53EC7`。
- PowerShell 脚本语法、Lua 测试文件语法和 `git diff --check` 均通过；`pack.ps1 -InteractiveD3D` 打包 5 个 Lua 文件，0 error、0 warning。

随后为修复 D3D state 泄漏重新构建并部署了
`CA01703ACDB5C26251ED4D1A305910728D4844DA6408F4B0D781C07CFB6748AF`。该 hash 与当前
`src\build\bin\Release\newD3d9.dll`、游戏目录 `d3d9.dll` 和 proxy sidecar 一致，实机视觉恢复正常；
但对应 `renderer.cpp` 修改尚未提交，所以这是一条“脏工作区构建已实机验证”的证据，不是发布 provenance。

### 8.2 回归与实机结果

未启用 D3D 代理的普通回归：

```powershell
.\tools\deploy.ps1 -BaseMap .\reference\base.w3m
```

结果为 `108 passed, 0 failed, 108 total`。这证明代理缺失时，`yd_japi` 的可选 D3D 注册失败不会破坏非 D3D 功能。

真实 D3D 回归：

```powershell
.\tools\deploy.ps1 -BaseMap .\reference\base.w3m -InteractiveD3D -NoKill
```

部署工具将构建产物复制为游戏目录 `d3d9.dll`，并生成 128x128 高对比视觉探针；探针 SHA-256 为
`952B23437A15F2C65AA9C114920533E63D278D1765B70DA0EC5E709D153EAE6B`。proxy 和探针均由 sidecar hash 标识所有权，未覆盖未知文件。

套件结果为 `115 passed, 0 failed, 115 total`，包括：

- proxy 加载、bridge 注册、真实系统 D3D、`IDirect3D9` wrapper、device wrapper 和帧渲染状态；
- 字体属性与字符串返回 ABI；
- 文字内容、颜色和属性往返；
- 贴图尺寸、像素尺寸、加载状态和 trigger 开关；
- 真实鼠标进入和离开贴图区域。

### 8.3 视觉与交互证据

真实 War3 窗口首先显示黄色 `JAPI D3D VISUAL PASS - move cursor into checkerboard` 和棋盘贴图；
鼠标移入棋盘后标题变为绿色 `JAPI D3D HOVER PASS - now move cursor outside`；移出后显示绿色
`JAPI D3D VISUAL + HOVER PASS`。同一画面中的测试汇总为 `ALL TESTS PASSED 115/115`，无黑屏或闪退。

目标 War3 进程以提权级别运行，非提权部署进程读取其模块列表得到空结果，因此未把模块枚举当作成功证据。
进程内 `GetD3DStatus` 最终覆盖全部位（`0x7F`），再结合 D3D API 往返、真实贴图渲染和鼠标命中，
完成了 proxy、系统 DLL、wrapper、device 与 EndScene 链路的端到端确认。

### 8.4 保留项

本阶段已实测的是 proxy 加载、注册、部署、字体/文字/贴图和真实命中子链。以下项目仍按范围约定保留：

- `TextureAddEvent` / `TextureRemoveEvent` 的 JASS code 回调兼容（原阶段保留，键盘路径后由 §9 完成）；
- MPQ 内 BLP 资源解码；
- `rect` handle 形式的贴图裁剪。

### 8.5 2026-08-03 P0 修复实测

当前修复使用仓库默认空白地图执行：

```powershell
.\src\build.bat
.\src\src\d3d9\verify_contract.ps1
.\tools\deploy.ps1
.\tools\deploy.ps1 -InteractiveD3D
```

- Win32 Release 构建无编译或链接错误；contract 验证结果为
  `surface=54, proxy=49, canonical=5, fixture=27/54, untested=27`。
- 普通实机结果为 `108 passed, 0 failed, 108 total`；`ShowConsole` 的隐藏/恢复真实 frame 断言通过。
- D3D 贴图 source rect 使用内置 Hrect ABI 完成 setter/getter 四边界往返。
- 单一 War3 实例依次显示 `VISUAL PASS`、`HOVER PASS`、`EVENT PASS` 和
  `VISUAL + HOVER + EVENT PASS`；最终脚本读取到 `121 passed, 0 failed, 121 total` 并自动终止 War3。
- 修复提交为 `8bba4ae`。由于 `src\build.bat` 当前硬编码主工作区路径，detached worktree 验收改用
  相同的 VS2022 Win32/CMake 参数直接配置构建；该干净构建无编译或链接错误。
- detached clean worktree 的 `newD3d9.dll`、游戏目录 `d3d9.dll` 和
  `.japi_d3d_proxy.sha256` 均为 `CD3896606FE2F20861F34A1406457972F982D2A72ED8F4B9173606F4FCCF101C`；
  视觉探针和 sidecar 均为 `952B23437A15F2C65AA9C114920533E63D278D1765B70DA0EC5E709D153EAE6B`。
- 普通 108/108 与 D3D 121/121 均使用该 clean worktree 的 `yd_japi.dll`；D3D 实机实际加载同一
  clean worktree 的 proxy，脚本读取结果并自动终止 War3。

这条记录完成本批 proxy 的提交态源码、干净构建、部署物和 sidecar provenance。主工作区仍保留用户的
非 D3D 修改，但不参与 detached `8bba4ae` 构建。

## 9. 后续扩展：TextureAddEvent / TextureRemoveEvent

同日继续实现并验证了键盘型贴图事件回调，原 §1 和 §8.4 中的事件回调保留项由本节更新；
项目当前完成度仍以 `docs/STATUS.md` 为准。

实现契约：

- 新增真实 custom native `SetHeroLevels(C)V`，把 JASS code 值写入 bridge hashtable 槽 0，兼容原版 `GetFuncAddr(code)` wrapper。
- `TextureAddEvent(IIII)I` 为每个事件保留独立的按下/弹起 JASS timer，避免快速按下/弹起互相覆盖回调。
- 输入过滤器通过 bridge 内部 direct-handler 调用代理的 `GetMouseInTexture`，事件命中与真实 renderer 的 visible、trigger 和边界状态一致。
- 回调启动前，以 `GetExpiredTimer()` 的 handle id 为父键写入 `0xFF=texture`、`0x100=key`、`0x101=action`、`0xFE=event`。
- `TextureRemoveEvent(II)V` 销毁两个 timer、释放 handle 引用并删除注册；`GetTextureEventCount()` 仅作为测试诊断入口。

实测仍使用：

```powershell
.\tools\deploy.ps1 -BaseMap .\reference\base.w3m -InteractiveD3D -NoKill
```

真实鼠标进入棋盘后按下并弹起 Shift（War3 1.27a 的 `WARK_SHIFT=0`），两个 JASS code 回调均执行，
四个上下文槽全部匹配，回调内移除事件后注册数恢复，随后鼠标移出完成最终视觉验收。
普通回归保持 `108/108`；D3D 套件为 `120 passed, 0 failed, 120 total`，最终窗口显示
`JAPI D3D VISUAL + HOVER + EVENT PASS` 和 `ALL TESTS PASSED 120/120`。

这里的 120 是累计总数：108 个普通基线测试 + 12 个 D3D fixture 检查。该 fixture 只触达
53 个 D3D handler 中的 25 个。真实 Shift 行为来自物理键盘输入和 message hook，不能证明 D3D
`SetKeyboard` 的 WARK→VK 注入实现正确。

尚未覆盖的是鼠标按钮码以及原版注释提到的鼠标进入/离开回调语义；MPQ BLP 和 `rect` handle
裁剪也仍为后续项。

## 10. 当前 D3D 修复与验收顺序

该顺序属于 D3D 会话；构建、打包、测试统计和部署门禁框架由基础工作树负责，不在本文扩张实现范围：

1. **已完成**：建立 54-name manifest，固化 27/54 触达与 27 个未触达名字；
2. **已完成**：D3D 不再注册 5 个 canonical 重名，不依赖覆盖语义；
3. **已完成实现并通过构建**：提取共用 WARK→VK 转换，覆盖全部已定义键组；
4. **已完成并实机通过**：恢复 SrcRect 的 `(IHrect;)V` setter 和 `(I)Hrect;` getter；
5. **已完成并实机通过**：state-block 与兼容修复提交为 `8bba4ae`，从 detached clean worktree
   构建、重新部署并回读一致 hash；
6. **已完成**：proxy、探针和 sidecar 的安全幂等卸载、未知文件保护，以及卸载后普通非 D3D 启动；
7. **已完成 P1/P2**：版本化 session/generation ABI 与 `jass.d3d` Font/Text/Texture 基础 userdata；
8. **后续主线**：进入 [D3D-LUA-SDK-DESIGN.md](D3D-LUA-SDK-DESIGN.md) 的 P3-P6：统一 render queue、
   MPQ asset、Subscription、自动 session、device reset、完整 GC/失败路径和文档验收。

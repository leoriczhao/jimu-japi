# D3D9 Proxy 加载、注册、部署与视觉验收设计

> 本文是当前 D3D9 接入工作的实现契约。项目完成度仍只以
> [`../STATUS.md`](../STATUS.md) 为唯一权威状态；本文负责记录本阶段的架构、风险和验收方法。

## 1. 目标与范围

本阶段交付一条可重复、可诊断、默认不覆盖第三方文件的 D3D9 链路：

1. Warcraft III 进程启动时加载本项目的 `d3d9.dll` 代理；
2. 代理加载系统真实 `d3d9.dll`，包装 `IDirect3D9` / `IDirect3DDevice9`，在 `EndScene` 绘制覆盖层；
3. 地图加载 `yd_japi.dll` 后，显式找到已加载的代理并注册 D3D bridge handler；
4. 部署工具按显式开关部署代理和视觉探针资源，并拒绝静默覆盖未知的 `d3d9.dll`；
5. 自动测试验证注册和对象属性，真实 War3 窗口验证文字、字体、贴图及鼠标命中。

本阶段不把内置 JAPI 的 `DLL_initializeD3d9` ABI 原样复刻。内置实现是“后加载插件 + Present 地址注册”，当前项目已有代码则是“进程启动代理 + COM wrapper”；两者的加载时机和 ABI 不兼容，强行混合会得到一条不可验证的链路。

本阶段也不承诺 `TextureAddEvent` / `TextureRemoveEvent` 的 JASS code 回调兼容层、MPQ 内 BLP 解码和 `rect` handle 裁剪。这些保留为后续 D3D API 对齐工作；当前交付的真实交互边界是 `GetMouseInTexture` 命中测试和 `SetTextureTrigger` 开关。

## 2. 已确认事实与当前缺口

### 2.1 运行环境事实

- 目标版本为 Warcraft III 1.27a、32 位进程。
- 当前 `Game.dll` 包含 `d3d9.dll` 和 `Direct3DCreate9` 字符串，并在运行时选择渲染后端；`War3.exe` 本身不静态导入 D3D。
- 当前游戏目录没有第三方 `d3d9.dll`，但有官方 `D3DX9_42.dll`。
- 因为 D3D9 是运行时加载，放在 `War3.exe` 同目录的代理必须在启动前就位；地图 MPQ 在游戏启动后才加载，不能承担第一次 D3D 截获。

### 2.2 代码缺口

- `newD3d9.dll` 当前 PE 只导出 `InitializeD3DAPI`，源码中的 `Direct3DCreate9` 没进入导出表。
- `yd_japi.dll` 当前没有定位代理，也没有调用 `InitializeD3DAPI`。
- 文字/贴图 handler 的字符串返回仍返回裸 `char*`，而 bridge 需要 JASS string id。
- 贴图加载只尝试 `d3dx9_43.dll` 和 `d3dx9_33.dll`，与目标目录现有的 `D3DX9_42.dll` 不匹配。
- 部署脚本只部署地图，不部署代理或可识别的视觉探针资源。
- 没有能区分“DLL 已加载、handler 已注册、设备已包装、帧已绘制”的状态证据。

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

本阶段只有在以下条件同时满足时才可把“D3D proxy 加载/注册/部署/视觉验收”标为完成：

1. Proxy 的两项必要导出和真实 DLL 转发经 PE 检查；
2. 未安装 proxy 时普通非 D3D 功能仍可工作，D3D 注册失败只记日志；
3. `-InteractiveD3D` 能安全部署并启动测试图；
4. 自动 D3D 状态和属性测试全绿，普通回归不下降；
5. 真实窗口中字体/文字/贴图可见，鼠标进入和离开命中区产生预期变化；
6. 文档记录真实命令、结果、视觉捕获证据和仍未覆盖的 API。

## 8. 实测记录

验证日期：2026-07-31；目标环境：Warcraft III 1.27a，32 位 D3D9。

### 8.1 构建与 PE 契约

- `src\build.bat` 成功生成 `yd_japi.dll` 和 `newD3d9.dll`；仅保留既有 C4819 编码警告，无编译或链接错误。
- `objdump -p src\build\bin\Release\newD3d9.dll` 确认导出未修饰名 `Direct3DCreate9`、`InitializeD3DAPI`，导入表不含 `d3d9.dll`。
- 本次 proxy SHA-256 为 `628C1B752108505E698669C20461C395B3413036F35FA550DF12F12708F53EC7`。
- PowerShell 脚本语法、Lua 测试文件语法和 `git diff --check` 均通过；`pack.ps1 -InteractiveD3D` 打包 5 个 Lua 文件，0 error、0 warning。

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

本阶段完成的是 proxy 加载、注册、部署、字体/文字/贴图和真实命中链。以下项目仍按范围约定保留：

- `TextureAddEvent` / `TextureRemoveEvent` 的 JASS code 回调兼容；
- MPQ 内 BLP 资源解码；
- `rect` handle 形式的贴图裁剪。

# SDK 发行流程（RELEASE）

> 本文档描述如何把一个提交（commit）变成一份可交付的 SDK 发行包：钉版本 → 干净 worktree 构建 → 产物收集 → 实机回归 → SHA-256 回读 → 文档锚定 → 打包 → 常见坑。
>
> - 最后更新：**2026-11-16**
> - 相关文档：`CHANGELOG.md`（版本历史与版本号口径）、`docs/STATUS.md` §4（实机验证现状，**唯一权威**）、`docs/planning/D3D-LUA-SDK-DESIGN.md` §14.4（0.4.0 = `d151fd7` 的提交态产物溯源）、`docs/guide/SDK-GUIDE.md`（使用者视角）
> - 版本定义见第 0 节；每节标注 **脚本化 / 手动** 与 **验证状态**。本文只写已经跑过、或明确标注「未验证」的东西。

---

## 0. 先搞清楚「版本号」是哪个

SDK 版本号只有一个来源：**`jass.d3d` 的 `kVersion` 常量**。

| 版本号 | 来源（文件:行） | 当前值 | 是否代表 SDK 版本 |
|---|---|---|---|
| Lua SDK 版本 | `src/src/lua_engine/lua_engine/libs_d3d.cpp:35` `constexpr const char* kVersion = "0.4.0";` | `0.4.0` | **是**（唯一来源） |
| Lua 侧读取 | `require("jass.d3d").version()`（`libs_d3d.cpp:1984` 推栈） | `"0.4.0"` | 是（同源） |
| ABI 版本 | `require("jass.d3d").abi_version()` | `1` | 否（接口二进制代数） |
| 运行时版本 | `src/src/lua_engine/lua_engine/libs_runtime.cpp:245` 硬编码 `"1.0.0.0"` | `1.0.0.0` | 否（历史遗留，未与 SDK 联动） |
| 插件版本 native | `src/src/extensions/ex_natives/GameInfo.cpp:42` 硬编码 `"1.0.0"` | `1.0.0` | 否（历史遗留，未与 SDK 联动） |
| 发行包版本 | `tools/release-sdk.ps1` 从 `kVersion` 解析 | 同 `kVersion` | 是 |

**bump 规则**：只有当 **Lua 侧 D3D API 发生不兼容/新增变化**时才改 `kVersion`。纯工具链、示例、文档、脚手架改动 **不 bump**，记在 `CHANGELOG.md` 的 `[Unreleased]` 下。

> 2026-11-16 这一轮（`release-sdk.ps1` + `CHANGELOG.md` + `docs/RELEASE.md` + `examples/`）就是这种情况：`kVersion` 仍是 `0.4.0`，本轮的改动全部落在 `[Unreleased]`。这也是为什么 `d151fd7..HEAD` 之间的提交会让 `yd_japi.dll` 的 SHA-256 变化，却 **不** 让 SDK 版本变化 —— 变的是 JASS 通道（`GetFuncAddr`、JASS wrapper 生成等），不是 `jass.d3d` API。

---

## 1. 前置条件

| 项 | 要求 | 检查命令 | 说明 |
|---|---|---|---|
| WAR3 1.27a | 游戏目录存在且含 `war3.exe` | `Test-Path "D:\Warcraft III Frozen Throne 1.27a publish\war3.exe"` | `tools/deploy.ps1:39` 硬编码该路径；`tools/deploy.ps1` **不读** `tools/config.local.ps1`（只有 `tools/d3d-proxy.ps1:23-31` 读） |
| VS 2019/2022 + C++ 工具链 | `vcvars32.bat` 可调用 | `Test-Path "D:\vs2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat"` | 必须 32 位（`-A Win32`），WAR3 1.27a 是 32 位进程 |
| CMake | ≥ 3.15（`src/CMakeLists.txt` 要求） | `cmake --version` | 本机实测 `cmake version 4.0.0` |
| git | 支持 `worktree add --detach` | `git --version` | 本机实测 `git version 2.49.0.windows.1` |
| PowerShell | 5.1（Windows 自带） | `$PSVersionTable.PSVersion` | 本机实测 `5.1.26100`；`tools/release-sdk.ps1` 只用 5.1 语法 |
| **32 位** `objdump.exe` | 在 `PATH` 中且能识别 PE32 | `(Get-Command objdump.exe).Source` | 只在「部署/校验 D3D 代理」时需要，**构建不需要**。本机 `PATH` 里只有 MinGW **64 位**版，验不过 `pei-i386` 检查 |
| `D3DX9_42.dll` | 游戏目录或 `SysWOW64`/`System32` 有 | `Test-Path "$env:WINDIR\SysWOW64\D3DX9_42.dll"` | 只在「跑 D3D 实机回归」时需要（`deploy.ps1:176-187` 按 游戏目录 → SysWOW64 → System32 顺序解析），构建不需要 |
| 磁盘 | 1–2 GB 空闲 | `Get-PSDrive C` | `build\clean-*` 一次约 200 MB；脚本默认用完即删 |

---

## 2. 步骤 0：钉住提交与版本 —— 先确认你在哪儿

> **脚本化**：`tools/release-sdk.ps1` 自动完成（步骤 0 内部）。

发行包的字节 = 源码 + 工具链。要复现文档里的 SHA-256，**必须**从干净 worktree 的确定提交构建。

```powershell
cd C:\Users\leoric\Desktop\code\map-inject      # 主工作区或任意 worktree 均可
git rev-parse HEAD                              # 记录 40 位 commit
git log -1 --format=%cI                         # 记录提交时间（ISO 8601）
git status --porcelain                          # 必须为空，否则产物不可溯源
git show <commit>:src/src/lua_engine/lua_engine/libs_d3d.cpp | Select-String 'kVersion'
```

判据：

| 检查 | 通过标准 | 不通过怎么办 |
|---|---|---|
| `git rev-parse HEAD` | 等于你要发版的那个 commit | 先 `git fetch`/切到目标提交 |
| `git status --porcelain` | **输出为空** | 有未提交改动就不能当发行基线；先提交或 `git stash`（本仓库约定：不替别人 stash） |
| `kVersion` | 与你打算写在 `CHANGELOG.md` 里的版本一致 | 改 `libs_d3d.cpp:35` 后再走一遍（改版本会改变 `yd_japi.dll` 字节，hash 必须重算） |

> 示例（本仓库 2026-11-16 的现状）：`kVersion` 仍是 `0.4.0`，因为最后一个改动 `src/` 的提交就是 `498a308` —— 它之后的提交全落在 `tools\`、`examples\`、`docs\`，DLL 与 Lua 引擎源码没动，三者不矛盾：发的是「0.4.0 SDK 之上的工具链/文档更新」，所以 `Unreleased` 不空、版本号不动，产物 hash 也不变。

---

## 3. 步骤 1：干净 worktree + 构建（为什么不能直接用 `src\build.bat`）

> **脚本化**：`tools/release-sdk.ps1`（不加 `-NoBuild` 时）内部执行第 2、3 步；手工复现按本节命令。

### 3.1 为什么 `src\build.bat` 不能当发行构建命令

`src/build.bat` 第 3 行是：

```bat
cd /d "C:\Users\leoric\Desktop\code\map-inject\src"
```

它 **写死了主工作区的绝对路径**。在 `build\clean-<sha7>` 这种 detached worktree 里调用它，实际编译的是**主工作区**的源码和主工作区的 `build/` 目录 —— 产物与「干净提交」没有对应关系，溯源就断了。同一原因记录在 `docs/STATUS.md` §4 与 `docs/planning/D3D-LUA-SDK-DESIGN.md` §14.4。

所以发行构建必须用「等价但路径无关」的命令：`vcvars32 + cmake -S <clean>\src -B <clean>\src\build-clean`。

### 3.2 手工命令（已验证的口径，与 §14.4 一致）

```powershell
# 1) 从目标提交拉一个 detached 干净 worktree（不要复用主工作区）
git worktree add --detach build\clean-<sha7> <commit>

# 2) 确认它就是目标提交，且工作区干净
git -C build\clean-<sha7> rev-parse HEAD
git -C build\clean-<sha7> status --porcelain      # 必须为空

# 3) 32 位环境 + VS 生成器 + Release 配置
cmd /c ""D:\vs2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat" >nul ^
  && cd /d build\clean-<sha7>\src ^
  && cmake -S . -B build-clean -G "Visual Studio 17 2022" -A Win32 ^
  && cmake --build build-clean --config Release"
```

生成器 / 架构 / 配置这三个值与 `src/CMakeLists.txt`、`src/build.bat` 一致，**不能改**：

| 参数 | 值 | 依据 |
|---|---|---|
| 生成器 | `Visual Studio 17 2022` | `src/build.bat` 第 6 行 `cmake .. -G "Visual Studio 17 2022" -A Win32` |
| 架构 | `Win32` | 同上；WAR3 1.27a 是 32 位 |
| 配置 | `Release` | `src/build.bat` 第 8 行 `cmake --build . --config Release` |
| 产物目录 | `<build 目录>\bin\Release\` | `src/CMakeLists.txt:140/195/211` `RUNTIME_OUTPUT_DIRECTORY "$BIN/bin"` + 多配置生成器追加配置名子目录 |

> 注意：`Release` 配置里也定义了 `JAPI_DEBUG`（`src/CMakeLists.txt:132`），所以 Release 产物同样会写 `C:\ProgramData\japi_debug.txt`。**日志有内容不能证明你跑的是 Debug 版**。

### 3.3 收尾

```powershell
git worktree remove --force build\clean-<sha7>
```

`build\clean-*` 一次约 200 MB；`tools/release-sdk.ps1` 默认在打包结束后自动删除（加 `-Keep` 保留现场）。

**验证状态**：命令串逐字对照 `src/build.bat`、`src/CMakeLists.txt`、`docs/STATUS.md` §4 与 `D3D-LUA-SDK-DESIGN.md` §14.4 —— **已核对**；本轮（2026-11-16）**没有**跑完整构建（约 10 分钟，由 lead 复用既有预构建产物），因此「脚本的自动构建分支」为 **未验证**，只有 `-NoBuild` 分支端到端跑过。

---

## 4. 步骤 2：产物清单

一次构建产出 3 个文件（全部落在 `<build>\bin\Release\`）：

| 文件名 | 目标 | 用途 | 大小（0.4.0 干净构建） |
|---|---|---|---|
| `yd_japi.dll` | `add_library(yd_japi SHARED)`（`CMakeLists.txt:105`） | 注入游戏进程的主 DLL：Lua 5.4 + `jass.*` 模块 + bridge handler | 544768 B |
| `newD3d9.dll` | `add_library(newD3d9 SHARED)`（`:171`） | `d3d9.dll` 代理 sidecar（D3D SDK 的呈现/输入通道） | 90112 B |
| `d3d_sdk_contract_test.exe` | `add_executable`（`:203`） | D3D SDK ABI/契约自检，**不需要游戏**即可跑 | 23040 B |

`d3d_sdk_contract_test.exe` 通过 `add_dependencies`（`:209`）依赖 `newD3d9`，所以要在 `newD3d9.dll` 旁边跑：

```powershell
cd build\clean-<sha7>\src\build-clean\bin\Release
.\d3d_sdk_contract_test.exe
# 期望：D3D SDK contract PASS: ABI v1, sessions, generation handles, dependencies,
#       alpha/z/assets/input capabilities, failure counters, stress=1000
```

---

## 5. 步骤 3：实机回归（5 组 + 2 项静态检查）

> **手动**（必须；lead 单点执行，一次只允许一个 war3 进程）。**这些数字来自 `docs/STATUS.md` 头部表与 2026-11-16 lead 的复跑记录，不是本文档作者跑的。**

### 5.0 两个必须先知道的事实

1. **`tools/deploy.ps1` 不会因为测试失败而报错。** 它只在 `pack.ps1` 失败时 `throw`（`tools/deploy.ps1:163`）。测试挂了，脚本依然"成功"退出。**必须人工读日志里的 `Results:` 行**。
2. 日志有两条：

| 日志 | 何时用 | 格式标记 |
|---|---|---|
| `C:\ProgramData\japi_debug.txt` | 默认（`src/src/debug_log.h:144`） | 结尾一行 ` Results: N passed, M failed, T total`（`map/tests/test_suite.lua:895`，**行首有一个空格**） |
| `C:\ProgramData\japi_debug_<pid>.txt` | 主日志被旧实例锁住时（`debug_log.h:153`；`deploy.ps1:196-208` 会打印 NOTE 并回退到它） | 同上 |

读结果：

```powershell
Get-Content C:\ProgramData\japi_debug.txt -Tail 5 | Select-String 'Results:'
```

### 5.1 五组回归

| # | 组名 | 命令 | 期望 `Results:` | 记录日期 |
|---|---|---|---|---|
| 1 | 默认实机回归 | `.\tools\deploy.ps1` | `122 passed, 0 failed, 122 total` | 2026-11-15 |
| 2 | JASS wrapper 回归 | `.\tools\deploy.ps1 -WithJassWrappers` | `125 passed, 0 failed, 125 total` | 2026-11-15 |
| 3 | GetFuncAddr 回归 | `.\tools\deploy.ps1 -WithGetFuncAddr` | `126 passed, 0 failed, 126 total` | 2026-11-16 |
| 4 | 地图级 VM 重启回归 | `.\tools\deploy.ps1 -TestReboot` | `9 passed, 0 failed, 9 total` | 2026-11-15 |
| 5 | 交互 D3D 回归 | 见 5.4 | `170 passed, 0 failed, 170 total` | 2026-11-16 |

补充说明：

- 组 2/3 是 **增量开关**：默认打包时对应小节打印 `[SKIP]`（`STATUS.md` §4 第 8c/8d 节），所以默认是 122，加了开关才 125/126。
- 组 5 的 **170 = 122（基础套件）+ 48（D3D 用例）**。`docs/STATUS.md` 里的 `164` 是旧口径 `116 + 48`（基础套件后来涨到 122）。两者不是矛盾，是分母不同 —— 引用时务必写清口径。
- 每组之间 **必须** 等 war3 完全退出（单实例锁）；详见第 9 节坑表。

### 5.2 跑之前：先确认产物就是你要发的那份

`tools/deploy.ps1` 打包进地图的 DLL 来自 `-DllPath`（默认 `src\build\bin\Release\yd_japi.dll`），代理来自 `-D3DProxyPath`（默认 `src\build\bin\Release\newD3d9.dll`）。如果要用干净 worktree 的产物跑回归，就显式传路径：

```powershell
.\tools\deploy.ps1 -DllPath build\clean-<sha7>\src\build-clean\bin\Release\yd_japi.dll `
                   -D3DProxyPath build\clean-<sha7>\src\build-clean\bin\Release\newD3d9.dll
```

### 5.3 静态检查（不需要游戏）

```powershell
# D3D 表面/代理契约静态检查
.\src\src\d3d9\verify_contract.ps1
# 期望：D3D contract PASS: surface=54, proxy=49, canonical=5, fixture=54/54, untested=0

# ABI/契约可执行自检（见第 4 节）
.\src\build\bin\Release\d3d_sdk_contract_test.exe
```

### 5.4 交互 D3D 回归（需要自动驱动 + 人工收尾）

```powershell
# 终端 A：保持前台，等 build\war3.kill 出现后关掉游戏（-Hold）
.\tools\deploy.ps1 -InteractiveD3D -Hold

# 终端 B：等游戏窗口就绪后按 [WAIT] 标记自动驱动（鼠标/键盘/24 次窗口缩放）
.\tools\drive-interactive-d3d.ps1

# 人工看完画面后收尾
New-Item -ItemType File build\war3.kill
Get-Content C:\ProgramData\japi_debug.txt -Tail 5 | Select-String 'Results:'
# 期望：170 passed, 0 failed, 170 total
```

`build\war3.kill` 只是 `-Hold` 等待循环的收尾信号；真正关游戏靠 `deploy.ps1` 的 `Stop-War3Process`（优先用创建句柄，失败则修进程 DACL 再 `TerminateProcess`）。
启动器已经死掉留下的孤儿、或手工起的游戏，用 `.\tools\kill-war3.ps1` 关（`-DryRun` 只报告能不能打开）；希望「启动器被强杀也不留孤儿」就给 `deploy.ps1` 加 `-Job`（kill-on-close Job Object）。
`-InteractiveD3D` 会把 `deploy.ps1` 的超时自动放宽到 3660 秒（`tools/deploy.ps1:48-53`）。首次运行要放前台，否则夹具抢不到真实输入，日志会以 `timed out waiting for real mouse/keyboard input` 失败（2026-11-15 的 165/166 事故即此原因，修在 `65bceb5`）。

---

## 6. 步骤 4：SHA-256 回读与校验

> **脚本化**：`tools/release-sdk.ps1` 写出 `SHA256SUMS.txt` 与 `manifest.json`；回读比对按本节命令。

### 6.1 读回并比对

```powershell
$out = 'build\sdk\0.4.0-498a308'
foreach ($name in 'yd_japi.dll','newD3d9.dll','d3d_sdk_contract_test.exe') {
    $h = (Get-FileHash (Join-Path $out $name) -Algorithm SHA256).Hash
    "{0}  {1}" -f $h, $name
}
# 再和 SHA256SUMS.txt 比对（注意：文件里是两个空格分隔）
Get-Content (Join-Path $out 'SHA256SUMS.txt')
```

一键严格比对（任意一行不一致就报错）：

```powershell
$out = 'build\sdk\0.4.0-498a308'
$bad = 0
foreach ($line in Get-Content (Join-Path $out 'SHA256SUMS.txt')) {
    if (-not $line.Trim()) { continue }
    $hash, $name = $line -split '\s{2}', 2
    $actual = (Get-FileHash (Join-Path $out $name) -Algorithm SHA256).Hash
    if ($actual -ne $hash.ToUpper()) { $bad++; Write-Host "MISMATCH $name" }
}
if ($bad) { throw "$bad artifact(s) failed SHA-256 verification" } else { 'All artifacts verified.' }
```

### 6.2 为什么 **不能** 在游戏目录里跑 `tools\d3d-proxy.ps1 -Verify`

`tools/d3d-proxy.ps1` 的契约检查要求 **游戏目录内** 有 `D3DX9_42.dll`，否则直接失败：

```text
D3DX9_42.dll is required: <game dir>\D3DX9_42.dll
```

而 `tools/deploy.ps1` 是从 `%WINDIR%\SysWOW64`/`System32` 解析这个 DLL 的 —— 所以「deploy 能跑」和「d3d-proxy -Verify 能跑」不是一回事（`docs/STATUS.md` §4 与 §14.4 都记录了这条）。

替代方案（也是 0.4.0 溯源实际用的办法）：

| 要校验的对象 | 做法 |
|---|---|
| 游戏目录里的 `d3d9.dll` 代理是否就是我装的那份 | `Get-FileHash "<game dir>\d3d9.dll"`，与 `<game dir>\.japi_d3d_proxy.sha256` 及 manifest 中的 `newD3d9.dll` 对比 |
| 视觉探针位图 | `Get-FileHash "<game dir>\japi_d3d_visual_probe.bmp"` 对比 `.japi_d3d_probe.sha256` |
| 运行时用的 `yd_japi.dll` | **不在游戏目录**：`pack.ps1` 把 `-DllPath` 作为地图负载打进 MPQ（`pack.ps1:526` 复制成 `$WorkDir\japi.tga`），日志里会打印 `DLL: ...` 全路径 |

> **`-NoBuild` 的包不能当发行产物**：它从 `src\build\bin\Release` 复制本机工作区产物，hash 与 0.4.0 干净构建（`3A4C8CD1…` / `0564A518…` / `87EBB317…`）**不同**，manifest 里 `built=false`、`artifact_source="local_worktree"`、`local_worktree_dirty=true` 就是明证。它只用来验证脚本流程。

---

## 7. 步骤 5：文档锚定（hash / 版本 / 日期要落到四处）

> **手动**（发版人负责；`tools/release-sdk.ps1` 只在 `manifest.json` 的 `docs` 字段里登记锚点）。

| 文档 | 改什么 | 位置 |
|---|---|---|
| `docs/STATUS.md` §4 | 产物表（文件 / 字节 / SHA-256）、干净构建命令、回归数字 | §4「提交态产物溯源」 |
| `CHANGELOG.md` | 新版本节的产物表 + 验证表；未发版则追加 `[Unreleased]` | 顶层 `[Unreleased]` / `[0.4.0]` |
| `docs/guide/D3D-LUA-API.md` | `d3d.version()` 行的当前值 | API 表第一行 |
| `map/tests/test_d3d_sdk.lua:33` | 版本断言 `assert(d3d.version() == "0.4.0")` | 必须与 `kVersion` 同步，否则默认回归直接挂 |
| `docs/guide/SDK-GUIDE.md` §0.4 | 「三个版本号别搞混」表格 | 指向 `../CHANGELOG.md` |

**只改一处等于没改**：`test_d3d_sdk.lua` 的断言和 `kVersion` 必须同一次提交里一起动（0.4.0 就是这么做的：`d151fd7` 只改 3 个文件）。

---

## 8. 步骤 6：打包发行包

> **脚本化**：`tools/release-sdk.ps1`（PowerShell 5.1）。文件存成 UTF-8 **带 BOM**：它内嵌中文文案，PS 5.1 读无 BOM 的 UTF-8 会按 ANSI 解码并解析失败（踩过）。改完文件顺手确认前 3 字节是 `EF BB BF`。

### 8.1 命令

```powershell
# 推荐：从指定提交完整构建后打包（约 10 分钟）
.\tools\release-sdk.ps1 -Commit 498a308

# 只验证流程（复用 src\build\bin\Release 的现有产物，不构建）
.\tools\release-sdk.ps1 -NoBuild -Commit 498a308 -OutDir build\scratch\release-test

# 保留干净 worktree 现场（默认会删）
.\tools\release-sdk.ps1 -Commit 498a308 -Keep

# 额外组装地图作者包 sdk\（详见 8.5）
.\tools\release-sdk.ps1 -SdkBundle
.\tools\release-sdk.ps1 -SdkBundle -NoVendor      # 不带 tools\w3x2lni（小 88.7 MB，作者没法打包）
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Commit` | `HEAD` | 目标提交（完整 sha 或短 sha 都行，脚本内部 `rev-parse`） |
| `-Version` | 空 = 自动 | 自动从该提交的 `libs_d3d.cpp` 解析 `kVersion` |
| `-OutDir` | `<repo>\build\sdk\<version>-<sha7>` | 必须在 `<repo>\build` 之下，否则脚本拒绝执行 |
| `-NoBuild` | 关 | 不构建，从 `src\build\bin\Release` 复制；manifest 标 `built=false` |
| `-Keep` | 关 | 打包后保留 `build\clean-<sha7>` |
| `-SdkBundle` | 关 | 额外组装地图作者包 `sdk\`（内容见 8.5），并在 manifest 里加 `sdk_bundle` 段 |
| `-NoVendor` | 关 | 仅配合 `-SdkBundle`：跳过 `tools\w3x2lni` vendor（包从 90 MB 降到 ~1.5 MB，但作者无法 `pack`） |

### 8.2 输出结构

```text
build\sdk\0.4.0-498a308\
├── yd_japi.dll
├── newD3d9.dll
├── d3d_sdk_contract_test.exe
├── SHA256SUMS.txt          # <64 位大写 hash> + 两个空格 + 文件名，LF 换行
├── manifest.json           # 版本/提交/工具链/产物 hash/回归基准/文档锚点
└── sdk\                    # 只有 -SdkBundle 才有：地图作者包（整体拷走即自包含）
    ├── README.md           # 由 tools\sdk-bundle\README.template.md 渲染
    ├── SHA256SUMS.txt      # 包内全部文件（含 vendor）的 SHA-256
    ├── CHANGELOG.md
    ├── docs\               # docs\guide 全量（当前 8 份）+ STATUS/RELEASE + planning 2 份
    ├── examples\           # 示例（数量以 manifest.json 为准，当前 12 个）+ README.md
    ├── tools\              # 13 个脚本 + config.example.ps1 + pjass.exe + callback + object-data\ + w3x2lni\
    ├── reference\empty-map\
    └── src\
        ├── build\bin\Release\   # 3 个二进制 = pack/deploy 的默认 -DllPath / -D3DProxyPath
        └── src\                 # 仅 3 个注册表源，供 gen-jass-wrappers.ps1
```

### 8.3 `manifest.json` 字段

| 字段 | 含义 |
|---|---|
| `schema` | 清单格式版本（当前 `1`） |
| `version` / `version_source` | SDK 版本 = `kVersion`，以及解析来源（`libs_d3d.cpp`） |
| `commit` / `commit_short` / `commit_date` / `commit_subject` | 发行基线提交 |
| `branch` | 脚本运行时所处分支（仅信息用途） |
| `dirty` | 请求的构建输入是否脏 |
| `clean_worktree` / `clean_worktree_asserted` | 干净 worktree 路径 + 是否断言过「HEAD 正确且 `status --porcelain` 为空」 |
| `built` / `artifact_source` / `local_worktree_dirty` | 产物是「本次干净构建」还是「本机工作区复制」 |
| `built_at` | UTC 时间戳 |
| `build_command` | 实际执行的生成器命令（`-NoBuild` 时为 `"not run (-NoBuild)"`） |
| `artifacts[]` | `{name, bytes, sha256}` ×3 |
| `regressions_source` / `regressions_verified` / `regressions[]` | 回归基准来源（`docs/STATUS.md` 头部表）、是否本次实测、5 组 `{name, expected, recorded_date, command}` |
| `docs[]` | 相关文档锚点 `{path, anchor}` |
| `toolchain` | `{generator, arch, config, vcvars32, cmake, powershell, host}` |
| `sdk_bundle` | 仅 `-SdkBundle`：`{path, files, bytes, hashed_files, readme, readme_template, sha256sums, docs[], examples[], tools[], base_map, binaries[], registries[], vendor{included, files, bytes, overlaid_files, source, note}, layout}` |

### 8.4 脚本的失败条件（fail loudly）

| 条件 | 行为 |
|---|---|
| 3 个产物任一缺失 | `throw` 终止，不写清单 |
| 干净 worktree `HEAD` 不对，或 `git status --porcelain` 非空 | `throw`（源码不可溯源） |
| `-OutDir` 不在 `<repo>\build` 之下 | `throw`（避免往仓库里写产物） |
| `git worktree add` 失败（目录已存在/被占用） | 透传 `git` 的 stderr 并终止 |
| `-SdkBundle`：文档/示例/基座/二进制/工具任一缺失 | `throw`（逐文件 `Copy-FileTo`，缺了就停） |
| `-SdkBundle`：示例不是 10 个、某示例没有 `war3map.lua`、`reference\empty-map` 少于 10 个文件 | `throw` |
| `-SdkBundle`：README 渲染后仍残留 `@@…@@` 占位符 | `throw`（说明模板与脚本的 token 表脱节） |
| `-SdkBundle`（不加 `-NoVendor`）：`tools\w3x2lni\bin\w3x2lni-lua.exe` 不存在 | `throw`（没有运行时，作者打不了包） |

### 8.5 地图作者包（`-SdkBundle`）

给「只想写地图、不碰 C++」的作者用：把文档、示例、脚手架与打包脚本、空白基座、`w3x2lni` vendor、3 个二进制按**仓库子集布局**放进 `sdk\`。作者脚本一律靠 `$Root = Split-Path -Parent $PSScriptRoot` 推仓库根，所以把 `sdk\` 当根用、**脚本一行不改**就能 `new-project` → `pack` → `deploy`。

- **内容来源**：默认全部取自干净 worktree（发布提交）。两个例外：`tools\sdk-bundle\README.template.md`（模板本身，属生成器资产）和 `tools\w3x2lni\bin\*.dll`（19 个，被仓库 `.gitignore` 的 `*.dll` 排除，干净 worktree 拿不到；没有它们作者打不了包）。覆盖数量记在 manifest 的 `sdk_bundle.vendor.overlaid_files`。
- **`sdk\src\src\` 只放 3 个注册表源**：`extensions\ex_natives\Initialize.cpp`、`lua_engine\lua_engine\libs_message.cpp`、`d3d9\handler_manifest.json`。`pack.ps1 -WithJassWrappers`（示例 09 用它）要 regex 扫这三份文本生成 JASS wrapper；只当数据读，不参与编译 —— 漏掉它们时示例 09 的 `[pack]` 会以 `handler registry not found` 失败（实测踩过）。
- **示例 11/12 的额外依赖**：`tools\object-data\`（`build.lua`+`compiler.lua`，示例 11 的 `objects.lua` 由 pack.ps1 步骤 [1c] 编译）与 `tools\drive-ui-components.ps1`（示例 12 的 `-Live` 驱动）必须进包；缺任何一个，包外的 `verify-examples.ps1` 都会在 11 或 12 上失败。
- **入口是 `sdk\README.md`**：包里有什么 / 三分钟上手 / 怎么验证包（含 `SHA256SUMS.txt` 校验片段）/ 脚本清单 / 7 条必读坑 / 版本与来源。模板在 `tools\sdk-bundle\README.template.md`，占位符 `@@VERSION@@`、`@@ARTIFACTROWS@@`、`@@TREEFILES@@` 等由脚本填充，残留未替换的占位符会 `throw`。
- **不放进包**：`src/src/` 其余源码、`map/`、`docs/architecture|analysis/`、`tools\debugger\`、`tools\release-sdk.ps1` 自身（需要现场编译）。README 里明说这些链接打不开属预期。
- **自包含门槛（必须做，否则不许发）**：把 `sdk\` 整个拷到仓库外，①`tools\verify-examples.ps1` 静态+打包**全部通过**（数量以 examples\manifest.json 为准，当前 12）；②`tools\new-project.ps1` 生成空工程后 `tools\pack.ps1` 必须出图；③`tools\deploy.ps1` 实机一次（2026-11-16 已做到：`Results: 9 passed, 0 failed, 9 total (0 skipped)`）。

2026-11-16 实测（`build\sdk\0.4.0-c14b043\sdk\` 整个拷到 `%TEMP%\sdk-standalone-c14b043`，全程在仓库外执行）：

| 项 | 结果 |
|---|---|
| 包体积 | 683 文件 / 90.3 MB（94637720 B；vendor 615 文件 / 88.7 MB），`sdk\SHA256SUMS.txt` 683 行 |
| 校验和回读 | `SHA256SUMS.txt` 683 条逐条 `Get-FileHash` → **683/683 一致**，无缺失 |
| `tools\verify-examples.ps1`（静态+打包） | `Examples: 10 passed, 0 failed, 10 total`；`[skip] luac not found` 属预期（包内没有 Lua 源码与 gcc） |
| `tools\new-project.ps1 -Name Smoke -Path …` | 25 个文件（17 基座 + 8 脚手架） |
| `tools\pack.ps1 … -OutFile build\Smoke.w3x` | `Done -> build\Smoke.w3x`，275636 B，`JASS syntax check OK` |
| 实机 `deploy` | 包内 `tools\deploy.ps1 -MapDir … -BaseMap … -MapName Smoke.w3x` → 日志 `Results: 9 passed, 0 failed, 9 total (0 skipped)` + `ALL CHECKS PASSED (9/9)`，exit 0 |
| `tools\verify-examples.ps1 -Live`（实机 10 例） | 一轮跑完：`01 5/5`、`02 8/8`、`03 6/6`、`04 5/5`、`05 6/6`、`06 5/5`、`07 5/5`、`08 7/7`、`09 6/6`、`10 6/6`，末行 `Examples: 10 passed, 0 failed, 10 total`（仓库内那次被别的会话挤成两批，这是首次一次跑完） |
| manifest 交叉核对 | `sdk_bundle.{files,hashed_files,bytes}` = `683/683/94637720`；`vendor.overlaid_files=19`；`docs=11 examples=10 tools=11 registries=3 binaries=3` |

> `-SdkBundle -NoBuild` 产出的 `sdk\` 同样**不可发布**：二进制来自本地 checkout。且 vendor 里的 19 个 DLL 只能来自出包机，换台机器出包必须先补 `tools\w3x2lni\bin\*.dll`。

---

## 9. 步骤 7：坑表（Pitfalls）

| 现象 | 原因 | 处理 |
|---|---|---|
| 部署后日志不更新 / 秒退 | WAR3 单实例锁：旧进程还在，新进程立刻退出 | `tools\kill-war3.ps1 -DryRun` 看一眼，再 `tools\kill-war3.ps1`（修进程 DACL 后 Terminate；`Stop-Process -Force` 对它是 Access denied），等 2 秒再跑 |
| `NOTE: ...japi_debug.txt is locked by a stale instance` | 旧实例仍持有日志句柄 | 脚本自动回退到 `japi_debug_<pid>.txt`（`deploy.ps1:196-208`）；也可以主动清旧进程 |
| 两个 agent 同时 `deploy`，日志串台 | 共享日志被 `Remove-Item` 后互相覆盖 | **串行**执行；打包用 `-WorkDir build\scratch\<tag>\work` 隔离，地图名用 `-MapName` 隔离 |
| `objdump.exe is required to validate the D3D proxy exports` | `PATH` 里没有 `objdump.exe` | 装 32 位 binutils 并加入 `PATH`；仅静态校验需要 |
| 报 `file format pei-x86-64` / 不是 PE32 | `PATH` 里是 MinGW **64 位** objdump | 换成 32 位版本（`pei-i386`） |
| `collision: refusing to overwrite unknown file` | 游戏目录里的 `d3d9.dll` 不是本项目装的（没有匹配的 sidecar） | 手工确认后删除那个文件，或先 `tools\d3d-proxy.ps1 -Uninstall` |
| `D3DX9_42.dll is required ...` | 游戏目录/系统目录都没有 | 装 DirectX 9 运行库，或把 `D3DX9_42.dll` 复制到 `SysWOW64` |
| 拉不到产物（`git checkout` 后 `bin\Release` 不存在） | 构建产物不入 git（`.gitignore` 忽略 `build/`、`src/build/`、`*.dll`） | 产物只能构建得到；发行包靠 `build\sdk\…` 传递 |
| 日志为空就以为跑了 Debug 版 | `Release` 也定义 `JAPI_DEBUG`（`CMakeLists.txt:132`） | 用 `manifest.json` / hash 判断是哪份 DLL，不要看日志有无 |
| `build\clean-*` 占满磁盘 | 一个干净 worktree ≈ 200 MB | `git worktree remove --force build\clean-<sha7>`（脚本默认已删） |
| `git worktree add` 报目录已存在 | 上一次没清理 | 用 `--detach`（脚本已用）；或先 `git worktree prune` |

---

## 10. 验证状态汇总（2026-11-16）

| 结论 / 命令 | 状态 | 证据 |
|---|---|---|
| `tools/release-sdk.ps1 -NoBuild` 端到端 | **已验证** | exit 0；产出 3 产物 + `SHA256SUMS.txt` + `manifest.json`；包内 hash 与 `src\build\bin\Release` 源文件逐一对齐；清单可被 `ConvertFrom-Json` 解析；干净 worktree 已自动删除 |
| 同上，在全部工具链/示例/文档提交之后复跑（`9347b12`，以及最后一次改动 `tools\`/`examples\` 的 `b2e11ab`） | **已验证**（lead 复跑两次） | 两次都 exit 0；干净 worktree 自动创建并删除；产出 `build\sdk\0.4.0-b2e11ab\`（另有 `0.4.0-9347b12\`）`{SHA256SUMS.txt, manifest.json}`；`yd_japi.dll` `87C83BA1CE0E6E413CEA7B9D6018E9A289259EC9C2F01EE02E7827DAF6661908`（547328 B）、`newD3d9.dll` `7D3063B6A3C52DC91A084F9002A4AB0678AE2E0D6CBFE2B4ABF63567876986D5`（90112 B）、`d3d_sdk_contract_test.exe` `8E0A3E5D341B9FCD97FCBF612E0060FFDFAA4350E14C8E88186D9A028987B458`（23040 B），三者与独立 `Get-FileHash` 一致 |
| `-NoBuild` 产物 hash 不等于 0.4.0 干净 hash | **已验证**（预期差异） | 本机 `87C83BA1…`/`7D3063B6…`/`8E0A3E5D…` vs 干净 `3A4C8CD1…`/`0564A518…`/`87EBB317…` |
| `tools/release-sdk.ps1 -NoBuild -SdkBundle` 组装 `sdk\` | **已验证** | `build\sdk\0.4.0-c14b043\sdk\` 683 文件 / 90.3 MB（早先 `1da154c` 同为 683 文件 / 90.2 MB）；`sdk\SHA256SUMS.txt` 683 行；manifest `sdk_bundle` 段含 `files/hashed_files/vendor.overlaid_files=19`；`sdk\README.md` 无残留 `@@…@@` |
| `sdk\` 自包含·静态+打包（仓库外） | **已验证** | 拷到 `%TEMP%\sdk-standalone-1da154c` 后 `tools\verify-examples.ps1` → `Examples: 10 passed, 0 failed, 10 total`（首轮曾因缺 3 个注册表源让示例 09 `fail`，补齐后 10/10） |
| `sdk\` 自包含·脚手架+打包 | **已验证** | `tools\new-project.ps1` → 25 文件；`tools\pack.ps1` → `build\Smoke.w3x` 275638 B |
| `sdk\` 自包含·实机 deploy | **已验证** | 包内 `tools\deploy.ps1` 部署脚手架工程 → 日志 `Results: 9 passed, 0 failed, 9 total (0 skipped)` + `ALL CHECKS PASSED (9/9)`，exit 0（早先是另一个会话的 `-Demo -Hold` 占着单实例锁，等它退出后补跑） |
| `sdk\` 自包含·实机 `-Live`（10 例一轮） | **已验证** | 包内 `tools\verify-examples.ps1 -Live` → `Examples: 10 passed, 0 failed, 10 total`，每例 `[live] ok`（合计 59 条检查）；此前仓库内 `-Live` 被单实例锁挤成两批 |
| `sdk\` 最终包复跑（HEAD `c14b043`） | **已验证** | `build\sdk\0.4.0-c14b043\sdk\` 683 文件：`SHA256SUMS.txt` 683 条全部 `Get-FileHash` 一致；静态+打包 10/10；脚手架打包 `build\Smoke.w3x` 275636 B；`manifest.json` 的 `sdk_bundle` = 683 文件 / 683 校验和 / 94637720 字节 |
| 脚本的 **完整构建分支**（`vcvars32` + `cmake`） | **未验证** | 本轮未跑完整构建（约 10 分钟，复用 lead 预构建产物）；命令串已逐字对照 `src/build.bat` / `CMakeLists.txt` / §14.4 |
| 0.4.0 干净 hash 复现 | **未验证**（本轮未重建 `d151fd7`） | 数值引自 `docs/STATUS.md` §4 与 `docs/planning/D3D-LUA-SDK-DESIGN.md` §14.4 |
| 五组回归数字（122 / 125 / 126 / 9 / 170） | **已验证**（由 lead 在 2026-11-15/16 实机复跑，本文档作者未跑） | `docs/STATUS.md` 头部表；交互 D3D 2026-11-16 为 170（= 122 + 48） |
| `Get-FileHash` 回读比对流程 | **已验证** | 本机对 `build\scratch\release-test` 执行，3/3 一致 |
| 游戏目录 `d3d-proxy.ps1 -Verify` 不可用 | **已验证**（复现 `D3DX9_42.dll is required`） | `docs/STATUS.md` §4、§14.4 |

---

## 11. 一页速查

```powershell
# 0. 钉版本：确认 HEAD 干净且 kVersion 是你想要的
git status --porcelain; git rev-parse --short HEAD

# 1. 打包（完整构建 + 3 产物 + SHA256SUMS + manifest）
.\tools\release-sdk.ps1 -Commit <sha>

# 1b. 顺手出地图作者包 sdk\（可选，见 8.5）
.\tools\release-sdk.ps1 -Commit <sha> -SdkBundle

# 2. 回读核对 hash
Get-Content build\sdk\<version>-<sha7>\SHA256SUMS.txt

# 3. 用这份产物跑实机回归（串行！单实例）
.\tools\deploy.ps1 -DllPath build\sdk\<version>-<sha7>\yd_japi.dll `
                   -D3DProxyPath build\sdk\<version>-<sha7>\newD3d9.dll
Get-Content C:\ProgramData\japi_debug.txt -Tail 5 | Select-String 'Results:'

# 4. 把 commit / 日期 / hash 写回 docs\STATUS.md §4、CHANGELOG.md、docs\guide\D3D-LUA-API.md
```

---

## 12. 附录：怎么确认你在跑哪个版本

三层确认，从「最可信」到「只能当辅助」：

### 12.1 游戏内 Lua（唯一权威）

```lua
local d3d = require("jass.d3d")
print("SDK " .. d3d.version() .. " / ABI " .. tostring(d3d.abi_version()))
-- 期望：SDK 0.4.0 / ABI 1
```

`d3d.version()` 直接返回 `src/src/lua_engine/lua_engine/libs_d3d.cpp:35` 的 `kVersion`，是 SDK 版本的唯一来源；默认回归里已有硬断言（`map/tests/test_d3d_sdk.lua:33-34`：`assert(d3d.version() == "0.4.0")` / `assert(d3d.abi_version() == 1)`），版本不对这条用例会直接红。

### 12.2 文件身份（唯一能证明「跑的是哪份二进制」）

```powershell
(Get-FileHash <你打包用的那份>\yd_japi.dll -Algorithm SHA256).Hash
# 与 build\sdk\<version>-<sha7>\SHA256SUMS.txt / manifest.json 对比
```

注意 `yd_japi.dll` **不在游戏目录**：`pack.ps1` 把它以 `japi.tga` 名义塞进地图 MPQ（`pack.ps1:526`），部署日志里有 `DLL: ...` 全路径。要对比的是「打包进去的那份」，不是游戏目录里任何遗留文件。

### 12.3 日志指纹（只能当辅助，不能证明版本）

| 表面 | 位置 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| `install_lazy_hook: ExecuteFunc hooked` | `C:\ProgramData\japi_debug.txt` 首行（`lua_loader.cpp:229`） | DLL 加载并挂上了 ExecuteFunc 钩子 | 哪一版 |
| `[HH:MM:SS pid=N] Initialize() START` / `DONE` | `C:\ProgramData\japi_sync.log`（`debug_log.h:27-42` 的 `sync_write`；打印点 `dllmain.cpp:209` / `:322`） | **哪个进程**在什么时候加载了 DLL（多实例时区分谁是谁） | 哪一版 |
| ` Results: N passed, M failed, T total` | `japi_debug.txt` 末尾（`test_suite.lua:895`） | 测试套件跑完了 | 哪一版 |

> **日志里没有版本 banner**：这是已知缺口（见 `CHANGELOG.md`「已知缺口」），所以不能靠日志判断版本，只能靠 12.1 / 12.2。

### 12.4 两个「看着像版本号、其实不是」的

| 调用 | 恒返回 | 来源 | 为什么不能用 |
|---|---|---|---|
| `GetPluginVersion()` | `"1.0.0"` | `src/src/extensions/ex_natives/GameInfo.cpp:42`（字面量） | 0.3.0-dev 与 0.4.0 都报同一个值 |
| `require("jass.runtime").version` | `"1.0.0.0"` | `src/src/lua_engine/lua_engine/libs_runtime.cpp:245`（字面量） | 同上 |

另外 `GetGameVersion()` 返回 `6374`（WAR3 1.27a）—— 那是**游戏**版本，不是 SDK 版本。

**验证状态**：12.1 的期望值由默认回归断言（2026-11-15 为 `122 passed, 0 failed, 122 total`，见 `docs/STATUS.md` 头部表）；12.2 的 `Get-FileHash` 流程在 `build\scratch\release-test` 上实测 3/3 一致；12.3「日志无版本 banner」为 2026-11-16 实际读 `japi_debug.txt` 与 `japi_sync.log` 得出的结论。
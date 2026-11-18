# WAR3 map-inject 地图作者 SDK @@VERSION@@

面向地图作者的自包含发布包：解压后不需要源码仓库的其它目录，就能建工程、打包、部署到 WAR3 1.27a、跑示例回归。

- 版本：`@@VERSION@@`（DLL 内 `kVersion` 与 `d3d.version()` 返回同一个值）
- 提交：`@@COMMIT7@@`（`@@COMMIT@@`，@@COMMITDATE@@）
- 打包：@@BUILTAT@@，@@BUILDKIND@@
- 目标运行环境：WAR3 **1.27a**（只支持这个版本）、Windows、PowerShell 5.1+

@@DRAFTWARNING@@

## 1. 包里有什么

| 目录 | 内容 |
|---|---|
| `docs/guide/` | 6 份作者文档：SDK 快速上手、SDK 指南、Cookbook、D3D HUD 的 Quickstart / API / 迁移 |
| `docs/` | `STATUS.md`（模块完成度与验证强度）、`RELEASE.md`（维护者视角的出包流程）、`planning/` 里被指南引用的两份设计文档 |
| `examples/` | 10 个可运行的最小示例，每个都有自己的 `README.md` 与 `war3map.lua`；`manifest.json` 是索引 |
| `tools/` | 脚手架与打包/部署/回归脚本（清单见第 4 节）、`pjass.exe`、`callback`、`config.example.ps1` |
| `tools/w3x2lni/` | @@VENDORSTATUS@@ |
| `reference/empty-map/` | 空白基座地图（解包形态，17 个文件）：`new-project.ps1` 默认拿它当基座 |
| `src/build/bin/Release/` | `yd_japi.dll`（注入主体）、`newD3d9.dll`（D3D 代理）、`d3d_sdk_contract_test.exe`（契约测试） |
| `src/src/`（仅 3 个文件） | `gen-jass-wrappers.ps1` 要扫的注册表源（EX*/game-info handler 注册、message handler 注册、`handler_manifest.json`）：`pack.ps1 -WithJassWrappers`（示例 09 用的就是它）靠这些文本生成 JASS wrapper，不参与编译 |
| `CHANGELOG.md` | 版本历史与每一项修复的验证记录 |
| `SHA256SUMS.txt` | 本目录下全部 @@HASHCOUNT@@ 个文件（不含本清单自身）的 SHA-256，含 vendor，格式 `<hash>  <相对路径>` |

整个包 @@TREEFILES@@ 个文件 / @@TREEMB@@ MB（不含 `SHA256SUMS.txt` 自身，vendor 占大头），直接拷走整个目录即可。

**不在包里**：除上面那 3 个注册表文件以外的 C++ 源码 `src/src/`、仓库自测用的 `map/` 开发目录、`architecture/` `analysis/` 等内部文档、调试器 payload `tools/debugger/`、出包脚本 `tools/release-sdk.ps1`（它需要 `src/` 现场编译）。文档里指向这些位置的链接打不开，属预期行为。

**环境要求**：不需要装 Lua、CMake、Visual Studio——DLL 已经是编好的；只需要 Windows + PowerShell 5.1+ + WAR3 1.27a。

## 2. 三分钟上手

把**本目录当作"仓库根"**（`tools\` 就在这一层），在**这个目录里**执行：

```powershell
cd <解压出来的目录>

# ① 建工程：拷基座、生成 war3map.lua / lib / tests / README
.\tools\new-project.ps1 -Name MyMap -Path D:\maps

# ② 打包：内联 Lua + 注入 DLL -> build\MyMap.w3x
.\tools\pack.ps1 -MapDir D:\maps\MyMap -BaseMap D:\maps\MyMap\base-map -WorkDir build\work -OutFile build\MyMap.w3x

# ③ 部署：拷进 Maps\Test、启动 War3、轮询日志等结果
.\tools\deploy.ps1 -MapDir D:\maps\MyMap -BaseMap D:\maps\MyMap\base-map -MapName MyMap.w3x
```

`new-project.ps1` 收尾时会把这三条命令按你的实际路径再打印一遍（基座是目录还是 `.w3x` 文件时参数不同），照抄它打印的版本更保险。

成功的标志：

- 打包最后一行 `Done -> build\MyMap.w3x`，中间有 `Bundled N Lua files into war3map.lua`
- 部署后日志里出现 `Results: 9 passed, 0 failed, 9 total (0 skipped)` 与 `ALL CHECKS PASSED (9/9)`

日志固定写在 `C:\ProgramData\japi_debug.txt`（进程号后缀版是 `japi_debug_<pid>.txt`）：

```powershell
Get-Content C:\ProgramData\japi_debug.txt -Tail 40
```

`deploy.ps1` 默认游戏目录是 `D:\Warcraft III Frozen Throne 1.27a publish`。装在别处就传 `-War3Dir`，或者把 `tools\config.example.ps1` 复制成 `tools\config.local.ps1` 后改 `$War3Dir`（`config.local.ps1` 不会被提交）。

## 3. 验证这个包本身

```powershell
# 静态检查 + 逐例打包（不启动游戏，约 1 分钟）
.\tools\verify-examples.ps1

# 只做静态检查（几秒）
.\tools\verify-examples.ps1 -SkipPack

# 再加逐例实机（需要独占整机，见第 5 节第 2 条）
.\tools\verify-examples.ps1 -Live
```

静态 + 打包必须 10/10（出包前的门槛）；`-Live` 是逐个示例真开游戏跑一遍。

包里不带 `luac.exe`，所以静态检查会先打印一行 `[skip] luac not found`——其余检查（模块名、`require` 位置、打包）照常跑。想打开 Lua 语法检查：装一份 Lua 5.4，把 `luac.exe` 的路径设到 `$env:LUAC`，或直接放到 `build\scratch\luac\luac.exe`；`tools\build-luac.ps1` 需要 `src\vendor\lua-5.4\src` 和 gcc，包里没有，不能用。

校验文件没被改动过：

```powershell
$bad = 0
Get-Content .\SHA256SUMS.txt | ForEach-Object {
    $h, $p = $_ -split '  ', 2
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath ($p -replace '/', '\')).Hash -ne $h) {
        $bad++; Write-Host ("MISMATCH " + $p)
    }
}
"mismatches: $bad"
```

发布的二进制（`src\build\bin\Release\`）：

| 文件 | 字节 | SHA-256 |
|---|---|---|
@@ARTIFACTROWS@@

## 4. 脚本清单

| 脚本 | 作用 | 常用参数 |
|---|---|---|
| `tools\new-project.ps1` | 生成工程骨架 | `-Name`、`-Path`、`-Base`、`-Force` |
| `tools\pack.ps1` | 打包：内联 Lua、注入 DLL、修 `war3map.j` | `-MapDir`、`-BaseMap`、`-OutFile`、`-WorkDir`、`-DllPath`、`-W3x2Lni`、`-SkipJassCheck` |
| `tools\deploy.ps1` | 打包 + 拷进 `Maps\Test` + 启动 + 等 `Results` 行 | `-MapDir`、`-BaseMap`、`-MapName`、`-War3Dir`、`-Timeout`、`-Hold`、`-Job` |
| `tools\verify-examples.ps1` | 示例回归：静态 / 打包 / 实机 | `-Filter`、`-SkipPack`、`-Live`、`-Timeout` |
| `tools\build-luac.ps1` | 编一个 `luac.exe` 供静态语法检查（包里缺 Lua 源码和 gcc，用不上） | 无 |
| `tools\d3d-proxy.ps1` | 安装 / 检查 / 卸载 D3D 代理 | `-Install`、`-Remove`、`-Status` |
| `tools\drive-interactive-d3d.ps1` | 按 `[WAIT]` 标记自动驱动交互式 D3D 回归 | `-ResizeCount`、`-TimeoutSeconds` |
| `tools\gen-jass-wrappers.ps1` | 按 C++ 注册表生成 JASS wrapper（需要源码仓库，包里跑不了完整版） | `-Check`、`-Force` |
| `tools\kill-war3.ps1` | 关掉 `war3.exe`，包括杀不掉的孤儿（修进程 DACL 再 Terminate，不需要管理员） | `-ProcessId`、`-DryRun` |
| `tools\_war3ctl.ps1` | 上面那个脚本的库：判活、DACL 修复、kill-on-close Job Object，由 `deploy.ps1` dot-source | 无（不单独运行） |

`reference\empty-map` 是**目录形态**的基座（已解包），`pack.ps1` 直接把它当源文件读；如果 `-BaseMap` 指向 `.w3m`/`.w3x` 文件，则先解包再打包（工程 README 第 2 节有区别）。

## 5. 必读的坑（都踩过）

1. **只支持 WAR3 1.27a**，其它版本 DLL 加载不上。
2. **单实例、独占整机**：`deploy.ps1` 与 `verify-examples.ps1 -Live` 运行时不能有别的 War3 在跑，也不能有别的会话同时部署——日志 `C:\ProgramData\japi_debug.txt` 和 `<War3Dir>\Maps\Test\` 是共享资源。
3. **日志路径固定**在 `C:\ProgramData\japi_debug.txt`。往别处指会一直等不到 `Results` 行。
4. `require "模块"` 必须写在**行首**（第 0 列）：缩进或注释掉的 `require` 不会被内联，进游戏就报模块找不到。
5. `jass.globals` 的**数组**在加载期（约 1 秒内）不可用，写进去会被丢掉；标量正常。改数组要放到 `after()` / timer 里。
6. `jass.sleep` 在同一个 action 里只睡一次是可靠的，多段串联不可靠，而且 `sleep` 会让 action 从头重入。规范写法见 `examples\05-sleep-sequence\`。
7. 示例的交互式输入（键盘、鼠标、D3D 窗口）在 `-Live` 下只是模拟；真人操作路径需要真的在窗口里按键。

排障细节见 `docs\guide\SDK-GUIDE.md` 的故障排查一节，以及 `docs\guide\SDK-QUICKSTART.md` 的逐步检查表。

## 6. 版本与来源

- 版本号取自源码 `src/src/lua_engine/lua_engine/libs_d3d.cpp` 的 `kVersion`；出包脚本在 clean worktree 上编译，因此二进制与提交严格对应（`-NoBuild` 除外，那种包不得对外发布）。
- `manifest.json`（本目录的上一级）记录出包提交、构建方式、三个二进制的字节数与 SHA-256、以及回归记录来源；`sdk_bundle` 段记录本包的文件数与字节数。
- 变更记录与每一项实测证据见 `CHANGELOG.md`。
- 重新出包（在源码仓库里）：`.\tools\release-sdk.ps1 -SdkBundle`；只装二进制：`.\tools\release-sdk.ps1 -NoBuild`。

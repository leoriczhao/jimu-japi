# WAR3 Lua SDK Quickstart：30 分钟跑出第一张自己的图

> **给谁看**：会写一点 Lua、想在自己的 WAR3 1.27a 地图里跑脚本的地图作者。不需要 C++，不需要改 DLL。
> **读完你会得到**：一个自己的工程目录、一条可复现的打包命令、一条可复现的部署命令，游戏里出现一片 `[PASS]` 和一行 `Results: 3 passed, 0 failed, 3 total`。
> **前提**：Windows；Warcraft III 1.27a 已安装；本仓库已 clone 且能 `src\build.bat` 编译出 `src\build\bin\Release\yd_japi.dll`；没有别的 war3.exe 在跑。
> **如果你拿到的是 `sdk\` 分发包**：不用 clone 仓库、不用编译 DLL。解压后先读包根目录的 `README.md`（三分钟上手），再 `cd` 到包根执行下面同样的命令——包内 `tools\`、`reference\empty-map`、`src\build\bin\Release` 都已就位。

| 项目 | 值 |
|---|---|
| 适用游戏版本 | Warcraft III 1.27a（Windows，单实例） |
| SDK 版本 | 0.6.0（`jass.d3d.version()`） |
| 本文档日期 | 2026-11-16 |
| 验证状态 | 本文 §1-§5 的命令链 2026-11-16 在本机实机跑通：打包 exit 0，游戏内日志 `Results: 3 passed, 0 failed, 3 total`；DLL SHA-256 `87C83BA1CE0E6E413CEA7B9D6018E9A289259EC9C2F01EE02E7827DAF6661908`（547328 字节，HEAD 498a308） |
| 更深的内容 | 模块语义看 [SDK-GUIDE.md](SDK-GUIDE.md)，常见任务看 [SDK-COOKBOOK.md](SDK-COOKBOOK.md) |

---

## 0. 30 分钟路线图

| 分钟 | 做什么 | 完成标志 |
|---|---|---|
| 0-5 | §1 前置检查 | `yd_japi.dll` 存在、没有残留 war3 进程 |
| 5-10 | §2 建工程、写 `war3map.lua` | 目录里有 `war3map.lua` 和 `base-map\` |
| 10-15 | §3 打包 | 输出末尾是 `  Done -> ...\hello-sdk.w3x` |
| 15-25 | §4 部署到游戏 | 日志里有 `Results: 3 passed, 0 failed, 3 total` |
| 25-30 | §5 改一行验证链路 | 故意改坏的断言变成 `[FAIL]`，`1 failed` |

---

## 1. 前置检查（5 分钟）

### 1.1 DLL 编出来了吗

```powershell
cd src
.\build.bat
cd ..
Get-Item src\build\bin\Release\yd_japi.dll | Select-Object Length, LastWriteTime
```

| 期望 | 说明 |
|---|---|
| 文件存在，大小约 547328 字节 | DLL 打包时被复制成地图里的 `japi.tga` 塞进 MPQ |
| 编译输出里没有 error | 编译失败先解决，后面每一步都依赖它 |

想确认自己编的和文档里的是同一份：

```powershell
Get-FileHash src\build\bin\Release\yd_japi.dll -Algorithm SHA256 | Format-List Hash
# 2026-11-16 的构建：87C83BA1CE0E6E413CEA7B9D6018E9A289259EC9C2F01EE02E7827DAF6661908
```

### 1.2 没有残留的 war3 进程

```powershell
Get-Process war3 -ErrorAction SilentlyContinue
```

有输出就先关掉。1.27a 有单实例锁：第二个实例起不来，表现为「deploy 等满超时、日志文件根本不产生」——那不是你的脚本写错了。

### 1.3 确认工具能看见你的 War3 目录

`tools\deploy.ps1:39` 把游戏目录写死成：

```text
D:/Warcraft III Frozen Throne 1.27a publish
```

| 情况 | 怎么办 |
|---|---|
| 游戏就装在这里 | 什么都不用做 |
| 装在别处 | 改 `tools\deploy.ps1` 第 39 行的 `$War3Dir`（目前没有 `-War3Dir` 参数） |
| 想跑 D3D 示例 | 额外装 proxy：`tools\d3d-proxy.ps1 -Install`；本文的 hello 示例不需要 |

---

## 2. 建工程（5 分钟）

### 2.1 目录结构

一个工程 = 一个目录，里面必须有 `war3map.lua`；如果想让地图有底图（地形/英雄），再加一个 `base-map\` 目录。

```text
build/scratch/hello-sdk/
├── war3map.lua          <- 你的全部 Lua 逻辑（pack.ps1 会递归收集这里所有 .lua）
└── base-map/            <- 基座地图源目录（本仓库的空白图：64x64 平地 + 1 个 10 级英雄）
    ├── war3map.j        <- JASS 引导代码（含 initializePlugin 锚点）
    ├── war3map.w3i
    └── ...
```

```powershell
New-Item -ItemType Directory -Force build\scratch\hello-sdk | Out-Null
Copy-Item -Recurse reference\empty-map build\scratch\hello-sdk\base-map
```

> **更快的路（可选）**：仓库自带脚手架，一条命令生成上面的结构再加 `lib/`、`tests/`、`config.lua`、`README.md`：
>
> ```powershell
> .\tools\new-project.ps1 -Name hello-sdk -Path build\scratch\scaffold
> ```
>
> 它最后打印的 next steps 里的 pack 命令可以直接跑（2026-11-16 验证：`Bundled 5 Lua files into war3map.lua` → `Done -> ...`），生成的 `tests\smoke.lua` 自带 9 项引擎检查，健康日志是 ` Results: 9 passed, 0 failed, 9 total (0 skipped)` 加 `ALL CHECKS PASSED (9/9)`。
> 脚手架只写文件、不启动游戏，也不改 `tools\pack.ps1` / `tools\deploy.ps1`。
> **本文后面为了讲清最小结构，用的仍是上面手工建的那份（3 项检查）**；两条路之后的打包、部署命令完全一致。

### 2.2 写 `war3map.lua`

把下面的内容原样存成 `build\scratch\hello-sdk\war3map.lua`。这份文件是 2026-11-16 实机跑出 `Results: 3 passed` 的那一份。

```lua
-- hello-sdk/war3map.lua
-- japi SDK quickstart：地图作者入口。pack.ps1 会把本目录下所有 .lua 内联进地图。
local jass = require "jass.common"
local d3d  = require "jass.d3d"

local pass, fail = 0, 0

-- 和 map/game/demo.lua 同款断言 helper：成功打 [PASS]，失败打 [FAIL] 并记一次 fail
local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("  [PASS] " .. name)
    else
        fail = fail + 1
        print("  [FAIL] " .. name .. " : " .. tostring(err))
    end
end

-- 地图 boot 阶段很多 native 还不能用，延时到开局后再跑检测
local function after(seconds, fn)
    local timer = jass.CreateTimer()
    jass.TimerStart(timer, seconds, false, function()
        jass.DestroyTimer(timer)
        pcall(fn)
    end)
end

after(1.0, function()
    print("========================================")
    print(" hello-sdk / japi SDK")
    print("========================================")

    check("SDK 版本是 0.6.0", function()
        local v = d3d.version()
        assert(v == "0.6.0", "got " .. tostring(v))
    end)

    check("jass.common 能调到 JASS native", function()
        local player = jass.GetLocalPlayer()
        assert(player ~= nil, "GetLocalPlayer() returned nil")
        assert(jass.GetPlayerId(player) >= 0, "GetPlayerId() < 0")
    end)

    check("jass.call 与 jass.X 等价", function()
        local p1 = jass.GetLocalPlayer()
        local p2 = jass.call("GetLocalPlayer")
        assert(p1 == p2, "metatable dispatch and jass.call disagree")
    end)

    print(string.format(" Results: %d passed, %d failed, %d total", pass, fail, pass + fail))
end)
```

### 2.3 三个必须知道的规则

| 规则 | 为什么 |
|---|---|
| `require` 必须**顶格**写，并且用**双引号** | `tools/pack.ps1` 的 Lua 打包器只匹配行首的双引号 `require "模块"`；写成单引号或缩进，模块不会被打进地图，游戏里才会报错。`jass.*` 是运行时 preload，不受影响。打包时加 `-RequireReport` 可逐条看到「内联 / 缓存 / 引擎 / 缺失」，`-StrictRequires` 让缺失、无法内联或循环依赖的模块在打包期失败；注释与字符串中的 `require` 会被忽略。检查覆盖字面量模块名，不解析动态表达式或 `require` 的别名；自定义运行时加载器也可能解决静态检查报出的缺失，需要作者自行确认。 |
| 用 `print()`，别用 `BJDebugMsg` 打日志 | Lua 的 `print` 被 DLL 重定向进 `C:\ProgramData\japi_debug.txt`；游戏屏幕上的文字部署脚本读不到。 |
| 逻辑放在 `after(1.0, ...)` 之类的延迟里 | 地图 boot 阶段（脚本刚执行时）部分 native 不可用；1 秒是回归里验证过的安全起点。 |

---

## 3. 打包（5 分钟）

一条命令：

```powershell
.\tools\pack.ps1 -MapDir build\scratch\hello-sdk -BaseMap build\scratch\hello-sdk\base-map -WorkDir build\scratch\hello-sdk-work -OutFile build\scratch\hello-sdk.w3x
```

| 参数 | 作用 | 建议 |
|---|---|---|
| `-MapDir` | 你的工程目录，`pack.ps1` 会递归收集里面的 `*.lua` | 必填 |
| `-BaseMap` | 底图（这里是我们复制出来的 `base-map\`） | 指向你自己的 `base-map\`，别用默认值 |
| `-WorkDir` | 中间产物目录 | **永远显式给一个独立目录**：`pack.ps1` 每次都会先清空它（第 177 行），共用会互相踩 |
| `-OutFile` | 产物路径 | 不写就是 `build\output.w3x`，多工程并行时一定要写 |

期望输出（2026-11-16 实机，exit code 0）：

```text
  Base map: C:\...\hello-sdk\base-map
  Map dir:  C:\...\hello-sdk
  DLL:      C:\...\src\build\bin\Release\yd_japi.dll
  Output:   C:\...\build\scratch\hello-sdk.w3x
  [1/5] Copy base-map source directory
  [1b] Compile unit object data
  [2/5] Bundle Lua
  Bundled 1 Lua files into war3map.lua
  [3/5] Patching war3map.j
  Array prealloc: 3 array globals
  Bootstrap: plugin marker map
  Array prealloc: JapiForceAllocArrays injected
  JASS syntax check OK
  [4/5] Inject DLL + callback
  [5/5] Repack
  Done -> C:\...\build\scratch\hello-sdk.w3x
```

中间夹着几十行 w3x2lni 打印的 `Content-Length: ...` 与 `{type="text",args="正在..."}` 调试噪声，可以直接忽略。

| 关键行 | 含义 |
|---|---|
| `Bundled 1 Lua files into war3map.lua` | 你的 `war3map.lua` 被内联进地图（数字 = 收集到的 Lua 文件数） |
| `Bootstrap: plugin marker map` | 识别出基座是带 `initializePlugin` 的插件图，插入 `LoadScript` 调用成功 |
| `JASS syntax check OK` | `tools\pjass.exe` 校验通过（外来 vJass 地图可加 `-SkipJassCheck` 跳过） |
| `Done -> ...w3x` | 打包成功，这条路径就是随后要部署的地图 |

> `[1b] Compile unit object data` 只在基座是 unpacked 源目录（带 `war3map.w3u.ini`）时出现。
> 如果这步报 `w3x2lni obj failed`，先确认 `tools\w3x2lni\bin\*.dll` 在（这些 DLL 被 `.gitignore` 忽略，新 clone 的 worktree 可能缺）。

---

## 4. 部署到游戏并读结果（10 分钟）

`deploy.ps1` = 打包 + 复制到 `Maps\Test\` + 启动 war3 + 轮询日志直到出现 `Results:` 行。

```powershell
Get-Process war3 -ErrorAction SilentlyContinue   # 再确认一次：必须为空
.\tools\deploy.ps1 -MapDir build\scratch\hello-sdk -BaseMap build\scratch\hello-sdk\base-map -MapName hello-sdk -Timeout 180
```

期望输出（结构固定，路径随你的机器变）：

```text
[1/4] Packing map...
  Map packed OK
[2/4] Deploying to War3...
  Deployed to D:\Warcraft III Frozen Throne 1.27a publish\Maps\Test\hello-sdk.w3x
[3/4] Launching War3...
[4/4] Waiting for test results (180s timeout)...
  ...（这里回显日志最后 35 行，含你的 [PASS] 与 Results 行）...
  War3 terminated
```

`[4/4]` 之后回显的日志里，你应该看到这一段（2026-11-16 实机原文）：

```text
========================================
 hello-sdk / japi SDK
========================================
  [PASS] SDK 版本是 0.6.0
  [PASS] jass.common 能调到 JASS native
  [PASS] jass.call 与 jass.X 等价
 Results: 3 passed, 0 failed, 3 total
```

### 4.1 自己读日志（比 deploy 的回显更完整）

```powershell
Get-Content C:\ProgramData\japi_debug.txt -Encoding UTF8 | Select-String 'PASS|FAIL|Results:'
```

| 必须满足 | 否则 |
|---|---|
| 日志文件存在，且 `LastWriteTime` 晚于本次启动 | 文件不存在 = 游戏没进地图 / DLL 没加载（见 §6 第一行） |
| 出现 `Results:` 行，`failed` 为 0 | 出现 `[FAIL]` 行：读那一行的错误文本，`failed` 计数会告诉你失败几条 |
| deploy 打印 `  War3 terminated` | 打印 `Timed out after Ns` = 没等到 Results 行，脚本可能还在跑（把 `-Timeout` 调大） |

### 4.2 为什么日志里中文可能乱码

DLL 写日志用 UTF-8。Windows PowerShell 5.1 的 `Get-Content` 默认按系统代码页（936）解码，所以中文会乱：

```powershell
# 正确姿势
Get-Content C:\ProgramData\japi_debug.txt -Encoding UTF8
# 或者
[System.IO.File]::ReadAllLines('C:\ProgramData\japi_debug.txt', [Text.Encoding]::UTF8)
```

---

## 5. 改一行，确认链路真的在跑（3 分钟）

把 `war3map.lua` 里第一条断言故意改坏：

```lua
    check("SDK 版本是 0.6.0", function()
        local v = d3d.version()
        assert(v == "9.9.9", "got " .. tostring(v))   -- 故意写错的版本
    end)
```

重新跑一遍 §4，日志应该变成：

```text
  [FAIL] SDK 版本是 0.6.0 : ...: got 0.6.0
 Results: 2 passed, 1 failed, 3 total
```

看到 `1 failed` 就说明整条链路（打包 → DLL 加载 → Lua 执行 → 日志）是通的，失败也能被如实上报。改回去，再做下一步。

---

## 6. 如果失败：先看这张表

| 现象 | 最可能的原因 | 处置 |
|---|---|---|
| deploy 打印 `WARNING: No log content read` 或 `Timed out after Ns`，`C:\ProgramData\japi_debug.txt` **不存在**（或 0 字节） | 有另一个 war3.exe 实例在跑（1.27a 单实例锁）：进程起来了但没进地图，DLL 从未加载，所以整份日志从头就不会产生。**这不是断言失败，也不是 SDK 有问题。** | `Get-Process war3`；有就全部关掉，再重跑 deploy |
| war3 弹 `unable to initialize` 之类的错误 | 同上：另一个实例占用 / 启动资源不可用 | 关掉所有 war3 实例，确认没有残留进程后重试 |
| 日志有内容，但没有 `Results:` 行 | 脚本没跑到 `finish()`：timer 被销毁、报错中断，或者你设的延时比 `-Timeout` 还长 | 看日志最后几行；确认 `after(1.0, ...)` 的秒数 < `-Timeout`；给 `runtime.error_handle` 装个打印 |
| 日志里中文是乱码 | 控制台按 936 代码页解码 UTF-8 日志 | `Get-Content ... -Encoding UTF8`（§4.2） |
| pack 报 `JASS syntax check failed: <file>` | 你在地图 JASS 里加了 `native` 声明，位置或名字不对 | 声明必须在**第一个函数之前**，且名字必须已存在于引擎 native 表；细节见 [docs/planning/JASS-NATIVE-DECLARATIONS.md](../planning/JASS-NATIVE-DECLARATIONS.md)。只想验证自己的 Lua 时，打包加 `-SkipJassCheck` |
| 游戏直接回主菜单，日志一行都没有 | 同上：非法 native 声明（最常见），或声明写在函数之后 | 删掉你自己加的声明，改用 Lua 侧 `japi()` 注册 + JASS 侧 `UnitId` 桥（[SDK-COOKBOOK.md](SDK-COOKBOOK.md) 配方 9） |
| 日志里 `module 'xxx' not found` | 你的 `require` 没被内联：不是顶格写、或用了单引号 | 改成行首 `require "lib.xxx"`（双引号），重新打包；用 `-RequireReport`/`-StrictRequires` 在打包期定位 |
| 全局数组读出来是 `nil`、`#arr` 是 `0` | 你在脚本加载期碰了数组全局：那一刻数组还没预分配，元素读 `nil`、写被静默丢弃（同一时刻**标量**全局完全正常） | 把数组 I/O 挪进一次性 `TimerStart(timer, 1.0, false, ...)`；时序规则见 [SDK-GUIDE.md](SDK-GUIDE.md) 第 2 节的「时序」小节 |
| `sleep` 流程跑不完 / 阶段被重置回开头 | 多段 `sleep` 串联不可靠（同一形态一次 3.5 s 跑完、另一次 15 s 没恢复），action 还会被从头重入（某次 3.8 s 内进 6 次，每次把 `state.stage` 重置回 1） | 一个 action 只 `sleep` 一次、进度写状态字段、多段用 timer 链；**不要**加一次性守卫（实测加了之后流程永不恢复，15 s 不动）。见 [SDK-GUIDE.md](SDK-GUIDE.md) 第 7 节「实测」 |
| 键盘/鼠标 hook 收不到事件（或 `d3d` 订阅没反应） | **War3 窗口不在前台**：输入过滤器挂在游戏自己的消息分发上，窗口失焦时一个事件都不会来。这是环境限制，不是 SDK 故障 | 用鼠标点一下游戏窗口让它变成前台窗口；无人值守时用 `-Hold` + `tools\drive-interactive-d3d.ps1` 驱动（它自己会把窗口抬到前台）。语义见 [SDK-GUIDE.md](SDK-GUIDE.md) 第 5 节 |
| `d3d.is_available()` 返回 false | 未运行在 D3D9 模式（例如 `-opengl`）或未加载 D3D9 | 正常 D3D9 模式下 0.5.0 支持零重启自动激活，也可用 `japi proxy --install` 预装代理；注意 `d3d.version()` 仍会返回 0.5.0，**不能**用它判断可用性 |
| pack 报 `w3x2lni obj failed` | `tools\w3x2lni\bin\*.dll` 缺失（被 .gitignore 忽略） | 从主 checkout 复制这些 DLL 过来 |
| 打包/部署结果时好时坏 | 多人/多任务共用 `-WorkDir` 或默认 `build\work` | 每次给独立的 `-WorkDir` 和 `-OutFile` |

---

## 7. 下一步

| 想做的事 | 去看 |
|---|---|
| 每个 `jass.*` 模块的完整语义、坑、生命周期 | [SDK-GUIDE.md](SDK-GUIDE.md) |
| 12 个可直接抄的配方（HUD、热键、施法、SLK、JASS 桥、hook、sleep） | [SDK-COOKBOOK.md](SDK-COOKBOOK.md) |
| 现成的 10 个示例地图 | `examples\01-hello-jass` … `examples\10-getfunc-addr`（每个目录一个可直接打包的工程，`war3map.lua` 头部注释写了预期日志） |
| D3D 渲染的完整 API | [D3D-LUA-API.md](D3D-LUA-API.md)、[D3D-LUA-QUICKSTART.md](D3D-LUA-QUICKSTART.md) |
| 版本历史 / 发布流程 | [../../CHANGELOG.md](../../CHANGELOG.md)、[../RELEASE.md](../RELEASE.md) |
| 当前完成度与验证强度（唯一权威） | [../STATUS.md](../STATUS.md) |
| 新建工程的脚手架 | `tools\new-project.ps1 -Name <名字> -Path <目录>`（生成 `war3map.lua` / `lib/` / `tests/` / `base-map/` / README） |

> 本文只写实机验证过的事实；发现与你的环境不符时，以 `docs/STATUS.md` 和源码为准，并请提 issue。

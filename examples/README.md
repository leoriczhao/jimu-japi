# examples —— 可运行示例集

> 2026-11-18 增补：当前清单共 12 例，静态+打包 `12/12` 通过；本轮新增物编例 11 实机 `4/4`、UI 例 12 实机 `3/3`，联合 `-Live` 命令 exit 0。下方 2026-11-16 的 10 例记录保留其历史口径，不代表本轮把旧例全部重新实机运行。

> 日期：2026-11-16 ｜ 适用 SDK：本仓库 `src\build\bin\Release\yd_japi.dll`（SHA-256 `87C83BA1CE0E6E413CEA7B9D6018E9A289259EC9C2F01EE02E7827DAF6661908`，547328 字节）
> 验证状态：`tools\verify-examples.ps1` 静态 + 打包 **10/10 通过**（静态里含 `luac -p` Lua 语法检查，见「Lua 语法检查」一节）；`-Live` **10 个示例全部实机 `0 failed`**（2026-11-16，同一 DLL，分两批：03:20/03:27 那批 9 个、03:48 那批含 05 的 6 个）。01/08/09/10 与 05 因另一会话占用 war3 单实例锁和共享日志，没能在同一批里跑完（原因见下文「-Live 撞车」）；**逐例数字在各示例 README 的「已验证 / 未验证」表里**，不在这里重复。**未跑过的项一律不在这里声明通过。**
> 端到端实机证据（2026-11-16，lead 实测，同一 DLL）：「脚手架生成的工程」用 `-MapDir build\scratch\proj\MyMap` 进游戏跑出 ` Results: 9 passed, 0 failed, 9 total (0 skipped)` 与 `ALL CHECKS PASSED (9/9)`，说明 `deploy.ps1 -MapDir` → 打包 → 启动 → 日志这条链路在本 SDK 上可用；本目录示例的逐条 `-Live` 结果见各示例 README 的「已验证 / 未验证」表。

每个示例都是一个完整的小地图工程，可以用 `tools\pack.ps1 -MapDir examples\<示例>` 打包，也可以复制整个目录作为自己的项目骨架。01–10 的入口是单文件；11 另带构建专用的 `objects.lua`；12 自带可复用的 `lib/ui.lua`，这两例要连同附属文件一起复制。

第二批入口见 [代码化物编与 UI 指南](../docs/guide/OBJECT-DATA-UI.md)。示例 12 的 `-Live` 会自动启动真实窗口输入驱动，进行禁用点击、启用点击、窗口 resize 和新位置点击；不要在验证期间另外操作游戏。

## 示例索引

| 编号 | 示例 | 用到的模块 | 是否需要 D3D | 额外 pack 开关 | 一行说明 |
|------|------|-----------|-------------|---------------|----------|
| 01 | [01-hello-jass](01-hello-jass/README.md) | `jass.common` | 否 | 无 | 读玩家名/句柄，证明 `jass.<native>()` 与 `jass.call()` 等价 |
| 02 | [02-input-hook](02-input-hook/README.md) | `jass.common` `jass.hook` `jass.message` | 否 | 无 | 接管一个 native，并安装键鼠输入回调 |
| 03 | [03-d3d-hud](03-d3d-hud/README.md) | `jass.common` `jass.d3d` | **是** | 无（需 d3d9 proxy） | BLP 底板 + 一行文字，0.1s timer 每帧 `set_text` |
| 04 | [04-create-unit-order](04-create-unit-order/README.md) | `jass.common` | 否 | 无 | 造原生步兵、补满血、下 move 点命令并确认真的动了 |
| 05 | [05-sleep-sequence](05-sleep-sequence/README.md) | `jass.common` `jass.runtime` `jass.sleep` | 否 | 无 | trigger action 里用 `sleep()` 写线性开场流程 |
| 06 | [06-globals](06-globals/README.md) | `jass.common` `jass.globals` | 否 | 无 | Lua 直接读写 `udg_` 标量、整型数组、字符串数组 |
| 07 | [07-slk](07-slk/README.md) | `jass.common` `jass.slk` | 否 | 无 | 按 id 查技能/单位等 SLK 行，替代手写 if |
| 08 | [08-d3d-subscription](08-d3d-subscription/README.md) | `jass.common` `jass.d3d` | **是** | 无（需 d3d9 proxy） | hit_test 面板 + click 订阅 + 订阅生命周期/计数 |
| 09 | [09-jass-wrappers](09-jass-wrappers/README.md) | `jass.common` `jass.globals` | 否 | `-WithJassWrappers` | JASS wrapper 与 Lua bridge 两条路径调同一个 native，结果对比 |
| 10 | [10-getfunc-addr](10-getfunc-addr/README.md) | `jass.common` `jass.globals` `jass.debug` | 否 | `-WithGetFuncAddr` | 把 `code` 参数转成整数地址，反查绑定标签并当 `TriggerAddAction` 用 |
| 11 | [11-object-data](11-object-data/README.md) | `jass.common` `jass.slk` | 否 | 自动发现 `objects.lua` | 构建单位与三级技能，再在游戏里核对创建、等级和 SLK |
| 12 | [12-ui-components](12-ui-components/README.md) | `jass.common` `jass.d3d` + 自带 `lib.ui` | **是** | 无 | 按钮状态、嵌套布局、真实点击与 resize、资源回收 |

## 每个示例的固定结构

`war3map.lua` 里用两条注释把文件切成三段，贴走的时候一眼能看出哪些要带、哪些能删：

```lua
-- (A) 头注释：编号 / 用途 / 需要的开关 / 预期日志 / 验证状态
-- ============ 以下这段可以粘进自己的 war3map.lua ============
--     (B) 真正的功能代码：require "jass.*" 或本示例自带模块，不跨示例目录 require
-- ============ 以下为示例自检，粘到自己地图时可以删掉 ============
--     (C) 内联自检 harness + 收尾 timer
```

约定的输出格式（与 `map\game\demo.lua` 一致，脚本可以统一解析）：

```text
  [PASS] 检查项名字
  [FAIL] 检查项名字 : 失败原因
========================================
 Results: 5 passed, 0 failed, 5 total
========================================
```

- 大部分旧示例在约 3.8 秒收尾；物编例在延迟初始化后验证，UI 组件例必须等待真实输入与 resize 完成。结果汇总只能在对应工作结束后输出。
- `deploy.ps1` 的成功判定正则就是 `Results:.*total`，所以这一行必须**只有一条**、且 `failed` 必须为 0。
- 健康环境下 `failed == 0` 且 `total >= 3`；`verify-examples.ps1` 就是按这个判定的。

## 怎么跑一个示例

**1）先做静态检查（不启动游戏，几十秒）**

```powershell
# 只检查 01（-Filter 是正则，匹配 manifest 里的 id）
.\tools\verify-examples.ps1 -Filter 01
```

> 这一步会顺带用 `luac -p` 查 Lua 语法（找得到 luac 才查；没有就打一行 `[skip]`，见下文「Lua 语法检查」）。

**2）打包成一个 w3x（不动 build\work、不动 build\output.w3x）**

```powershell
.\tools\pack.ps1 -MapDir examples\01-hello-jass `
    -WorkDir build\scratch\ex-01\work `
    -OutFile build\scratch\ex-01\out.w3x
```

> `pack.ps1` 会：复制 `reference\empty-map` 基座 → 把 `examples\01-hello-jass` 下所有 `*.lua` 内联成
> `war3map.lua`（模块名按相对路径推导）→ 往 `war3map.j` 里插 bootstrap → 注入 `yd_japi.dll`（改名 `japi.tga`）
> → 用 w3x2lni 打包。**不需要**手动改 `war3map.j`。

**3）进游戏看日志**

```powershell
# 启动 War3、等 Results 行、打印日志尾、然后关掉 War3
.\tools\deploy.ps1 -MapDir examples\01-hello-jass -MapName vx-01.w3x
```

- 部署位置：`<War3Dir>\Maps\Test\vx-01.w3x`（`War3Dir` 由 `deploy.ps1` 内部固定）。
- 日志：`C:\ProgramData\japi_debug.txt`；如果该文件被占用，DLL 会退化成
  `C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。
- **中文乱码**：日志是 UTF-8，而 PowerShell 5.1 的 `Get-Content` 默认按 GBK 解码，所以自己看日志要写
  `Get-Content C:\ProgramData\japi_debug.txt -Encoding UTF8`（否则 `[PASS]` 后面的中文会变成 `宸插姞杞斤` 这种）。
  `deploy.ps1` 从 2026-11-16 起也改成 `-Encoding UTF8`，因此它的控制台输出和
  `build\verify-examples\<id>.log` 里的中文是正常的 —— 只有 03:45 之前生成的老日志是乱码。
- `deploy.ps1` 没有 `-OutFile` 参数，`-MapDir` 的打包结果固定写 `build\output.w3x`，
  **所以同一时刻只能有一个人在跑 deploy**。

**4）D3D 示例（03、08）要多做一步**

`deploy.ps1` 只有在 `-InteractiveD3D` / `-Demo` / `-TestReboot` 模式下才会安装并校验
`d3d9.dll` proxy；普通 `-MapDir` 跑法不会。所以先自己装一次：

```powershell
# War3 必须完全退出（脚本会检查）；-Install 这一步要求 D3DX9_42.dll 就在 War3 目录里
.\tools\d3d-proxy.ps1 -Install -War3Dir 'D:\Warcraft III Frozen Throne 1.27a publish'

# 然后照常 deploy，游戏进程里就会加载 proxy，d3d.is_available() 才为真
.\tools\deploy.ps1 -MapDir examples\03-d3d-hud -MapName vx-03.w3x
```

> 示例 03/08 里如果 `d3d.is_available()` 一直是假，会打一条 `[FAIL]`，message 里就是上面这两条命令。
> 用完想恢复原状：`.\tools\d3d-proxy.ps1 -Uninstall -War3Dir ...`。

**代理装没装好，看 sidecar 哈希，别只看 `-Verify`**（2026-11-16 实机确认）

| 判断方式 | 依据 | 现状 |
|---|---|---|
| 真正的判据（ownership） | 游戏目录 `d3d9.dll` 的 SHA256 == `.japi_d3d_proxy.sha256` 里记的值；同目录还有 `japi_d3d_visual_probe.bmp` + `.japi_d3d_probe.sha256` | 代理归谁所有由 sidecar 哈希证明，跟 `-Verify` 是否成功无关 |
| `-Verify` | 除哈希外还要求 `D3DX9_42.dll` 在 **war3.exe 旁边**，否则直接报 `D3DX9_42.dll is required: <War3Dir>\D3DX9_42.dll` | 本机 `D3DX9_42.dll` 在 `C:\Windows\SysWOW64`（Windows 加载器能找到，游戏照常跑），游戏目录没有 → **代理明明是好的，`-Verify` 也会失败** |
| `-Install` | 同样要求 `D3DX9_42.dll` 在 War3 目录，且 War3 必须已经退出 | 所以装好的机器别重复 `-Install`，会被拒（`War3 is running ...` 或 `D3DX9_42.dll is required ...`）|

```powershell
# 手查代理是否已装好（不需要 -Verify）
$dir = 'D:\Warcraft III Frozen Throne 1.27a publish'
(Get-FileHash "$dir\d3d9.dll" -Algorithm SHA256).Hash   # 应与下一行输出一致
Get-Content "$dir\.japi_d3d_proxy.sha256"
```

`tools\verify-examples.ps1 -Live` 就按这个现实来：**只有游戏目录里没有 `d3d9.dll`、或它的哈希与 sidecar 不一致时才 `-Install`**；一致就直接跳过，打印 `[ok] d3d9 proxy already installed in <dir> (sidecar hash agrees); leaving it alone`。装完之后如果 `-Verify` 因缺 `D3DX9_42.dll` 报错，只打一条 `[warn]` 然后继续，不判示例失败。

**5）opt-in 示例（09、10）必须带开关**

```powershell
# 09：要 -WithJassWrappers（deploy 会把同名开关透给 pack）
.\tools\deploy.ps1 -MapDir examples\09-jass-wrappers -MapName vx-09.w3x -WithJassWrappers

# 10：要 -WithGetFuncAddr
.\tools\deploy.ps1 -MapDir examples\10-getfunc-addr -MapName vx-10.w3x -WithGetFuncAddr
```

不带开关跑这两个示例，第一个自检项就会失败并明确告诉你少了哪个开关。

## 怎么验证全部

```powershell
# 默认：文件结构 + Results 格式 + 逐个打包，不启动游戏
.\tools\verify-examples.ps1

# 再进游戏实跑一遍（串行，一个一个来）
.\tools\verify-examples.ps1 -Live

# 只跑一部分（正则匹配 id），例如只跑 D3D 和 opt-in 示例
.\tools\verify-examples.ps1 -Live -Filter '03|08|09|10'
```

| 参数 | 作用 |
|------|------|
| `-Filter <正则>` | 只处理 id 匹配的示例（`'0[1-5]'`、`'d3d'` 都行） |
| `-Live` | 额外逐个 `deploy.ps1` 进游戏，解析日志里最后一条 `Results:` 行 |
| `-SkipPack` | 只做静态检查，不打包（快） |
| `-Timeout 120` | 单次进游戏等 Results 的超时秒数（默认 120） |
| `-KeepWork` | 保留 `build\scratch\ex-<id>\`（默认跑完删掉） |
| `-War3Dir <路径>` | `-Live` 且选中 D3D 示例时用来校验/安装 d3d 代理；不传依次找 `tools\config.local.ps1` → `tools\deploy.ps1` 的默认游戏目录（存在才用），都没有才报错 |

输出是一张表 + 最后一行：

```text
Example                          D3D    Static Pack   Live   Note
01-hello-jass                    no     ok     ok     ok
...
Examples: 10 passed, 0 failed, 10 total
```

规则：

- 默认模式：静态 OK 且打包 OK 才算 passed（`-SkipPack` 时只看静态）。
- `-Live`：再要求日志里最后一条 `Results:` 行 **failed == 0 且 total >= 3**。
- 任何一项失败 → 退出码 **1**；全绿 → 退出码 0。
- `-Live` 是**串行**的：每次开跑前都断言没有 `war3.exe` 在跑；发现就有明确的报错并中止，
  绝不在别人的 deploy 跑着的时候插一脚（一个游戏实例、一份共享日志）。
- `-Live` 还需要**环境独占**：不只是本脚本串行，而是**整台机器上不能有别的 deploy / 地图在跑**。
  日志和地图目录都是全机共享的。

**-Live 撞车（2026-11-16 实机踩到）**

`verify-examples.ps1 -Live` 和任何别的 `deploy.ps1` 会话共用两样东西：
`C:\ProgramData\japi_debug.txt`（含 `_<pid>` 退化文件）和 `<War3Dir>\Maps\Test\`。两边同时跑的结果：

| 症状 | 真正原因 | 怎么办 |
|------|----------|--------|
| `[live] no fresh Results line`，但该示例日志里 `[PASS]` 都在、就是没有 `Results` 行 | 另一方 deploy 启动时 `Remove-Item C:\ProgramData\japi_debug.txt` 把文件删了再重建；我们的 war3 已把 `[PASS]` 写进旧文件，3.8s 后把 `Results` 写进**已被 unlink 的旧句柄**（写进虚空），而轮询看的是新文件 | 等对方跑完，重跑该示例；不是示例的 bug |
| `[live] war3.exe is already running (PID: …)`，后续示例直接 skipped | 1.27a 有单实例锁，另一方的 war3 还在；我们的保护性断言拒绝开跑 | 等对方结束（**不要杀进程**），或换机器/换时段 |
| 结果表里同时出现别人的 `Maps\Test\output.w3x` 被改写 | 两边的 `-MapDir` 打包都写 `build\output.w3x`、部署都落 `Maps\Test\` | 同上，串行跑 |

**开跑前自己确认一次**（两条命令都为「干净」才开）：

```powershell
Get-Process war3 -ErrorAction SilentlyContinue        # 应该没有输出
Get-ChildItem 'C:\ProgramData\japi_debug*.txt' | Select-Object Name, LastWriteTime, Length   # mtime 应该不是刚刚
```

撞车的两个症状一律**不要**当成示例失败去改代码：先确认环境干净，再重跑一次。

**Lua 语法检查（luac，可选但强烈建议）**

`verify-examples.ps1` 的静态检查里多了一条 Lua 语法检查：只要找得到 `luac`，就对每个
`examples\<dir>\war3map.lua` 跑一次 `luac -p`（只解析，不生成字节码）。

| 情况 | 行为 |
|------|------|
| 找到 luac | 先打印 `  luac: <路径>`，再逐个解析 |
| 语法错误 | 该示例 `[static] fail`，并把 luac 原文打进日志，例如 `[static] luac -p failed: examples\06-globals\war3map.lua:119: unexpected symbol near <eof>` |
| 找不到 luac | **不算失败**，只打一行 `  [skip] luac not found - see tools\build-luac.ps1 for a one-shot build`，其它检查照跑 |

查找顺序：`$env:LUAC` → `build\scratch\luac\luac.exe` → PATH 里的 `luac` / `luac5.4`。

为什么需要它：`pjass` 只查 `war3map.j`，上面的结构性检查也看不到 Lua chunk 编不过；而 `pack.ps1` 会照常把坏 chunk
打进地图，实机表现只是「没有 Results 行」，很难定位。2026-11-16 就用它抓到过三处漏写的 `)`。

本机默认没有 luac，用仓库自带的 Lua 5.4 源码编一个（几秒钟，只写 `build\scratch\luac\`）：

```powershell
# 已存在时直接跳过；-Force 强制重编
.\tools\build-luac.ps1

# gcc 查找顺序：$env:CC → PATH 里的 gcc.exe → D:\qt\Tools\mingw810_64\bin\gcc.exe
# 源码：src\vendor\lua-5.4\src（除 lua.c 外全部 *.c）；产物：build\scratch\luac\luac.exe
```

## 怎么把示例贴进自己的地图

1. **拿三段里的中间那段。** 从 `-- ============ 以下这段可以粘进自己的 war3map.lua ============`
   到 `-- ============ 以下为示例自检 ... ============` 之间的代码就是给地图作者的；
   自检段可以直接删掉（删了就没有 `Results` 行，别再用 deploy 等结果）。
2. **`require` 必须写在行首。** `pack.ps1` 只内联行首的 `require "..."`
   （正则 `^(local\s+\w+\s*=\s*)?require\s+"..."`）；缩进过的 require 不会被内联。
3. **自己项目里可以有 `lib\`。** 打包时模块名由相对路径推导（`lib\util.lua` → `require "lib.util"`），
   但示例本身刻意不跨目录，就是为了保证"复制一个目录就能跑"。
4. **入口文件名固定是 `war3map.lua`。** `-MapDir` 打包时它就是地图入口脚本。
5. **别把自检的 `print` 格式改坏。** 如果你保留自检段，收尾必须只有一条
   ` Results: %d passed, %d failed, %d total`，否则 `deploy.ps1`/`verify-examples.ps1` 解析不到。
6. **想要脚手架而不是复制示例**：把 `examples\NN-<名字>\` 整个目录复制成自己的项目目录即可，
   里面没有硬编码路径，`pack.ps1 -MapDir <你的目录>` 就能打包。

## 通用坑（先看这里）

这些都是 2026-11-16 在 1.27a 上实测踩到、并且已经写进对应示例注释里的坑。贴到自己地图里第一次跑之前，照着扫一遍。

| 坑 | 现象 | 正确做法 |
|----|------|----------|
| `require` 没写在行首 | 打包没报错，进游戏却提示模块找不到 | 每行 `require "jass.xxx"` 都从第 0 列开始（`local x = require "..."` 也可以，但 `require` 前面不能有缩进）；见 01 |
| 加载阶段读写 JASS **数组**全局 | 不报错，但写入的值丢了、`#arr == 0` | 数组全局要等地图初始化（约 1.0s）再读写；标量全局没有这个限制。见 06 的「代码要点」 |
| 在 timer 回调里 `sleep()` | 直接报错（底层 `TriggerSleepAction` 只能恢复 trigger 线程） | 把流程放进 `CreateTrigger` + `TriggerAddAction` 的 action 线程；见 05 |
| 以为 `sleep(x)` 精确等 x 秒 | 实际是「至少 x 秒」：实测区间 **0.3s–1.1s**（恢复本身 0.3–0.43s；从第一次进入算起的墙钟含重入会到 1.1s） | 线性流程用 `sleep`，**精确定时用 `TimerStart`**；见 05 |
| 多段 `sleep()` 串联写线性流程 | 同一套 DLL 上一种写法能通、另一种写法整条链不恢复（探针 p3 通、p7 挂） | **只睡一次**；多步编排用 timer 链（`TimerStart` 里再 `TimerStart`），见 05 的「代码要点」 |
| `trigger` 的 action 被重复进入（一次性 timer 事件也会） | 状态被打回初值，看起来像「流程卡住」 | **千万不要加「已运行就 return」的守卫**：续跑依赖 action 被重新进入，加了守卫第一段能过、第二段 15s 再也不回来（探针 p6 实测）。用 `stage` 字段标记进度、进入次数打进日志；见 05 |
| 留下「yield 后永不 resume」的协程 | 单独**不致命**（探针 p4/p5 里带悬挂协程照样跑到 stage 3），但会占用续跑映射，排查时只会添噪声 | 别为了写自检造悬挂协程；协程要么跑到结束，要么别造。见 05 |
| 自检里 `Results` 行出现多次 | `deploy.ps1` / `verify-examples.ps1` 解析到错的那条 | 整个 chunk 里只保留一处 `print(string.format(" Results: %d passed, %d failed, %d total", ...))`；见各示例 C 段 |
| 用 `d3d.*` 但没装 D3D 代理 | `d3d.is_available()` 为 false，示例会给出安装命令 | 先 `tools\d3d-proxy.ps1 -Install`，并用 `deploy.ps1 -InteractiveD3D/-Demo/-TestReboot` 启动；见 03 / 08 |
| `stats().subscriptions()` 之类多写括号 | `attempt to call a number value (field 'subscriptions')` | `d3d.stats()` 的字段是**值**不是方法（`textures`/`texts`/`subscriptions`）；见 08 |

## 关于"无人值守"

示例全部**不需要真人输入**就能通过：

- 02 只验证"输入回调装上了、能被 msg 表调用"；真正的按键事件只有真人按才会到（README 里写明）。
- 08 只验证订阅的建立/参数校验/计数/失效；**Lua 侧没有伪造鼠标点击的接口**，
  所以不假装模拟点击，也不写"必须有人点一下"的自检项。
- 05 的 `sleep` 用 trigger action + 采样 timer 自证，不依赖任何输入。
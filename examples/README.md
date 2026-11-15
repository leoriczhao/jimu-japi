# examples —— 可运行示例集

> 日期：2026-11-16 ｜ 适用 SDK：本仓库 `src\build\bin\Release\yd_japi.dll`（SHA-256 `87C83BA1CE0E6E413CEA7B9D6018E9A289259EC9C2F01EE02E7827DAF6661908`，547328 字节）
> 验证状态：`tools\verify-examples.ps1` 静态 + 打包 **10/10 通过**；进游戏（`-Live`）由发布流程串行跑，结果写进 `docs\RELEASE.md` 的发布记录。**未跑过的项一律不在这里声明通过。**
> 端到端实机证据（2026-11-16，lead 实测，同一 DLL）：「脚手架生成的工程」用 `-MapDir build\scratch\proj\MyMap` 进游戏跑出 ` Results: 9 passed, 0 failed, 9 total (0 skipped)` 与 `ALL CHECKS PASSED (9/9)`，说明 `deploy.ps1 -MapDir` → 打包 → 启动 → 日志这条链路在本 SDK 上可用；本目录示例的逐条 `-Live` 结果以此后发布记录为准。

每个示例都是一个完整的小地图工程：一个目录、一个 `war3map.lua`，没有 `lib\` 依赖，
可以被 `tools\pack.ps1 -MapDir examples\<示例>` 直接打包，也可以整个目录复制走当自己的项目骨架。

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

## 每个示例的固定结构

`war3map.lua` 里用两条注释把文件切成三段，贴走的时候一眼能看出哪些要带、哪些能删：

```lua
-- (A) 头注释：编号 / 用途 / 需要的开关 / 预期日志 / 验证状态
-- ============ 以下这段可以粘进自己的 war3map.lua ============
--     (B) 真正的功能代码：只 require "jass.*"，不依赖 lib，不跨目录 require
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

- `Results` 行由收尾 timer 在 **3.5~4.5s**（各示例实际是 3.8s）打出，之前所有异步工作必须完成。
- `deploy.ps1` 的成功判定正则就是 `Results:.*total`，所以这一行必须**只有一条**、且 `failed` 必须为 0。
- 健康环境下 `failed == 0` 且 `total >= 3`；`verify-examples.ps1` 就是按这个判定的。

## 怎么跑一个示例

**1）先做静态检查（不启动游戏，几十秒）**

```powershell
# 只检查 01（-Filter 是正则，匹配 manifest 里的 id）
.\tools\verify-examples.ps1 -Filter 01
```

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
- `deploy.ps1` 没有 `-OutFile` 参数，`-MapDir` 的打包结果固定写 `build\output.w3x`，
  **所以同一时刻只能有一个人在跑 deploy**。

**4）D3D 示例（03、08）要多做一步**

`deploy.ps1` 只有在 `-InteractiveD3D` / `-Demo` / `-TestReboot` 模式下才会安装并校验
`d3d9.dll` proxy；普通 `-MapDir` 跑法不会。所以先自己装一次：

```powershell
# 需要 War3 完全退出（脚本会检查），并且 D3DX9_42.dll 在 War3 目录或 SysWOW64
.\tools\d3d-proxy.ps1 -Install -War3Dir 'D:\Warcraft III Frozen Throne 1.27a publish'

# 然后照常 deploy，游戏进程里就会加载 proxy，d3d.is_available() 才为真
.\tools\deploy.ps1 -MapDir examples\03-d3d-hud -MapName vx-03.w3x
```

> 示例 03/08 里如果 `d3d.is_available()` 一直是假，会打一条 `[FAIL]`，message 里就是上面这两条命令。
> 用完想恢复原状：`.\tools\d3d-proxy.ps1 -Uninstall -War3Dir ...`。

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

## 关于"无人值守"

示例全部**不需要真人输入**就能通过：

- 02 只验证"输入回调装上了、能被 msg 表调用"；真正的按键事件只有真人按才会到（README 里写明）。
- 08 只验证订阅的建立/参数校验/计数/失效；**Lua 侧没有伪造鼠标点击的接口**，
  所以不假装模拟点击，也不写"必须有人点一下"的自检项。
- 05 的 `sleep` 用 trigger action + 采样 timer 自证，不依赖任何输入。

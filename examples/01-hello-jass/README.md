# 01 最小可运行示例：调用 JASS native

> 日期：2026-11-16 ｜ 模块：`jass.common` ｜ 额外开关：无 ｜ D3D：不需要 ｜ 入口：`war3map.lua`

## 用途

- 证明三件事：DLL 注入成功、`jass.common` 能 require、`jass.<native>()` 真的调到了游戏引擎。
- 顺便演示两种等价写法：`jass.GetPlayerId(p)`（元表自动分发）和 `jass.call("GetPlayerId", p)`（显式调用）。
- 这是排查"DLL 到底进没进游戏"时第一个该跑的示例。

## 怎么跑

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 01

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\01-hello-jass `
    -WorkDir build\scratch\ex-01\work `
    -OutFile build\scratch\ex-01\out.w3x

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\01-hello-jass -MapName vx-undefined.w3x
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 01] ...
  [PASS] jass.common 已加载且 jass.call 可用
  [PASS] GetLocalPlayer 返回可用句柄
  [PASS] 元表调用与 jass.call 等价
  [PASS] GetPlayerName 返回非空字符串
  [PASS] Player(id) 指回同一个玩家的句柄
========================================
 Results: 5 passed, 0 failed, 5 total
========================================
```

- 健康环境 **5 passed / 0 failed / 5 total**。

## 代码要点

- `local jass = require "jass.common"` —— 只有这一行依赖，没有 `lib\`，没有跨目录 require。
- `jass.common` 的元表把**任何**没定义的字段名变成一次 native 调用，所以不需要为每个 native 写包装函数。
- `jass.GetLocalPlayer()` 返回句柄；句柄用 `jass.GetHandleId()` 取整数，Lua 侧不要自己算。
- `jass.Player(jass.GetPlayerId(p))` 必须指回同一个玩家的句柄 —— 这一条同时验证了句柄编解码没有错位。

## 三段结构

- **(A) 头注释**：编号 / 用途 / 需要的开关 / 预期日志 / 验证状态。
- **(B) 可粘贴段**：`-- ============ 以下这段可以粘进自己的 war3map.lua ============` 之后是真正的功能代码，
  只有 `require "jass.*"`，不依赖 `lib\`，不跨目录 require。
- **(C) 自检段**：`-- ============ 以下为示例自检，粘到自己地图时可以删掉 ============` 之后是内联的
  `check` / `finish` harness 和 `3.8s` 的收尾 timer。删掉就没有 `Results` 行了。

## 已验证 / 未验证

| 项 | 状态 |
|----|------|
| 文件结构、`Results` 格式（恰好一行、可被 `Results:.*total` 解析） | **已验证**：`tools\verify-examples.ps1` 静态检查通过 |
| 用到的 `jass.*` 模块全部可 `require`、API 调用在仓库内有出处 | **已验证**：逐个符号在 `map\` / `docs\guide\` / `src\` 里检索到 |
| `-MapDir` 打包产出非平凡 w3x | **已验证**：`tools\verify-examples.ps1` 打包通过 |
| 游戏内 `0 failed` 的实跑结果 | **未验证（本文件写作时）**：由 `tools\verify-examples.ps1 -Live` 串行跑，结果记到 `docs\RELEASE.md` 的发布记录 |

风险与注意事项：

- `jass.GetPlayerName` 在 `map\` 里没有现成调用点（它是 common.j 标准 native，靠元表分发，风险低）。
- 若玩家名是空字符串（极少数改过名的环境）第四项会 FAIL —— 这属于环境问题，不是 SDK 问题。

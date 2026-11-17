# 04 造单位 + 下命令

> 日期：2026-11-16 ｜ 模块：`jass.common` ｜ 额外开关：无 ｜ D3D：不需要 ｜ 入口：`war3map.lua`

## 用途

- 一个空地图上最常见的第一步：造个单位、补满血、让它走起来。
- 演示 rawcode（`hfoo` = 原生步兵）、`fourcc` 换算、点命令、以及"命令到底有没有生效"的判定方法。

## 怎么跑

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 04

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\04-create-unit-order `
    -WorkDir build\scratch\ex-04\work `
    -OutFile build\scratch\ex-04\out.w3x

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\04-create-unit-order -MapName vx-04-create-unit-order.w3x
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 04] ...
  [PASS] CreateUnit 造出可用单位句柄
  [PASS] 单位类型与 rawcode 一致
  [PASS] SetWidgetLife 按最大生命补满
  [PASS] move 点命令被接受并成为当前命令
  [PASS] 单位确实向目标点移动
========================================
 Results: 5 passed, 0 failed, 5 total
========================================
```

- 健康环境 **5 passed / 0 failed / 5 total**。

## 代码要点

- `fourcc("hfoo")` 把 4 个字符压成整数 rawcode：`local a,b,c,d = s:byte(1,4) return ((a*256+b)*256+c)*256+d`。
- 出生点用 `jass.GetPlayerStartLocationX/Y`，别写死坐标（示例地图起点是 `-715.4, 615.2`）。
- 造完先 `SetWidgetLife(u, GetUnitState(u, ConvertUnitState(1)))` 补满；`ConvertUnitState(0/1/2/3)` = 当前生命/最大生命/当前魔法/最大魔法。
- `jass.OrderId("move")` 把命令名转成整数；`IssuePointOrderById(u, order_id, x, y)` 下点命令。
- 判定命令生效：`GetUnitCurrentOrder(u)` 等于刚下的 `order_id`，并且位置真的变了（示例用 `> 32` 的位移阈值）。
- 收尾 `jass.RemoveUnit(u)`，别在地图里留垃圾。

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
| 游戏内 `0 failed` 的实跑结果 | **已验证**：2026-11-16 `tools\verify-examples.ps1 -Live` 实机跑出 `Results: 5 passed, 0 failed, 5 total`（DLL `87C83BA1…`，deploy 参数 `-Timeout 120`） |

风险与注意事项：

- **`jass.IssuePointOrderById` 在 `map\` 里没有调用点**（仓库里点命令走的是 `message.order_point`）；它是 common.j 标准 native，元表分发能直接调，但它是本示例里唯一没有仓库内先例的调用。
- 位移断言依赖"起点周围是空地"：初始 1 秒内如果被别的单位/建筑卡住，位移可能不足 32 而 FAIL。示例用 `GetPlayerStartLocationX + 512` 选目标点，正常情况下不会撞上。
- `hfoo` 是游戏原生单位（不是 `reference\empty-map\war3map.w3u.ini` 里定义的 `Hrif`），1.27a 一定存在。
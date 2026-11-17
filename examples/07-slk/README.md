# 07 查游戏数据表（SLK）

> 日期：2026-11-16 ｜ 模块：`jass.common` `jass.slk` ｜ 额外开关：无 ｜ D3D：不需要 ｜ 入口：`war3map.lua`

## 用途

- 按 id 直接查游戏数据（技能、单位、物品、buff、科技、可破坏物、装饰物），替代一堆 `if id == 'AHbz' then`。
- 表是**惰性加载**的：第一次访问才解析，之后走缓存 —— 所以查了不亏，但第一次查有开销。

## 怎么跑

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 07

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\07-slk `
    -WorkDir build\scratch\ex-07\work `
    -OutFile build\scratch\ex-07\out.w3x

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\07-slk -MapName vx-07-slk.w3x
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 07] ...
  [PASS] 七张 SLK 表都能取到
  [PASS] ability 行数足够（>= 10 行）
  [PASS] 按 id 取技能行，字段 code 可读
  [PASS] 按 id 取单位行，字段 race 可读
  [PASS] 第二次访问命中缓存（rawget 可见）
========================================
 Results: 5 passed, 0 failed, 5 total
========================================
```

- 健康环境 **5 passed / 0 failed / 5 total**。

## 代码要点

- `local slk = require "jass.slk"`，七张表：`slk.ability` / `slk.unit` / `slk.item` / `slk.buff` / `slk.upgrade` / `slk.destructable` / `slk.doodad`。
- 按 rawcode 取行：`slk.ability["AHbz"].code == "AHbz"`、`slk.unit["hpea"].race == "human"`。
- 行是字段表，字段名跟 SLK 列名一致（`code`、`race`、`class`…），不存在的 key 返回 `nil`。
- 缓存验证：第二次访问后 `rawget(slk, "ability")` 就是缓存住的那张表，且行数 `>= 10`。

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

- 数据来自**本机安装的 1.27a**：换了游戏版本/改了 `war3.mpq` 的机器上，某些字段可能不存在或行数变少。示例只断言"常见行存在 + 行数 >= 10"，已经是很松的阈值。
- 没有做"修改数据"的演示 —— `jass.slk` 是只读查询，改数据要走 native（不在本示例范围）。
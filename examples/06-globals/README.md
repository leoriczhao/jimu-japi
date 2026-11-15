# 06 读写 JASS 全局变量

> 日期：2026-11-16 ｜ 模块：`jass.common` `jass.globals` ｜ 额外开关：无 ｜ D3D：不需要 ｜ 入口：`war3map.lua`

## 用途

- Lua 和 JASS 共享同一批 `udg_` 全局：Lua 写的值，触发器/其他 JASS 代码立刻能看到 —— 拿它当配置表、开关、跨语言状态位。
- 演示标量、整型数组、字符串数组三种最常用的形态。

## 怎么跑

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 06

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\06-globals `
    -WorkDir build\scratch\ex-06\work `
    -OutFile build\scratch\ex-06\out.w3x

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\06-globals -MapName vx-06-globals.w3x
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 06] ...
  [PASS] jass.globals 已加载
  [PASS] 标量全局可写可读
  [PASS] 整型数组元素可写可读
  [PASS] 字符串数组可写可读
  [PASS] 数组被 pack.ps1 预分配为 8192 个槽位
========================================
 Results: 5 passed, 0 failed, 5 total
========================================
```

- 健康环境 **5 passed / 0 failed / 5 total**。
- 时序：这些 `[PASS]` 行不是在加载时打的 —— 数组全局要等地图初始化跑完才有数组块，示例把 `poke_globals()` 放在 **1.0s** 的一次性 timer、检查放在 **1.2s**（详见下面「代码要点」和「风险与注意事项」）。

## 代码要点

- `local globals = require "jass.globals"`；之后 `globals.udg_xxx` 就是那个全局变量，读写都是 `__index`/`__newindex` 转发。
- 数组同理：`globals.udg_lua_test_array[5] = 909`。**不要**把整个数组读出来再改，直接按下标写。
- **数组有时序限制**：`war3map.lua` 顶层（加载阶段）数组块还没分配 —— `#arr == 0`、`arr[i]` 读 `nil`、写进去被静默丢弃；至少要等一个 timer tick（示例用 1.0s）才能读写。标量全局没这个限制，加载时就能用。
- 未写过的槽位读出来不一样：**整型数组**未写槽位读 `0`，**字符串数组**未写槽位读 `nil`（JASS 未初始化 string 是 null handle）。所以字符串数组一定要先写后读。
- `#globals.udg_lua_test_array == 8192`：`pack.ps1` 会给声明的 array 做预分配（`JapiForceAllocArrays`，对每个数组自赋值 `[8191]`），所以高位下标也能直接写。
- 字符串数组 `globals.udg_lua_test_string_array[7] = "abc"`。
- 变量必须在基座地图的 `war3map.j` 里声明过（`reference\empty-map\war3map.j` 已经声明了本示例用的 `udg_lua_test_*`）；自己地图里没有的全局写进去会报错。

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

- 用 `-NoArrayPrealloc` 打包时最后一项一定 FAIL（数组没预分配，`#arr` 也不是 8192）—— 这是预期行为，README 里说明了。
- 数组千万别在加载阶段写：写不会报错，但值会丢（实测 `#arr == 0`、读回 `nil`）。`map\tests\test_suite.lua` 的 globals 用例也是在 1.0s 之后才跑的，原因相同。
- 示例依赖 `reference\empty-map\war3map.j` 里的 `udg_lua_test_*` 声明；把这些示例贴进**别人**的地图时，要在自己的 `war3map.j` 里声明同名全局，或者换用自己的 `udg_` 名字。
# 09 JASS wrapper：JASS 与 Lua 两条调用路径对比

> 日期：2026-11-16 ｜ 模块：`jass.common` `jass.globals` ｜ 额外开关：`-WithJassWrappers` ｜ D3D：不需要 ｜ 入口：`war3map.lua`

## 用途

- `-WithJassWrappers` 会按 C++ 注册表给每个 native 生成 JASS 五步 wrapper（`common.j` 风格的函数声明），**JASS 侧可以直接调**，不必走 Lua。
- 示例把"JASS wrapper 算出来的值"和"Lua 直接调 native 算出来的值"逐项对比，证明两条路径结果一致。

## 怎么跑

> **必须带 `-WithJassWrappers`**：`pack.ps1` 生成 JASS wrapper 并注入一个 `2.00s` 的探针 action（`JapiWrapperProbeActions`），把结果写进 `udg_lua_wrapper_*` 全局；不带开关时这些全局会停在初始值（`-1` / `false`），第一项自检就会 FAIL 并提示加开关。

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 09

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\09-jass-wrappers `
    -WorkDir build\scratch\ex-09\work `
    -OutFile build\scratch\ex-09\out.w3x -WithJassWrappers

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\09-jass-wrappers -MapName vx-09-jass-wrappers.w3x -WithJassWrappers
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 09] ...
  [PASS] JASS wrapper 探针已注入（udg_lua_wrapper_ready == 1）
  [PASS] GetGameVersion：JASS wrapper 与 Lua bridge 结果一致
  [PASS] Hex(255) 在两侧都是 000000FF
  [PASS] GetPluginVersion 两侧一致且非空
  [PASS] GetLittleMapX / SetLittleMapX 的 real 往返
  [PASS] GetChatState 两侧都是 boolean 且一致
========================================
 Results: 6 passed, 0 failed, 6 total
========================================
```

- 健康环境 **6 passed / 0 failed / 6 total**；不带开关时 **0 passed / 1 failed / 1 total**。
- 时序：探针是打包时注入的 **2.00s 一次性 timer**（`tools\pack.ps1:281`），到点才填 `udg_lua_wrapper_*`；示例把全部检查放到 `2.6s` 的一次性 timer 里跑。加载时就检查只会读到 `udg_lua_wrapper_ready = 0`（实测 0/6 passed）。

## 代码要点

- 脚本加载时先写 `globals.udg_lua_japi_alive = 1` —— 探针会先检查这个标志，为 0 就直接返回（这是 avoids 重复初始化的约定）。
- `bridge_call(name, spec, ...)` 是从 Lua 直接调 JASS 函数的通用写法：把参数按顺序 `SaveInteger`/`SaveReal`/`SaveStr`/`SaveBoolean` 进 hashtable 的 slot `i`，`SaveStr(ht, key, 0, spec)` 写类型串，然后 `jass.UnitId(name)` 触发 RPC，最后按返回类型 `LoadInteger`/`LoadReal`/`LoadStr`/`LoadBoolean` 取回。
- 对比项：`GetGameVersion`（整数，JASS == Lua 且 > 0）、`Hex(255)`（字符串，两侧都是 `"000000FF"`）、`GetPluginVersion`（字符串，非空且相等）、`GetLittleMapX`/`SetLittleMapX`（实数往返，误差 `1e-4`）、`GetChatState`（布尔，两侧相等）。
- 实数往返为什么不用 `GetFps`：它是活计数器，两次采样本来就不相等，不能做确定性断言。
- 探针在 `2.00s` 完成，示例收尾在 `3.8s`，留了足够余量。

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
| 游戏内 `0 failed` 的实跑结果 | **已验证**：2026-11-16 `tools\verify-examples.ps1 -Live` 实机跑出 `Results: 6 passed, 0 failed, 6 total`（6/6，DLL `87C83BA1…`）。与另外几个示例**不在同一批**跑完：另一会话占了 war3 单实例锁和共享日志，重跑时被打断，撞车原因见 `examples\README.md` 的「-Live 撞车」一节 |

风险与注意事项：

- 依赖 JASS 侧探针在 `2.00s` 前后跑完；如果地图加载远超预期（首帧卡 1s+）探针会推迟，但收尾在 3.8s，余量足够。
- `udg_lua_wrapper_*` 这些全局只在注入 wrapper 的基座上才存在；贴到自己地图时要保证基座 `war3map.j` 里声明了它们（`pack.ps1` 的注入逻辑就是这么判定的）。
- 仓库实机基线：`-WithJassWrappers` 下回归 **125/125**（比默认 122 多出的正是 wrapper 三项）。
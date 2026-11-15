# 10 函数地址与绑定标签（GetFuncAddr）

> 日期：2026-11-16 ｜ 模块：`jass.common` `jass.globals` `jass.debug` ｜ 额外开关：`-WithGetFuncAddr` ｜ D3D：不需要 ｜ 入口：`war3map.lua`

## 用途

- 把 JASS 的 `code` 参数（函数值）转成**整数地址**，用于函数指针表、按名字反查、把地址再当 `code` 用。
- `-WithGetFuncAddr` 注入的探针会把三个函数的地址写进 `udg_lua_getfunc_addr/addr2/addr3`，示例验证"同函数同地址、不同函数不撞车、地址可反查、地址可执行"。

## 怎么跑

> **必须带 `-WithGetFuncAddr`**：`pack.ps1` 会声明引擎隐藏 native `SetHeroLevels takes code f`、在 `endglobals` 后建 `GetFuncAddr(f)`，并在 `2.20s` 用 `JapiGetFuncAddrProbeActions` 填 `udg_lua_getfunc_*`，最后置 `udg_lua_getfunc_ready = 1`。不带开关时第一项 FAIL 并提示加开关。

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 10

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\10-getfunc-addr `
    -WorkDir build\scratch\ex-10\work `
    -OutFile build\scratch\ex-10\out.w3x -WithGetFuncAddr

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\10-getfunc-addr -MapName vx-10-getfunc-addr.w3x -WithGetFuncAddr
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 10] ...
  [PASS] GetFuncAddr 探针已注入（udg_lua_getfunc_ready == 1）
  [PASS] code 参数转成非零整数地址
  [PASS] 同一个函数两次转换得到同一地址，不同函数不撞车
  [PASS] 地址能反查到绑定标签
  [PASS] jass.debug.save_func_addr 取回 SaveFunc 的锚点
  [PASS] 地址可以当 code 传给 TriggerAddAction
========================================
 Results: 6 passed, 0 failed, 6 total
========================================
```

- 健康环境 **6 passed / 0 failed / 6 total**；不带开关时 **0 passed / 1 failed / 1 total**。
- 时序：探针是打包时注入的 **2.20s 一次性 timer**（`tools\pack.ps1:327`），到点才填 `udg_lua_getfunc_*`；示例把全部检查放到 `2.6s` 的一次性 timer 里跑。加载时就检查只会读到 `udg_lua_getfunc_ready = 0`（实测 0/6 passed）。

## 代码要点

- 同样先写 `globals.udg_lua_japi_alive = 1`（探针会先看这个标志）。
- `jdbg.func_bind_lookup(addr)` 把地址反查回绑定标签 —— 示例断言 `== "jass-getfunc-target"`。
- `jdbg.save_func_addr()` 返回 `SaveFunc` 自己的地址，可以当锚点比对（示例断言它等于 `udg_lua_getfunc_addr2`）。
- `addr3 == addr`（同一个函数两次转换得到同一地址）、`addr2 ~= addr`（不同函数不同地址）。
- 地址能直接当 `code` 用：`TriggerAddAction(trigger, addr)` 之后 `TriggerExecute`，`udg_lua_getfunc_hits` 应该 +1。

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

- 这是**引擎内部行为**（函数值 = 地址），不是 JASS 标准；它依赖 `-WithGetFuncAddr` 注入的隐藏 native，`pack.ps1`/基座任何一边改了注入逻辑都会让它失效。
- 仓库实机基线：`-WithGetFuncAddr` 下回归 **126/126**。
- 地址只在本次进程内有效，不要存档、不要跨局比较。
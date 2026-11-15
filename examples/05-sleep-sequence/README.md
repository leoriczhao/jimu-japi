# 05 用 sleep 编排开场流程

> 日期：2026-11-16 ｜ 模块：`jass.common` `jass.runtime` `jass.sleep` ｜ 额外开关：无 ｜ D3D：不需要 ｜ 入口：`war3map.lua`

## 用途

- 把"开场放单位 → 等 0.3s → 提示 → 等 0.3s → 开打"写成**线性代码**，而不是一层层嵌套 timer。
- 这是 map 作者从 JASS 的 `TriggerSleepAction` 迁移过来时最想保留的写法。

## 怎么跑

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 05

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\05-sleep-sequence `
    -WorkDir build\scratch\ex-05\work `
    -OutFile build\scratch\ex-05\out.w3x

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\05-sleep-sequence -MapName vx-undefined.w3x
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 05] ...
  [PASS] jass.sleep 已加载（模块表 + 全局 sleep）
  [PASS] 协程外调用 sleep 会报错（不是静默失败）
  [PASS] 协程里 sleep 会让协程挂起
  [PASS] trigger action 里 sleep 后流程继续推进到 stage 3
  [PASS] sleep(0.30) 期间确实挂起了（被采样到 >= 5 次，约 0.1s 以上）
  [PASS] 流程跑完后 runtime.sleep 已复位为 false
========================================
 Results: 6 passed, 0 failed, 6 total
========================================
```

- 健康环境 **6 passed / 0 failed / 6 total**。

## 代码要点

- `require "jass.sleep"` 会注册一个**全局** `sleep()`；模块表上也有 `.sleep`（两种取法都能用）。
- **必须先打开 `runtime.sleep = true`**，否则 `sleep()` 直接报错。
- `sleep()` 只能在 **trigger / action 线程**里调用 —— 因为底层是 `TriggerSleepAction`，它只能恢复 trigger 线程。**放在 timer 回调里会失败**。示例的做法：`CreateTrigger` + `TriggerAddAction(jass.code(...))` + `TriggerRegisterTimerEvent(trigger, 0.05, false)` 起线程。
- 协程里 `sleep()` 会让协程 `suspended`；协程外调用会**报错**（不是静默失败）—— 这正好可以拿来做自检。
- 挂起期间别的代码照跑：示例用 `0.02s` 采样 timer 记录"看到过 stage 1"的次数（>= 5 次说明真的挂了 ~0.1s 以上，而不是瞬间跑完）。
- 流程跑完把 `runtime.sleep` 复位为 `false`，这是脚本自己该做的卫生工作。

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

- "被采样到 >= 5 次"取决于 timer 调度精度；在严重掉帧的机器上守着 3.8s 的收尾时间仍然够，但如果整机卡死 >3s 会 FAIL。
- 示例里 `local sleep = (require "jass.sleep").sleep` 故意写成带括号的形式 —— `pack.ps1` 只内联**行首** `require`，所以这行不会被静态合并，运行期由 DLL 的模块系统解析。这本身也顺带验证了 `jass.*` 是运行时模块。

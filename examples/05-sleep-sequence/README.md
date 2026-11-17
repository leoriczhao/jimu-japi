# 05 用 sleep 让 action 线程等一次

> 日期：2026-11-16 ｜ 模块：`jass.common` `jass.runtime` `jass.sleep` ｜ 额外开关：无 ｜ D3D：不需要 ｜ 入口：`war3map.lua`

## 用途

- 在 trigger/action 线程里用 `sleep(seconds)` 等一次，再继续往下走 —— 从 JASS 的 `TriggerSleepAction` 迁移过来最想保留的写法。
- **只演示一段 sleep**；多步编排用 timer 链（示例里也给了配方）。这不是保守写法，而是 2026-11-16 在 1.27a 上 6 个独立探针实测出来的唯一可靠形态。

## 怎么跑

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 05

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\05-sleep-sequence `
    -WorkDir build\scratch\ex-05\work `
    -OutFile build\scratch\ex-05\out.w3x

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\05-sleep-sequence -MapName vx-05-sleep-sequence.w3x
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 05] action entry #1 at tick 1
[example 05] stage 1 at tick 1: 挂起 0.30s
[example 05] timer 链 step 2 at tick 1
[example 05] timer 链 step 3 at tick 2: 多步编排完成
[example 05] action entry #2 at tick 4
[example 05] stage 1 at tick 4: 挂起 0.30s
[example 05] action entry #3 at tick 8
[example 05] stage 1 at tick 8: 挂起 0.30s
[example 05] stage 2 at tick 12: 恢复了，接着往下走
  [PASS] jass.sleep 已加载（模块表 + 全局 sleep 是同一个函数）
  [PASS] 协程外调用 sleep 会报错（不是静默失败）
  [PASS] trigger action 至少被进入 1 次（重入是 1.27a 的正常现象，不设上限）
  [info] action 共进入 3 次，最后 stage = 2
  [PASS] 挂起期间定时器看到过 stage == 1（确实睡过去了）
  [PASS] 之后定时器看到 stage == 2（确实恢复了），日志里带实测耗时
  [info] 最后一次 sleep：tick 8 → tick 12，实测等了约 0.4s（参数 0.30s）
  [PASS] 流程跑完后 runtime.sleep 已复位为 false
========================================
 Results: 6 passed, 0 failed, 6 total
========================================
```

- 健康环境 **6 passed / 0 failed / 6 total**。
- tick 数字每次不同（0.1s 一格）：**挂起时长以日志为准，断言只看「看到过 stage 1」+「看到过 stage 2」**，不赌固定秒数。
- `action entry #N` 的 N 每次不同：2026-11-16 两次实机一次 2 次、一次 3 次。那是 1.27a 的正常重入行为，**不要用守卫去挡**（见下）。
- `[info] 最后一次 sleep：tick A → tick B` 这一行量的是**真正恢复了的那一段**（action 在 `sleep` 前后各记一个 tick）。不要用「第一次看到 stage 1」到「看到 stage 2」的墙钟差 —— 那会把重入的等待也算进去（实测会打成 1.1s）。
- **把它当区间，不要当单个数**：0.3s–1.1s 都见过。恢复本身落在 0.3s–0.43s（六探针用细时钟量到 0.433s，本示例 0.1s 时钟粒度下打出 0.3s / 0.4s）；而「从第一次 stage 1 起算」的墙钟是 1.1s，那是两次重入叠出来的，不代表 sleep 慢。
- 8s 还没看到 stage 2 会打 `[example 05] 8s 兜底触发：entries=… stage=…` 再收尾（同样只有一条 `Results` 行），不会 hang 住地图。

## 代码要点

- `require "jass.sleep"` 会注册一个**全局** `sleep()`；模块表上也有 `.sleep`（示例断言两者是同一个函数）。
- **必须先打开 `runtime.sleep = true`**，否则 `sleep()` 直接报错；流程跑完记得复位成 `false`。
- `sleep()` 只能在 **trigger / action 线程**里调用 —— 底层是 `TriggerSleepAction`，它只能恢复 trigger 线程；放在 timer 回调里会报错。示例：`CreateTrigger` + `TriggerAddAction(jass.code(...))` + `TriggerRegisterTimerEvent(trigger, 0.10, false)`。
- **精度约「参数 + 0.1 秒」**：2026-11-16 六探针实测 `sleep(0.05)` 恢复用 0.075s、`sleep(0.30)` 恢复用 0.43s。要精确计时用 `TimerStart`。
- **只睡一次**。多段 sleep 串联实测不可靠：同一套 DLL 上，`sleep(0.30) × 2` 的探针 p3 能通（stage3 @3.549s，期间 action 被重入 6 次），换一种状态机写法的 p7 直接挂（15s entries 一直 = 1，从未恢复）。多步编排请用 timer 链：

```lua
local t = jass.CreateTimer()
jass.TimerStart(t, 0.10, false, function()
    jass.DestroyTimer(t)
    -- 第二步
    local t2 = jass.CreateTimer()
    jass.TimerStart(t2, 0.10, false, function()
        jass.DestroyTimer(t2)
        -- 第三步
    end)
end)
```

- **千万不要在 action 顶部加「已经跑过就 return」的守卫**：挂起后的续跑依赖 action 被重新进入，守卫会把它掐死。探针 p6 实测：加了守卫后第一段 sleep 恢复、第二段 15s 再也不回来。
- **action 会被从头重入**（p3 在 3.8s 内进了 6 次，每次都把状态打回初值），所以：状态用 `stage` 字段标记、轮询去判，不要假设它只跑一次、也不要靠「进入次数的奇偶」推断进度。
- 收尾不要赌固定秒数：示例用 `0.02s` 轮询看到 `stage == 2` 就 finalize，另起 `8s` 兜底防 hang。
- 加载期自检里**不要**造「yield 之后永不 resume」的协程，也不要在 action 之前先自己试 `sleep`：探针 p4/p5 证明单独不致命，但会占用续跑映射，只会给排查添噪声。

## 三段结构

- **(A) 头注释**：编号 / 用途 / 需要的开关 / 预期日志 / 实测事实 / 验证状态。
- **(B) 可粘贴段**：`-- ============ 以下这段可以粘进自己的 war3map.lua ============` 之后是真正的功能代码，
  只有 `require "jass.*"`，不依赖 `lib\`，不跨目录 require。
- **(C) 自检段**：`-- ============ 以下为示例自检，粘到自己地图时可以删掉 ============` 之后是内联的
  `check` / `finish` harness、`0.02s` 轮询 timer 和 `8s` 兜底 timer。删掉就没有 `Results` 行了。

## 已验证 / 未验证

| 项 | 状态 |
|----|------|
| 文件结构、`Results` 格式（恰好一行、可被 `Results:.*total` 解析） | **已验证**：`tools\verify-examples.ps1` 静态检查通过 |
| 用到的 `jass.*` 模块全部可 `require`、API 调用在仓库内有出处 | **已验证**：逐个符号在 `map\` / `docs\guide\` / `src\` 里检索到 |
| `-MapDir` 打包产出非平凡 w3x | **已验证**：`tools\verify-examples.ps1` 打包通过 |
| sleep 的恢复延迟、「多段串联不可靠」、「加守卫会掐死续跑」 | **已验证**：2026-11-16 六个独立探针地图实测（见「代码要点」的数字） |
| 本示例自身的游戏内 `0 failed` 结果 | **已验证**：2026-11-16 `tools\verify-examples.ps1 -Live` 实机跑出 `Results: 6 passed, 0 failed, 6 total`（DLL `87C83BA1…`，连续两次 6/6） |

风险与注意事项：

- 断言只看「看到过 stage 1」和「看到过 stage 2」，**不看具体秒数**：恢复延迟取决于宿主调度，实测区间 0.3s–1.1s（恢复本身 0.3–0.43s，墙钟含重入会到 1.1s），不保证。
- 如果某台机器连单段 `sleep(0.30)` 都卡住，会看到 8s 兜底行 + 2 项 FAIL（stage 1 / stage 2）。那说明宿主的 `TriggerSleepAction` 有问题，不是示例写法问题 —— 请把日志发给 SDK 维护者。
- 示例里 `local sleep = (require "jass.sleep").sleep` 故意写成带括号的形式 —— `pack.ps1` 只内联**行首** `require`，所以这行不会被静态合并，运行期由 DLL 的模块系统解析。
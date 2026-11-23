# 示例 05 · 协程等待（jass.sleep）与 Timer 链编排

演示如何在 `TriggerAddAction` 线程内调用 `sleep()` 进行单次挂起，以及多步骤异步流程推荐使用的 timer 链写法。

## 构建与运行

```powershell
japi build examples\05-sleep-sequence -o dist\05-sleep-sequence.w3x
japi run   examples\05-sleep-sequence
```

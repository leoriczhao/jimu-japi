# 示例 02 · native hook + 输入回调

演示 `jass.hook.hook` 接管原生 JASS native（通过末参 `orig` 调用原实现）以及 `jass.message.hook` 监听并拦截游戏内按键输入（按 `Q` 键触发提示并吞掉输入）。

## 构建与运行

```powershell
japi build examples\02-input-hook -o dist\02-input-hook.w3x
japi run   examples\02-input-hook
```

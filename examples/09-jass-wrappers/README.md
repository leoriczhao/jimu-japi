# 示例 09 · JASS 扩展 native wrapper 与 jass.japi

演示使用 `--with-jass-wrappers` 为 JASS 侧生成扩展 native 包装函数，并在 Lua 侧通过 `jass.japi` 直接调用同名扩展 native。

## 构建与运行

```powershell
japi build examples\09-jass-wrappers --with-jass-wrappers -o dist\09-jass-wrappers.w3x
japi run   examples\09-jass-wrappers --with-jass-wrappers
```

# 旧图 EX setter 兼容检查

在仓库根目录运行 `tools\w3x2lni\bin\w3x2lni-lua.exe tests\api-compat\run.lua`，预期三个检查均通过。检查只读取参考地图的 JASS 和当前注册源码。

- `EXSetAbilityState`、`EXSetItemDataString` 的旧包装函数写入相同的参数，调用后忽略返回值。现有 Lua 接口继续返回布尔值。
- `EXSetEffectZ` 的旧包装函数声明了两个 real，实际只写入一个。当前分发使用注册签名，只读取旧图实际写入的参数。

`jass.selector.hero()` 的离线用例位于 `tests/selector/`。

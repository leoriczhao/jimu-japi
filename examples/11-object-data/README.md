# 示例 11 · 代码化物编（objects.lua）

通过构建期声明文件 `objects.lua` 定义自定义单位 `'uO11'` 与 3 级自定义技能 `'AO11'`，打包时自动编译为标准 `war3map.w3u` / `war3map.w3a` 且不进入运行时脚本。

## 构建与运行

```powershell
japi build examples\11-object-data -o dist\11-object-data.w3x
japi run   examples\11-object-data
```

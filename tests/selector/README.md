# jass.selector 离线测试

本目录只验证 `jass.selector.hero()` 的**纯 Lua 逻辑**，不启动 War3、不加载地图、不打包、不链接 DLL。
模块源码是 `src/src/lua_engine/lua_engine/libs_selector_lua.h` 里的 raw string（DLL 实际编译的同一份文本），
测试从该文件中抽取源码并注入假的 `jass.common`。

## 运行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\selector\run.ps1
# 或
tools\w3x2lni\bin\w3x2lni-lua.exe tests\selector\run.lua
```

期望末行：`Selector offline: N passed, 0 failed, N total`。

## 覆盖内容

- `hero()` 返回稠密的英雄数组，顺序与引擎单位组枚举一致；
- 英雄判定与 YDWE `IsHero()` 一致：单位类型 rawcode 首字节为 `A`–`Z`（`GetUnitTypeId` 的高字节）；
- 空世界返回空表，不返回 `nil`；
- `handle_level = 0` 时 `FirstOfGroup` 用整数 `0` 表示空组，循环仍能终止；
- `CreateGroup` / `GetWorldBounds` 返回 `nil` 或 `0`、`GroupEnumUnitsInRect` / `FirstOfGroup` /
  `GroupRemoveUnit` / `GetUnitTypeId` 抛错时，临时 group/rect 都会释放；
- 清理失败只在枚举成功时上报；枚举本身的错误不会被清理错误掩盖；
- 静态检查：`jass.selector` 已注册到 `package.preload`、`libs_selector.cpp` 已进入 CMake 源列表、
  C++ 侧没有内存扫描/hook/native 注册，Lua 侧只 `require "jass.common"`。

## 语义与排除项（重要限制）

- **没有额外排除死亡/隐藏单位。** YDWE 原版 `IsVaildUnit` 检查的是 CUnit 私有标志位
  （`+0x20`、`+0x5C`）。离线材料里没有这些位与「死亡/隐藏」的确定映射，而本次约束又禁止读内存，
  所以不做猜测性过滤。`hero()` 返回引擎 `GroupEnumUnitsInRect(GetWorldBounds())` 实际暴露的单位：
  死亡单位通常会在组里（参考 `reference/builtin-japi/main.lua:55` 的目标过滤需要显式检查
  `UNIT_TYPE_DEAD`），隐藏单位是否出现由引擎组枚举行为决定。调用方若要严格排除，可在结果上用
  `jass.IsUnitType(u, jass.UNIT_TYPE_DEAD)` / `jass.IsUnitHidden(u)` 再过滤。
- **只覆盖世界边界内的单位。** 原版遍历引擎 CUnit 数组；本实现用 `GetWorldBounds()` 的矩形枚举，
  坐标落在世界边界之外的异常单位不会被返回。
- **顺序不保证。** 原版遍历引擎 CUnit 数组，本实现遍历 JASS 单位组；两者顺序可能不同。
- **调用时机。** 与其它直接调 native 的代码一样，VM 刚加载时部分 native 可能尚不可用；
  `hero()` 会抛出明确错误而不是返回半成品。按仓库惯例放到开局后（例如一次性 timer）调用。
- **每次调用都是快照。** 不复用 group/rect、不缓存结果；高频调用请自行降频。
- **只覆盖 `hero()`。** YDWE `jass.selector` 只导出 `hero`；本实现保持一致。
- **离线验证的边界。** 真实 1.27a 引擎里 `GetWorldBounds` / 组枚举 / 隐藏单位的具体行为仍需实机确认；
  本轮按约束没有启动 War3。
- **SDK bundle 打包模式。** 仓库内 `tools/pack.ps1` 会从 `open_lua_engine.cpp` 自动发现引擎模块；
  `-SdkBundle` 使用的静态清单尚未加入 `jass.selector`（本次不改打包脚本），若在冻结 SDK 包内用
  `-StrictRequires`，需要把 `'jass.selector'` 补进该清单。

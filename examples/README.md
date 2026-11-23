# 示例工程（Examples）

本目录包含 12 个独立可打包的 WAR3 1.27a Lua 示例工程。每个目录都可直接打包运行，或复制为自己的项目起点。

## 打包与运行

```powershell
# 打包单个示例
.\japi.exe build examples\01-hello-jass -o dist\01-hello-jass.w3x

# 打包并启动 War3 1.27a 运行
.\japi.exe run examples\01-hello-jass
```

需要额外编译开关的示例：
- `09-jass-wrappers`：`.\japi.exe build examples\09-jass-wrappers --with-jass-wrappers`
- `10-getfunc-addr`：`.\japi.exe build examples\10-getfunc-addr --with-get-func-addr`

## 示例一览

| 目录 | 主题 | 主要模块 |
|---|---|---|
| `01-hello-jass` | 调用 JASS native 与屏幕提示 | `jass.common` |
| `02-input-hook` | native hook 与键盘输入拦截 | `jass.hook` / `jass.message` |
| `03-d3d-hud` | D3D9 文本与贴图 HUD | `jass.d3d` |
| `04-create-unit-order` | 创建单位与点目标命令 | `jass.common` |
| `05-sleep-sequence` | 协程 `sleep` 与 timer 链编排 | `jass.sleep` / `jass.runtime` |
| `06-globals` | 读写 JASS 标量与数组全局变量 | `jass.globals` |
| `07-slk` | 查询 SLK 单位/技能/物品表 | `jass.slk` |
| `08-d3d-subscription` | D3D 贴图点击命中、悬停与窗口缩放事件 | `jass.d3d` |
| `09-jass-wrappers` | JASS 侧扩展 native wrapper 与 `jass.japi` 调用 | `jass.japi` |
| `10-getfunc-addr` | JASS 函数地址反查与 `jass.debug` | `jass.debug` |
| `11-object-data` | 代码化物编（`objects.lua`）定义自定义单位与技能 | `jass.slk` + `objects.lua` |
| `12-ui-components` | 响应式行列布局与按钮组件库 | `jass.d3d` + `lib/ui.lua` |

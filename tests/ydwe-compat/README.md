# YDWE 兼容离线测试（`tests/ydwe-compat`）

本目录只做**离线**验证：不启动 War3、不加载地图、不打包、不部署、不链接/运行漏洞载荷。
所有检查都只读仓库文件、运行本地构建产物。

## 运行

```powershell
# 先构建（只编译，不启动游戏）
src\build.bat

# 4 个步骤全跑
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ydwe-compat\run.ps1
# 期望末行：YDWE compat offline: 4 step(s) passed
```

单独运行：

```powershell
python -B tests\ydwe-compat\test_unit_state_migrate.py      # 25 项：迁移工具 + 静态一致性
tools\w3x2lni\bin\w3x2lni-lua.exe tests\ydwe-compat\run_lua.lua  # 17 项：jass.ydwe
src\build\bin\Release\button_icon_test.exe <repo-root>      # 47 项：C++ 图像模块
python -B tests\ydwe-compat\test_button_icons.py            # 11 项：CLI 端到端
```

## 覆盖内容

### 单位状态迁移（`test_unit_state_migrate.py`）

- `GetUnitState` / `SetUnitState` / `GetUnitStateSwap` / `GetUnitStatePercent` 的扩展状态改写；
- `ConvertUnitState(<literal>)` 拆包、`0X20 -> 0x20` 规范化、命名常量解析；
- 注释、`//#`、字符串、rawcode、BOM、CRLF/CR、GBK 注释字节完全不动；
- vanilla `0..3`、UjAPI-only `4..7`、未知值、Set no-op `0x14/0x15/0x42/0x43` 不改；
- 多行调用、全局初始化器、`constant function`、`config`、`main` 握手前调用跳过并报告；
- 参数/local 同名遮蔽的状态名跳过（`shadowed-state`）；嵌套在 unit/value 参数里的状态读取也会改写；
- 幂等、`--check`/`--in-place`/`--out`/`--report-json`/`--emit-compat`；
- 迁移输出 + 生成块用 `tools\pjass.exe` + 1.27.1 `common.j`/`blizzard.j` 编译通过；
  不生成 wrapper 时编译失败（证明 wrapper 依赖是真实的）；
- 状态表与 `UnitState.cpp` 的 enum/switch 逐项比对；`PasButton` 副本与 YDWE 参考逐值比对；
  `libs_ydwe_lua.h` 的 47 项与 JSON 一致；注册签名 `(II)R`/`(IIR)V`/`(S)V`/`(SSS)B` 静态断言；
- 新运行时代码不含 `SFileLoadFile`/`iat(`/`VirtualProtect`/`japi_add`/`inline_hook`/
  `war3_searcher`/`handle_to_object` 等禁止机制（注释除外）。

### `jass.ydwe`（`run_lua.lua`）

- 从 `libs_ydwe_lua.h` 抽取 DLL 实际编译的同一份 raw Lua 源码，注入假
  `jass.common`/`jass.japi`；
- vanilla 走 common、扩展走 japi、`GetHandleId` 传递、浮点状态截断；
- UjAPI-only、未知状态、Set no-op、非数字/NaN/Inf/越界参数全部抛错；
- 模块不替换 `jass.common` 函数；静态检查 preload/CMake/require 范围。

### 图像模块（`button_icon_test.exe`）

- BLP1 palette 编码/解码精确往返；mip 表连续；1×1 边界；
- BLP2 palette/raw 解码；BLP2 DXT 明确拒绝；坏 magic 拒绝；
- YDWE `BlpDisable` / `BlpBlend` raw BGRA FNV 黄金值；
- `war3mapMap.blp`（BLP1 JPEG 256×256）解码尺寸与首像素 CMYK 修正值；
- 归档路径映射、`..`/绝对路径/盘符/设备名拒绝。

### CLI 端到端（`test_button_icons.py`）

- `raw-disable` / `raw-blend` 与独立 Python YDWE 公式**逐像素精确相等**；
- `disable` 写标准 `CommandButtonsDisabled\DIS*.blp` 并更新 `(listfile)`；
- `blend` 写指定 map-relative 路径；`run` 清单批处理；
- 路径穿越、非 64×64、缺失输入、非 BLP 失败；
- 输出 BLP 的 alpha 逐像素精确，RGB 量化误差 ≤ 40。

## 语义与排除项（重要限制）

- **没有 hook `GetUnitState`/`SetUnitState`**。未迁移的 JASS 调用、二进制地图、动态状态表达式
  保持原版行为；本目录不验证“透明兼容”。
- 迁移工具跳过全局初始化器、`constant function`、`config`、`main` 握手前调用；被自定义函数
  提前调用的场景只能靠作者保证在 `initializePlugin()` 之后执行。
- `GetHandleId(unitstate)` 的运行时值没有实机验证；直接迁移路径不依赖它，helper 路径依赖。
- UjAPI-only `4..7` 未实现；`0x29` 未复刻 YDWE 的缺失 break bug；`MAX_LIFE/MAX_MANA` 的
  Set 不走 YDWE 特殊路径。
- **原版命令卡动态加载未做**：没有 Storm `SFileLoadFile` 拦截/虚拟 MPQ。运行期 native 只做
  真实生成与落盘（`<mapdir>\japi-button-icons\`），本局命令卡不会看到生成物；必须构建期打包。
- 1.27a 是否接受 `alphaBits=8` 的 BLP1 palette + 多 mip 命令卡图标、loose file 搜索链、
  图标缓存刷新时机均未实机验证。
- 只支持 64×64；BLP2 DXT 输入不支持；输出 palette 量化与 YDWE 的 JPEG q95 字节不可能一致。
- D3D 代理的 `src/d3d9/texture_asset.cpp` 仍使用自己的 WIC 副本；本轮没有改它，D3D 的
  BLP1 JPEG 颜色/alpha 问题不在本目录覆盖范围。
- `PasButton`/算法来自 YDWE（GPL）；分发前需确认许可证义务。
- 本轮没有运行 `pack.ps1`、`deploy.ps1` 或 conformance 实机套件；`manifest.lua` 已重新生成
  （82 个 bridge handler），但 199 项实机基线没有复跑。

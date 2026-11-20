# AGENT.md — 工作流 & 开发约定

## 概览

本项目有三条工作流，互相独立但可串联：

| 工作流 | 输入 | 输出 | 脚本 |
|--------|------|------|------|
| **DLL 编译** | `src/src/**/*.cpp` | `src/build/bin/Release/yd_japi.dll` | `src/build.bat` |
| **地图打包** | `map/*.lua` + 基座地图 + DLL | `build/output.w3x` | `tools/pack.ps1` |
| **部署测试** | `build/output.w3x` | War3 日志 | `tools/deploy.ps1` |
| **新建地图项目（作者）** | 项目名 + 基座地图 | 可打包的项目目录 | `tools/new-project.ps1` |
| **示例验证（作者）** | `examples/**` | 每个示例的 `Results:` 行 | `tools/verify-examples.ps1` |
| **接口一致性（引擎）** | `src/src/**` 里的注册表 | 每个 native 的 `[PASS]`/`[FAIL]`/`[SKIP]` + `Conformance:` 汇总行 | `tests/conformance/run.ps1` |

## 架构

```
war3map.j（干净，只调标准 JASS native）
  └→ initializePlugin()
       ├→ StartCampaignAI(Player(12), "callback")  ← 加载 exploit
       │    └→ callback（内存 exploit + DLL 加载）
       │         └→ japi.tga (yd_japi.dll) 的 Initialize()
       │              ├→ inline hook UnitId → 哈希表 RPC 分发
       │              ├→ table_hook ExecuteFunc（惰性初始化钩子）
       │              └→ 清扫残留 japi<pid>.dll（看门狗；旧版裸 <pid>.dll 也清）
       ├→ UnitId(I2S(GetHandleId(japi_ht)))   ← 桥接表句柄交给 DLL
       └→ ExecuteFunc("japiDoNothing")        ← 首次调用触发：
            创建 Lua VM + 加载 war3map.lua + 安装 message_dispatch 输入过滤
```

- **war3map.j**：干净的 JASS 代码，只调 `UnitId`/`SaveStr`/`LoadReal` 等标准 native
- **callback**：exploit 代码，通过 `StartCampaignAI` 加载（AI 脚本不走 JASS 检测）
- **DLL**：inline hook `UnitId` 做 JASS→Lua 分发（哈希表传参）；Lua VM 在首次 ExecuteFunc 时惰性创建（对齐内置 JAPI）

---

## 工作流 0：SDK 使用者（地图作者）

地图作者的入口不是 `map/`（那是本仓库的回归工程），而是「一个地图项目目录 + `-MapDir`」：

```powershell
# 1. 生成项目（war3map.lua + lib/ + tests/ + config + base-map + README）
.\tools\new-project.ps1 -Name MyMap -Path ..\my-maps

# 2. 打包（项目目录自带基座地图，不依赖 reference/empty-map）
.\tools\pack.ps1 -MapDir ..\my-maps\MyMap -BaseMap ..\my-maps\MyMap\base-map -OutFile build\MyMap.w3x

# 3. 打包 + 部署 + 等结果（日志：C:\ProgramData\japi_debug.txt）
.\tools\deploy.ps1 -MapDir ..\my-maps\MyMap -BaseMap ..\my-maps\MyMap\base-map -MapName MyMap.w3x
```

| 资源 | 路径 | 说明 |
|------|------|------|
| 上手文档 | `docs/guide/SDK-QUICKSTART.md` | 30 分钟从零到第一个玩法 |
| 模块指南 | `docs/guide/SDK-GUIDE.md` | 按 `jass.*` 模块讲怎么用 |
| 玩法配方 | `docs/guide/SDK-COOKBOOK.md` | 可直接粘贴的代码片段 |
| 代码化物编与 UI | `docs/guide/OBJECT-DATA-UI.md` | `objects.lua` 单位/技能声明、`lib.ui` 按钮布局、示例 11/12 与真实输入验证 |
| 示例 | `examples/`（`manifest.json` + `tools/verify-examples.ps1`） | 12 个示例；11 为物编，12 附带 UI 模块与真实输入驱动 |
| 版本与变更 | `CHANGELOG.md` | SDK 版本策略与历史 |
| 出包流程 | `docs/RELEASE.md` + `tools/release-sdk.ps1` | 可复现的发布流程 |
| 自包含作者包 | `build\sdk\<ver>-<sha7>\sdk\README.md`（`release-sdk.ps1 -SdkBundle` 产出） | 文档+示例+脚本+vendor+二进制一体，解压即用 |

`-MapDir` 指向的目录必须有 `war3map.lua`（入口）；模块名 = 相对路径去掉 `.lua` 并把 `/` 换成 `.`（`lib/util.lua` → `require "lib.util"`），从入口可达的受支持 `require` 会递归内联。根 `objects.lua` 是构建专用保留文件，会编译成单位/技能物编而不会进入游戏 Lua 模块；不需要物编声明的工程可以省略它。

---

## 工作流 1：DLL 开发（C++ 侧）

修改 C++ 源码 → 编译 → 产出 DLL。

```powershell
cd src
.\build.bat
# 输出：src/build/bin/Release/yd_japi.dll
```

**目录约定**：

| 路径 | 用途 |
|------|------|
| `src/src/yd_core/` | YDWE 核心（改编自 ydwar3） |
| `src/src/lua_engine/` | Lua 引擎 + bridge dispatch |
| `src/src/extensions/` | 自定义扩展 native |
| `src/vendor/lua-5.4/` | Lua 5.4 源码（静态编译） |

**改机器码必须可回滚**：字节补丁用 `base::hook::patch_guard`（备份后写、`restore()`/析构还原），inline hook 用 `warcraft3::jass::inline_hook_install(target, detour, &info)` + `inline_hook_uninstall(&info)`。裸写 `VirtualProtect` + `memcpy` 会丢掉原始字节。安装按 target 幂等（重复安装返回已有 trampoline，不会二次打补丁），地图重开时 `Initialize()` / `SimulateMapBoot` 会调 `inline_hook_reassert_all()` 把被引擎改写的 JMP 按记录补回去。合同由 `hook_rollback_test.exe` 钉住。

**添加自定义 native**：

1. 编辑 `src/src/extensions/custom_natives.cpp`
2. 用 `jass::japi_add()` 注册函数
3. 重新编译

---

## 工作流 2：地图开发（Lua 侧）

编写 Lua 脚本 → 打包进地图。

```powershell
.\tools\pack.ps1
# 输出：build/output.w3x
```

**目录约定**：

| 路径 | 用途 |
|------|------|
| `map/war3map.lua` | 用户主入口（必须存在） |
| `map/lib/*.lua` | 用户库模块，`require "lib.xxx"` |
| `map/tests/*.lua` | 测试模块，`require "tests.xxx"` |
| `build/output.w3x` | 打包输出（不要提交） |

**pack.ps1 流程**：

1. 复制默认 `reference/empty-map/` 源地图，或解包显式传入的 `.w3m` / `.w3x` → `build/work/`
2. 若存在 `war3map.w3u.ini`，先生成 Warcraft III 使用的 `war3map.w3u` 对象数据
3. 合并 `map/` 下 Lua → `build/work/war3map.lua`（UTF-8 无 BOM；`__modcache` 模块缓存）；`require` 按「地图模块 / 引擎 `jass.*` / 缺失」分类，`-RequireReport` 打印逐条来源，`-StrictRequires` 让无法内联的模块在打包期失败
4. **patch `build/work/war3map.j`**：先打印所有注入锚点（`globals` / `endglobals` / `main` / `initializePlugin` / `LoadScript` / 首个函数 / 探针全局）的行号；在 `call initializePlugin(...)` 后插入 `SaveStr + UnitId("LoadScript")`，或在已存在的 `LoadScript` 前后补齐数组预分配与探针；锚点缺失/错位时抛出带锚点摘要的错误
5. 复制 DLL → `build/work/japi.tga`，复制 callback，复制 `war3map.lua` → `script\war3map.lua`，更新 `(listfile)`
6. 把 D3D 代理带进地图（**无条件**）：`newD3d9.dll` → `d3d9.tga`、`D3DX9_42.dll` → `d3dx9_42.tga`，外加 `d3d9.tga.sha256`（代理哈希）；连同 `(listfile)` 写入。没有开关：代理文件缺失直接报错，不会静默出一张没有 `jass.d3d` 的图
7. 重新打包为 `build/output.w3x`；`-SkipRepack` 在 patch 后停止，只保留 `-WorkDir` 供检查

**D3D 代理随地图分发**：代理本体是 `d3d9.dll` 的替身，只能在进程启动时被游戏加载，**地图内无法对当前这一局生效**。所以每张地图都由 `yd_japi.dll` 在 `Initialize` 时把 `d3d9.tga` / `d3dx9_42.tga` 从 MPQ 写到 `war3.exe` 所在目录（`stage_d3d_proxy_from_map`，日志 `D3D: staged d3d9.dll from the map`），并写入 `.japi_d3d_proxy.sha256` 供 `tools\d3d-proxy.ps1` 认领；**下一次启动**才生效。目标位置已有文件时不覆盖（字节相同视为"已就位"，不同视为别人的 wrapper，只记日志）。这与内置 JAPI 把 `newD3d9.dll` 塞进 `wenhao_plugin.tga` 的思路一致，区别只是我们的模块必须提前一局落地。

`D3DX9_42.dll` 是微软再发行文件且被 `*.dll` 忽略，干净克隆里没有副本，所以 `-D3dxPath` 的默认值按 `reference\builtin-japi\extracted` → `src\build\bin\Release` → `SysWOW64` → `System32` 顺序取第一个存在的。

两个 DLL 走**静态 CRT（`/MT`）**（`src/CMakeLists.txt` 的 `CMAKE_MSVC_RUNTIME_LIBRARY`），所以产物只依赖系统 DLL，不依赖 `MSVCP140` / `VCRUNTIME140`。新增第三方库时不要再引入 `/MD` 目标，否则链接期 `LNK2038`，或者编出来的代理在没装 VC 运行库的机器上直接加载失败。

**Lua 侧注册 JAPI 函数**：

```lua
local japi = require "jass.japi"

-- 注册一个 JASS 可调用的函数
japi("TestAdd", "(II)I", function(a, b)
    return a + b
end)

-- JASS 侧通过 UnitId("TestAdd") 调用
```

**Lua 调试器（可选）**：

```lua
local runtime = require "jass.runtime"
runtime.debugger = 4278   -- 启动 DAP 监听（需 -WithDebugger 打包）
```

- 打包时加 `-WithDebugger`（deploy.ps1 同样支持），调试资源注入 MPQ。
- VS Code 安装 `actboy168.lua-debug`，`launch.json` 用 `attach` + `127.0.0.1:4278`。
- 断点源文件路径：`<war3目录>\japi-debugger\script\war3map.lua`。
- 断点命中会冻结游戏画面（断点语义）；仅单机调试用。详细设计：`docs/planning/LUA-DEBUGGER-DESIGN.md`。

---

## 工作流 3：部署测试

```powershell
.\tools\deploy.ps1
# 打包 + 部署到 War3 + 启动 + 等待测试结果（判定依据：japi_debug.txt 出现 "Results:" 行）
```

---

## 完整开发循环

### 场景 A：只改 Lua（最常见）

```powershell
# 1. 编辑 map/war3map.lua
# 2. 打包 + 测试
.\tools\deploy.ps1
```

### 场景 B：改 C++ DLL

```powershell
# 1. 编辑 src/src/...
# 2. 编译 DLL
cd src; .\build.bat; cd ..
# 3. 打包 + 测试
.\tools\deploy.ps1
```

---

## 配置管理

**当前实现**：War3 安装路径在 `tools/deploy.ps1` 顶部硬编码（`$War3Dir = "D:\Warcraft III Frozen Throne 1.27a publish"`），不同的机器请直接改这一行。`tools/config.local.ps1`（gitignored）已预留但**尚未接入**任何脚本；`config.example.ps1` 描述的 `-War3Dir` 参数 / `WAR3_DIR` 环境变量是规划中的方案，当前不可用。

---

## 脚本参数速查

**pack.ps1**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-BaseMap` | `reference\empty-map` | 基座地图文件或 unpacked 源目录 |
| `-DllPath` | `src\build\bin\Release\yd_japi.dll` | DLL 路径 |
| `-OutFile` | `build\output.w3x` | 输出路径 |
| `-MapDir` | `map` | Lua 源码目录（任意自带 `war3map.lua` 的项目树） |
| `-WorkDir` | `build\work` | 中间产物目录；并行打包时给每个任务一个独立目录 |
| `-RequireReport` | 关 | 打印每个 `require` 的分类（地图内联/缓存/引擎 `jass.*`/缺失）与未使用的 Lua 文件 |
| `-StrictRequires` | 关 | 有缺失或无法内联的地图模块时打包失败（默认只 WARNING） |
| `-SkipRepack` | 关 | patch 完 `-WorkDir` 后停止，不写 `.w3x`，用于检查注入锚点/脚本 |
| `-ProxyPath` | `src\build\bin\Release\newD3d9.dll` | 打进地图的代理文件（每张图都带，无开关） |
| `-D3dxPath` | 依次探测 `reference\builtin-japi\extracted` → `src\build\bin\Release` → `SysWOW64` → `System32` | 打进地图的 D3DX 再发行文件 |

**deploy.ps1**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-BaseMap` | `reference\empty-map`（由 pack.ps1 采用） | 可覆盖的基座地图文件或源目录 |
| `-DllPath` | 同 pack.ps1 | DLL 路径 |
| `-LogFile` | `C:\ProgramData\japi_debug.txt` | 结果判定日志。DLL 硬编码写这个路径（`src/src/debug_log.h`，另有 `japi_debug_<pid>.txt` 兜底），**没有覆盖开关**；传别的路径会让 deploy 等一个永远没人写的文件而超时（脚本现在会打 WARNING） |
| `-Timeout` | 120 | 超时秒数（超时只 WARNING，不以非零退出） |
| `-NoKill` | 开关 | 不杀 War3 |
| `-MapDir` | 不传（用 `map`） | 透传给 pack.ps1：打包任意项目树 |
| `-MapName` | `output.w3x` | 部署到 `Maps\Test\<MapName>`；多人/多会话共用游戏目录时必须区分 |
| `-InteractiveD3D` / `-Demo` / `-TestReboot` | 开关 | 额外安装 D3D 代理并断言其导出表；交互模式默认 `-Timeout 3660` |

其余开关（`-WithJassWrappers` `-WithGetFuncAddr` `-WithDebugger` `-Hold` …）见 `tools/deploy.ps1` 头部 usage。

注意：deploy.ps1 **没有** `-War3Dir` 参数，War3 路径见上方"配置管理"。

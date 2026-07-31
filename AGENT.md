# AGENT.md — 工作流 & 开发约定

## 概览

本项目有三条工作流，互相独立但可串联：

| 工作流 | 输入 | 输出 | 脚本 |
|--------|------|------|------|
| **DLL 编译** | `src/src/**/*.cpp` | `src/build/bin/Release/yd_japi.dll` | `src/build.bat` |
| **地图打包** | `map/*.lua` + 基座地图 + DLL | `build/output.w3x` | `tools/pack.ps1` |
| **部署测试** | `build/output.w3x` | War3 日志 | `tools/deploy.ps1` |

## 架构

```
war3map.j（干净，只调标准 JASS native）
  └→ initializePlugin()
       ├→ StartCampaignAI(Player(12), "callback")  ← 加载 exploit
       │    └→ callback（内存 exploit + DLL 加载）
       │         └→ japi.tga (yd_japi.dll) 的 Initialize()
       │              ├→ inline hook UnitId → 哈希表 RPC 分发
       │              ├→ table_hook ExecuteFunc（惰性初始化钩子）
       │              └→ 清扫残留 <pid>.dll（看门狗）
       ├→ UnitId(I2S(GetHandleId(japi_ht)))   ← 桥接表句柄交给 DLL
       └→ ExecuteFunc("japiDoNothing")        ← 首次调用触发：
            创建 Lua VM + 加载 war3map.lua + 安装 message_dispatch 输入过滤
```

- **war3map.j**：干净的 JASS 代码，只调 `UnitId`/`SaveStr`/`LoadReal` 等标准 native
- **callback**：exploit 代码，通过 `StartCampaignAI` 加载（AI 脚本不走 JASS 检测）
- **DLL**：inline hook `UnitId` 做 JASS→Lua 分发（哈希表传参）；Lua VM 在首次 ExecuteFunc 时惰性创建（对齐内置 JAPI）

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
2. 合并 `map/` 下 Lua → `build/work/war3map.lua`（UTF-8 无 BOM；`__modcache` 模块缓存）
3. **patch `build/work/war3map.j`**：在 `call initializePlugin(  )` 后插入 `SaveStr(...,"()V") + UnitId("LoadScript")`（找不到锚点会立即报错）
4. 复制 DLL → `build/work/japi.tga`，复制 callback，复制 `war3map.lua` → `script\war3map.lua`，更新 `(listfile)`
5. 重新打包为 `build/output.w3x`

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

**当前实现**：War3 安装路径在 `tools/deploy.ps1` 第 18 行硬编码（`$War3Dir = "D:\Warcraft III Frozen Throne 1.27a publish"`），不同的机器请直接改这一行。`tools/config.local.ps1`（gitignored）已预留但**尚未接入**任何脚本；`config.example.ps1` 描述的 `-War3Dir` 参数 / `WAR3_DIR` 环境变量是规划中的方案，当前不可用。

---

## 脚本参数速查

**pack.ps1**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-BaseMap` | `reference\empty-map` | 基座地图文件或 unpacked 源目录 |
| `-DllPath` | `src\build\bin\Release\yd_japi.dll` | DLL 路径 |
| `-OutFile` | `build\output.w3x` | 输出路径 |
| `-MapDir` | `map` | Lua 源码目录 |

**deploy.ps1**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-BaseMap` | `reference\empty-map`（由 pack.ps1 采用） | 可覆盖的基座地图文件或源目录 |
| `-DllPath` | 同 pack.ps1 | DLL 路径 |
| `-LogFile` | `C:\ProgramData\japi_debug.txt` | 结果判定日志 |
| `-Timeout` | 120 | 超时秒数（超时只 WARNING，不以非零退出） |
| `-NoKill` | 开关 | 不杀 War3 |

注意：deploy.ps1 **没有** `-War3Dir` 参数，War3 路径见上方"配置管理"。

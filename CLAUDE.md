# map-inject — WAR3 地图注入方案

## 项目目标

复刻内置 JAPI（wenhao_plugin）的功能，通过 callback exploit 在 MPQ 模式下加载，提供 Lua 引擎 + JASS 扩展 native + 游戏数据查询。

## 参考项目关系

```
┌─────────────────────────────────────────────────────┐
│                    我们的项目 (map-inject)              │
│                                                     │
│  目标：复刻 builtin-japi 的功能                        │
│  代码基础：从 YDWE 提取核心模块，改编适配                │
│  native 签名参考：UjAPI                               │
└──────┬──────────────────┬──────────────────┬─────────┘
       │                  │                  │
       ▼                  ▼                  ▼
  ┌─────────┐      ┌──────────────┐    ┌─────────┐
  │  YDWE   │      │ builtin-japi │    │  UjAPI  │
  │ (编辑器) │      │ (wenhao_plugin)│   │(2333插件)│
  └─────────┘      └──────────────┘    └─────────┘
```

| 项目 | 角色 | 说明 |
|------|------|------|
| **YDWE** | 代码库来源 | 完整的 War3 编辑器插件框架。我们从里面提取 yd_core、lua_engine、SlkLib 等核心模块，改编适配后编译进我们的 DLL |
| **builtin-japi (wenhao_plugin)** | 功能参考（已逆向） | 内置 JAPI 插件，独立 DLL，跑在 War3 进程里。**我们要实现的功能就是它提供的功能**。和 YDWE 共享同一套 C++ 代码谱系（同一个 SlkLib、jass 接口层）。逆向报告：`reference/builtin-japi/wenhao_plugin逆向分析报告.html` |
| **UjAPI** | native 签名参考（已逆向） | 2333 的 JAPI 扩展，提供 EX* 系列 native 的函数签名。我们用它的签名来注册 native。参考手册：`reference/ujapi/UjAPI_Native参考手册.html`，JASS 源码：`reference/ujapi/UjAPI.j` |

**关键区别**：YDWE 跑在编辑器里，builtin-japi 跑在游戏里。我们的 DLL 跑在游戏里，所以行为上对标 builtin-japi，代码上从 YDWE 提取。

### builtin-japi 功能范围

> 当前完成度、验证强度和下一阶段统一维护在 `docs/STATUS.md`；本节只描述模块职责。

builtin-japi 提供以下 `jass.*` Lua 模块：

| 模块 | 用途 |
|------|------|
| `jass.common` | JASS native 调用（metatable 自动分发） |
| `jass.globals` | JASS 全局变量读写 |
| `jass.japi` | 自定义 native 注册（Lua 侧注册 handler） |
| `jass.hook` | native hook（拦截/替换 JASS 函数） |
| `jass.runtime` | 运行时配置（sleep、console、handle_level 等） |
| `jass.message` | 输入消息系统（键盘、鼠标、命令、选择） |
| `jass.debug` | 调试工具 |
| `jass.slk` | 游戏数据表查询（ability/unit/item 等 SLK 数据） |
| `jass.sleep` | 协程 sleep（TriggerSleepAction 集成） |
| `jass.storm` | MPQ 文件读取 |
| `jass.debugger` | DAP 调试器（127.0.0.1:4278；设计见 `docs/planning/LUA-DEBUGGER-DESIGN.md`） |

### 实现原则

1. **功能对标 builtin-japi**：实现什么功能、暴露什么接口，以 builtin-japi 为准
2. **代码从 YDWE 提取**：具体实现从 YDWE 源码里提取核心模块，改编适配 callback 模式
3. **native 签名参考 UjAPI**：EX* 系列 native 的函数签名以 UjAPI 为准
4. **callback 模式适配**：YDWE 原始代码面向编辑器，需要改编为面向游戏进程（详见适配要点表）

## 项目结构

```
map-inject/
├── CLAUDE.md
├── AGENT.md
│
├── map/                         ← 地图开发目录
│   ├── demo.w3x                # 测试地图
│   ├── war3map.lua             # 用户 Lua 脚本
│   ├── game/                   # 波次防守 demo（wave.lua 游戏循环 + demo.lua 自检）
│   ├── lib/                    # Lua 工具库
│   └── tests/                  # 回归夹具
│
├── src/                         ← DLL 源码目录
│   ├── CMakeLists.txt
│   ├── build.bat
│   ├── src/
│   │   ├── yd_core/            ← 从 YDWE 提取的核心（改编）
│   │   │   ├── hashtable.h     # VM 内存布局定义
│   │   │   ├── jass.h/cpp      # JASS 类型、字符串、调用
│   │   │   ├── hook.h/cpp      # native 注册/hook 框架
│   │   │   ├── nf_register.cpp # 改编：直接注册而非 hook StormAlloc
│   │   │   ├── func_value.h/cpp
│   │   │   └── war3_searcher.h/cpp
│   │   ├── lua_engine/         ← 从 YDWE 提取的 Lua 引擎（改编）
│   │   │   ├── lua_loader.cpp  # 改编：Initialize() 主动启动
│   │   │   ├── bridge_dispatch.cpp  # UnitId hook + 哈希表 RPC 分发
│   │   │   ├── open_lua_engine.cpp
│   │   │   ├── jassbind.h/cpp
│   │   │   ├── callback.h/cpp
│   │   │   └── libs_*.cpp      # jass.common, jass.hook, jass.japi 等
│   │   └── extensions/         ← dllmain.cpp（DLL 入口/Initialize）+ 自定义扩展 native
│   └── vendor/
│       └── lua-5.4/
│
├── tools/                       ← 构建 & 打包工具
│   ├── callback                # exploit JASS 代码（通过 StartCampaignAI 加载）
│   ├── pack.ps1                # MPQ 打包脚本（Lua 合并 + DLL 注入，不动 war3map.j）
│   ├── deploy.ps1              # 打包 + 部署 + 启动 War3 + 等结果
│   ├── make-foreign-map.ps1    # 生成无 japi 痕迹的外来地图夹具
│   ├── drive-interactive-d3d.ps1  # 按 [WAIT] 标记自动驱动交互 D3D 回归
│   ├── drive-demo.ps1          # 驱动 -Demo -Hold 会话：真左键/真 Q/真 R + 截图
│   ├── gen-jass-wrappers.ps1   # 按 C++ 注册表生成 JASS 五部曲 wrapper
│   ├── pjass.exe               # JASS 语法检查
│   ├── fetch-w3x2lni.ps1       # 拉取/更新 w3x2lni（脚本+数据未入库）
│   └── w3x2lni/                # 地图格式转换（仅编译产物 bin/ 入库）
│
├── reference/
│   ├── empty-map/              # 默认空白地图源 + Hrif 英雄火枪手对象定义
│   ├── base.w3m                # 本地旧基座地图（gitignored）
│   ├── vanilla_map/            # 基座地图的 unpacked 源文件
│   ├── builtin-japi/           # 内置 JAPI 逆向（wenhao_plugin）
│   │   ├── wenhao_plugin逆向分析报告.html  # 完整逆向报告（DLL 结构、模块、内存布局）
│   │   ├── callback            # exploit JASS 代码
│   │   ├── main.lua            # Lua 示例代码（slk/message/keyboard 用法）
│   │   └── war3map.j           # JASS 代码（japi bridge、wrapper、trampoline）
│   ├── ujapi/                  # UjAPI 逆向（2333 插件）
│   │   ├── UjAPI_Native参考手册.html  # EX* native 签名手册
│   │   ├── UjAPI.j             # UjAPI JASS 源码
│   │   ├── ujapi_common.j      # 通用 native 声明
│   │   └── ujapi_wrapper.j     # wrapper 函数
│   ├── YDWE/                   # YDWE 完整源码（代码库来源）
│   │   └── Development/
│   │       ├── Core/ydbase/    # hook 框架
│   │       ├── Core/ydwar3/    # JASS VM 接口
│   │       ├── Core/SlkLib/    # SLK 解析器（ObjectManager、SlkReader）
│   │       └── Plugin/Warcraft3/yd_lua_engine/  # Lua 引擎
│   └── old-japi/               # 旧方案存档
│
├── docs/                        ← 文档
│   ├── STATUS.md               # 唯一权威状态
│   ├── architecture/
│   ├── planning/
│   ├── guide/                  # 用户文档（D3D Lua SDK quickstart / API / 迁移）
│   └── analysis/
│
└── reference/                   ← 逆向参考
    ├── builtin-japi/            # 内置 JAPI（callback exploit 来源）
    ├── ujapi/                   # UjAPI（2333 扩展 native 参考）
    ├── ujapi-full/              # UjAPI GitHub 完整仓库
    ├── YDWE/                    # YDWE 完整源码（编译基座）
    └── old-japi/                # 旧的单 DLL 方案（存档参考）
```

## YDWE 核心源码位置（需提取改编）

| 模块 | 源码路径 | 用途 |
|------|----------|------|
| ydbase | `Development/Core/ydbase/` | hook 框架（IAT/EAT/inline） |
| ydwar3 | `Development/Core/ydwar3/` | JASS VM 接口、native 注册、内存结构 |
| yd_lua_engine | `Development/Plugin/Warcraft3/yd_lua_engine/` | Lua 引擎、jass.* 模块 |
| yd_jass_api | `Development/Plugin/Warcraft3/yd_jass_api/` | EX* 扩展 native |

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

- **war3map.j**：干净的 JASS，只调 `UnitId`/`SaveStr`/`LoadReal` 等标准 native
- **callback**：exploit 代码，通过 `StartCampaignAI` 加载（AI 脚本不走 JASS 检测）
- **DLL**：inline hook `UnitId` 做 JASS→Lua 分发，哈希表传参；Lua VM 惰性创建（对齐内置 JAPI）

## Callback 模式适配要点

| YDWE 原始机制 | 问题 | 改编方案 |
|---|---|---|
| nf_register.cpp hook StormAlloc | VM 已初始化，hook 不触发 | `nf_register::flush_add_only()` 直接触发 nfunction_add |
| lua_loader.cpp hook war3map.j | war3map.j 已执行 | table_hook `ExecuteFunc`，首次调用时惰性创建 lua_State 并加载 war3map.lua（对齐内置 JAPI） |
| yd_jass_api 依赖 event_add 信号 | 信号不会触发 | EX* native 改为 bridge handler（register_cpp_handler）经 UnitId RPC 分发 |
| JASS→Lua 通过 nfunction_add 注册 | 通不过 JASS 检测 | inline hook UnitId + 哈希表 RPC（内置 JAPI 方案） |
| SetWindowLongPtr WndProc hook 截输入 | Windows 层钩子，脆弱且看不到游戏内分发 | `message_dispatch::add_filter`（CGameUI 虚表 +0x10，内置 JAPI 方案） |

## 构建（DLL 编译）

```powershell
cd src
.\build.bat
# 输出：src/build/bin/Release/yd_japi.dll
```

## 打包 & 测试（地图开发）

```powershell
# 首次/换机器：拉取 w3x2lni 的脚本与数据（未入库；pin 在上游 commit，当前 2.7.4）
.\tools\fetch-w3x2lni.ps1

# 打包地图（合并 Lua + 注入 DLL + patch war3map.j 插入 LoadScript 调用）
.\tools\pack.ps1
# 输出：build/output.w3x

# 打包 + 部署到 War3 + 启动 + 等待测试结果
.\tools\deploy.ps1

# 详细工作流参见 AGENT.md
```

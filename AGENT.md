# AGENT.md — 工作流 & 开发约定

## 概览

本仓库采用**双层工具链**，彻底分离「地图作者 SDK」与「引擎内部维护」：

| 角色 | 工具链 | 源码位置 | 产物 / 入口 | 说明 |
|---|---|---|---|---|
| **地图作者 SDK** | **Rust**（静态单文件 CRT，零依赖） | `cli/` | `cli/target/release/japi.exe`（SDK 包内位于根目录 `japi.exe`） | `new` / `check` / `build` / `run` / `test` / `proxy` / `doctor` / `kill` |
| **引擎维护与测试** | **Node.js 24 原生 TS**（零 `node_modules`、零构建） | `tools/dev/` | `node tools/dev/cli.ts` | `build` / `test` / `release` / `foreign-map` / `clean` |
| **引擎本体（C++）** | MSVC Win32 Release (`/MT`) | `src/` | `src/build/bin/Release/{yd_japi.dll,newD3d9.dll,...}` | 注入游戏进程执行 |

开发环境版本由根目录 `mise.toml` 锁定（`node = "24"`、`rust = "stable"`）；地图作者使用独立 SDK 发布包时只需运行 `japi.exe`，无需安装 Rust、Node、Python 或配置 PowerShell。

---

## 架构

```
war3map.j（干净，只调标准 JASS native）
  └→ initializePlugin()
       ├→ StartCampaignAI(Player(12), "callback")  ← 加载 exploit
       │    └→ callback（内存 exploit + DLL 加载）
       │         └→ japi.tga (yd_japi.dll) 的 Initialize()
       │              ├→ inline hook UnitId → 哈希表 RPC 分发
       │              ├→ table_hook ExecuteFunc（惰性初始化钩子）
       │              └→ 清扫残留 japi<pid>.dll（看门狗）
       ├→ UnitId(I2S(GetHandleId(japi_ht)))   ← 桥接表句柄交给 DLL
       └→ ExecuteFunc("japiDoNothing")        ← 首次调用触发：
            创建 Lua VM + 加载 script\war3map.lua + 安装 message_dispatch 输入过滤
```

---

## 工作流 0：地图作者（Rust `japi.exe`）

在源码仓库中先编出 `japi.exe`（`node tools/dev/cli.ts build cli`），在 SDK 发布包中直接使用根目录 `japi.exe`：

```powershell
# 0. 检查环境（War3 路径、DLL、D3DX、w3x2lni、pjass、D3D 代理状态）
japi doctor

# 1. 新建项目（自动生成 japi.json + war3map.lua + lib/ + tests/ + config + base-map + README）
japi new MyMap --path ..\my-maps

# 2. 静态检查（不写 .w3x，检查 Lua require / objects.lua / JASS 语法）
japi check ..\my-maps\MyMap --strict-requires

# 3. 打包（自动读项目根 japi.json，输出到 dist\MyMap.w3x）
japi build ..\my-maps\MyMap

# 4. 启动 War3 交互游玩（不等待 Results: 行，也不自动杀进程）
japi run ..\my-maps\MyMap

# 5. 跑自动化测试（等待 C:\ProgramData\japi_debug.txt 出现 Results: 行后退出）
japi test ..\my-maps\MyMap

# 6. 管理 D3D 代理 / 强杀残留（含 1.27a deny-only DACL 修复）
japi proxy --verify     # 或 --install / --uninstall
japi kill
```

**Lua 多文件打包约定**：
- `japi build` 使用标准 Lua 5.4 **`package.preload["mod.name"] = function(...) ... end`** 打包进 `script\war3map.lua`；
- 模块源码原封不动保留，**不再限制 `require` 必须写在行首第 0 列**——缩进、`require("lib.util")`、条件 `require`、`pcall(require, ...)` 全部原生支持；
- 根 `objects.lua` 是构建专用物编声明文件，会通过 `tools/object-data/build.lua` 编译成 `.w3u`/`.w3a`，不会进入运行时 Lua 包。

**项目清单 `japi.json`**（可选，位于项目根目录，显式 CLI 参数始终覆盖配置）：

```json
{
  "schema": 1,
  "name": "MyMap",
  "baseMap": "base-map",
  "outFile": "dist/MyMap.w3x",
  "mapName": "MyMap.w3x",
  "withJassWrappers": false,
  "withGetFuncAddr": false,
  "withDebugger": false,
  "strictRequires": false
}
```

---

## 工作流 1：引擎维护与发版（统一入口：`mise.toml` + `tools/dev/cli.ts`）

所有依赖拉取、编译、测试、发版统一通过根目录 [mise.toml](mise.toml) 任务入口执行（底层为零依赖 Node 24 原生 TS）：

```powershell
# 0. 首次/换机器：装工具链（Node 24 + Rust）并拉取锁定版本的 w3x2lni 脚本与数据
mise install
mise run setup                           # 等价：node tools/dev/cli.ts setup（支持 --force）

# 1. 编译 C++ 单 TGA DLL（内嵌 newD3d9.dll + D3DX9_42.dll）与 Rust japi.exe
mise run build                           # 等价：node tools/dev/cli.ts build all
mise run build:dll                       # 仅编 C++ DLL
mise run build:cli                       # 仅编 Rust japi.exe

# 2. 跑全量离线回归（8 套：cli + pack + object-data + selector + ui + ydwe-compat + d3d-contract + examples）
mise run test
node tools/dev/cli.ts test cli           # cargo test
node tools/dev/cli.ts test pack          # 18 项打包诊断（单 TGA / war3map.imp / wtg+wct / SDK 布局）
node tools/dev/cli.ts test object-data   # 物编编译器 + w3x2lni 往返 + 打包集成
node tools/dev/cli.ts test selector      # 离线 jass.selector 套件
node tools/dev/cli.ts test ui            # 离线 UI 库与示例契约
node tools/dev/cli.ts test ydwe-compat   # Python + Lua + C++ + CLI 离线套件
node tools/dev/cli.ts test d3d-contract  # D3D handler 清单与 C++ 注册/覆盖率核对
node tools/dev/cli.ts test examples      # 12 个示例语法+打包（支持 --filter / --live）

# 3. 跑 War3 实机回归
node tools/dev/cli.ts test live          # 主回归（map/）
node tools/dev/cli.ts test demo          # 波次防守 Demo
node tools/dev/cli.ts test conformance   # 原生接口一致性测试台

# 4. 出可复现的作者 SDK 发布包（clean worktree 编译 C++ DLL + Rust japi.exe）
mise run release                         # 等价：node tools/dev/cli.ts release --sdk-bundle
node tools/dev/cli.ts release --sdk-bundle --no-build   # 复用本地产物做草稿验证

# 5. 辅助维护
node tools/dev/cli.ts foreign-map        # 生成 build/foreign-map 外来地图夹具
mise run clean                           # 安全移除 build/ 下 worktree 并清空 build/
```

---

## 引擎开发约定（C++ 侧）

- **目录约定**：
  - `src/src/yd_core/`：YDWE 核心（改编自 ydwar3）
  - `src/src/lua_engine/`：Lua 引擎 + bridge dispatch
  - `src/src/extensions/`：自定义扩展 native
  - `src/src/d3d9/`：D3D9 渲染代理（`newD3d9.dll`）
  - `src/vendor/lua-5.4/`：Lua 5.4 静态库
- **改机器码必须可回滚**：字节补丁用 `base::hook::patch_guard`，inline hook 用 `warcraft3::jass::inline_hook_install` + `inline_hook_uninstall`。
- **静态 CRT（`/MT`）**：`yd_japi.dll`、`newD3d9.dll` 与 Rust `japi.exe`（`+crt-static`）全部静态链接 CRT，不依赖目标机器安装 VC 运行库。
- **D3D 代理随地图分发**：`japi build` 无条件打包 `d3d9.tga`、`d3dx9_42.tga` 与 `d3d9.tga.sha256`；游戏内由 `yd_japi.dll` 释放到 `war3.exe` 同目录，下一次启动生效。

---

## 配置管理

`japi.exe` 自动兼容**源码仓库布局**（`src/build/bin/Release/`、`reference/empty-map/`、`tools/w3x2lni/`）与**干净 SDK 包布局**（`bin/`、`templates/empty-map/`、`vendor/w3x2lni/`）：

- **War3 安装目录优先级**：`--war3-dir` > 环境变量 `WAR3_DIR` > 根目录 `japi.local.json`（模板见 `japi.local.json.example`，gitignored；亦兼容读取旧 `tools/config.local.ps1`）> 内置默认路径（`D:\Warcraft III Frozen Throne 1.27a publish`）。
- **引擎日志路径**：DLL 固定写 `C:\ProgramData\japi_debug.txt`（并发兜底 `japi_debug_<pid>.txt`），不可通过 CLI 改写。
- **Lua DAP 调试器**：打包加 `--with-debugger`，Lua 侧设 `runtime.debugger = 4278`，VS Code `actboy168.lua-debug` attach `127.0.0.1:4278`。

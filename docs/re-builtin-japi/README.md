# builtin-japi（wenhao_plugin）全新逆向文档

本目录是对"内置 JAPI"插件的**从零逆向**成果。所有结论均来自对原始二进制与地图文件的直接分析（objdump 反汇编、纯 struct PE 解析脚本、字节级文件对比），**未参考任何既有逆向资料**（`docs/analysis/`、旧 HTML 报告等均未使用）。

## 分析对象

| 对象 | 来源 | 说明 |
|------|------|------|
| `build/_orig_check/wenhao_plugin.tga` | builtin-japi.w3x 解包 | 4.65MB 加载器 DLL（ImageBase 0x10000000） |
| `reference/builtin-japi/extracted/*.dll/.exe` | 从其 .rsrc 提取 | 5 个内嵌 PE（注意：两个文件名与内部名交叉互换） |
| `build/_orig_check/` 地图文件 | 同 w3x 解包 | war3map.j (2243 行)、main.lua、war3map.imp、callback 等 |

## 文档索引

| 文档 | 对象 | 内容 |
|------|------|------|
| [01-loader-wenhao-plugin.md](01-loader-wenhao-plugin.md) | wenhao_plugin.tga | PE 结构、资源枚举、`call`/`get` 导出全反汇编、加载链六阶段 |
| [02-jass-dll.md](02-jass-dll.md) | Jass.dll（1.5MB，546 导出） | JASS hook 引擎：native 表布局、五种 hook、japi 注册、UnitId 通道、看门狗线程 |
| [03-yd-lua-engine.md](03-yd-lua-engine.md) | yd_lua_engine.dll（996KB，600 导出） | 定制 Lua 5.3 fork、惰性初始化链、15 个 jass.* 模块、exec-lua 通道、SLK |
| [04-d3d9-proxy-and-tools.md](04-d3d9-proxy-and-tools.md) | newD3d9.dll + pjass.exe + d3dx9_42.dll | D3D9 渲染层真实挂钩方式、pjass 反解壳 UPX、d3dx9 官方性验证 |
| [05-map-side.md](05-map-side.md) | 地图侧文件 | MPQ 清单、initializePlugin 逐行、113 个 UnitId 分发名、wrapper 约定 |
| [09-runtime-gates-and-dormant-code.md](09-runtime-gates-and-dormant-code.md) | jass.dll 运行时行为补完 | pjass 运行时语法闸门（失败 `exit(0)`）、`callback` hash 闸门 `0x880B034B`、看门狗清理器（否证插件扫描）、d3d8 临时设备取 Present、WININET=StormLib HTTP 后端、注册表 dead store |
| [10-tables-hooks-and-game-side.md](10-tables-hooks-and-game-side.md) | jass.dll 表与钩子 + game.dll 侧 | async 队列表与 IAT 触发、`hook()` 五位定义（0x4 = 改注册块立即数）、`from_string` 表项指针、事件双表（安装账本 vs 事件总线）、fnA=`get_instance`（per-thread TLS 槽表）/fnB=`get_gameui`（CGameUI 单例） |

## 经交叉验证的整体架构

```
war3map.j main()
  └→ initializePlugin()
       ├→ StartCampaignAI(Player(12), "callback")     ← AI 脚本机制加载 exploit
       │    └→ callback（return-bug 类型混淆 → Memory[] 任意读写 → shellcode）
       │         └→ ExportFileFromMpq("wenhao_plugin.tga" → "<pid>.dll")
       │              └→ LoadLibrary + 调导出 "call"(arg)     【原版尾部；仓库 callback 尾部已被改】
       │                   ├→ 写盘 pjass.exe / D3DX9_42.dll / newD3d9.dll
       │                   ├→ LoadLibrary jass.dll（Sleep(10) 无界重试）
       │                   │    └→ Jass.dll!call(0)：注册 JAPI native + hook UnitId/AbilityId 等
       │                   │         └→ 看门狗线程：轮询 "get"==1 → DeleteFileA("<pid>.dll") 清理
       │                   ├→ LoadLibrary lua_engine.dll（= yd_lua_engine）
       │                   │    └→ init_lua_engine()：hook ExecuteFunc/AbilityId（惰性，不建 Lua 状态）
       │                   ├→ Jass.dll!init(0)
       │                   └→ g_initialized = 1（0x10014F50）
       ├→ UnitId(I2S(GetHandleId(japi_ht)))            ← 把桥接 hashtable 句柄交给插件
       └→ UnitId("SaveFunc") + GetFuncAddr(japiDoNothing) ← 注册轮询锚点
```

首次 `ExecuteFunc` 时 yd_lua_engine 才惰性创建 Lua 状态（定制 5.3 fork）→ 注册 15 个 jass.* 模块到 `_PRELOAD` → debugger listen 127.0.0.1:4278 → 执行 Base64 chunk → 自卸载钩子。运行时通道三条：

- **UnitId(str)**：JASS→插件 RPC（hashtable 传参，签名字符串如 `(II)I`），jass.dll 对其做 **inline hook（UnitId+0x13）**
- **AbilityId("exec-lua: xxx")**：加载执行 MPQ 内 Lua 模块（前缀 9 字符检测）
- **EXExecuteScript("(S)S")**：直接执行 Lua 字符串

## 关键事实交叉验证表

| 事实 | 独立验证来源 |
|------|-------------|
| extracted/ 两 DLL 文件名交叉互换（996KB=yd_lua_engine，110KB=newD3d9） | 03、04 各自从导出目录内部名验证 |
| 仓库 callback 尾部非原版（原版调 `call`，插件无 `Initialize` 导出） | 01（导出表仅 call/get）、05（callback 字节 vs 导出矛盾） |
| native 哈希表节点布局：+0x18 name、**+0x1c(28) func_address** | 02 反汇编（table_hook 函数体）；与本项目 hashtable.h 一致 |
| 加载全程同步完成（call 返回即初始化完毕，"get" 仅供轮询确认） | 01（call 六阶段无异步）、05（war3map.j 紧接 UnitId 交表） |
| D3DX9_42.dll 是微软官方文件（仅剥除签名块） | 04 与本机 SysWOW64 逐字节比对 |

## 对 map-inject 项目的修正点（本轮新逆向推翻/补充的旧认知）

1. **`call` 的参数无关紧要**：入参存到 0x10014F54 后**全二进制无任何读取点**。旧认知"必须传 pExportFromMpq"不成立——我们 callback 传 0 没有损失。
2. **UnitId 是 inline hook（+0x13 起，版本>6401 再 +2）**，不是改表/改链表。我们改链表节点 +12 的方案机制不同但等价可行（与 callback 的 CreateJassNativeHook 同源）。
3. **jass.dll 有看门狗线程**：`call` 导出内 CreateThread，自旋等 "get"==1 后 `DeleteFileA("<pid>.dll")`、Sleep(10000) 再清理历史残留——PID 命名是为了多开不冲突 + 事后自清。清理器的过滤条件是"纯数字名 + 文件大小 4–6MB"（**不是** PID 数值范围，2026-11-19 更正）。我们没有这个清理机制（可不加）。
3b. **没有插件目录扫描**：`\*.dll` + `FindFirstFileA` 只服务上面的清理器；全库 `LoadLibraryA` 仅 2 处（d3d8/d3d8d 的 `DebugSetMute` 代理、`newD3d9.dll`）、`LoadLibraryW` 仅 1 处（Storm.dll）。所谓"可插拔插件"是误读，见 [09](09-runtime-gates-and-dormant-code.md)。
4. **Lua 引擎是惰性初始化**：init_lua_engine 只装 ExecuteFunc/AbilityId 两个 table_hook，首次 ExecuteFunc 才建 Lua 状态；且执行的是 **Base64 编码 chunk**。我们的 Initialize 直接建状态是简化，方向可行。
5. **输入系统不走 WndProc hook**：用 `message_dispatch::add_filter`（游戏内消息分发过滤），过滤器按消息 ID 分发 key_down/mouse_down 等到 Lua。我们的 libs_message 用 SetWindowLongPtr（YDWE 方式），属于不同路线。
6. **newD3d9.dll 不是 d3d9 代理**：它只建临时设备读 vtable+0x44 取 Present 地址注册给 Jass.dll，真正挂钩在 Jass.dll 侧；渲染管线 = storm 读图 → D3DXCreateTexture → ID3DXSprite/ID3DXFont 每帧绘制。
7. **内嵌 Lua 是定制 5.3 fork**：`lua_newstate2(alloc,ud,seed)`、`lua_setgchash` 私有导出，`lua_State` 布局较官方 +0xC。我们用官方 Lua 5.4，交互面仅限于 C API，无碍。
8. **pjass.exe 被故意反解壳**（UPX method/level 字段非法化 + LZMA stub + 压缩流移位修补），作者明显不希望它被分析。**2026-11-19 更正：它真的会被调用**——`InitGame` 里 `CreateThread` 起线程，把 `common.j`/`blizzard.j`/`war3map.j` 从 MPQ 抽到 `jass_temp\`，再 `CreateProcessA("pjass.exe jass_temp\...")` 读管道；洗掉两条良性警告后统计 `returned`/`Index `，有错就 `exit(0)` 杀掉整个 war3。同线程还有一道 `callback` 文件 hash 闸门（必须等于 `0x880B034B`），不匹配也 `exit(0)`。见 [09](09-runtime-gates-and-dormant-code.md)。

## 存疑点汇总（各文档末节有完整清单）

- 原版 callback 尾部实物已失（仓库与 w3x 内均为改版），`call` 的原始调用参数不可考（但见修正点 1：参数无读取点，影响为零）
- fnA/fnB 两个 game.dll 函数的真实语义（"config"/"EnableSelect" 仅为定位特征）
- ExecuteFunc 惰性初始化中 Base64 chunk "war3map_main" 的内容来源路径
- pjass.exe 壳内内容（两层扰乱，手工解壳失败）
- `exec-lua:wenhao_texture` 对应的 Lua 文件不在 MPQ 中，去向不明

## 分析中间产物（可复验）

- `build/_re_analysis/`：parse_rsrc.py、extract_pe.py、wenhao_disasm.txt、5 个内嵌 PE 原样导出
- `build/re-scratch/`：undname.py（MSVC 修饰名还原，546 条零失败）、exports_full.tsv、iat_map.txt、disasm 转储
- `build/_re_analysis/lua_engine/`：03 的 PE 解析脚本与导出/反汇编/字符串转储

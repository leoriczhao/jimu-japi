# 03 · yd_lua_engine.dll（内置 JAPI 的 Lua 引擎）逆向分析

> 分析对象：`reference/builtin-japi/extracted/newD3d9.dll`（996 352 字节）
> 所有结论均来自对该二进制的直接解析（自写 PE 解析脚本 / objdump 2.30 反汇编 / 字符串扫描），未参考任何已有分析资料。
> 约定：RVA 以 ImageBase 0x10000000 为基准；VA = RVA + 0x10000000；文件偏移另注。

---

## 一、概述

`newD3d9.dll` 的文件名具有误导性：其导出目录内部名为 **`yd_lua_engine.dll`**，是"内置 JAPI"体系中的 **Lua 引擎模块**。它在 Warcraft III 1.27a 进程内：

- 内嵌一个**定制过的 Lua 5.3** 解释器（导出全部 Lua C API 供自己/他模块链接）；
- 通过 **Jass.dll** 提供的底层能力（jass VM 钩子、Storm 档案读取、内存搜索、消息分发等）与游戏交互；
- 向 Lua 暴露 `jass.*` 系列共 **15 个模块**（common/globals/japi/hook/runtime/slk/console/debug/message/bignum/log/ai/debugger/selector/storm）；
- 内置完整的 **SLK/物体编辑器数据解析库**（`slk::` 命名空间，449 个 C++ 导出）；
- 提供运行时执行 Lua 代码的通道（`AbilityId("exec-lua:...")` 钩子、新 JAPI 函数 `EXExecuteScript`）。

与 Jass.dll 的分工：Jass.dll 负责"贴游戏"（搜索游戏内存、钩 jass 函数、Storm 文件 IO、窗口消息分发、D3D 信息），yd_lua_engine.dll 负责"Lua 世界"（解释器、模块层、SLK 数据、把游戏事件翻译成 Lua 调用）。两者通过**导出表互相调用**：yd_lua_engine 导入 Jass.dll 的 114 个符号，并反向把 3 个查询回调注入 Jass.dll 的函数地址表。

---

## 二、事实清单（带证据）

### 2.1 PE 基本信息与内部名验证

| 项目 | 值 | 证据 |
|---|---|---|
| 格式 | PE32 DLL (i386) | `file` 输出；e_lfanew=0x110，COFF machine=0x14c |
| ImageBase | 0x10000000 | 可选头偏移 +28 |
| 入口点 | RVA 0x7027b | 可选头偏移 +16 |
| COFF 时间戳 | 0x59E23261（2017-10-14） | COFF 头 |
| 区段 | .text(0x1000/0x9ABF8) .rdata(0x9C000/0x4DDEE) .data(0xEA000/0x5EA8) .rsrc(0xF0000/0x1E0) .reloc(0xF1000/0x6FBC) | 区段表 |
| 导出目录 | RVA 0xBFAD0，大小 0x2798A | 数据目录项 0 |
| **内部名** | **`yd_lua_engine.dll`** | 导出目录 Name RVA=0xC1268 → 字符串 @文件偏移 0xC0268 |
| 导出数量 | 函数 600 / 名称 600，OrdinalBase=1 | 导出目录 |

结论：**文件名 newD3d9.dll ≠ 内部名；按导出目录内部名，本文件即 yd_lua_engine.dll**（陷阱 1 验证完毕）。
CRT 为静态链接：全文件无 MSVCRT*.dll 导入，且含 Dinkumware STL 版权串 `"Copyright (c) 1992-2004 by P.J. Plauger, licensed by Dinkumware, Ltd."`。

### 2.2 导出表（600 个）分组

按名称可分为四组（完整转储用自写脚本解析导出目录获得，RVA 与 objdump `-p` 一致）：

**A. 插件接口（3 个）**

| 导出 | RVA | 行为（反汇编证据） |
|---|---|---|
| `PluginName` | 0x1466 | `mov eax,0x100AE834; ret` —— 返回常量字符串 `"yd_lua_engine"`（ASCII，@文件 0xAA834） |
| `SetWindow` | 0x1459 | 将第一个参数存入全局 `0x100EEB80`（见 2.8） |
| `init_lua_engine` | 0x11981 | 初始化入口（见 2.6） |

**B. 引擎内部导出（1 个）**

- `?initialize@lua_loader@lua_engine@warcraft3@base@@YAXXZ`（RVA 0x11830）—— C++ 名显示源码命名空间为 `base::warcraft3::lua_engine::lua_loader`。

**C. slk:: 命名空间 C++ 符号（449 个）** —— SLK/物体数据解析库（见 2.7）。直方图：`SlkValue` 318、`ObjectManager` 26、`SlkSingle` 8、`SlkTable` 5、`WesTable` 5、`WtsTable` 5、`MetaTable` 4、`MetaSingle` 4、`SlkReader` 2、`IniTable` 1，其余为 STL 模板实例。

**D. Lua C API（147 个）** —— 93 个 `lua_*` + 44 个 `luaL_*` + 10 个 `luaopen_*`：

```
lua_* (93):  lua_absindex lua_arith lua_atpanic lua_callk lua_checkstack lua_close
  lua_compare lua_concat lua_copy lua_createtable lua_dump lua_error lua_gc
  lua_getallocf lua_getfield lua_getglobal lua_gethook lua_gethookcount lua_gethookmask
  lua_geti lua_getinfo lua_getlocal lua_getmetatable lua_getstack lua_gettable
  lua_gettop lua_getupvalue lua_getuservalue lua_iscfunction lua_isinteger lua_isnumber
  lua_isstring lua_isuserdata lua_isyieldable lua_len lua_load lua_newstate lua_newstate2
  lua_newthread lua_newuserdata lua_next lua_pcallk lua_pushboolean lua_pushcclosure
  lua_pushfstring lua_pushinteger lua_pushlightuserdata lua_pushlstring lua_pushnil
  lua_pushnumber lua_pushstring lua_pushthread lua_pushvalue lua_pushvfstring lua_rawequal
  lua_rawget lua_rawgeti lua_rawgetp lua_rawlen lua_rawset lua_rawseti lua_rawsetp
  lua_resume lua_rotate lua_setallocf lua_setfield lua_setgchash lua_setglobal lua_sethook
  lua_seti lua_setlocal lua_setmetatable lua_settable lua_settop lua_setupvalue
  lua_setuservalue lua_status lua_stringtonumber lua_toboolean lua_tocfunction
  lua_tointegerx lua_tolstring lua_tonumberx lua_topointer lua_tothread lua_touserdata
  lua_type lua_typename lua_upvalueid lua_upvaluejoin lua_version lua_xmove lua_yieldk
luaL_* (44): luaL_addlstring luaL_addstring luaL_addvalue luaL_argerror luaL_buffinit
  luaL_buffinitsize luaL_callmeta luaL_checkany luaL_checkinteger luaL_checklstring
  luaL_checknumber luaL_checkoption luaL_checkstack luaL_checktype luaL_checkudata
  luaL_checkversion_ luaL_error luaL_execresult luaL_fileresult luaL_getmetafield
  luaL_getsubtable luaL_gsub luaL_len luaL_loadbufferx luaL_loadfilex luaL_loadstring
  luaL_newmetatable luaL_newstate luaL_openlibs luaL_optinteger luaL_optlstring
  luaL_optnumber luaL_prepbuffsize luaL_pushresult luaL_pushresultsize luaL_ref
  luaL_requiref luaL_setfuncs luaL_setmetatable luaL_testudata luaL_tolstring
  luaL_traceback luaL_unref luaL_where
luaopen_* (10): base coroutine debug io math os package string table utf8
```

注意其中有 **2 个不属于任何标准 Lua 发行版的函数**：`lua_newstate2`、`lua_setgchash`（见 2.4）。

### 2.3 内嵌 Lua 版本：5.3.x

| # | 证据 | 位置 |
|---|---|---|
| 1 | 字符串 `"Lua 5.3"`（紧跟 `"_VERSION"`，为 lbaselib 注册 `_VERSION` 的取值） | .rdata RVA 0xB24A0（文件 0xB14A0） |
| 2 | `lua_version`（RVA 0x15580）：`L==NULL` 时返回静态 double **503.0** | 常量 @VA 0x100AF1B0（文件 0xAA1B0），8 字节小尾序 = 503.0 |
| 3 | `lua_resume`（RVA 0x18F10）为 **3 参数**形态：`mov eax,[ebp+0x10]; neg eax; shl eax,4; add [edi+0x14],eax`（`L->top -= nargs*16`，TValue=16 字节）；且 `movzwl 0x74(%edi)` 读取 16 位 `nny` 字段 | 反汇编 0x10018F10 起；Lua 5.4 的 `lua_resume` 为 4 参数，可据此排除 5.4 |
| 4 | 存在 5.3 引入的 API：`lua_isinteger`、`lua_stringtonumber`、`lua_rotate`、`lua_geti`、`lua_seti`、`luaopen_utf8` | 导出表 |
| 5 | 存在 5.2 引入的 API（排除 5.1）：`lua_compare`、`lua_arith`、`lua_copy`、`lua_rawlen`、`lua_rawgetp`、`lua_rawsetp`、`luaL_setfuncs`、`luaL_traceback`、`luaL_requiref`、`luaL_checkversion_`；且为 `luaL_newstate` 而非 5.1 的 `lua_open` | 导出表 |
| 6 | 排除 5.4：存在 `lua_getuservalue`/`lua_setuservalue`（单数形式），**无** 5.4 的 `lua_getiuservalue`/`lua_setiuservalue`、`lua_closethread`、`lua_resetthread` | 导出表 |
| 7 | package.path 模板含 `..\share\lua\5.3\?.lua`（见 2.6） | .rdata RVA 0xB2810 |

小版本号：二进制中未见 `Lua 5.3.x` 完整发布号字符串（嵌入式裁剪，无 `LUA_COPYRIGHT`）。**推断为 5.3.4**：构建时间 2017-10，当时最新发行版即 5.3.4（5.3.5 发布于 2018-09）。此点为时间线推断，**存疑**。

### 2.4 Lua 为非原版 fork：结构偏移 +0xC 与两个私有 API

`lua_newstate2`（RVA 0x1C1E0，ord 535）反汇编显示签名为 **`lua_newstate2(lua_Alloc alloc, void* ud, unsigned int seed)`**：

- 以 `alloc(ud, NULL, 8, 0x340)` 分配 0x340 字节的 LG 块；
- `mov eax,[ebp+0x10]` → `mov [edx+0x38],eax`：**第三参数 seed 写入 global_State+0x38**（原版 5.3 的 `G->seed` 在 +0x2C，且原版 `lua_newstate` 无 seed 参数，种子由 `makeseed()` 内部生成）；
- `G+0x7C = mainthread(L)`、`G+0x70 = 0xC8 (gcpause=200)`、`G+0x3D = 7 (GCstate)`、`G+0x3C = currentwhite`、`L+0x18 = l_G`、`L+0x34 = L (twups)`、`L+0x74 = 1 (word, nny)`、`L+0x12 = 0 (status)`。

对照原版 5.3 布局（`l_G`@0x0C、`seed`@0x2C、`gcpause`@0x64、`panic`@0x6C、`version`@0x74、`mainthread`@0x70、`twups`@0x28、`status`@0x06），**该 fork 在 `lua_State` 与 `global_State` 头部各多插入 12 字节（3 个 dword）私有字段**，所有后续偏移系统性 +0xC。另两处旁证：

- 状态创建后 `[[L+0x18]]+0x78 = 0x1001052A`（0x1001086B），即向 `G->panic`（0x6C+0xC=0x78）写入 panic 回调；该回调体内引用格式串 `"PANIC: unprotected error in call to Lua API (%s)\n"`（.rdata RVA 0xB01D8）；
- `lua_version` 读 `[L+0x18]+0x80`（0x10015591），即 `G->version`（0x74+0xC=0x80）。

`lua_setgchash`（RVA 0x18260，ord 564）：做标准 `index2adr` 解析（含对 0xFFF0B9D8 = LUA_REGISTRYINDEX = -1001000 的比较，对应 LUAI_MAXINDEX=1000000），随后把**栈顶 TValue 的 value/tt 两个 dword 写入 idx 处 GCObject 的 +8/+0xC** 并弹栈。语义疑似"给表/对象设置自定义哈希/GC 回调"，**具体机制未证实**（标准 5.3 的 Table 布局 +8=metatable、+0xC=array，与该写法不吻合，应为 fork 私有字段）。

### 2.5 导入表

| DLL | 符号数 | 说明 |
|---|---|---|
| Jass.dll | 114 | 见下（ILT RVA 0xE74D4，IAT 起 RVA 0x9C014，DLL 名字符串 @RVA 0xE95A0） |
| KERNEL32.dll | 98 | 常规 Win32；含 `LoadLibraryW`、`GetProcAddress`（debugger 用，见 2.9） |
| USER32.dll | 3 | 仅 `GetCursorPos`、`ScreenToClient`、`GetClientRect` |
| ADVAPI32.dll | 5 | `RegOpenKeyExW`/`RegCreateKeyExW`/`RegQueryValueExW`/`RegCloseKey`（用途见存疑点） |

**没有** `GetAsyncKeyState`、`SetWindowLongA/W/Ptr`、`CallWindowProc*`、钩子类 API —— 本 DLL **不做窗口子类化/键盘钩子**；输入事件全部经由 Jass.dll 的 `message_dispatch`（见 2.8）。

Jass.dll 的 114 个导入符号按职能分组（全部为 `base::warcraft3::*` / `base::*` / `jass::*` C++ 名）：

- **jass 函数调用**：`jass::call`（可变参）、`jass::call_param`（构造/push\<T\>/push_real/data/析构）、`jass::call(name,uint,uint)`、`jass::callJass`、`jass::get_func_addr`、`jass::jass_func`、`jass::japi_func`、`jass::initialize_mapping`、`jass::jass_function`/`jass::japi_function`（两个 unordered_map 数据导入）、`jass::get_func_name`、`jass::func_value::*`（is_valid/get_return/get_param/set_sleep/has_sleep/get_address）
- **jass 钩子**：`jass::hook`、`jass::unhook`、`jass::table_hook`、`jass::table_unhook`、`jass::japi_add`、`jass::trampoline_create`、`base::hook::inline_install`
- **jass 变量/字符串**：`jass::global_variable::*`（构造/[]/array_size/array_vaild/type/is_array/is_vaild/name/ptr）、`jass::handle_ref`/`handle_unref`、`jass::from_real`/`to_real`、`jass::create_string`/`from_string`/`from_trigstring`/`from_stringid`、`jass::SetCharToJstring`、`detail::string_hash`、`jass::save_addr`/`remove_saved_addr`、`jass::get_map_name`/`get_map_path`、`jass::get_logs_switch`
- **游戏内存/搜索**：`war3_searcher::get_gameui`/`get_version`、`get_war3_searcher`、`basic_searcher::search_string`/`search_int64_in_text`、`get_vfn_ptr`、`next_opcode`、`convert_function`、`get_current_jass_pos`、`object_to_handle`/`handle_to_object`/`get_object_type`、`get_jass_vm`/`get_jass_thread`
- **游戏状态**：`player::local`、`player::selection`、`command_line`（构造/析构/has/map[]）、`register_game_reset_event`
- **Storm 档案 IO**：`storm_dll` 构造/析构 + `load_file`/`unload_file`/`has_file`/`get_proc`
- **窗口/D3D**：`d3d::GetWar3Window`、`d3d::get_func_addr`（返回 `std::map<string,uint>&`）
- **消息分发**：`message_dispatch::add_filter`/`remove_filter`
- **控制台**：`console::enable`/`disable`/`read_post`/`read_try`/`read_release`/`disable_close_button`
- **基础设施**：`exception`/`windows_exception`/`system_exception` 类、`path::get/normalize/equal`（boost::filesystem）、`file::read_stream`/`write_stream`、`u2w`/`w2u`、`Base64Decode`

### 2.6 init_lua_engine 与启动链（反汇编还原）

**`init_lua_engine`（RVA 0x11981）本体极小，不创建 Lua 状态**：

```asm
10011981  call   dword [0x1009C138]      ; Jass.dll!base::d3d::GetWar3Window()
10011987  mov    [0x100EEB80], eax       ; 保存游戏主窗口 HWND
1001198C  call   0x10011830              ; lua_loader::initialize()
10011991  ; 一次性守卫（0x100EEDC0 标志位）内调用 0x1001186A
```

**`lua_loader::initialize`（RVA 0x11830）** 注册两个 jass 表钩子（`jass::table_hook(name, &原地址, 新回调)`，IAT 0x9C120）：

- `table_hook("ExecuteFunc", &0x100EEB64, 0x100115ED)` —— 钩住 jass 原生函数 ExecuteFunc；
- `table_hook("AbilityId", &0x100EEB6C, 0x10010A93)` —— 钩住 jass 原生函数 AbilityId。

**一次性初始化（RVA 0x1001186A）** 做两件事：

- `japi_add(0x10010B81, "EXExecuteScript", "(S)S")`（IAT 0x9C124）——向 Jass.dll 注册新 JAPI 函数 **EXExecuteScript**（签名 (S)S：字符串→字符串，处理器 RVA 0x10B81）；
- 向 `d3d::get_func_addr()` 返回的 `map<string,uint>`（IAT 0x9C134）写入 3 个反向查询回调：
  `["get_jass_func_info"]=0x10010D1D`、`["get_jass_func_msg"]=0x10010CB4`、`["get_lua_call_msg"]=0x100015EF`。

**Lua 状态惰性单例（RVA 0x100107EC）**：所有入口经 `0x10011B38`（取状态持有槽 `0x100EEDC4`，首次访问时经 `register_game_reset_event` 注册一个游戏重置回调，可调用对象 vtable @RVA 0xB04F8）→ `0x100107EC`：`if (*holder==NULL) { 创建; 执行调试器语句 }`。创建函数（RVA 0x10010825）顺序为：

1. **取游戏随机种子**：`get_war3_searcher()` → `search_string("SetRandomSeed")`（字符串 @RVA 0xAEC74）→ `next_opcode(addr+5, 0x8B, 6)` → 指针链 `[eax+2]→[eax]→[eax+4]` 取出一个 dword（即 jass 函数 SetRandomSeed 体内引用的游戏 RNG 状态全局）；
2. **`lua_newstate2(alloc=0x10010506, ud=0, seed=游戏种子)`**（0x1001085D）——Lua 字符串哈希种子与游戏种子绑定；
3. 写 panic 回调（`G+0x78 = 0x1001052A`，见 2.4）；
4. **`luaL_openlibs(L)`**（RVA 0x1C3E0，ord 482）；
5. **注入 preload searcher**（RVA 0x100105C4）：操作 `_LOADED`、`package`、`searchers` 表，向 `package.searchers` 写入 preload 搜索器（特征串 `"\n\tno field package.preload['%s']"` @RVA 0xB0218、`"_PRELOAD"` @RVA 0xB020C）；
6. **设置 package.path / cpath 并追加 3 个自定义 searcher**（RVA 0x10010658）：
   - `package.path = "!\lua\?.lua;!\lua\?\init.lua;!\?.lua;!\?\init.lua;!\..\share\lua\5.3\?.lua;!\..\share\lua\5.3\?\init.lua;.\?.lua;.\?\init.lua"`（@RVA 0xB2810，文件 0xB1810）
   - `package.cpath = "!\?.dll;!\..\lib\lua\5.3\?.dll;!\loadall.dll;.\?.dll"`
   - 追加 searcher 函数 0x1000D236 / 0x1000D019 / 0x1000D759（`lua_rawseti` 入表）；**其中 0x1000D019、0x1000D236 体内调用 Jass.dll 的 `storm_dll::load_file`/`unload_file`（IAT 0x9C040/0x9C03C）——即从地图 MPQ 档案内加载 Lua 模块**；
7. **注册 15 个 jass.* 模块**（RVA 0x100131B9）：逐条以 `_PRELOAD[name]=openf` 形式预载（辅助函数 RVA 0x10013173：`lua_getfield(L, LUA_REGISTRYINDEX, "_PRELOAD")` → `lua_pushcclosure(openf)` → `lua_setfield(-2, name)`）：

   | 模块 | openf RVA | 模块 | openf RVA |
   |---|---|---|---|
   | jass.common | 0xA748 | jass.message | 0x15281 |
   | jass.globals | 0xBD52 | jass.bignum | 0xB4B1 |
   | jass.japi | 0xC5BA | jass.log | 0xCC47 |
   | jass.hook | 0xC473 | jass.ai | 0x9E0D |
   | jass.runtime | 0xEE4E | jass.debugger | 0x138EC |
   | jass.slk | 0x1017F | jass.selector | 0xFAD2 |
   | jass.console | 0xAAE8 | jass.storm | 0x104CE |
   | jass.debug | 0xBA97 | （共 15 个） | — |

   （模块名字符串 @RVA 0xB0534–0xB05F0，文件 0xAF534 起）

   同函数内还创建两个元表（`luaL_newmetatable` + `luaL_setfuncs`）：
   - **`jhandle_t`**：`__eq`=0x1000287C、`__tostring`=0x100028B0、`__gc`=0x100028CC —— 游戏 handle 的 Lua 包装类型；
   - **`jarray_t`**：`__index`=0x1000253B、`__newindex`=0x100025C6、`__len`=0x10002625 —— jass 数组包装类型；
8. 回到 0x100107EC：**立即执行** `luaL_loadstring(L, "(require 'jass.debugger').listen('127.0.0.1', 4278)")`（串 @RVA 0xB02E8）+ `lua_pcallk(L, nargs=0, nresults=-1(LUA_MULTRET), msgh=0, ctx=0, k=NULL)`（参数序据 0x1001080F–0x10010817 六次入栈还原）—— 引擎启动即在本机 4278 端口监听调试器。

**ExecuteFunc 钩子（RVA 0x100115ED）—— 引擎主入口，一次性**：

- `jass::from_string(参数)` 取被执行函数名；构造 `"initialization"` 等字符串；
- 调 `0x1001136C`：`detail::string_hash(name)` → 转 36 进制文本 → 拼 `".mdx"` → `storm_dll::has_file` 检测地图内是否存在该哈希命名文件；
- 条件成立时调 `0x1001121A`：**`Base64Decode(内容)` → `luaL_loadbufferx(L, 解码缓冲, 长度, chunkname, 0)` → pcall**（IAT 0x9C118 = Base64Decode，luaL_loadbufferx RVA 0x1B130）；
- 以 `(".mdx",3)`、`(".blp",4)` 调 `0x10011429`（内部经 `get_map_name`/`string_hash`/`has_file` 遍历地图资源，语义见存疑点）；
- `lua_pushcclosure(L, 0x10011122, 0); lua_setglobal(L, "compare_file")` —— 注册 Lua 全局函数 compare_file；
- 以 chunkname **"war3map_main"**（@RVA 0xB0430）调 `0x1001121A` 执行对应 Base64 脚本 —— **这是地图 Lua 主脚本的加载点**；
- 结尾 `table_unhook("ExecuteFunc", &0x100EEB64, 0x100115ED)` **自卸载**，再经 `get_func_addr("ExecuteFunc")`、`SetCharToJstring` 转发原始调用。

**AbilityId 钩子（RVA 0x10010A93）—— 运行时 exec-lua 通道**：

- 参数经 `from_string` 取出后，检查 9 字符前缀 **`"exec-lua:"`**（@RVA 0xB031C；`push 9` 做长度比较）；
- 命中则剥去可选首尾双引号（0x22），取 Lua 状态，`lua_getglobal(L,"require")` + `lua_pushlstring(负载)` + 安全调用（0x10001919）—— 即 `require("...代码...")`；
- 无论命中与否，结尾 `call [0x100EEB6C]` 转发原 AbilityId。

**EXExecuteScript 处理器（RVA 0x10010B81）**：`from_string` → `from_trigstring` → `luaL_loadbufferx` → pcall → 返回值经 `lua_tolstring` → `jass::create_string` 转回 jass 字符串返回（与签名 "(S)S" 吻合）。

**反向查询回调**（供 Jass.dll 侧调用，把请求转给 Lua 全局函数）：

- `get_jass_func_msg`（0x10010CB4）：`lua_getglobal(L,"get_jass_func_msg")` + `lua_pushinteger(参数)` + pcall，失败返回 `""`；
- `get_jass_func_info`（0x10010D1D）：同上但 `lua_pushstring(参数)`；
- 另有一定时器初始化分支（RVA 0x10010E85 附近）：经 `luaL_loadstring` 执行 `"function get_jass_variable(name)\treturn (require 'jass.globals')[name]end"`（@RVA 0xB0368）并以 `"get_jass_variable"` 设为全局；定时器系统经 `jass::callJass` 调用 jass 原生 `CreateTimer`/`TimerStart`/`GetExpiredTimer`/`DestroyTimer`（字符串 @RVA 0xB0260/0xB027C/0xB0288/0xB026C），到期回调 0x100108E8 —— 即 **jass.runtime 的定时器是用游戏原生计时器模拟的**。

### 2.7 SLK 系统证据

**符号证据**（导出表，449 个 `slk::` C++ 名）：

- 核心类：`slk::ObjectManager`（含 `load<SLK_TYPE/TXT_TYPE/ROBJECT_TYPE/META_SLK_TYPE/OBJ_TYPE>` 模板实例与 `get_table_map`）、`slk::SlkTable`、`slk::IniTable`、`slk::MetaTable`、`slk::ObjTable<0/1>`、`slk::WesTable`、`slk::WtsTable`、`slk::SlkValue`（318 个实例方法）、`slk::SlkSingle`、`slk::MetaSingle`、`slk::object_id`、`slk::SlkReader`/`WesReader`/`WtsReader`、哈希用 `ignore_case` 比较器；
- ObjectManager 构造签名之一为 `ObjectManager(InterfaceStorm&)` —— SLK 库直接吃 Storm 档案接口；
- jass.slk 模块 openf（RVA 0x1017F）：一次性在全局 0x100EEDA8 构造 `storm_dll`（IAT 0x9C048）对象并注册 atexit 清理；向模块表写入类型常量 `ability`/`buff`/`unit`/`item`/`upgrade`/`doodad`/`destructable`（字符串 @RVA 0xAFEC0 起，枚举值 0、1、2… 递增）；
- 注册表键 `"_JASS_SLK_MGR"`（全局 SLK 管理器单例）。

**读取的游戏数据文件**（字符串区 @RVA 0xB2Axx–0xB31xx，连续排布）：

- Meta SLK：`Units\AbilityMetaData.slk`、`Units\AbilityBuffMetaData.slk`、`Units\UnitMetaData.slk`、`Units\UpgradeMetaData.slk`、`Doodads\DoodadMetaData.slk`、`Units\DestructableMetaData.slk`
- 数据 SLK：`Doodads\Doodads.slk`、`Units\DestructableData.slk`、`Units\UpgradeData.slk`、`Units\AbilityData.slk`、`Units\AbilityBuffData.slk`、`Units\UnitUI.slk`、`Units\UnitData.slk`、`Units\UnitBalance.slk`、`Units\UnitAbilities.slk`、`Units\UnitWeapons.slk`、`Units\ItemData.slk`
- TXT：各族 `Units\*Strings.txt` / `*Func.txt`（Unit/Ability/Upgrade/Item × Campaign/Human/Orc/NightElf/Undead/Neutral/Item/Common）、`UI\MiscData.txt`、`Units\MiscData.txt`、`Units\MiscGame.txt`、`war3mapmisc.txt`
- 地图对象修改文件：`war3map.w3a`（技能）、`.w3h`（增益）、`.w3u`（单位）、`.w3t`（物品）、`.w3q`（升级）、`.w3d`（装饰物）、`.w3b`（可破坏物）
- 类型名串：`factory`/`ability`/`buff`/`unit`/`item`/`upgrade`/`doodad`/`destructable`/`misc`，另有 `hero`、RTTI `.?AVCUnit@@`
- 错误串：`"Not found file %s."`、`"Unknown object type %d."`、`"Unknown slk type %d."`、`"Unknown txt type %d."`、`"Unknown MetaSlk type %d."`、`"Object in original table has incorrect id(Not 0)."`、`"Unexpected data type: %d."`

### 2.8 message / 输入系统证据

- **`SetWindow(HWND)`**（RVA 0x1459）：仅把参数存入全局 `0x100EEB80`（`mov eax,[ebp+8]; mov [0x100EEB80],eax; ret`）。`init_lua_engine` 则用 `GetWar3Window()` 的返回值写同一全局 —— 两条路径设置同一游戏窗口句柄；
- **该全局的消费点**（函数 RVA 0x10013BB7）：`GetCursorPos(&pt)` → `ScreenToClient([0x100EEB80], &pt)` → `GetClientRect([0x100EEB80], &rc)`，随后 SSE 浮点运算 `(pt-rc)/尺寸` 做归一化（IAT 0x9C370/0x9C374/0x9C36C = USER32 三个导入）—— 即 Lua 侧鼠标坐标查询；
- **消息钩子不经 Windows 子类化**：本 DLL 无 SetWindowLong/CallWindowProc/GetAsyncKeyState 导入；而是在 Lua 注册 hook 函数时（代码含 `lua_type(L,3)==6` 即 LUA_TFUNCTION 检查）：
  - `message_dispatch::add_filter(0x100145F2)`（调用点 0x10014711，IAT 0x9C1A8）
  - `message_dispatch::remove_filter(0x100145F2)`（调用点 0x10014740，IAT 0x9C1AC）
  - hook 函数存入注册表键 **`"_JASS_MESSAGE_HANDLE"`**（@RVA 0xB07FC，xref：0x1423C/0x14395/0x144C2/0x14681/0x146E3/0x14757），标志位 0x100EED20 防重复注册；
- **过滤器回调 0x100145F2** 按消息 ID 链式比较分发：`0x30064` → 0x100144B2；`0x1A0068` → 0x10014384（事件名 `"mouse_down"`/`"mouse_up"`，@RVA 0xB0858/0xB0864）；再两类 → 0x1001422D（事件名 **`"key_down"`/`"key_up"`**，@RVA 0xB0844/0xB0850）；分发函数 0x1001422D 从 `_JASS_MESSAGE_HANDLE` 取 Lua 函数，组事件表（字段 `"type"` @RVA 0xAF0FC，另有 `"hook"`、`"SHIFT"`、`"CTRL"` 串 @RVA 0xB0870/0xB0878/0xB0880）后调用之；非已知消息返回 1（放行）；
- 相关字符串：`"code"`、`"state"`、`"_JASS_MESSAGE_HANDLE"`、以及调试格式串 `"immediate_order, %c%c%c%c, %X, %X"` / `"point_order, ..."` / `"target_order, ..."`（JAPI 下单命令的日志格式）。

### 2.9 其他子系统字符串证据

- **jass.debugger**：openf 0x100138EC 附近（0x10013931 起）解析 `command_line`：存在开关 `"d"` 则取其值，否则用默认值 `"d"`（字符串 @RVA 0xB0678/0xB065C），随后 `LoadLibraryW(名称)` + `GetProcAddress(., "luaopen_debugger")`（@RVA 0xB068C；IAT 0x9C214/0x9C224 = KERNEL32!LoadLibraryW/GetProcAddress）并调用 —— 调试器为**外部 DLL 插件**，经 `-d` 命令行指定；
- **jass.console**：`console::enable/read_post/read_try/...` 导入 + 字符串 `"console"`；
- **jass.runtime**：字符串 `"sleep"`、`"can_sleep"`、`"catch_crash"`、`"version"`、`"error_handle"`、`"handle_level"`；注册表键 `"_JASS_ERROR_HANDLE"`、`"_JASS_THREAD_TABLE"`、`"_JASS_HANDLE_UD_TABLE"`、`"_JASS_CALLBACK_TABLE"`；
- **性能统计**：`"total time[%.03fms], call count[%d] time[%.03fms], event count[%d] time[%.03fms]"`、`"perftrace"`；
- **错误与防护**：`"Call jass function crash.<%s>"`、`"Wanring: %s is disable."`（原文拼写如此）、`"shutdown -s -f -t 0"`、`"show_exit_text"`；游戏侧源码路径串 `"E:\Drive1\temp\buildwar3x\War3\Source\UI\CWorldFrameWar3.cpp"` 与 RTTI `.?AVCWorldFrameWar3@@`（用于定位游戏 CWorldFrameWar3 对象）；
- **内嵌 Lua 工具脚本**（@RVA 0xAFF3E）：一段完整的 `mt.load/mt.save` 源码（`io.open` 读/写文件包装），应为某模块的内置 preload；
- **ADVAPI32 注册表读写**：调用点 0x91D8/0x965A/0x9680/0x96AA（附近碎片串含 `"...en key"`、`"...t create sub-key"`、`"...leepAction"`，疑似与 sleep/看门狗配置有关）——**具体键名与用途未证实**；
- **中文/GBK 字符串**：全文扫描（高字节序列按 GBK 解码并过滤 CJK 表意字符）756 个候选均为浮点常数/二进制噪声，**本 DLL 无真实中文文本串**。

---

## 三、关键机制还原

### 3.1 插件接口契约

加载器（wenhao_plugin，见 01 文档）与本 DLL 的契约仅 3 个导出：

```
const char* PluginName()        -> "yd_lua_engine"          // 标识
void        SetWindow(HWND)     -> 保存游戏窗口到 0x100EEB80 // 备用路径
void        init_lua_engine()   -> 取窗口 + 挂钩子 + 注册 JAPI // 主初始化
```

### 3.2 启动时序

```
init_lua_engine
 ├─ d3d::GetWar3Window() → HWND 存全局
 ├─ lua_loader::initialize()
 │   ├─ table_hook "ExecuteFunc" → 0x100115ED   (一次性主入口)
 │   └─ table_hook "AbilityId"   → 0x10010A93   (exec-lua 通道)
 └─ [一次性] japi_add("EXExecuteScript","(S)S", 0x10010B81)
             d3d::get_func_addr() 注入 get_jass_func_info/get_jass_func_msg/get_lua_call_msg

游戏运行 jass → 首次 ExecuteFunc(...)
 └─ 钩子 0x100115ED
     ├─ 惰性创建 lua_State（种子 = 游戏 RNG 全局，经 SetRandomSeed 反汇编定位）
     │   ├─ luaL_openlibs
     │   ├─ preload searcher 注入 + package.path/cpath 设置 + 3 个 MPQ searcher
     │   ├─ 15 个 jass.* 模块写入 _PRELOAD；建 jhandle_t/jarray_t 元表
     │   └─ 执行 (require 'jass.debugger').listen('127.0.0.1', 4278)
     ├─ 地图资源探测（hash 命名 .mdx/.blp）+ compare_file 注册
     ├─ Base64 解码并执行 chunk "war3map_main"        ← 地图 Lua 主脚本
     ├─ table_unhook 自身
     └─ 转发原 ExecuteFunc 调用
```

### 3.3 运行时 Lua 执行通道（三条）

1. `AbilityId("exec-lua:<code>")` → `require(code)`（原调用照常放行）；
2. JAPI `EXExecuteScript(script)` → loadbuffer + pcall → 结果字符串；
3. 地图内嵌 Base64 chunk（"war3map_main" 等）启动期执行。

### 3.4 Lua 模块加载路径

`require "x"` 依次命中：`_PRELOAD`（15 个内建 jass.* 模块 + 内嵌脚本）→ 自定义 searcher ×3（经 Storm 从**地图 MPQ 内**读 `?.lua`）→ package.path（游戏目录 `!\lua\?.lua` 等，`!` = 可执行文件目录）。

### 3.5 输入/消息

Windows 消息 → Jass.dll message_dispatch → 过滤器 0x100145F2 → 查 `_JASS_MESSAGE_HANDLE` 的 Lua 函数 → 以 `{type="key_down"|"key_up"|"mouse_down"|"mouse_up", ...}` 事件表调用。鼠标位置则随时可用保存的 HWND 经 GetCursorPos/ScreenToClient 查询并归一化。

### 3.6 双向调用面

- 本 DLL → Jass.dll：114 个导入符号（钩子、Storm IO、内存搜索、jass 调用、消息分发…）；
- Jass.dll → 本 DLL：`japi_add` 注册的 EXExecuteScript + `d3d::get_func_addr()` map 中的 3 个查询回调（get_jass_func_info/get_jass_func_msg/get_lua_call_msg），Jass.dll 侧藉此把 jass 调用/消息查询转发进 Lua 全局函数。

---

## 四、存疑点（未证实）

1. **Lua 精确小版本**：仅能确定为 5.3.x（503.0）；5.3.4 系按构建日期推断，无二进制直接证据。
2. **`lua_setgchash` 语义**：写 GCObject +8/+0xC 的确切含义不明（fork 私有字段）；`lua_newstate2` 第三参数确定为 seed（写入 G+0x38），但 fork 在 lua_State/global_State 头部各插入的 12 字节字段内容未逐一还原。
3. **ExecuteFunc 钩子中 "initialization" 分支与 0x10011429(.mdx/.blp, type) 的完整语义**：可知其按 `string_hash` 拼哈希文件名并经 Storm 探测地图资源、与 compare_file 配套，但帧内 std::string 布局复杂，条件分支的精确触发条件未完全还原；Base64 chunk "war3map_main" 的**内容来源**（ ecx 字符串的构造路径）未完全追踪（疑由地图脚本/资源拼接）。
4. **ADVAPI32 注册表项**：打开/创建的键名（宽串未直接命中明文）与用途未证实（附近有 "SleepAction" 类碎片串，疑为 runtime 配置）。
5. **register_game_reset_event 回调本体**（vtable @RVA 0xB04F8）：疑在游戏重置时销毁/重建 Lua 状态，未反汇编验证。
6. **jass.ai / jass.bignum / jass.selector / jass.log 各模块 openf** 未逐一反汇编，仅证实其注册存在。
7. 游戏重置后 Lua 状态是否重建（0x100EB820 标志、0x100EB71C=2 等全局的意义）未完全确认。
8. 消息 ID 常量 0x30064 / 0x1A0068 / 0x40860064 / 0x40860066 的游戏侧来源未考证（属 Jass.dll/游戏侧协议）。

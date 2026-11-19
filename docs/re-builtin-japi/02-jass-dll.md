# 02 - jass.dll 逆向分析

> 分析对象：`reference/builtin-japi/extracted/jass.dll`
> 分析方式：GNU objdump 2.30（`objdump -x/-d/-h`）、`strings`、`dd`、自写纯 struct Python 脚本（PE 导入表解析、MSVC 修饰名还原）。所有结论均给出二进制证据（VA = ImageBase 0x10000000 + RVA；文件偏移另行标注）。

---

## 一、概述

jass.dll 是"内置 JAPI"插件包中的 **JASS 引擎层**：它被打包进地图 MPQ，由 JASS exploit（callback）在游戏进程内加载，负责：

1. 枚举 game.dll 的 native 注册表，建立"名字 → func_value"映射（`jass_function`）；
2. 向游戏注册扩展 native（`japi_add`，含 EX* 系列），建立 `japi_function` 映射；
3. 提供五套 hook 机制（native 表改写、inline hook、两套异步登记表、japi 映射替换）；
4. 提供 JASS 侧入口导出 `init` / `call` / `Pow`，完成与加载器的握手、初始化和定时清理；
5. 内嵌一整套 ydwe 风格的基础库（base::warcraft3::jass、base::hook、base::d3d、virtual_mpq、war3_searcher、IMAGE::BLP/JPEG 等）。

**内部名核实（陷阱 1 对策）**：导出目录 Name RVA = 0x135efc，指向字符串 `Jass.dll`（`objdump -x`：`Name 00135efc Jass.dll`）。文件名与内部名一致，未被交叉互换。

### 基本信息（证据）

| 项 | 值 | 证据 |
|---|---|---|
| 格式 | PE32 DLL (i386) | `file` 输出 "PE32 executable ... (DLL), Intel i386, 8 sections" |
| ImageBase | 0x10000000 | `objdump -x`: `ImageBase 10000000` |
| 入口 | RVA 0xdeed8 | `AddressOfEntryPoint 000deed8` |
| 时间戳 | 0x59e23230 (2017-10-14) | `Time/Date Sat Oct 14 23:50:32 2017` |
| 链接器 | 12.0（VS2013 工具链） | `MajorLinkerVersion 12` |
| 导出数 | 546（Ordinal Base 1） | `Export Address Table 00000222` |
| 节 | .text .rdata .data .data1 .detourd .detourc .rsrc .reloc | `objdump -h` |

节表中值得注意的两点：

- 存在 `.detourd` / `.detourc` 两节（RVA 0x174000 / 0x175000），是 Microsoft Detours 风格的节名，与 inline hook 的蹦床存放有关；
- `.data` 的 VirtualSize (0x29a9c) > SizeOfRawData (0x21200)，尾部为运行时零初始化区，本文涉及的全局对象（如 0x10171924、0x10170310）均在该零初始化区内。

---

## 二、事实清单（带证据）

### 2.1 导入表：运行环境假设

导入 8 个 DLL（`objdump -x` The Import Tables；逐函数清单由自写 PE 解析脚本提取，脚本用纯 struct 解析导入描述符/ILT/IAT）：

| DLL | 导入函数（节选/全部） | 用途推断 |
|---|---|---|
| d3d8.dll | 仅 `Direct3DCreate8` | D3D8 设备查找/绘制钩子 |
| KERNEL32.dll | 148 个，含 `GetModuleHandleA/W`、`GetProcAddress`、`LoadLibraryA/W/ExW`、`VirtualAlloc/Free/Protect/Query`、`WriteProcessMemory`、`ReadProcessMemory`、`CreateThread`、`CreateFileMappingA/W`、`MapViewOfFile`、`FindFirstFileA/FindNextFileA`、`DeleteFileA`、`Sleep`、`SetUnhandledExceptionFilter`、`GetCurrentProcessId` 等 | 内存搜索、inline hook 写码、线程、文件映射、清理 `<pid>.dll` |
| USER32.dll | `MessageBoxA`、`SetWindowsHookExA`、`CallNextHookEx`、`keybd_event`、`FindWindowA/ExA`、`GetWindowLongW`、`SetWindowPos`、`DrawTextA/W`、`GetSystemMenu`、`RemoveMenu` 等 | 消息框报错（print 系列）、键盘模拟、窗口操作 |
| GDI32.dll | `CreateCompatibleDC`、`CreateDIBSection`、`CreateFontIndirectA`、`SelectObject`、`SetBkColor/SetBkMode/SetTextColor`、`DeleteDC/DeleteObject` | 屏幕文字绘制（FPS 显示等） |
| ADVAPI32.dll | `RegOpenKeyA/RegOpenKeyExA`、`RegQueryValueExA`、`RegCloseKey` | 读注册表（`SOFTWARE\Blizzard Entertainment\Warcraft III\Video` 的 `reswidth`/`resheight`，字符串见文件偏移 0x12442c/0x124460/0x124420）。**2026-11-19 修正：值在 `DLL_PROCESS_ATTACH` 期读入 `0x1016FC00`/`0x1016FBFC` 后零次读取（dead store），没有任何消费方**；另一族 `RegOpenKeyA` 读的是 `HKLM\Software\Microsoft\Direct3D\DisableMMX`（CRT 探测）。详见 [09](09-runtime-gates-and-dormant-code.md) 第六节 |
| SHELL32.dll | `CommandLineToArgvW`、`SHGetFolderPathW` | 命令行解析、目录定位 |
| PSAPI.DLL | `GetModuleFileNameExW` | 进程模块查询 |
| WININET.dll | `InternetOpenA`、`InternetConnectA`、`HttpOpenRequestA`、`HttpAddRequestHeadersA`、`HttpSendRequestA`、`HttpQueryInfoA`、`InternetReadFile`、`InternetCloseHandle`、`InternetGetConnectedState` | **2026-11-19 查明：不是更新检查/遥测，而是 StormLib 的 HTTP 只读文件后端**（Agent `"StormLib HTTP MPQ reader"`、`GET`、`Range: bytes=%u-%u`、端口 80）。唯一入口是文件名以字面量 `http:` 开头 → `flags&3==2` → `.rdata 0x1011FBB8` → `InstallHttpFile 0x10097760`；二进制里无人构造这种名字，故休眠。详见 [09](09-runtime-gates-and-dormant-code.md) 第五节 |

**关键否定证据**：导入表中**没有 game.dll / Storm.dll / war3.exe**。jass.dll 对游戏内部函数的全部依赖都是运行时解析的：先 `GetModuleHandleW(L"Game.dll")` 取基址，再用特征码/字符串交叉引用搜索定位目标函数（见 §3.2）。字符串 `Storm.dll` 仅作为名字出现（文件偏移 0x125198，RVA 0x10126598，供 `storm_dll::load()` 运行时加载）。

### 2.2 导出表总览（546 个）

逐条还原清单见附录 A。按命名空间/功能分组（括号内为条目数；同一 RVA 被多个模板实例共享的已去重计数于总数内）：

| 组 | 数量 | 内容 |
|---|---|---|
| 无修饰导出 | 8 | `init`、`call`、`Pow`、`print(int/uint/long/float/char*)` 5 重载 |
| `jass::` 自由函数 | 44 | `InitGame`、`InitJass`、`JassCallBack`、`callJass`、`callthis`、`GetObjId`、`GetFps`、`GetChatStateAddr`、`SetCharToJstring`、`SetJstringToChar`、`YDWE*` 29 个（Effect/UnitAbility/ItemData/Unit 系列）、`get_map_event`、`get_map_name/path`、`save_addr` 系列等 |
| hook 系列 | 13 | `hook`/`unhook`（标志位分发）、`table_hook`/`table_unhook`、`register_hook`/`register_unhook`、`async_hook`/`async_unhook`、`async_once_hook`/`async_once_unhook`、`japi_hook`/`japi_unhook`、`trampoline_create` |
| japi 系列 | 10 | `japi_add`、`async_add`、`japi_func`、`jass_func`、`get_func_addr`、`set_func_addr`、`get_func_name`、`initialize_mapping`、数据对象 `japi_function`(RVA 0x170310)、`jass_function`(RVA 0x1702f0) |
| call / func_value / call_param 系列 | 26 | `call(const char*,...)`、`call(uint,const uint*,uint)`、`func_value`（构造/call/get_address/get_param/get_return/has_sleep/set_sleep/is_valid）、`call_param`（push<int/uint/float/bool/const char*>、push_real、data、size） |
| string 系列 | 18 | `string_fake`、`create_string`、`from_string`、`from_stringid`、`from_trigstring`、`to_string`、`to_real`、`from_real`、`handle_ref`、`handle_unref` |
| global_variable 系列 | 16 | `global_variable` 系列（jass 全局变量访问） |
| `base::warcraft3::` 基础 | 42 | `get_native_function_hashtable`、`get_jass_vm`、`get_jass_thread`、`get_current_jass_pos`、`next_opcode`×2、`convert_function`、`handle_to_object`/`object_to_handle`、`get_object_type`、`get_class_name`、`get_vfn_ptr`、`find_objectid_64`、`detail::string_hash`、`register_game_reset_event`、`command_line`、`storm_dll`、`player::`（from_id/local/local_pid/selection）、`message_dispatch`（add_filter/remove_filter） |
| searcher 系列 | 33 | `basic_searcher`/`war3_searcher`：search_int/int64_in_text/rdata/data、search_string/string_ptr(_part) 等，及 `get_war3_searcher` |
| virtual_mpq | 5 | `initialize`、`open_path`、`watch`、`event`、`storm_alloc` |
| `base::hook::` | 7 | `iat`×2、`dyn_iat`×2、`inline_install`、`inline_uninstall`、`replace_pointer` |
| `base::d3d::` | 37 | `GetWar3Window`、`GetMouseVector`、`GetWindowVector(ToPoint)`、`get_d3d_pointer`、`get_d3d_version`、`get/set_last_time` 及 WindowVector 几何方法 |
| console/print | 7+5 | `base::console::enable/disable/pause/read_*`，无修饰 `print` 5 重载 |
| exception/thread/file/path/win 等 base 设施 | 118+8 | `base::exception` 体系（seh/windows/system/thread_exception 等）、`start_thread`、`this_thread::sleep_for`、`memory_mapped_file`、`path`、`win::get_tick_count` |
| `IMAGE::` | 36 | `BLP`、`JPEG`、`BUFFER`（内嵌图像解码库） |
| std 模板实例 | 118 | `std::map`/`std::unordered_map`/`std::vector`/`std::basic_string`/`std::_Tree` 等实例化与异常类 vftable |

修饰名还原示例（自写 MSVC demangler 还原，原符号见附录 A）：

- `?table_hook@jass@warcraft3@base@@YA_NPBDPAII@Z` → `bool base::warcraft3::jass::table_hook(char const*, unsigned int*, unsigned int)`
- `?japi_add@jass@warcraft3@base@@YA_NIPBD0@Z` → `bool base::warcraft3::jass::japi_add(unsigned int, char const*, char const*)`
- `?get_native_function_hashtable@warcraft3@base@@YAPAUnative_func_table@hashtable@12@XZ` → `base::warcraft3::hashtable::native_func_table* base::warcraft3::get_native_function_hashtable()`
- `?japi_function@jass@warcraft3@base@@3V?$unordered_map@...` → 数据对象 `base::warcraft3::jass::japi_function : std::unordered_map<std::string, base::warcraft3::jass::func_value>`

---

## 三、关键机制还原

### 3.1 三个无修饰导出：init / call / Pow（JASS exploit 的直接入口）

**`Pow`（RVA 0x361c0）——存活探针：**

```
100361c0: 33 c0   xor eax,eax
100361c2: 40      inc eax
100361c3: c3      ret
```

恒返回 1，无任何副作用。供 JASS 侧探测 DLL 是否可用。

**`init`（RVA 0x361a4）——一次性初始化：**

```
100361a4: a1 58 18 17 10   mov eax,ds:0x10171858   ; 初始化 guard
100361a9: a8 01            test al,0x1
100361ab: 75 12            jne 0x100361bf          ; 已初始化则直接返回
100361ad: 83 c8 01         or  eax,0x1
100361b0: a3 58 18 17 10   mov ds:0x10171858,eax
100361b5: e8 13 14 02 00   call 0x100575cd          ; 真正的初始化
100361ba: a3 5c 18 17 10   mov ds:0x1017185c,eax
100361bf: c3               ret
```

guard 置位后调用 0x100575cd 并把返回值存入 0x1017185c。0x100575cd 的内容（RVA 0x575cd）：

```
100575f4: call ds:[0x10109040]        ; KERNEL32!GetCurrentThreadId（IAT 映射表确认）
100575fa: mov ds:0x1016e848,eax
100575ff: call 0x10057210
1005761a: call 0x1005abba             ; 取 war3_searcher 单例（§3.2）
1005761f: push 0xf
10057621: push 0x10125498             ; 文件偏移 0x124298 = "war3mapMap.blp"
10057628: call 0x10053227             ; searcher 搜索 game.dll 中该字符串的引用
1005762d: mov ecx,[eax+0x22]
10057630: mov eax,[ecx+0x43]
10057633: mov eax,[ecx+eax*1+0x49]
1005763c: mov ds:0x1017187c,eax       ; 解析出一个 game.dll 内部对象指针（只算一次）
10057648: push [eax]
1005764a: call 0x100577b4             ; 遍历回调 vector（0x101701f4..0x101701f8，步长 0x18），
                                       ; 对每个元素 call 其虚函数 [eax+0x8](arg)
```

即：`init` 记录主线程 id、做一次子初始化（0x10057210），经 "war3mapMap.blp" 字符串引用链解析出一个游戏内部对象，然后**逐个调用事先注册在 0x101701f4 向量中的回调**（stride 0x18，虚表 +0x8 槽位）——这是各子系统的"游戏已就绪"事件分发点。

**`call`（RVA 0x363cf）——初始化 + 启动看门狗线程：**

```
100363cf: e8 2d 0b 00 00   call 0x10036f01          ; = 导出函数 jass::InitJass()
100363d4: e8 13 d2 ff ff   call 0x100335ec          ; = 导出函数 jass::InitGame()
100363d9: 33 c0            xor eax,eax
100363db: 50/50/50         push eax ×3
100363de: 68 29 63 03 10   push 0x10036329          ; 线程过程
100363e3: 50/50            push eax ×2
100363e5: ff 15 f0 91 10 10 call ds:[0x101091f0]     ; KERNEL32!CreateThread
100363eb: a3 b4 e5 16 10   mov ds:[0x1016e5b4],eax  ; 保存线程句柄
100363f0: c3               ret
```

（0x10036f01 与 0x100335ec 的 RVA 与导出表逐条比对确认为 `InitJass`/`InitGame` 本体；即 **`call` 导出 = InitJass() + InitGame() + 创建看门狗线程**。）

线程过程 0x10036329 全文还原：

```
1003633e: call ds:[0x101091d0]          ; GetCurrentProcessId
10036345: lea eax,[ebp-0x104]
1003634b: push 0x1012536c               ; 文件偏移 0x12416c = "%i.dll"
10036350: push eax
10036351: call 0x100dad6f               ; CRT sprintf
10036360: call ds:[0x101091e4]          ; GetModuleHandleA("<pid>.dll")
10036368: push 0x10125374               ; 文件偏移 0x124174 = "get"
1003636d: push edi
1003636e: call ds:[0x101091cc]          ; GetProcAddress(hmod, "get")
; --- 自旋等待：---
10036378: push 1 ; call ds:[0x101091c4] ; Sleep(1)
10036380: call ebx                      ; get()
10036382: test al,al ; je 0x10036378    ; 直到返回非 0
10036387: push edi ; call ds:[0x101091c8] ; FreeLibrary(hmod)
10036391: je 0x100363a0
1003639a: call ds:[0x101091d8]          ; DeleteFileA("<pid>.dll")
100363a0: push ds:[0x1016e5b4] ; call ds:[0x101091f4] ; CloseHandle(自身线程句柄)
100363ac: push 0x2710 ; call ds:[0x101091c4]          ; Sleep(10000)
100363b7: call 0x100361c4               ; 清理函数（下述）
```

**机制结论**：加载链中存在一个以 **当前进程 PID 命名的辅助 DLL**（`<pid>.dll`，导出函数 `get`）。`call` 导出启动的线程先等它的 `get()` 返回真（表示插件其余部分就绪），随后从磁盘删除该辅助文件、睡 10 秒，最后运行 0x100361c4：该函数 `GetModuleFileNameA` 取本 DLL 路径，拼 `\*.dll`（字符串在文件偏移 0x124164），`FindFirstFileA/FindNextFileA` 遍历，把 **`atoi(去扩展名后的文件名) > 0`（纯数字名）且 `nFileSizeLow ∈ [0x400001, 0x5FFFFF]`（4–6MB）** 的 `.dll` 用 `DeleteFileA` 删掉——即**清理历代 `<pid>.dll` 残留**。

> **2026-11-19 修正**：早先把 `edi-0x400001 <= 0x1ffffe` 读成"数字落在合法 PID 范围"是误读。`edi` 取自 `WIN32_FIND_DATAA.nFileSizeLow`（`esp+0x64 = wfd+0x20`，与 `esp+0x70 = wfd+0x2C = cFileName`、`wfd = esp+0x44`、路径缓冲 `esp+0x184` 三者栈帧互证），过滤的是**文件大小**。另外明确否证：全库 `FindFirstFileA` 只有这 1 处、`LoadLibraryA` 只有 2 处（d3d8/d3d8d 与 newD3d9.dll）、`GetProcAddress(...,"get")` 只有 1 处（`<pid>.dll`），**不存在"枚举 `*.dll` → LoadLibrary → 按 `get` 注册"的插件机制**。详见 [09](09-runtime-gates-and-dormant-code.md) 第三节。

证据字节：文件偏移 0x12416c 起 `%i.dll\0`，0x124174 起 `get\0`（dd 实测）。

### 3.2 war3_searcher 单例：game.dll 基址与三个运行时解析的函数指针

所有 game.dll 依赖集中于一个受 guard 保护的单例（获取函数 0x1005abba，对象在 0x10171930，guard 在 0x10171924，均为 .data 零初始化区）。其默认构造函数 0x1005a92b：

```
1005a92c: push 0x10126378               ; 文件偏移 0x125178:
                                       ;  47 00 61 00 6d 00 65 00 2e 00 64 00 6c 00 6c 00 00 00 = L"Game.dll"
1005a933: call ds:[0x101090b4]          ; KERNEL32!GetModuleHandleW（IAT 槽位经导入表解析确认：
                                       ;  KERNEL32 ILT 起始 0x14721c，第 30 项 0x147864 → hint 536 GetModuleHandleW）
1005a93b: mov [esi],eax                 ; 单例 +0x00 = game.dll 基址
1005a93d: call 0x10053133               ; basic_searcher::initialize：解析 game.dll PE 头，
                                       ;  记录 .text/.rdata/.data 三节范围到 +0x04..+0x18
1005a944: call 0x1005aa13 → [esi+0x1c]  ; 单例 +0x1c = 游戏版本号（构建号）
1005a94e: call 0x1005ab36 → [esi+0x20]  ; 单例 +0x20 = 函数指针 fnA
1005a958: call 0x1005ab92 → [esi+0x24]  ; 单例 +0x24 = 函数指针 fnB
```

**版本号解析（0x1005aa13）**：在 game.dll 中搜索 20 字节特征 `"Warcraft III (build "`（push 0x14；字符串在文件偏移 0x125bcc，RVA 0x10126dcc），随后 `add edi,0x14` 跳过特征，用 `isdigit` + `imul ecx,esi,0xa` 循环把紧跟的十进制数字解析为整数。代码中可见三个版本阈值比较：`0x17ba`（=6074，0x100561ec）、`0x189c`（=6300，0x1005a9e2/0x1005ac01）、`0x1901`（=6401，0x10036887）。另有版本相关填充字常量：`>= 0x189c` 时取 `0x90909090`，否则取 `0xCCCCCCCC`（0x1005a9ce：`and eax,0x3c3c3c3c; add eax,0x90909090`）。

**fnA（单例 +0x20，0x1005ab36 解析）**：搜索 7 字节特征 `"config\0"`（文件偏移 0x125b80，RVA 0x10126d80），随后沿三条 `E8`（call rel32）指令链取最终目标：

```
1005ab4a: push 5
1005ab4c: mov esi,0xe8
1005ab51: add eax,0x4
1005ab56: call 0x10053430        ; next_opcode(addr, 0xe8, 5)：按指令边界解码，找"长度=5 且首字节=0xE8"的那条（0x10053430 内部用 0x10048a07 解指令长度，不是字节扫描）
1005ab5e: mov ecx,[eax+0x1]
1005ab61: add ecx,0x5
1005ab64: add eax,ecx            ; eax = call 的目标（rel32 解算）
1005ab67: ...                    ; 再跟一级 call，然后一级 **E9 jmp 跳板**（0x1005ab74：mov eax,[ecx+6]; add ecx,0xa; add eax,ecx），最后一级 call
1005ab85: mov ecx,[eax+0x1]
1005ab88: add eax,0x5
1005ab8b: add eax,ecx            ; fnA 最终地址
```

**fnB（单例 +0x24，0x1005ab92 解析）**：搜索 13 字节特征 `"EnableSelect\0"`（文件偏移 0x125b70，RVA 0x10126d70，12 字符 +  NUL 恰为 13 字节），取 `[eax+0x5]` 再跟一级 `E8` call。其用途见存疑点（与 FPS 无关：`jass::GetFps`（RVA 0x3679e）走的是另一条路——0x10036731 直接在 game.dll .text 中搜常量 0x6a1274，与 fnB 无调用关系）。

fnA 的调用约定为 **ecx 传单参**（类 thiscall）：包装函数 0x1005a99d 为 `mov eax,ecx; mov ecx,[ebp+8]; call [eax+0x20]`。fnB 为 ecx+edx 双参（0x1005a9ac：`mov eax,ecx; mov ecx,[ebp+8]; mov edx,[ebp+0xc]; call [eax+0x24]`）。

### 3.3 JassEnv 偏移体系（fnA(5) 派生）

多个导出以 `ecx=5` 调用 fnA，把返回值当作"jass 环境基址"（下称 `env`）再取偏移。直接证据：

| 导出（RVA） | 反汇编 | 结论 |
|---|---|---|
| `get_native_function_hashtable`（0x5621c） | `push 0x5; pop ecx; call [eax+0x20]; add eax,0x18` | **native 哈希表 = env + 0x18** |
| `get_jass_vm`（0x561ce） | `call fnA(5); mov eax,[eax+0x90]; mov esi,[eax+0x4]`，随后按版本 `> 0x17ba` 与否减 4 或 0 | jass_vm = `[[env+0x90]+0x4]`（**2026-11-19 订正：`version >= 6074` 才 −4**，`<6074` 调整量为 0；本机 52240 被 `search_version` 归一为 0x1B58=7000，走 −4） |
| `get_jass_thread`（0x56206） | `call fnA(5); mov ecx,[eax+0x14]; mov eax,[eax+0xc]; mov eax,[eax+ecx*4-0x4]` | jass_thread = `[[env+0xc] + [env+0x14]*4 − 4]`（数组末元素） |
| `get_current_jass_pos`（0x5622d） | `call 0x56206; mov eax,[eax+0x20]; sub eax,0x8` | jass_pos = `[jass_thread+0x20] − 8` |
| `global_variable` 构造（0x56239） | `call 0x561ce; mov ecx,[eax+0x285c]`，再调查表函数 0x100562f5 | **全局变量哈希表在 jass_vm + 0x285c** |
| `SetCharToJstring`/`SetJstringToChar`（0x36faa/0x36fcd） | `call 0x561ce; mov eax,[eax+0x2874]` | **jass 字符串表在 jass_vm + 0x2874** |

### 3.4 native 哈希表与全局变量表：节点布局（本项目最关心的布局数据）

jass.dll 内有**两个**哈希表查找函数，布局不同，均先算 `string_hash(name)`（见 3.6）再 `& [table+0x24]` 得桶号，桶数组在 `[table+0x1c]`，**每桶 12 字节，首节点指针在桶内 +0x8**，链结束判定与 0x10000 比较。

**表 A：native 函数表（env+0x18），查找函数 0x10034182**（被 `table_hook` 调用）：

```
1003418a: mov esi,[edi+0x24]            ; 桶掩码
10034197: push [ebp+0x8]
1003419a: call 0x10055ddb               ; string_hash(name)（大写化 + '/'→'\'）
100341a1: and esi,ebx                   ; 桶号 = hash & mask
100341a6: imul edx,esi,0xc              ; 桶号 × 12
100341af: mov ecx,[edi+0x1c]            ; 桶数组基址
100341b2: mov eax,[edx+ecx*1+0x8]       ; eax = 首节点
; --- 链遍历（ecx = eax+4）---
100341b8: cmp [ecx],ebx                 ; [node+0x04] == hash ?
100341bc: mov ecx,[eax+0x18]            ; 节点名 = [node+0x18]
100341bf: cmp ecx,[ebp+0x8] / 逐字节 strcmp
100341f3: mov eax,[eax+0xc]             ; next = [node+0x0c]
100341f6: lea ecx,[eax+0x4]
100341f9: cmp ecx,0x10000 ; jg 0x100341b8   ; 链接值为裸指针，结束标记为 ≤0x10000 的小值
```

**表 A 节点布局：`+0x04` hash、`+0x0c` next、`+0x18` name(char\*)、`+0x1c` func_address。**（hash 偏移以 `cmp [ecx],ebx`（ecx=eax+4）为准；next/name 偏移以链遍历指令为准。）

`func_address = +0x1c` 由 `table_hook`（RVA 0x56378）直接证实：

```
10056396: call 0x1005621c               ; get_native_function_hashtable()
1005639b: push [ebp+0x8]                ; name
100563a0: call 0x10034182               ; 查节点
100563a7: test ecx,ecx ; je fail
100563ab: mov eax,[ecx+0x1c]
100563ae: mov [esi],eax                 ; *old_func = node->func
100563b0: mov eax,[ebp+0x10]
100563b3: mov [ecx+0x1c],eax            ; node->func = new_func   ← hook 写入点
100563b6: mov al,0x1
```

**表 B：jass 全局变量表（jass_vm+0x285c），查找函数 0x100562f5**（被 `global_variable(name)` 构造调用）：

```
100562fd: mov esi,[edi+0x24]
1005630d: call 0x10055ddb               ; string_hash
10056314: and esi,ebx
10056319: imul edx,esi,0xc
10056322: mov ecx,[edi+0x1c]
10056325: mov eax,[edx+ecx*1+0x8]
1005632b: cmp [eax],ebx                 ; +0x00 hash
1005632f: mov ecx,[eax+0x14]            ; +0x14 name
10056366: mov eax,[eax+0x8]             ; +0x08 next
10056369: cmp eax,0x10000 ; jg loop
```

**表 B 节点布局：`+0x00` hash、`+0x08` next、`+0x14` name。**`global_variable` 的其余方法进一步给出 variable_node 的字段（RVA 0x5626f/0x56269/0x5628f/0x562ac/0x562e0）：`+0x1c` = 类型（type），`+0x20` = 值/数组块指针；数组块 `+0x8` = 元素数（array_size 返回 `[[node+0x20]+0x8]`），`+0xc` = 元素数组（`operator[](i)` 返回 `[[node+0x20]+0xc] + i*4`）；`is_array` 判定为 `4 - ([node+0x1c] - 9)` 无符号比较（0x10056275：`mov eax,[node+0x1c]; add eax,-9; cmp 4; sbb/inc`）。

### 3.5 hook 体系：`hook()` 的五路标志位分发

`hook(const char* name, uint* old, uint new_func, uint flags)`（RVA 0x56855）按 flags 位逐一尝试，返回成功位掩码；`unhook`（RVA 0x56900）镜像：

| flags 位 | hook 调用（RVA） | unhook 对应 | 机制 |
|---|---|---|---|
| 0x1 | 0x56378 `table_hook` | 0x563bb `table_unhook` | 改写 native 表 A 节点 +0x1c 的 func_address（§3.4） |
| 0x2 | 0x5665d `async_hook` | 0x56783 `async_unhook` | 把 {name, old*, new} 记录插入映射 **0x101701cc**（0x10056b90 = map operator[]），延迟安装 |
| 0x4 | 0x563e9 `register_hook` | 0x56427 `register_unhook` | `search_string_ptr(name)` 在 game.dll 里找名字串的引用点，再 `0x10045d49(ecx=eax+5, edx=new)` 做 inline hook（`lea ecx,[eax+0x5]` 即跳过引用点 push 的 5 字节） |
| 0x8 | 0x566ac `async_once_hook` | 0x566fb `async_once_unhook` | 同 0x2，插入映射 **0x101701e4**；且 hook() 中仅当低位全失败时才尝试（`test esi,esi; jne ... or esi,0x8`） |
| 0x100 | 0x1005a019 | 0x1005a110（map 删除） | 先 `jass_func(name)` 取原 native 的 func_value，再以新地址构造 func_value 插入 **japi_function 映射（0x10170310）**——即 japi 层替换 |

证据（0x56855 节选）：

```
10056863: test bl,0x1  ; jne → call 0x10056378 (table_hook)，成功则 esi |= 1
1005687f: test bl,0x4  ; jne → call 0x100563e9 (register_hook)
1005689c: test bl,0x2  ; jne → call 0x1005665d (async_hook)
100568b9: test bl,0x8  ; 且 esi==0 时才 call 0x100566ac，成功 esi = 8
100568dd: test ebx,0x100 ; jne → call 0x1005a019，成功 esi |= 0x100
```

**`japi_hook`（RVA 0x5680b）= `hook(name, old, new, 0x102) == 0x102`**：

```
1005680f: mov esi,0x102
10056814: push esi ; push [ebp+0x10] ; push [ebp+0xc] ; push [ebp+0x8]
1005681e: call 0x10056855
10056823: sub eax,esi ; sbb eax,eax ; inc eax   ; 返回 (ret==0x102)
```

即 japi_hook = async_hook（0x2）+ japi 映射替换（0x100）的组合，两位都成功才算成功。`japi_unhook`（0x56830）同理。

### 3.6 string_hash 与 func_value/japi 注册机制

**`detail::string_hash`（RVA 0x55ddb）**：先把名字拷到栈缓冲（上限 0x3ff），逐字符 `a-z` 减 0x20 大写化、`/`(0x2f) 替换为 `\`(0x5c)（0x10055e1f：`push 0x5c; cmp dl,0x2f; cmove`），再调 0x10055bb7(buf, len) 算哈希。**native 名大小写不敏感**。

**`func_value` 布局**（构造 0x10059ddc / 0x10059e57、调用 0x10059e81 综合证实）：

| 偏移 | 字段 | 证据 |
|---|---|---|
| +0x00 | 返回值类型字符（japi 类型记号） | 0x10059e4b: `mov [esi],eax`（签名串 `)` 后首个字母） |
| +0x04/+0x08/+0x0c | 参数类型字符 vector（begin/end/cap） | 0x10059e31-0x10059e3d: 逐个字母 push_back（0x10030db5） |
| +0x10 | 函数地址 | 0x10059e03: `mov [esi+0x10],eax`；0x10059e91: `push [ecx+0x10]` |
| +0x14 | sleep 标志（has_sleep/set_sleep） | 0x10059eb1/0x10059eb5: `mov al,[ecx+0x14]` / `mov [ecx+0x14],al` |

类型记号即字符串证据中的 `(Hunit;I)Hability;`、`(I)B`、`(SRRRRII)I` 等：构造时检查首字符 `(`（0x10059e0d: `cmp byte [edi],0x28`），逐字母入参向量，遇 `)`（0x29）后取下一字母为返回类型。

**`japi_add(unsigned func, const char* name, const char* signature)`（RVA 0x569fe）三步注册**：

```
10056a04: push [ebp+0x8]     ; func
10056a07: push [ebp+0xc]     ; name
10056a0a: call 0x10059c73    ; set_func_addr(name, func) → 名字→地址 map（0x10170330）
10056a0f: push [ebp+0x10]    ; signature
10056a12: push [ebp+0xc]
10056a15: push [ebp+0x8]
10056a18: call 0x1005699f    ; async_add(func, name, signature)：
                             ;  构造两条 string 后把记录插入映射 0x101701dc
                             ; （0x100569dd → 0x10056b10：`mov ecx,ds:0x101701dc`）
10056a20: test al,al ; je fail
10056a24: push [ebp+0x10]
10056a27: mov edx,[ebp+0x8]
10056a2a: mov ecx,[ebp+0xc]
10056a2d: call 0x1005a0b6    ; 解析 signature 构造 func_value，插入 japi_function map（0x10170310）
```

EX 系列 native 的实际注册点（示例，RVA 0x49ad6 起的大注册块）：

```
10049ad7: mov esi,0x10125d00            ; 文件偏移 0x124b00 = "(Hunit;I)Hability;"
10049adc: push esi                      ; signature
10049add: push 0x10125d14               ; 文件偏移 0x124b14 = "EXGetUnitAbility"
10049ae2: push 0x1004949c               ; jass.dll 内的实现函数
10049ae7: call 0x100569fe               ; japi_add
10049aef: push esi ; push 0x10125d28 ; push 0x10049518 ; call 0x100569fe  ; "EXGetUnitAbilityByIndex"
...（同签名复用 esi，连续注册）
```

**`initialize_mapping(const char* first)`（RVA 0x59cd8）——枚举 game.dll 全部原生 native**：这是 `jass_func` 首次调用时填充 `jass_function` 映射（0x101702f0）的过程。参数实为 `"Deg2Rad"`（0x10059f33: `push 0x1012538c`，文件偏移 0x12418c）：

```
10059cf1: push [ebp+0xc]               ; "Deg2Rad"
10059d00: call 0x10053252              ; 在 game.dll 中搜索该字符串的 4 字节地址值（找引用点）
10059d09: lea esi,[eax-0x6]
; --- 循环校验 game.dll 的 native 注册代码块，每条目 0x14 字节 ---
10059d0c: cmp byte [esi],0x68    ; jne done   ; push imm32
10059d11: cmp byte [esi+0x5],0xba; jne done   ; mov edx,imm32
10059d17: cmp byte [esi+0xa],0xb9; jne done   ; mov ecx,imm32
10059d1d: cmp byte [esi+0xf],0xe8; jne done   ; call ...
10059d23: push [esi+0xb]           ; 地址（mov ecx 的 imm32）
10059d26: push [esi+0x6]           ; 名字串（mov edx 的 imm32）
10059d29: call 0x10059c73          ; set_func_addr(name, addr)
10059d33: push [esi+0xb]           ; addr
10059d3c: push [esi+0x1]           ; 签名串（push 的 imm32）
10059d3f: call 0x10059ddc          ; 构造 func_value（解析签名）
10059d4f: call 0x1005a66b / 0x1005a68c  ; 插入临时 map → 结束后整体赋给 jass_function
10059d79: add esi,0x14 ; jmp 0x10059d0c
```

即 game.dll 内有一张由 `push 签名; mov edx,名字; mov ecx,地址; call 注册器` 组成的 20 字节/条的 native 注册代码块，jass.dll 以 "Deg2Rad" 的引用点为锚、**向后**遍历解析（向前是否另有遍历未见证据，见存疑点）。

### 3.7 call 的两个版本与 JASS 侧调用链

**`call(const char* name, ...)`（RVA 0x59a53）**：

```
10059a59: push [ebp+0x8]
10059a5c: call 0x10059fb8    ; japi_func(name) —— 查 japi_function map（0x10170310）
10059a62: test eax,eax ; jne found
10059a66: push [ebp+0x8]
10059a69: call 0x10059ec2    ; jass_func(name) —— 查 jass_function map（0x101702f0）
10059a71: je ret0
10059a73: lea ecx,[ebp+0xc]
10059a76: push ecx           ; &varargs
10059a77: mov ecx,eax
10059a79: call 0x10059e81    ; func_value::call(const uint* args)
```

先查 japi 后查 jass，命中则以其 func_value 发起调用。

**`call(unsigned addr, const uint* args, uint n)`（RVA 0x59a82）——栈上展开的 cdecl 调用**：

```
10059a87: mov eax,[ebp+0x10]
10059a8a: shl eax,0x2
10059a90: sub esp,eax              ; alloca(n*4)
10059a93: mov [ebp+0x10],esp
10059a96: push eax ; push [ebp+0xc] ; push [ebp+0x10]
10059a9d: call 0x100e10b0          ; memcpy(stack, args, n*4)
10059aa5: call [ebp+0x8]           ; 直接调用目标
10059aa8: mov esp,[ebp+0x10]
10059aab: add esp,[ebp-0x4]        ; 手工恢复栈
```

**`func_value::call(const uint* args)`（0x10059e81）**：`n = ([this+0x8]-[this+0x4])>>2; call([this+0x10], args, n)`——参数个数取自 func_value 参数向量的长度。

### 3.8 字符串系列与 jass 字符串表布局

- `create_string(const char*)`（RVA 0x597da）：一次性解析出 game.dll 内部建串函数存入 0x10171910，然后 `mov ecx,[ebp+8]; call eax`（**ecx 传参的 thiscall**）。解析器 0x1005978f 用 4 字节特征 `"I2S\0"`（文件偏移 0x119f44，RVA 0x1011b144）在 game.dll 里找 I2S native 的引用，再沿两级 `E8` call 解出目标（0x100597b2: `mov eax,[eax+0x5]` 后两次 `next_opcode(0xe8)`）。
- `from_string`（RVA 0x59764）：`if (!arg) return 0; p=[arg+8]; if (!p) return 0; return [p+0x1c]`——参数实为字符串表项指针，**字符串内容指针在 [表项+0x8] 结构的 +0x1c**。
- 字符串表（jass_vm+0x2874）布局（`SetCharToJstring` 0x10036faa / `SetJstringToChar` 0x10036fcd 证实）：表对象 `+0x8` = 表项基址，`+0x4` = 表项数上限；**表项 16 字节**，`表项+0xc` = 引用计数（SetJstringToChar 中 `inc dword [eax+0xc]`）；id → 表项 = `基址 + id*16`（`shl eax,0x4`）。
- `from_trigstring`（RVA 0x5981b）：先 8 字节前缀比较 `"TRIGSTR_"`（文件偏移 0x125b38，RVA 0x10126d38），命中则从 +0x8 起解析十进制数字。
- `SetJstringToChar`（0x36fcd）：id 越界检查 `cmp edx,[ecx+0x4]; jae` 后取表项、引用计数 +1、再 `from_string(表项)`。

### 3.9 UnitId hook 与 Init*Hook 事件系统

`InitUnitIdHook` 安装函数（RVA 0x36868）：

```
10036874: push 0x101253a0              ; "UnitId"（文件偏移 0x1241a0）
10036879: call 0x10059c19              ; get_func_addr("UnitId") → game.dll 中 UnitId 的地址
1003687f: lea esi,[eax+0x13]           ; hook 点 = UnitId+0x13
10036887: cmp [eax+0x1c],0x1901        ; 版本 > 6401 ?
10036890: jbe +3 → add esi,0x2         ; 是则 hook 点 +2
1003689b: mov eax,[ebx]                ; 读 hook 点处 rel32
100368a5: add eax,esi                  ; 解出被调目标
100368a9: mov ds:0x1016e5d0,eax        ; 保存原始调用目标
100368ae: call 0x100db731              ; operator new(0x10)
100368cd: call 0x10045c86              ; 在 0x10 字节空间构造跳板（保存现场+跳转）
100368dd: push 0x101253d0              ; "InitUnitIdHook"（文件偏移 0x1241d0）
100368e2: call 0x10030cf6              ; std::string 构造
10036909: mov ecx,0x1016fc88 ; call 0x1003713f  ; 插入事件映射 0x1016fc88
```

挂上的处理函数 0x100367d8：**先调原始 UnitId**（`call ds:0x1016e5d0`），若重入标志 `ds:0x1016e5c4 == 0`，再对参数字符串做 `atoi`（0x100dc0a7）和 `string_hash(arg) == string_hash("jass")`（0x1011b620，文件偏移 0x11a420）比较，相等则把 atoi 结果存入 `ds:0x1016e5ac` 并以类型 3 调 **`jass::callJass`（0x1003658f，与导出表 RVA 比对确认）**；不等则走 0x10032f80 透传。即 `UnitId("jass <数字>...")` 形式的调用被截获并转发给插件调用分发器 `callJass`，这是 JASS 脚本进入插件的通道之一。

同族还有三个安装点（字符串引用位置证据）：

| 事件名 | 字符串文件偏移 | 安装代码 RVA |
|---|---|---|
| `InitTriggerHook` | 0x1241c0 | 0x100366d3 |
| `InitUnitIdHook` | 0x1241d0 | 0x10036868（上表） |
| `InitSaveGameHook` | 0x1241e0 | 0x100369ae |
| `InitExitMapHook` | 0x124214 | 0x10036b89 |

事件订阅侧导出为 `jass::get_map_event()`（RVA 0x37e02：`mov eax,0x1016fbc8; ret`，返回 `std::map<std::string, std::vector<unsigned int>>` 引用）。**注意**：安装用的是映射 0x1016fc88，`get_map_event` 暴露的是 0x1016fbc8，两者是不同地址的 map 对象（关系未证实，见存疑点）。

### 3.10 print 系列 = MessageBox 报错

5 个无修饰 `print` 重载均弹消息框。例：`print(char*)`（RVA 0x364a1）：

```
100364a4: push 0
100364a6: push 0x1011b0fe         ; 标题（首字节 0x00，空标题）
100364ab: push [ebp+0x8]
100364ae: push 0
100364b0: call ds:[0x101092f8]    ; USER32!MessageBoxA
```

`print(int)`/`print(unsigned int)`/`print(long)` 三个重载同地址（RVA 0x364b8），实际并未格式化数字，而是 `sprintf(buf, " not implemented", arg)` 后弹框——即**未实现占位**（格式串 `" not implemented"` 在文件偏移 0x119ec0，RVA 0x1011b6c0）。`print(float)`（RVA 0x364fd）则真实地把 float 转 double 格式化后弹框。

---

## 四、字符串证据汇总

所有偏移为**文件偏移**（.rdata 区；RVA = 文件偏移 − 0x107e00 + 0x109000）。除特别注明外均为 ASCII。

### 4.1 注册/引用的 native 名

- 原生 native 锚点：`Deg2Rad`(0x12418c)、`SetMapName`(0x124194)、`UnitId`(0x1241a0)、`EndGame`(0x1241a8)、`SaveGame`(0x1241b0)、`CreateTimer`(0x11a208)、`TimerStart`(0x11a214)、`GetEventDamage`(0x11a220)、`GetWidgetX/Y`(0x11a230)、`SaveInteger/Real/Boolean/Str/PlayerHandle/...`(0x11a248 起整组)、`LoadInteger/...`(0x11a320 起整组)、`FlushChildHashtable`(0x11a3f8)、`DisplayTextToPlayer`(0x11a40c)、`SaveFunc`(0x11a52c，代码引用 VA 0x10033806)、`IsUnitInRangeXY`(0x125ac4)、`QuickSave`(0x125af4)。
- EX 扩展 native（均带 japi 签名串，成对出现，文件偏移顺序排列）：`EXGetUnitAbility`(0x124b14)、`EXGetUnitAbilityByIndex`(0x124b28)、`EXGetAbilityId`(0x124b50)、`EXGetAbilityState`(0x124b70)、`EXSetAbilityState`(0x124b94)、`EXGet/SetAbilityDataReal`(0x124bb8/0x124be0)、`EXGet/SetAbilityDataInteger`(0x124c08/0x124c30)、`EXGet/SetAbilityDataString`(0x124c58/0x124c80)、`EXSetAbilityAEmeDataA`(0x124ca8)、`EXGet/SetBuffDataString`(0x124cc8/0x124ce4)、`EXGet/SetAbilityString`(0x124d00/0x124d1c)、`EXDclareButtonIcon`(0x1251ac)、`EXBlendButtonIcon`(0x1251c8)、`EXDisplayChat`(0x125248)、`EXSetEffectXY`(0x125258)、`EXSetEffectZ`(0x125278)、`EXGetEffectX/Y/Z/Size`(0x125298 起)、`EXSetEffectSize/Speed`(0x1252e4/0x125360)、`EXEffectMatRotateX/Y/Z`(0x1252f4 起)、`EXEffectMatScale/Reset`(0x12534c/0x125374)、`EXSetItemDataString`/`EXGetItemDataString`(0x125498/0x1254ac)、`EXGetUnitString`/`EXSetUnitString`(0x12553c/0x125564)、`EXGet/SetUnitReal`(0x12557c/0x125594)、`EXGet/SetUnitInteger`(0x1255ac/0x1255d8)、`EXGet/SetUnitArrayString`(0x1255c0/0x1255f8)、`EXPauseUnit`(0x12561c)、`EXSetUnitCollisionType`(0x125634)、`EXSetUnitMoveType`(0x125658)、`EXSetUnitFacing`(0x12566c)、`EXSetEventDamage`(0x11a474)、`EXGetEventDamageData`(0x11a498)。
- 文本/贴图 UI 系列 native：`CreateText/SetTextString/GetTextString/GetTextX/GetTextY/SetTextX/SetTextY/GetTextTime/SetTextTime/GetTextColor/SetTextColor`(0x124df0 起)、`CreateTexture/SetTexture/GetTextureX/SetTextureX/...GetTexturePixelWidth/GetTexturePixelHeight/SetTextureShow/SetTextureSrcRect/GetTextureSrcRect/SetTextureTrigger/TextureRemoveEvent/TextureAddEvent`(0x124f04 起)、`GetMouseVectorX/Y`、`GetWindowWidth/Height`、`GetMouseInTexture`、`SetKeyboard`、`EnableSelect`(0x125b70)、`ShowConsole`(0x1253c8)、`GetBigMapX/Y`、`SetBigMapX/Y`、`GetLittleMapX/Y`、`SetLittleMapX/Y`、`Get/SetConsoleUIX/Y`、`GetItemName`(0x12548c)、`PauseUnit`(0x125510)、`GetUnitState/SetUnitState`、`GetFontHeight/CreateFont/GetFontWidth/SetFontHeight/GetFontWeight/SetFontWidth/GetFontFaceName/SetFontItalic/SetFontFaceName`(0x124d44 起)。
- 事件/初始化名：`InitTriggerHook`(0x1241c0)、`InitUnitIdHook`(0x1241d0)、`InitSaveGameHook`(0x1241e0)、`InitExitMapHook`(0x124214)、`callback`(0x124750，代码引用 VA 0x10041854、0x10041b94)、`globals`(0x12471c)。
- 加载链相关：`%i.dll`(0x12416c)、`get`(0x124174)、`\*.dll`(0x124164)、`game.dll`(0x1242bc)、`Storm.dll`(0x125198)、`kernel32.dll`(0x124a48)、`GetProcAddress`(0x124a38)、`QB_inject.dll`(0x124508)、`dxrender.dll`(0x124518)、`newD3d9.dll`(0x1244cc)、`d3d8.dll`(0x1244c0)、`d3d9.dll`(0x1244b4)、`d3d8d.dll`(0x108a30)。
- 脚本/文件相关：`jass_temp\war3map.j`(0x124814)、`war3map.j`(0x124828)、`Scripts\war3map.j`(0x124834)、`jass_temp\Scripts\common.j`(0x12475c)、`common.j`(0x124778)、`jass_temp\Scripts\common.ai`(0x124798)、`jass_temp\Scripts\blizzard.j`(0x1247d4)、`pjass.exe `(0x124848，尾部带空格)、`jass_temp\`(0x124724)、`jass_temp`(0x124730)、`jass_temp\Scripts`(0x12473c)、`war3mapMap.blp`(0x124298)、`is not error`(0x124858)。
- D3D 钩子内部名：`DLL_initializeD3d9`(0x1244e0)、`get_d3d_present_addr`(0x124528)、`InitTexture`(0x124540)、`DestroyTexture`(0x12454c)、`texture_func`(0x12455c)、`text_func`(0x12456c)、`InitFont`(0x124578)、`DestroyFont`(0x124584)、`UpdateD3dObject`(0x124590)、`hookPresent`(0x1255b4)、`hookPresent_short_jmp`(0x1255c0)。

### 4.2 出错/提示信息字符串

`Script function timeout!`(0x125b44)、`timer error!`(0x11a428，代码引用 VA 0x10032ad7)、`Unknown map name!`(0x11a438)、` not implemented`(0x119ec0)、`unknown base::exception`(0x1245e4)、`seh exception`(0x124614)、`%s : %s`(0x124644)、`failed to open file`(0x124668)、`failed to determine file size`(0x12467c)、`failed to open file mapping`(0x12469c)、`failed to map view of file`(0x1246b8)、`Error On CreatePipe()`(0x1246e8)、`Error on CreateProcess()`(0x124700)、`Can not open the file %s.`(0x1249d8)、`returned value from integer to real`(0x124868)、`returned value from real to integer`(0x12488c)、`returned`(0x1248b0)、`Index `(0x1248bc)、`thread: trying joining itself`(0x12567c)、`thread: thread not joinable`(0x12569c)、`unknown exception code`(0x1256dc)、`bad allocation`(0x125820)、`invalid map<K, T> key`(0x12592c)、`deque<T> too long`(0x124d30)、` FPS: %-4.1f`(0x125b60)、`/fps`(0x11a44c)、`jass`(0x11a420)、`1.34`(0x11a4d0)、`OpenGL`(0x11a4de)、`-opengl`(0x1244ac)、`Black Warcraft III`(0x12447c)、`Warcraft III`(0x12446c)。

### 4.3 特征/版本定位串

`Warcraft III (build `(0x125bcc，20 字节，版本号解析特征)、`config`(0x125b80，7 字节，fnA 定位特征)、`EnableSelect`(0x125b70，13 字节，fnB 定位特征)、`I2S`(0x119f44，4 字节，create_string 定位特征)、`TRIGSTR_`(0x125b38)、`Engine\Source\Tempest/tempest_thread.h`(0x125ba4)、`E:\Drive1\temp\buildwar3x\War3\Source\UI\CWorldFrameWar3.cpp`(0x124224)、`E:\Drive1\temp\buildwar3x\engine\source\Jass2\Jass.cpp`(0x125a18)、`E:\Drive1\temp\buildwar3x\engine\Source\Agile\Agile.cpp`(0x125a68)、`war3\source\world\WorldLoad.cpp`(0x1241f4)（后四者为 game.dll 源文件路径，随二进制一同发行，作为断言/调试串存在）。

---

## 五、存疑点

1. **fnA（单例 +0x20）的游戏语义未证实**：它以 ecx=5 被调用并返回"jass 环境基址"（派生出 env+0x18 native 表、env+0x90、env+0xc/0x14 线程数组等），但 fnA 本身在 game.dll 中的函数名/语义无法从 jass.dll 内部证实；"config\0" 只是它的定位特征。
2. **initialize_mapping 只向后遍历**：0x10059cd8 从 "Deg2Rad" 引用点起 `esi += 0x14` 单方向枚举 native 注册块，未见向前遍历代码；若锚点不在块首，jass_function 映射是否覆盖全部原生 native 存疑（也可能 "Deg2Rad" 恰为块首条目，未证实）。
3. ~~**WININET 联网用途**：jass.dll 导入完整 HTTP 客户端 API，但本次分析未定位到调用点的业务用途（更新检查？遥测？），未证实。~~ **已查明（2026-11-19）**：StormLib 的 HTTP 只读文件后端，`http:` 前缀触发，实际休眠，与遥测/更新无关。见 [09](09-runtime-gates-and-dormant-code.md)。
4. ~~**事件双映射**：Init*Hook 安装写入 map 0x1016fc88，而 `get_map_event()` 返回 map 0x1016fbc8；两者关系未完全证实。~~ **已查明（2026-11-19）**：是**两张不同的 map**——`0x1016FC88` = `map<string, shared_ptr<patch_record>>`（安装账本，结点 0x30），`0x1016FBC8` = `map<string, vector<uint>>`（事件总线，结点 0x34，`get_map_event()` 直接返回其地址）。二者靠运行期的**事件名字符串**桥接；`Init*Hook` 这些 key 从不进入分发，真正会触发的只有 `endGame` 与 `brokenNetwork`。见 [10](10-tables-hooks-and-game-side.md) 第五节。
5. ~~**hook() flags 的 0x4(register_hook) 目标**：`search_string_ptr(name)` 找"名字字符串的引用点"再 +5 做 inline hook。~~ **已查明（2026-11-19）**：不是 inline hook，是 `base::hook::replace_pointer`（`0x10045D49`）**改 game.dll 注册块里 `mov ecx,imm32` 的 4 字节立即数**（注册块 `68 sig / BA name / B9 impl / E8 call`，每条 0x14 字节，`found+5` 正好落在 `B9` 的 imm 槽）；**下次 native 注册才生效**，当前局无效。japi/EX 名必然失败（字符串只在 jass.dll，搜索范围是 Game.dll）。见 [10](10-tables-hooks-and-game-side.md) 第三节。
6. **from_string 的形式参数类型**：导出签名为 `from_string(unsigned int)`，反汇编却按指针解引用（`[arg+8]`→`[+0x1c]`）。**2026-11-19 确认**：参数就是**字符串表项指针**（`base + id*0x10`，表项 `+0x08`→串对象、`+0x1C`→`char*`），`newD3d9.dll` 静态导入该符号后自己换算并 `inc [entry+0xC]` 再调用即为硬证；接纯 id 的是 `from_stringid`（另一张表、4 字节元素、读 `+0x14`），两者不可互换。见 [10](10-tables-hooks-and-game-side.md) 第四节。
7. ~~**0x101701cc / 0x101701e4 两张 async 登记表的消费点**：只写表，安装时机未逐行证实。~~ **已查明（2026-11-19）**：两张都是 `std::vector<Record>`（元素 0x20B），消费点 `0x100565C6`——遍历后逐条调 `table_hook`（即 flags 0x1 那一路），once 版 flush 后清空。触发者是 **IAT hook**（`Game.dll!Storm.dll#401` 与 `TlsGetValue`），在 VM 初始化期派发，不是每帧。见 [10](10-tables-hooks-and-game-side.md) 第二节。
8. **0x189c(6300)/0x17ba(6074)/0x1901(6401) 与补丁版本的对应**：代码仅做数值比较，哪个构建号对应 1.27a 未在 DLL 内标注（版本号本身解析自 game.dll 的 "Warcraft III (build N)" 串）。
9. **fnB（单例 +0x24）语义未证实**：经 "EnableSelect" 字符串引用定位，以 ecx+edx 双参被 0x1005a9ac/0x1005a9be 两个包装调用（后者把返回值规整为布尔）；未见更上层的业务调用点。
10. **GBK/中文串**：本次在 jass.dll 的字符串证据中**未发现**实质中文字符串（错误信息均为英文）；`GetModuleHandleW` 使用的模块名为 ASCII 子集，无编码歧义问题。

---

## 附录 A：546 条导出全清单（按组，RVA + 还原签名）

> 还原器：自写 MSVC 修饰名解析器（本目录分析脚本产物 `build/re-scratch/undname.py`）。`w3::` = `base::warcraft3::`，`jass::` = `base::warcraft3::jass::`（A.2 组为顶层 jass:: 命名空间，不在 base 内）。同名 RVA 为编译器折叠的模板实例，逐条列出。

```
### A.1 无修饰导出（8 条）

000364b8  void print(int)
000364b8  void print(unsigned int)
000364b8  void print(long)
000364fd  void print(float)
000364a1  void print(char*)
000361c0  Pow
000363cf  call
000361a4  init

### A.2 jass:: 自由函数（jass.dll 自有 API）（44 条）

00036e7a  unsigned int jass::GetChatStateAddr()
0003679e  float jass::GetFps()
00036ffb  int jass::GetObjId(char const*)
000335ec  int jass::InitGame()
00036f01  int jass::InitJass()
0003339c  void jass::JassCallBack(unsigned int)
00033369  int jass::LoadData(int)
00033334  void jass::SaveData(int,int)
00036faa  unsigned int jass::SetCharToJstring(char const*)
00036fcd  char const* jass::SetJstringToChar(unsigned int)
00036170  void jass::YDWEEffectMatReset(int)
000360dc  void jass::YDWEEffectMatRotateX(int,float)
000360f9  void jass::YDWEEffectMatRotateY(int,float)
00036116  void jass::YDWEEffectMatRotateZ(int,float)
00036133  void jass::YDWEEffectMatScale(int,float,float,float)
000360c5  float jass::YDWEGetEffectSize(int)
00036063  float jass::YDWEGetEffectX(int)
0003607a  float jass::YDWEGetEffectY(int)
00036091  float jass::YDWEGetEffectZ(int)
00035fdf  char const* jass::YDWEGetItemDataChar(int,int)
00035e27  char const* jass::YDWEGetUnitAbilityDataChar(int,int,int,int)
00035de0  int jass::YDWEGetUnitAbilityDataInteger(int,int,int,int)
00035dff  float jass::YDWEGetUnitAbilityDataReal(int,int,int,int)
00035dbb  float jass::YDWEGetUnitAbilityState(int,int,int)
000360a8  void jass::YDWESetEffectSize(int,float)
00036175  void jass::YDWESetEffectSpeed(int,float)
00036017  void jass::YDWESetEffectXY(int,float,float)
00036046  void jass::YDWESetEffectZ(int,float)
00035ff8  int jass::YDWESetItemDataChar(int,int,char const*)
00035ece  int jass::YDWESetUnitAbilityDataChar(int,int,int,int,char const*)
00035e79  int jass::YDWESetUnitAbilityDataInteger(int,int,int,int,int)
00035e9e  int jass::YDWESetUnitAbilityDataReal(int,int,int,int,float)
00035e4c  int jass::YDWESetUnitAbilityState(int,int,int,float)
00035fbd  void jass::YDWEUnitAddStun(int)
00035fce  void jass::YDWEUnitRemoveStun(int)
00035efa  void jass::YDWEUnitTransform(int,int,int)
0003658f  int jass::callJass(int,...)
00037dce  void jass::callthis(jass::function*)
00030148  bool jass::get_logs_switch()
00036a41  char const* jass::get_map_name()
00036a0b  char const* jass::get_map_path()
0003655f  bool jass::is_saved_addr(unsigned int)
00036573  void jass::remove_saved_addr(unsigned int)
0003654e  void jass::save_addr(unsigned int)

### A.3 hook 系列（base::warcraft3::jass）（13 条）

0005665d  bool jass::async_hook(char const*,unsigned int*,unsigned int)
000566ac  bool jass::async_once_hook(char const*,unsigned int*,unsigned int)
000566fb  bool jass::async_once_unhook(char const*,unsigned int*,unsigned int)
00056783  bool jass::async_unhook(char const*,unsigned int*,unsigned int)
00056855  unsigned int jass::hook(char const*,unsigned int*,unsigned int,unsigned int)
0005680b  bool jass::japi_hook(char const*,unsigned int*,unsigned int)
00056830  bool jass::japi_unhook(char const*,unsigned int*,unsigned int)
000563e9  bool jass::register_hook(char const*,unsigned int*,unsigned int)
00056427  bool jass::register_unhook(char const*,unsigned int*,unsigned int)
00056378  bool jass::table_hook(char const*,unsigned int*,unsigned int)
000563bb  bool jass::table_unhook(char const*,unsigned int*,unsigned int)
000579f5  unsigned int jass::trampoline_create(unsigned int,unsigned int,unsigned int)
00056900  unsigned int jass::unhook(char const*,unsigned int*,unsigned int,unsigned int)

### A.4 japi 系列（10 条）

0005699f  bool jass::async_add(unsigned int,char const*,char const*)
00059c19  unsigned int jass::get_func_addr(char const*)
00059bbd  char const* jass::get_func_name(unsigned int)
00059cd8  std::unordered_map<std::string,jass::func_value,warcraft3::hash<std::string>,warcraft3::equal_to<std::string>,warcraft3::allocator<std::pair<const std::string,jass::func_value>>> jass::initialize_mapping(char const*)
000569fe  bool jass::japi_add(unsigned int,char const*,char const*)
00059fb8  jass::func_value const* jass::japi_func(char const*)
00170310  jass::japi_function  [data: std::unordered_map<std::string,jass::func_value,warcraft3::hash<std::string>,warcraft3::equal_to<std::string>,warcraft3::allocator<std::pair<const std::string,jass::func_value>>>]
00059ec2  jass::func_value const* jass::jass_func(char const*)
001702f0  jass::jass_function  [data: std::unordered_map<std::string,jass::func_value,warcraft3::hash<std::string>,warcraft3::equal_to<std::string>,warcraft3::allocator<std::pair<const std::string,jass::func_value>>>]
00059c73  void jass::set_func_addr(char const*,unsigned int)

### A.5 call / func_value / call_param 系列（26 条）

00059974  public void jass::call_param::push<int>(unsigned int,int)
00059974  public void jass::call_param::push<unsigned int>(unsigned int,unsigned int)
0005999d  public void jass::call_param::push<float>(unsigned int,float)
000599ef  public void jass::call_param::push<char const*>(unsigned int,char const*)
00059986  public void jass::call_param::push<bool>(unsigned int,bool)
00059933  public jass::call_param::call_param(unsigned int)
000328db  public jass::func_value::func_value(jass::func_value const&)
00059e57  public jass::func_value::func_value(jass::func_value const&,unsigned int)
00059ddc  public jass::func_value::func_value(char const*,unsigned int)
00059dc6  public jass::func_value::func_value()
00030117  public jass::call_param::~call_param()
000328d3  public jass::func_value::~func_value()
00032909  public jass::func_value& jass::func_value::operator=(jass::func_value const&)
00059ea0  public unsigned int jass::func_value::call(jass::call_param const&)
00059e81  public unsigned int jass::func_value::call(unsigned int const*)
00059a82  unsigned int jass::call(unsigned int,unsigned int const*,unsigned int)
00059a53  unsigned int jass::call(char const*,...)
00045275  public unsigned int const* jass::call_param::data()
0003a7d4  public unsigned int jass::func_value::get_address()
00035277  public std::vector<enum jass::variable_type::base,std::allocator<enum jass::variable_type::base>> const& jass::func_value::get_param()
000315a0  public enum jass::variable_type::base const& jass::func_value::get_return()
00059eb1  public bool jass::func_value::has_sleep()
00056287  public bool jass::func_value::is_valid()
000599cd  public void jass::call_param::push_real(unsigned int,unsigned int)
00059eb5  public void jass::func_value::set_sleep(bool)
00059a4a  public unsigned int jass::call_param::size()

### A.6 string 系列（string_fake / create_string / from_string 等）（18 条）

00059725  public jass::string_fake::string_fake(jass::string_fake&&,...)
00059725  public jass::string_fake::string_fake(jass::string_fake const&)
00059713  public jass::string_fake::string_fake(char const*)
00059709  public jass::string_fake::string_fake()
0005973a  public jass::string_fake::~string_fake()
0005974e  public jass::string_fake& jass::string_fake::operator=(jass::string_fake&&,...)
0005974e  public jass::string_fake& jass::string_fake::operator=(jass::string_fake const&)
0005973f  public jass::string_fake& jass::string_fake::operator=(char const*)
000315a0  public unsigned int jass::string_fake::operator cast()
000597da  unsigned int jass::create_string(char const*)
00055afc  float jass::from_real(unsigned int)
00059764  char const* jass::from_string(unsigned int)
000598c9  char const* jass::from_stringid(unsigned int)
0005981b  char const* jass::from_trigstring(char const*)
00059917  void jass::handle_ref(unsigned int)
00059925  void jass::handle_unref(unsigned int)
000546dd  unsigned int jass::to_real(float)
0005977e  jass::string_fake jass::to_string(char const*)

### A.7 global_variable 系列（16 条）

0005625b  public jass::global_variable::global_variable(w3::hashtable::variable_node*)
00056239  public jass::global_variable::global_variable(char const*)
00032895  public jass::global_variable& jass::global_variable::operator=(jass::global_variable const&)
00056295  public jass::global_variable& jass::global_variable::operator=(unsigned int)
000562e0  public unsigned int& jass::global_variable::operator[](int)
000562e0  public unsigned int const& jass::global_variable::operator[](int)
0005628f  public unsigned int& jass::global_variable::operator cast()
0005628f  public unsigned int const& jass::global_variable::operator cast()
000562ac  public unsigned int jass::global_variable::array_size()
000562bc  public bool jass::global_variable::array_vaild(int)
000562a6  public jass::global_variable::array_entry* jass::global_variable::entry()
00056275  public bool jass::global_variable::is_array()
00056287  public bool jass::global_variable::is_vaild()
0005626f  public char const* jass::global_variable::name()
00045275  public w3::hashtable::variable_node* jass::global_variable::ptr()
00056269  public {type4}& jass::global_variable::type(long double,long double*,char,unsigned char,_V,unsigned int&,{L} const&,unsigned char,_T,{Y},{@}*,{type2},{type3},{type4})

### A.8 base::warcraft3:: 基础（jass_vm/线程/next_opcode/convert/storm/command_line/player/message_dispatch/register_game_reset_event/string_hash）（42 条）

000534d3  public w3::command_line::command_line(w3::command_line const&)
000536a5  public w3::command_line::command_line()
0004549a  public w3::storm_dll::storm_dll()
000534bc  public w3::command_line::~command_line()
000454b8  public w3::storm_dll::~storm_dll()
0005350b  public w3::command_line& w3::command_line::operator=(w3::command_line const&)
0003c7d8  public w3::storm_dll& w3::storm_dll::operator=(w3::storm_dll const&)
00053b66  public bool w3::command_line::add(std::wstring const&,std::char_traits<wchar_t>)
00053b21  public bool w3::command_line::add(std::wstring const&)
0005822c  void w3::message_dispatch::add_filter(unsigned int)
00053ad5  public bool w3::command_line::app(std::wstring const&)
000533c0  unsigned int w3::convert_function(unsigned int)
00053b10  public bool w3::command_line::del(std::wstring const&)
0005ac65  unsigned int w3::find_objectid_64(w3::objectid_64 const&)
00058349  unsigned int w3::player::from_id(unsigned int)
0005ad1b  char const* w3::get_class_name(unsigned int)
0005622d  unsigned int w3::get_current_jass_pos()
00056206  unsigned int w3::get_jass_thread()
000561ce  w3::jass_vm_t* w3::get_jass_vm()
0005621c  w3::hashtable::native_func_table* w3::get_native_function_hashtable()
0005adb8  unsigned int w3::get_object_type(unsigned int)
000455a7  public unsigned int w3::storm_dll::get_proc(unsigned int)
0005ad5d  unsigned int w3::get_vfn_ptr(char const*)
0005adc8  unsigned int w3::handle_to_object(unsigned int)
00053af2  public bool w3::command_line::has(std::wstring const&)
00045588  public bool w3::storm_dll::has_file(char const*)
000454cd  public bool w3::storm_dll::load()
00045538  public bool w3::storm_dll::load_file(void*,char const*,void const**,unsigned int*,unsigned int,unsigned int,_OVERLAPPED*)
0004551c  public bool w3::storm_dll::load_file(char const*,void const**,unsigned int*)
00058366  unsigned int w3::player::local()
00058333  unsigned int w3::player::local_pid()
000533d0  unsigned int w3::next_opcode(unsigned int)
00053430  unsigned int w3::next_opcode(unsigned int,unsigned char,unsigned int)
0005ae1e  unsigned int w3::object_to_handle(unsigned int)
00053537  public static std::wstring w3::command_line::parse(std::function<std::wstring const&&(*)(std::char_traits<wchar_t>),{Z}>)
00055e55  void w3::register_game_reset_event(std::function<unsigned int&(*)(),{Z}>)
000582f5  void w3::message_dispatch::remove_filter(unsigned int)
00058373  w3::player::selection_t* w3::player::selection(unsigned int)
00053797  public std::wstring w3::command_line::str()
00055ddb  unsigned int w3::detail::string_hash(char const*)
00045569  public bool w3::storm_dll::unload_file(void const*)
00045518  public bool w3::storm_dll::valid()

### A.9 searcher 系列（basic_searcher / war3_searcher）（33 条）

0005311c  public w3::basic_searcher::basic_searcher(HINSTANCE__*)
0005a964  public w3::war3_searcher::war3_searcher(HINSTANCE__*)
0005a92b  public w3::war3_searcher::war3_searcher()
000328a5  public w3::basic_searcher& w3::basic_searcher::operator=(w3::basic_searcher const&)
000328bc  public w3::war3_searcher& w3::war3_searcher::operator=(w3::war3_searcher const&)
00045275  public unsigned int w3::basic_searcher::base()
0005a9ce  public unsigned int w3::war3_searcher::current_function(unsigned int)
0005a9ac  public unsigned int w3::war3_searcher::get_gameui(unsigned int,unsigned int)
0005a99d  public unsigned int w3::war3_searcher::get_instance(unsigned int)
0005a999  public unsigned int w3::war3_searcher::get_version()
0005abba  w3::war3_searcher& w3::get_war3_searcher()
00053133  private void w3::basic_searcher::initialize()
0005a9be  public bool w3::war3_searcher::is_gaming()
0005aa69  public unsigned int w3::war3_searcher::search_get_fps(unsigned int*,unsigned int)
0005aad2  public unsigned int w3::war3_searcher::search_get_func()
0005ab92  private unsigned int w3::war3_searcher::search_get_gameui()
0005ab36  private unsigned int w3::war3_searcher::search_get_instance()
00053308  public unsigned int w3::basic_searcher::search_int64_in_text(unsigned __int64)
00053322  public unsigned int w3::basic_searcher::search_int64_in_text(unsigned __int64,unsigned int)
00053394  public unsigned int w3::basic_searcher::search_int_in_data(unsigned int)
000533aa  public unsigned int w3::basic_searcher::search_int_in_data(unsigned int,unsigned int)
00053368  public unsigned int w3::basic_searcher::search_int_in_rdata(unsigned int)
0005337e  public unsigned int w3::basic_searcher::search_int_in_rdata(unsigned int,unsigned int)
0005333c  public unsigned int w3::basic_searcher::search_int_in_text(unsigned int)
00053352  public unsigned int w3::basic_searcher::search_int_in_text(unsigned int,unsigned int)
00053252  public unsigned int w3::basic_searcher::search_string(char const*)
00053227  public unsigned int w3::basic_searcher::search_string(char const*,unsigned int)
000532c6  public unsigned int w3::basic_searcher::search_string_part(char const*)
000531c4  public unsigned int w3::basic_searcher::search_string_ptr(char const*,unsigned int)
00053295  public unsigned int w3::basic_searcher::search_string_ptr_part(char const*)
00053276  public unsigned int w3::basic_searcher::search_string_ptr_part(char const*,unsigned int)
0005aa13  private unsigned int w3::war3_searcher::search_version()
000531b4  public unsigned int w3::basic_searcher::size()

### A.10 virtual_mpq 系列（5 条）

00058dd4  void w3::virtual_mpq::event(std::function<std::string const&&(*)(std::char_traits<char>),{Z}>)
00058b3d  bool w3::virtual_mpq::initialize(HINSTANCE__*)
00058c91  bool w3::virtual_mpq::open_path(boost::filesystem::path const&,unsigned int)
00058cae  void* w3::virtual_mpq::storm_alloc(unsigned int)
00058cc9  void w3::virtual_mpq::watch(std::string const&,std::function<double&(*)(std::string const&,void const**,unsigned int*,unsigned int),{Z}>)

### A.11 base::hook:: 底层 hook（7 条）

0004615f  bool base::hook::dyn_iat(HINSTANCE__*,wchar_t const*,char const*,unsigned int*,unsigned int)
000461a4  bool base::hook::dyn_iat(wchar_t const*,wchar_t const*,char const*,unsigned int*,unsigned int)
00047307  unsigned int base::hook::iat(HINSTANCE__*,char const*,char const*,unsigned int)
0004735a  unsigned int base::hook::iat(wchar_t const*,char const*,char const*,unsigned int)
000473e0  bool base::hook::inline_install(unsigned int*,unsigned int)
00047436  bool base::hook::inline_uninstall(unsigned int*,unsigned int)
00047489  unsigned int base::hook::replace_pointer(unsigned int,unsigned int)

### A.12 base::d3d:: 系列（37 条）

0003c72c  public base::d3d::text::text(base::d3d::text const&)
0003f34b  public base::d3d::text::text(tagLOGFONTA)
0003f375  public base::d3d::text::text(tagLOGFONTA,char const*)
0003f3a8  public base::d3d::text::text(tagLOGFONTA,char const*,float,float)
0003f3f2  public base::d3d::text::text(tagLOGFONTA,char const*,float,float,float)
0003f43f  public base::d3d::text::text(tagLOGFONTA,char const*,float,float,float,unsigned int)
0003f316  public base::d3d::text::text()
0003ad8c  public base::d3d::texture::texture(base::d3d::texture const&)
0003e2d4  public base::d3d::texture::texture(std::basic_string<char,std::char_traits<char>,base::allocator<char>>,base::d3d::loc_float,base::d3d::size_float,unsigned int,int)
0003e1f0  public base::d3d::texture_device::texture_device(std::basic_string<char,std::char_traits<char>,base::allocator<char>>,int*,base::allocator<char>)
0003f4fa  public base::d3d::text::~text()
0003e49a  public base::d3d::texture::~texture()
0003e281  public base::d3d::texture_device::~texture_device()
00030132  public base::d3d::WindowVector& base::d3d::WindowVector::operator=(base::d3d::WindowVector const&)
0003c780  public base::d3d::text& base::d3d::text::operator=(base::d3d::text const&)
0003ae2e  public base::d3d::texture& base::d3d::texture::operator=(base::d3d::texture const&)
0003ad77  public base::d3d::texture_device& base::d3d::texture_device::operator=(base::d3d::texture_device const&)
0003c3d4  base::d3d::WindowVector base::d3d::GetMouseVector()
0003c231  HWND__* base::d3d::GetWar3Window()
0003c245  base::d3d::WindowVector base::d3d::GetWindowVector()
0003c2fd  tagPOINT base::d3d::GetWindowVectorToPoint(base::d3d::WindowVector&)
0003ecb3  unsigned int base::d3d::get_d3d_pointer()
0003c55c  unsigned int base::d3d::get_d3d_version()
0003f2ab  std::map<int,std::shared_ptr<tagLOGFONTA>,base::less<int>,base::allocator<std::pair<const int,std::shared_ptr<tagLOGFONTA>>>>& base::d3d::get_font_map()
0003f2b1  std::shared_ptr<tagLOGFONTA> base::d3d::get_font_pointer(int)
0003c18c  std::map<std::basic_string<char,std::char_traits<char>,base::allocator<char>>,unsigned int,base::less<std::basic_string<char,std::char_traits<char>,base::allocator<char>>>,base::allocator<std::pair<const std::basic_string<char,std::char_traits<char>,base::allocator<char>>,unsigned int>>>& base::d3d::get_func_addr()
0003c497  __int64 base::d3d::get_last_time()
0003e695  public bool base::d3d::texture::get_mouse()
0003f240  std::map<int,std::shared_ptr<base::d3d::text>,base::less<int>,base::allocator<std::pair<const int,std::shared_ptr<base::d3d::text>>>>& base::d3d::get_text_map()
0003f246  std::shared_ptr<base::d3d::text> base::d3d::get_text_pointer(int)
0003e10a  std::map<std::basic_string<char,std::char_traits<char>,base::allocator<char>>,base::shared_ptr<base::d3d::texture_device>,base::less<std::basic_string<char,std::char_traits<char>,base::allocator<char>>>,base::allocator<std::pair<const std::basic_string<char,std::char_traits<char>,base::allocator<char>>,base::shared_ptr<base::d3d::texture_device>>>>& base::d3d::get_texture_device_map()
0003e110  std::shared_ptr<base::d3d::texture_device> base::d3d::get_texture_device_pointer(shared_ptr<base::d3d::texture_device>::basic_string<char,std::char_traits<char>,base::allocator<char>>)
0003e185  std::map<int,std::shared_ptr<base::d3d::texture>,base::less<int>,base::allocator<std::pair<const int,std::shared_ptr<base::d3d::texture>>>>& base::d3d::get_texture_map()
0003e18b  std::shared_ptr<base::d3d::texture> base::d3d::get_texture_pointer(int)
0003c4a3  void base::d3d::set_last_time(__int64)
0003e51d  public void base::d3d::texture::set_texture(std::basic_string<char,std::char_traits<char>,d3d::allocator<char>>)
0003e6de  bool base::d3d::texture_sort(std::shared_ptr<base::d3d::texture>&,base::d3d::texture)

### A.13 base::console:: 系列（7 条）

00051579  void base::console::disable()
00051589  bool base::console::disable_close_button()
00051504  void base::console::enable()
000515b4  void base::console::pause()
0005162e  bool base::console::read_post()
0005168e  void base::console::read_release(base::console::read_req_t*)
00051681  bool base::console::read_try(base::console::read_req_t*&)

### A.14 base::exception / thread / file / path / win 系列（118 条）

0005aeb8  public base::win::env_variable::env_variable(std::basic_string<wchar_t,std::char_traits<wchar_t>,base::allocator<wchar_t>>&&,...)
0005ae70  public base::win::env_variable::env_variable(base::win::env_variable const&)
0005ae70  public base::win::env_variable::env_variable(std::basic_string<wchar_t,std::char_traits<wchar_t>,base::allocator<wchar_t>> const&)
0005aea3  public base::win::env_variable::env_variable(wchar_t const*)
00040d53  public base::exception::exception(char const*&,...)
00040d7e  public base::exception::exception(wchar_t const*&,...)
00040c7b  public base::exception::exception(base::exception const&)
00040d3d  public base::exception::exception()
0004523c  public base::file::memory_mapped_file::memory_mapped_file(void*,unsigned __int64,unsigned int)
000451f8  public base::file::memory_mapped_file::memory_mapped_file(wchar_t const*)
00045217  public base::file::memory_mapped_file::memory_mapped_file(wchar_t const*,unsigned __int64,unsigned int)
0005625b  public base::win::pe_reader::pe_reader(HINSTANCE__*)
00050748  public base::win::pe_reader::pe_reader()
000458f1  public base::file::read_stream::read_stream(std::basic_string<char,std::char_traits<char>,base::allocator<char>> const&)
000459b2  public base::file::read_stream::read_stream(std::basic_string<wchar_t,std::char_traits<wchar_t>,base::allocator<wchar_t>> const&)
00045a1c  public base::file::read_stream::read_stream(boost::filesystem::path const&)
0004589a  public base::file::read_stream::read_stream(char const*)
0004595b  public base::file::read_stream::read_stream(wchar_t const*)
00041165  public base::seh_exception::seh_exception(base::seh_exception const&)
0004122a  public base::seh_exception::seh_exception(_EXCEPTION_POINTERS*)
000455c6  public base::file::stream::stream(char const*,int)
0004564c  public base::file::stream::stream(wchar_t const*,int)
00041088  public base::system_exception::system_exception(base::system_exception const&)
000412b7  public base::system_exception::system_exception(std::error_code const&,char const*)
000505aa  public base::thread::thread(base::thread const&)
00050748  public base::thread::thread()
0005051d  public base::thread_data_base::thread_data_base(base::thread_data_base const&)
000505fd  public base::thread_data_base::thread_data_base()
0005045e  public base::thread_exception::thread_exception(base::thread_exception const&)
000509d3  public base::thread_exception::thread_exception(int)
00050a1c  public base::thread_exception::thread_exception(enum std::errc::{name4},std::basic_string<char,std::char_traits<char>,errc::allocator<char>> const&)
000509f3  public base::thread_exception::thread_exception(enum std::errc::{name4},char const*)
000509ba  public base::thread_exception::thread_exception()
000504ed  public base::thread_resource_error::thread_resource_error(base::thread_resource_error const&)
00050a8d  public base::thread_resource_error::thread_resource_error(enum std::errc::{name4},std::basic_string<char,std::char_traits<char>,errc::allocator<char>> const&)
00050a6f  public base::thread_resource_error::thread_resource_error(enum std::errc::{name4},char const*)
00050a54  public base::thread_resource_error::thread_resource_error()
00041120  public base::windows_exception::windows_exception(base::windows_exception const&)
00041353  public base::windows_exception::windows_exception(char const*,int)
0004576f  public base::file::write_stream::write_stream(std::basic_string<char,std::char_traits<char>,base::allocator<char>> const&)
00045830  public base::file::write_stream::write_stream(std::basic_string<wchar_t,std::char_traits<wchar_t>,base::allocator<wchar_t>> const&)
00045830  public base::file::write_stream::write_stream(boost::filesystem::path const&)
00045718  public base::file::write_stream::write_stream(char const*)
000457d9  public base::file::write_stream::write_stream(wchar_t const*)
0004621d  public base::win::env_variable::~env_variable()
00040e2e  public virtual base::exception::~exception()
00045261  public base::file::memory_mapped_file::~memory_mapped_file()
000455be  public base::file::read_stream::~read_stream()
00041083  public virtual base::seh_exception::~seh_exception()
000456b8  public base::file::stream::~stream()
00041083  public virtual base::system_exception::~system_exception()
0005074e  public base::thread::~thread()
00050612  public virtual base::thread_data_base::~thread_data_base()
00050a45  public virtual base::thread_exception::~thread_exception()
00050a45  public virtual base::thread_resource_error::~thread_resource_error()
00041083  public virtual base::windows_exception::~windows_exception()
000455b9  public base::file::write_stream::~write_stream()
0005ae85  public base::win::env_variable& base::win::env_variable::operator=(base::win::env_variable const&)
00040ca8  public base::exception& base::exception::operator=(base::exception const&)
00032895  public base::win::pe_reader& base::win::pe_reader::operator=(base::win::pe_reader const&)
000411a4  public base::seh_exception& base::seh_exception::operator=(base::seh_exception const&)
000410b2  public base::system_exception& base::system_exception::operator=(base::system_exception const&)
000505cc  public base::thread& base::thread::operator=(base::thread const&)
00050541  public base::thread_data_base& base::thread_data_base::operator=(base::thread_data_base const&)
00050479  public base::thread_exception& base::thread_exception::operator=(base::thread_exception const&)
00050508  public base::thread_resource_error& base::thread_resource_error::operator=(base::thread_resource_error const&)
0004113b  public base::windows_exception& base::windows_exception::operator=(base::windows_exception const&)
00125800  base::exception::{vftable}  [vftable]
00125834  base::seh_exception::{vftable}  [vftable]
0012580c  base::system_exception::{vftable}  [vftable]
001268d4  base::thread_data_base::{vftable}  [vftable]
001268c8  base::thread_exception::{vftable}  [vftable]
001268bc  base::thread_resource_error::{vftable}  [vftable]
00125828  base::windows_exception::{vftable}  [vftable]
00041150  public void base::windows_exception::{_F}()
0004134f  public std::error_code const& base::system_exception::code()
0005b0a4  public bool base::win::env_variable::del()
00050779  public void base::thread::detach()
0005c826  bool base::path::equal(boost::filesystem::path const&,boost::filesystem::path const&)
0005b600  std::basic_string<char,std::char_traits<char>,base::allocator<char>> base::win::error_message(int)
0005b5e0  std::basic_string<char,std::char_traits<char>,base::allocator<char>> base::win::error_message()
0005aecd  public std::basic_string<wchar_t,std::char_traits<wchar_t>,win::allocator<wchar_t>> base::win::env_variable::get()
0005cb15  boost::filesystem::path base::path::get(enum base::path::PATH_TYPE::boost)
00041274  public virtual _CONTEXT const& base::seh_exception::get_context()
0005b32c  public unsigned int base::win::pe_reader::get_directory_entry(unsigned int)
0005b349  public unsigned int base::win::pe_reader::get_directory_entry_size(unsigned int)
00045275  public _IMAGE_DOS_HEADER* base::win::pe_reader::get_dos_header()
00041270  public virtual _EXCEPTION_RECORD const& base::seh_exception::get_exception_record()
00040e52  protected {$e}&& base::exception::get_format_string({r},{r},{o},{r},_m,{s},{g})
00040e6c  protected base::exception_detail::error_msg<char> base::exception::get_format_string(char const*,char*)
00040ef4  protected base::exception_detail::error_msg<wchar_t> base::exception::get_format_string(wchar_t const*,char*)
00050877  public unsigned int base::thread::get_id()
0005af95  public std::optional<std::basic_string<wchar_t,std::char_traits<wchar_t>,win::allocator<wchar_t>>> base::win::env_variable::get_nothrow()
0005b324  public _IMAGE_NT_HEADERS* base::win::pe_reader::get_nt_headers()
0005b361  public unsigned int base::win::pe_reader::get_num_sections()
0005b36c  public _IMAGE_SECTION_HEADER* base::win::pe_reader::get_section_by_name(char const*)
0005b2be  unsigned __int64 base::win::get_tick_count()
000412ab  public static void base::seh_exception::initialize()
00045707  public bool base::file::stream::is_open()
00050791  public void base::thread::join()
00045271  public void const* base::file::memory_mapped_file::memory()
00045275  public HINSTANCE__* base::win::pe_reader::module()
0005bd10  boost::filesystem::path base::path::detail::module_path(HINSTANCE__*)
0005bedb  boost::filesystem::path base::path::detail::module_path(void*,HINSTANCE__*)
000531b4  public unsigned int base::win::pe_reader::module_size()
00050a50  public int base::thread_exception::native_error()
0005c223  boost::filesystem::path base::path::normalize(boost::filesystem::path const&)
00045328  private void base::file::memory_mapped_file::open(void*,unsigned __int64,unsigned int)
00045278  private void base::file::memory_mapped_file::open(wchar_t const*,unsigned __int64,unsigned int)
0005b30e  public unsigned int base::win::pe_reader::rva_to_addr(unsigned int)
0005b07c  public bool base::win::env_variable::set(std::basic_string<wchar_t,std::char_traits<wchar_t>,win::allocator<wchar_t>> const&)
0005b302  public void base::win::pe_reader::set_module(HINSTANCE__*)
00045275  public unsigned int base::file::memory_mapped_file::size()
00050733  void base::this_thread::sleep_for(unsigned __int64)
000508a5  private void base::thread::start_thread()
00041278  public static void base::seh_exception::trans_func(unsigned int,_EXCEPTION_POINTERS*)
00040f6a  public virtual char const* base::exception::what()

### A.15 IMAGE:: 图像库（BLP/JPEG/BUFFER）（36 条）

000315a0  public IMAGE::BLP::BLP()
0003902f  public IMAGE::BUFFER::BUFFER(IMAGE::BUFFER const&)
0003902f  public IMAGE::BUFFER::BUFFER(std::basic_string<char,std::char_traits<char>,char_traits<char>::allocator<char>> const&)
0003a79e  public IMAGE::BUFFER::BUFFER()
000315a0  public IMAGE::JPEG::JPEG()
0002ff10  public IMAGE::BLP::~BLP()
00030d6d  public IMAGE::BUFFER::~BUFFER()
0002ff10  public IMAGE::JPEG::~JPEG()
000390a0  public IMAGE::BLP& IMAGE::BLP::operator=(IMAGE::BLP const&)
00039044  public IMAGE::BUFFER& IMAGE::BUFFER::operator=(IMAGE::BUFFER const&)
000390a0  public IMAGE::JPEG& IMAGE::JPEG::operator=(IMAGE::JPEG const&)
0003a7c0  public char& IMAGE::BUFFER::operator[](unsigned int)
000315a0  public std::basic_string<char,std::char_traits<char>,IMAGE::allocator<char>> const& IMAGE::BUFFER::Buf()
0003ad5f  protected static unsigned char IMAGE::JPEG::DestinationEmpty(jpeg_compress_struct*)
0003ad46  protected static void IMAGE::JPEG::DestinationInit(jpeg_compress_struct*)
0002ff10  protected static void IMAGE::JPEG::DestinationTerminate(jpeg_compress_struct*)
0003a7c0  public unsigned char* IMAGE::BUFFER::GetData(unsigned int)
0003a7c0  public unsigned char const* IMAGE::BUFFER::GetData(unsigned int)
0003a7d4  public unsigned int IMAGE::BUFFER::GetSize()
000395a3  protected bool IMAGE::BLP::LoadCompressed(IMAGE::BLP_HEADER&,IMAGE::BUFFER const&,IMAGE::BUFFER&)
000396c5  protected bool IMAGE::BLP::LoadUncompressed(IMAGE::BLP_HEADER&,IMAGE::BUFFER const&,IMAGE::BUFFER&)
0003950a  public bool IMAGE::BLP::Read(IMAGE::BUFFER const&,IMAGE::BUFFER&,int*,int*)
0003aa77  public bool IMAGE::JPEG::Read(IMAGE::BUFFER const&,IMAGE::BUFFER&,int*,int*)
0003a7af  public void IMAGE::BUFFER::Resize(unsigned int)
0003acbe  protected static void IMAGE::JPEG::SetMemoryDestination(jpeg_compress_struct*,unsigned char*,unsigned int)
0003ac5c  protected static void IMAGE::JPEG::SetMemorySource(jpeg_decompress_struct*,unsigned char*,unsigned int)
0003acfd  protected static unsigned char IMAGE::JPEG::SourceFill(jpeg_decompress_struct*)
0002ff10  protected static void IMAGE::JPEG::SourceInit(jpeg_decompress_struct*)
0003ad18  protected static void IMAGE::JPEG::SourceSkip(jpeg_decompress_struct*,long)
0002ff10  protected static void IMAGE::JPEG::SourceTerminate(jpeg_decompress_struct*)
000390a5  public bool IMAGE::BLP::Write(IMAGE::BUFFER const&,IMAGE::BUFFER&,int,int,int)
0003a8a7  public bool IMAGE::JPEG::Write(IMAGE::BUFFER const&,IMAGE::BUFFER&,int,int,int)
00039009  public std::_String_iterator<std::_String_val<std::_Simple_types<char>>> IMAGE::BUFFER::begin()
00039009  public std::_String_const_iterator<std::_String_val<std::_Simple_types<char>>> IMAGE::BUFFER::begin()
0003901d  public std::_String_iterator<std::_String_val<std::_Simple_types<char>>> IMAGE::BUFFER::end()
0003901d  public std::_String_const_iterator<std::_String_val<std::_Simple_types<char>>> IMAGE::BUFFER::end()

### A.16 其余 base:: 设施（8 条）

00050c49  bool base::Base64Decode(std::basic_string<char,std::char_traits<char>,char_traits<char>::allocator<char>> const&,std::char_traits<char>*)
00050ae8  bool base::Base64Encode(std::basic_string<char,std::char_traits<char>,char_traits<char>::allocator<char>> const&,std::char_traits<char>*)
000524fd  std::basic_string<char,std::char_traits<char>,char_traits<char>::allocator<char>> base::a2u(std::basic_string_view<char,std::char_traits<char>> const&,base::conv_method)
00052385  std::basic_string<wchar_t,std::char_traits<wchar_t>,char_traits<wchar_t>::allocator<wchar_t>> base::a2w(std::basic_string_view<char,std::char_traits<char>> const&,base::conv_method)
0005243b  std::basic_string<char,std::char_traits<char>,char_traits<char>::allocator<char>> base::u2a(std::basic_string_view<char,std::char_traits<char>> const&,base::conv_method)
000522cf  std::basic_string<wchar_t,std::char_traits<wchar_t>,char_traits<wchar_t>::allocator<wchar_t>> base::u2w(std::basic_string_view<char,std::char_traits<char>> const&,base::conv_method)
000523e0  std::basic_string<char,std::char_traits<char>,char_traits<char>::allocator<char>> base::w2a(std::basic_string_view<wchar_t,std::char_traits<wchar_t>> const&,base::conv_method)
0005232a  std::basic_string<char,std::char_traits<char>,char_traits<char>::allocator<char>> base::w2u(std::basic_string_view<wchar_t,std::char_traits<wchar_t>> const&,base::conv_method)

### A.17 std:: 模板实例（118 条）

std:: 模板实例共 118 条，为 `std::_Tree`/`std::map`/`std::unordered_map`/`std::vector`/`std::basic_string`/`std::function` 及 `base::exception` 各 vftable 的实例化，代表性条目：

00053f4a  public std::_Tree<std::_Tmap_traits<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar_t>::st
00053f7a  public std::_Tree<std::_Tmap_traits<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar_t>::st
00053c26  public std::_Tree_alloc<A,std::_Tree_base_types<std::pair<const std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wcha
00053c26  public std::_Tree_buy<std::pair<const std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar_t>::
00053c71  public std::_Tree_comp<A,std::_Tmap_traits<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar
000546bd  public std::_Tree_val<std::_Tree_simple_types<std::pair<const std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_
00053c9d  public std::map<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar_t>::std,allocator<wchar_t>
00053cb2  public std::map<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar_t>::std,allocator<wchar_t>
00053d3c  public std::map<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar_t>::std,allocator<wchar_t>
00053c11  public std::map<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar_t>::std,allocator<wchar_t>
0005406a  public std::_Tree<std::_Tmap_traits<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar_t>::st
0003b4f6  public std::_Tree_alloc<A,std::_Tree_base_types<std::pair<const std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wcha
0003b4f6  public std::_Tree_buy<std::pair<const std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar_t>::
0003b4f6  public std::_Tree_comp<A,std::_Tmap_traits<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar_t>>,allocator<wchar
00053fb5  public std::char_traits<wchar_t>& std::_Tree<std::_Tmap_traits<std::basic_string<wchar_t,std::char_traits<wchar_t>,allocator<wchar_t>::allocator<wchar
……（其余 103 条略，全部为 STL 容器/字符串/异常支撑代码）

```

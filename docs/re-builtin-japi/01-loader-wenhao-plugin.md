# 01 — 加载器 wenhao_plugin.tga 逆向分析

> 分析对象：`build/_orig_check/wenhao_plugin.tga`（从地图 MPQ 原样解出，4,653,568 字节）。
> 全部结论来自对该二进制的直接分析（objdump 2.30 反汇编 + 纯 struct Python 脚本解析）。
> 时间基准：本文 RVA 均相对 ImageBase `0x10000000`；VA = RVA + 0x10000000。

## 1. 概述

`wenhao_plugin.tga` 是一个 32 位 PE32 DLL（扩展名是伪装的 .tga），是"内置 JAPI"的**一级加载器（bootstrapper）**。
它的全部职责只有三件事：

1. 把自身 `.rsrc` 里嵌入的 5 个 PE 释放（写盘）到当前目录；
2. `LoadLibraryA` 加载其中两个功能 DLL（jass.dll、lua_engine.dll），并依次调用它们的初始化导出；
3. 用导出 `get` 向外界报告"初始化已完成"。

DLL 本体极小（`.text` 仅 0xC764 ≈ 50 KB），文件体积的 **98.3% 是 `.rsrc` 资源节**——嵌入的 5 个子 PE。
真正的游戏 hook 逻辑不在本文件内，而在它释放出的 `Jass.dll`（资源 109）与 `yd_lua_engine.dll`（资源 111）中（另有专文分析）。

**控制权交接结论（先说答案）**：`call` 导出在一次调用内**同步**完成全部初始化——写文件、加载两个子 DLL、依次调用 `Jass.dll!call(0)` → `yd_lua_engine.dll!init_lua_engine()` → `Jass.dll!init(0)`，最后把 `g_initialized` 置 1 才返回。DllMain 本身只保存模块句柄，不做任何初始化。

## 2. 事实清单（带证据）

### 2.1 文件身份与"陷阱 1"验证

- `file`：`PE32 executable for MS Windows 5.01 (DLL), Intel i386, 5 sections`。
- 导出目录内部名（Export Directory Name RVA 指向的字符串）：`wenhao_plugin.tga`
  （证据：`objdump -x` 导出表段 `Name 0001228c wenhao_plugin.tga`）。
  内部名与文件名一致，**未发生交叉互换**，本文件确为加载器本体。
- COFF 头 TimeDateStamp 与导出目录时间戳同为 `0x59E23263` = **2017-10-14 15:50:59 UTC**（objdump 按本地时区显示为 `Sat Oct 14 23:50:59 2017`），与嵌入的 Jass.dll（15:50:32）、newD3d9.dll（15:50:41）、yd_lua_engine.dll（15:50:57）为同一构建批次。
- 链接器版本 12.0（对应 VS2013 工具链）；Subsystem = Windows GUI；`DllCharacteristics 0x140`（DYNAMIC_BASE | NX_COMPAT）。
- Load Config 目录（RVA 0x11DB8，文件偏移 0x109B8）大小 0x48，尾部字段为 `0x10013000`（SafeSEH handler 表 VA，指向 .data 起始），即启用了 /SAFESEH。

### 2.2 PE 头与节区表

ImageBase `0x10000000`，入口点 RVA `0x174E`，FileAlignment 0x200，SectionAlignment 0x1000。

| 节 | VirtualSize | VA | RawSize | 文件偏移 | 说明 |
|---|---|---|---|---|---|
| .text  | 0x00C764 | 0x10001000 | 0x00C800 | 0x000400 | 代码 |
| .rdata | 0x004918 | 0x1000E000 | 0x004A00 | 0x00CC00 | 导入/导出/字符串常量 |
| .data  | 0x00300C | 0x10013000 | 0x001200 | 0x011600 | 虚尺寸远大于裸数据：0x10014200 起为 BSS |
| .rsrc  | 0x45C878 | 0x10017000 | 0x45CA00 | 0x012800 | **占全文件 98.3%**（4,573,696 / 4,653,568） |
| .reloc | 0x000E28 | 0x10474000 | 0x001000 | 0x46F200 | 重定位 |

证据：`objdump -x` 的 `Sections:` 表与 data directory（`Entry 2 00017000 0045c878 Resource Directory`）。

### 2.3 导入表：只有一个 DLL，但 72 个函数

导入目录只有一个描述符：`DLL Name: KERNEL32.dll`（ILT RVA 0x122D0，IAT RVA 0xE000）。
IAT 共 72 项（0x1000E000–0x1000E11C，步长 4）。逐一列出（IAT VA → 函数名，由解析 ILT 逐项得出）：

```
0x1000e000 FindResourceA      0x1000e004 FreeResource        0x1000e008 LoadResource
0x1000e00c Sleep              0x1000e010 SizeofResource      0x1000e014 GetLastError
0x1000e018 GetProcAddress     0x1000e01c LoadLibraryA        0x1000e020 LockResource
0x1000e024 GetModuleHandleA   0x1000e028 DeleteFileA         0x1000e02c GetCommandLineA
0x1000e030 GetCurrentThreadId 0x1000e034 IsDebuggerPresent   0x1000e038 IsProcessorFeaturePresent
0x1000e03c EncodePointer      0x1000e040 DecodePointer       0x1000e044 EnterCriticalSection
0x1000e048 LeaveCriticalSection 0x1000e04c RtlUnwind         0x1000e050 WriteFile
0x1000e054 WideCharToMultiByte 0x1000e058 GetConsoleCP       0x1000e05c GetConsoleMode
0x1000e060 CloseHandle        0x1000e064 HeapFree            0x1000e068 SetLastError
0x1000e06c ExitProcess        0x1000e070 GetModuleHandleExW  0x1000e074 AreFileApisANSI
0x1000e078 MultiByteToWideChar 0x1000e07c GetProcessHeap     0x1000e080 GetStdHandle
0x1000e084 GetFileType        0x1000e088 DeleteCriticalSection 0x1000e08c GetStartupInfoW
0x1000e090 GetModuleFileNameA 0x1000e094 QueryPerformanceCounter 0x1000e098 GetCurrentProcessId
0x1000e09c GetSystemTimeAsFileTime 0x1000e0a0 GetEnvironmentStringsW 0x1000e0a4 FreeEnvironmentStringsW
0x1000e0a8 UnhandledExceptionFilter 0x1000e0ac SetUnhandledExceptionFilter
0x1000e0b0 InitializeCriticalSectionAndSpinCount 0x1000e0b4 GetCurrentProcess
0x1000e0b8 TerminateProcess   0x1000e0bc TlsAlloc            0x1000e0c0 TlsGetValue
0x1000e0c4 TlsSetValue        0x1000e0c8 TlsFree             0x1000e0cc GetModuleHandleW
0x1000e0d0 SetFilePointerEx   0x1000e0d4 SetStdHandle        0x1000e0d8 WriteConsoleW
0x1000e0dc FlushFileBuffers   0x1000e0e0 IsValidCodePage     0x1000e0e4 GetACP
0x1000e0e8 GetOEMCP           0x1000e0ec GetCPInfo           0x1000e0f0 GetModuleFileNameW
0x1000e0f4 LoadLibraryExW     0x1000e0f8 HeapAlloc           0x1000e0fc HeapReAlloc
0x1000e100 CreateFileW        0x1000e104 GetStringTypeW      0x1000e108 OutputDebugStringW
0x1000e10c HeapSize           0x1000e110 LCMapStringW        0x1000e114 SetEndOfFile
0x1000e118 ReadFile           0x1000e11c ReadConsoleW
```

其中**加载器自身逻辑只用到 11 个**（FindResourceA / LoadResource / LockResource / SizeofResource /
FreeResource / DeleteFileA / GetLastError / Sleep / GetModuleHandleA / LoadLibraryA / GetProcAddress，
证据见 §3 反汇编中 `call DWORD PTR ds:0x1000e0xx` 的实际引用）；其余 61 个全部是静态链接 MSVCRT
（fopen/fwrite/fclose、CRT 启动、SEH、堆、TLS 等）带入的。

旁证：导入表中**没有** CreateProcess / WinExec / ShellExecute / 网络 / 注册表函数——
wenhao_plugin 自身不会执行它写盘的 `pjass.exe`，也不联网、不写注册表。

### 2.4 导出表

```
Ordinal Base 1，Number in EAT = 2
[1] RVA 0x1100  call   （VA 0x10001100，文件偏移 0x500）
[2] RVA 0x1230  get    （VA 0x10001230，文件偏移 0x630）
```

证据：`objdump -x` 导出表（Export Address Table RVA 0x12278；Name Pointer Table RVA 0x12280）。
两导出均为 cdecl（函数末尾裸 `ret`，调用方清栈，见 §3.3/§3.4）。

### 2.5 .rsrc 资源枚举：5 个嵌入 PE + 1 个 manifest

objdump 不解析资源目录，用纯 struct 的 Python 脚本解析资源树
（资源根：RVA 0x17000 = 文件偏移 0x12800；RVA→文件偏移换算 `off = rva - 0x17000 + 0x12800`）。
共 6 个资源，类型名为自定义字符串 `"EXE"` / `"DLL"`；5 个 PE 资源的语言 ID 均为 **2052（0x804，zh-CN）**，manifest 为 1033（en-US）：

| 类型 | ID | 资源 RVA | 大小 | 文件偏移 | 头 16 字节 | 内部身份（证据见下） |
|---|---|---|---|---|---|---|
| EXE | **108** | 0x00017190 | 40,974 (0xA00E) | 0x12990 | `4d 5a 90 00 03 00 00 00 04 00 00 00 ff ff 00 00` | **pjass.exe**（UPX 壳） |
| DLL | **109** | 0x000211A0 | 1,532,928 (0x176400) | 0x1C9A0 | 同上 MZ | **Jass.dll** |
| DLL | **110** | 0x001975A0 | 110,080 (0x1AE00) | 0x192DA0 | 同上 MZ | **newD3d9.dll** |
| DLL | **111** | 0x001B23A0 | 996,352 (0xF3400) | 0x1ADBA0 | 同上 MZ | **yd_lua_engine.dll** |
| DLL | **115** | 0x002A57A0 | 1,892,184 (0x1CDF58) | 0x2A0FA0 | 同上 MZ | **d3dx9_42.dll** |
| MANIFEST(24) | 2 | 0x004736F8 | 381 (0x17D) | 0x46EEF8 | `3c 3f 78 6d 6c …`（`<?xml `） | asInvoker manifest |

每个嵌入 PE 的身份由两条独立证据链确认：

1. **各 PE 自身导出目录内部名**（脚本解析其 PE 头得到）：
   - 109 → `'Jass.dll'`，节区 `.text .rdata .data .data1 .detourd …`（含 **Microsoft Detours 标记节 `.detourd`**），时间戳 2017-10-14 15:50:32 UTC；
   - 110 → `'newD3d9.dll'`，时间戳 2017-10-14 15:50:41 UTC；
   - 111 → `'yd_lua_engine.dll'`，时间戳 2017-10-14 15:50:57 UTC；
   - 115 → `'d3dx9_42.dll'`，时间戳 2009-07-27（微软官方 DirectX 再发行组件，非作者编译）；
   - 108 → 无导出目录；节区为 `UPX0/UPX1/UPX2`，含 `UPX!` 魔数（UPX 压缩壳），PE 时间戳字段为异常值 `0xC085FFFF`（UPX 特征）。
2. **`call` 导出中的释放代码**把资源 ID 与写盘文件名绑定（§3.3）：108→`pjass.exe`，115→`D3DX9_42.dll`，110→`newD3d9.dll`，109→`jass.dll`，111→`lua_engine.dll`。

注意**写盘文件名与 DLL 内部名不同**：109 内部名 `Jass.dll` 写为 `jass.dll`；111 内部名 `yd_lua_engine.dll` 写为 `lua_engine.dll`。

manifest 内容（381 字节，全文可读）为标准的 `<requestedExecutionLevel level='asInvoker' uiAccess='false'/>`。

补充验证：`call` 要查找的三个子 DLL 导出在被嵌入 DLL 的导出表中**确实存在**（脚本解析其导出 Name Pointer Table）——
Jass.dll（109）共 546 个导出，含 `call` 与 `init`；yd_lua_engine.dll（111）共 600 个导出，含 `init_lua_engine`。

## 3. 关键机制还原

### 3.1 DllMain 与 CRT 入口（RVA 0x174E）

入口点 0x1000174E 是 VS2013 CRT 的 `_DllMainCRTStartup`：

```asm
1000174e: cmp  DWORD PTR [ebp+0xc],0x1      ; fdwReason == DLL_PROCESS_ATTACH ?
10001755: jne  0x1000175c
10001757: call 0x1000486d                    ; CRT 初始化（__security_init_cookie 等）
1000175c: push [ebp+0x10] / [ebp+0xc] / [ebp+0x8]
10001765: call 0x10001771                    ; SEH 包装体
```

SEH 包装体 0x10001771 在 0x100017DE 处 `call 0x10001000`——真正的用户 DllMain 只有 5 条指令：

```asm
10001000: push ebp
10001001: mov  ebp,esp
10001003: mov  eax,DWORD PTR [ebp+0x8]       ; hinstDLL
10001006: mov  ds:0x10014f4c,eax             ; g_hModule = hinstDLL
1000100b: mov  eax,0x1
10001010: pop  ebp
10001011: ret  0xc
```

**DllMain 只把模块句柄存入全局槽位 `g_hModule`（0x10014F4C，.data 的 BSS 段），立即返回 TRUE。**
任何 DLL_PROCESS_ATTACH 时刻都不写文件、不加载子 DLL。

### 3.2 资源释放辅助函数 write_resource_to_file（RVA 0x1020）

调用约定为非标准混合约定：`write_resource_to_file(文件名 [栈 arg0], 资源类型串 edx, 资源ID ecx)`。
被 `call` 调用 5 次。逐段还原：

**第一段——DeleteFileA 重试循环（有界，10 次）：**

```asm
10001026: mov  ebx,DWORD PTR ds:0x1000e028   ; ebx = DeleteFileA
1000102f: mov  edi,DWORD PTR [ebp+0x8]       ; edi = 文件名
10001033: mov  [ebp-0x4],edx                 ; 保存资源类型串 ("exe"/"dll")
10001036: mov  [ebp-0x8],ecx                 ; 保存资源 ID
10001039: call ebx                           ; DeleteFileA(文件名)
1000103b: call DWORD PTR ds:0x1000e014       ; GetLastError()
10001043: cmp  eax,0x7e                      ; 126 = ERROR_MOD_NOT_FOUND
10001046: je   0x1000107f                    ;  → 直接释放
10001048: cmp  eax,0x2                       ; ERROR_FILE_NOT_FOUND
1000104b: je   0x10001068                    ;  → 释放
1000104d: test eax,eax                       ; 0 = 删除成功
1000104f: je   0x10001068                    ;  → 释放
                                            ; 其他错误（如 5 = ACCESS_DENIED，文件被占用）：
10001051: push 0xa
10001053: call DWORD PTR ds:0x1000e00c       ; Sleep(10)
10001059: push edi
1000105a: call ebx                           ; DeleteFileA(文件名) 再试
1000105c: call DWORD PTR ds:0x1000e014       ; GetLastError()
10001062: inc  esi
10001063: cmp  esi,0xa
10001066: jl   0x10001043                    ; 最多 10 轮
10001068: (循环结束后) 仍非 {0,2,0x7e} → 0x10001076: xor al,al; ret   ; 返回 0（调用方不检查）
```

**第二段——定位资源并写盘：**

```asm
1000107f: push [ebp-0x4]                     ; 类型串 "exe"/"dll"
10001085: movzx eax,ax  (来自[ebp-0x8])      ; 资源 ID 取低 16 位
10001089: push DWORD PTR ds:0x10014f4c       ; g_hModule
1000108f: call DWORD PTR ds:0x1000e000       ; FindResourceA(g_hModule, ID, 类型)
10001098: push g_hModule; call ds:0x1000e008 ; LoadResource
100010a5: mov  [ebp-0x8],eax
100010a8: call DWORD PTR ds:0x1000e020       ; LockResource → ebx = 数据指针
100010af: push g_hModule; call ds:0x1000e010 ; SizeofResource → esi = 大小
100010bd: push 0x10011d44                    ; "wb"（证据：0x10011D44 处字节 77 62 00）
100010c2: push edi                           ; 文件名
100010c5: call 0x10001309                    ; fopen(文件名, "wb")  → edi = FILE*
100010cd: push edi / push esi / push 1 / push ebx
100010d1: call 0x10001477                    ; fwrite(数据, 1, 大小, FILE*)
100010d6: push edi
100010d7: call 0x10001565                    ; fclose(FILE*)
100010e2: call DWORD PTR ds:0x1000e004       ; FreeResource
100010ea: mov  al,0x1                        ; 返回 1
```

CRT 函数身份佐证：0x10001309 以 `push 0x40; push mode; push name; call 0x10001245` 的形式包装
（MSVCRT `fopen` → `_fsopen(..., _SH_DENYNO=0x40)` 的定式）；0x10001477 含 SEH 帧、
FILE._flag（`[esi+0xc]`）检查与 `_lock_file`/`_unlock_file`，是 `fwrite`；0x10001565 同构包装
0x100014F9（`_fclose_nolock`：`test BYTE PTR [esi+0xc],0x83` 检查 _IOREAD/_IOWRT/_IORW 标志位）。

### 3.3 导出 `call`（RVA 0x1100）——完整流程

函数头字节（文件偏移 0x500）：
`55 8b ec 8b 45 08 ba 54 1d 01 10 53 56 57 68 48 1d 01 10 b9 6c 00 00 00 a3 54 4f 01 10`

接收 1 个 cdecl 参数（记为 `arg0`），**第一步先把它存入全局槽位 `0x10014F54`**。
全流程反汇编要点（字符串常量的文件偏移与内容见下表）：

**阶段 A——无条件释放 3 个文件：**

```asm
10001106: mov  edx,0x10011d54                ; "exe"
1000110e: push 0x10011d48                    ; "pjass.exe"
10001113: mov  ecx,0x6c                      ; 资源 ID 108
10001118: mov  ds:0x10014f54,eax             ; g_call_arg = arg0
1000111d: call 0x10001020                    ; 释放 EXE/108 → pjass.exe
10001122: push 0x10011d58                    ; "D3DX9_42.dll"
10001127: mov  edx,0x10011d68                ; "dll"
1000112c: mov  ecx,0x73                      ; 资源 ID 115
10001131: call 0x10001020                    ; 释放 DLL/115 → D3DX9_42.dll
10001136: push 0x10011d6c                    ; "newD3d9.dll"
1000113b: mov  edx,0x10011d68                ; "dll"
10001140: mov  ecx,0x6e                      ; 资源 ID 110
10001145: call 0x10001020                    ; 释放 DLL/110 → newD3d9.dll
1000114a: add  esp,0xc
```

**阶段 B——确保 jass.dll 已加载（含 Sleep 重试）：**

```asm
1000114d: push 0x10011d78                    ; "jass.dll"
10001152: call DWORD PTR ds:0x1000e024       ; GetModuleHandleA("jass.dll")
10001158: mov  ebx,DWORD PTR ds:0x1000e00c   ; ebx = Sleep
1000115e: mov  esi,eax                       ; esi = hJass
10001160: mov  edi,DWORD PTR ds:0x1000e01c   ; edi = LoadLibraryA
10001166: test esi,esi
10001168: jne  0x100011a1                    ; 已在进程中 → 跳过释放与加载
1000116a: push 0x10011d78; mov edx,"dll"; mov ecx,0x6d   ; 资源 ID 109
10001179: call 0x10001020                    ; 释放 DLL/109 → jass.dll
10001181: push 0x10011d78
10001186: call edi                           ; LoadLibraryA("jass.dll")   ← 首次尝试
1000118a: test esi,esi / jne 0x100011a1
10001190: push 0xa
10001192: call ebx                           ; Sleep(10)
10001194: push 0x10011d78
10001199: call edi                           ; LoadLibraryA("jass.dll")
1000119f: je   0x10001190                    ; ★ 无界重试：直到成功为止
```

**阶段 C——调 `Jass.dll!call(0)`：**

```asm
100011a1: push 0x10011d84                    ; "call"
100011a6: push esi                           ; hJass
100011a7: call DWORD PTR ds:0x1000e018       ; GetProcAddress(hJass, "call")
100011ad: test eax,eax
100011af: je   0x100011b8                    ; 找不到就静默跳过
100011b1: push 0x0
100011b3: call eax                           ; Jass.dll!call(0)
```

**阶段 D——确保 lua_engine.dll 已加载（同样的无界重试结构）：**

```asm
100011b8: push 0x10011d8c                    ; "lua_engine.dll"
100011bd: call DWORD PTR ds:0x1000e024       ; GetModuleHandleA
100011c3: test eax,eax / jne 0x100011f6
100011c7: push 0x10011d8c; mov edx,"dll"; lea ecx,[eax+0x6f]  ; eax=0 → 资源 ID 111
100011d4: call 0x10001020                    ; 释放 DLL/111 → lua_engine.dll
100011dc: push 0x10011d8c
100011e1: call edi                           ; LoadLibraryA 首次尝试
100011e5: jne  0x100011f6
100011e7: push 0xa; call ebx                 ; Sleep(10)
100011eb: push 0x10011d8c; call edi          ; LoadLibraryA
100011f4: je   0x100011e7                    ; ★ 无界重试
```

**阶段 E——调 `yd_lua_engine.dll!init_lua_engine()`：**

```asm
100011f6: mov  edi,DWORD PTR ds:0x1000e018   ; GetProcAddress
100011fc: push 0x10011d9c                    ; "init_lua_engine"
10001201: push eax                           ; hLua
10001202: call edi
10001206: je   0x1000120a
10001208: call eax                           ; init_lua_engine()（0 个参数）
```

**阶段 F——调 `Jass.dll!init(0)`，置完成标志，返回：**

```asm
1000120a: push 0x10011dac                    ; "init"
1000120f: push esi                           ; hJass
10001210: call edi                           ; GetProcAddress(hJass, "init")
10001215: test eax,eax
10001217: je   0x10001220
10001219: push 0x0
1000121b: call eax                           ; Jass.dll!init(0)
10001220: mov  DWORD PTR ds:0x10014f50,0x1   ; g_initialized = 1
1000122a: pop  ebp
1000122b: ret
```

字符串常量证据（.rdata，文件偏移 = VA − 0x1000E000 + 0xCC00）：

| VA | 文件偏移 | 内容 | 用途 |
|---|---|---|---|
| 0x10011D44 | 0x10944 | `"wb"` | fopen 模式 |
| 0x10011D48 | 0x10948 | `"pjass.exe"` | 释放名（资源 108） |
| 0x10011D54 | 0x10954 | `"exe"` | 资源类型名 |
| 0x10011D58 | 0x10958 | `"D3DX9_42.dll"` | 释放名（资源 115） |
| 0x10011D68 | 0x10968 | `"dll"` | 资源类型名 |
| 0x10011D6C | 0x1096C | `"newD3d9.dll"` | 释放名（资源 110） |
| 0x10011D78 | 0x10978 | `"jass.dll"` | 加载名（资源 109） |
| 0x10011D84 | 0x10984 | `"call"` | Jass.dll 导出 |
| 0x10011D8C | 0x1098C | `"lua_engine.dll"` | 加载名（资源 111） |
| 0x10011D9C | 0x1099C | `"init_lua_engine"` | yd_lua_engine.dll 导出 |
| 0x10011DAC | 0x109AC | `"init"` | Jass.dll 导出 |

全部为 ASCII，本 DLL 中无中文/GBK 字符串。

还原为伪代码：

```c
// 全局（.data BSS 段，加载时为零）
HMODULE g_hModule     = NULL;  // 0x10014F4C，DllMain 写入
int     g_initialized = 0;     // 0x10014F50，call 写入 / get 读出
DWORD   g_call_arg    = 0;     // 0x10014F54，call 写入，本 DLL 内无人读

int write_resource_to_file(const char* fname /*栈*/, const char* type /*edx*/, int id /*ecx*/) {
    int tries = 0;
    DeleteFileA(fname);
    DWORD err = GetLastError();
    // 0x10001043 循环：错误码 ∉ {0, 2, 0x7e} 时 Sleep(10) 重删，最多重试 10 次
    while (err != 0 && err != 2 /*ERROR_FILE_NOT_FOUND*/ && err != 0x7e /*126*/) {
        Sleep(10);
        DeleteFileA(fname);
        err = GetLastError();
        if (++tries >= 10) break;             // 0x10001063: cmp esi,0xa / jl 循环头
    }
    if (err != 0 && err != 2 && err != 0x7e) return 0;   // 0x10001068 终判，调用方不检查返回值
    HRSRC h = FindResourceA(g_hModule, (LPCSTR)(WORD)id, type);
    HGLOBAL g = LoadResource(g_hModule, h);
    void* p = LockResource(g);
    DWORD sz = SizeofResource(g_hModule, h);
    FILE* f = fopen(fname, "wb");
    fwrite(p, 1, sz, f);
    fclose(f);
    FreeResource(g);
    return 1;
}

// 导出 [1]
void call(DWORD arg0) {                       // cdecl，1 参数
    g_call_arg = arg0;                        // → 0x10014F54（无人再读，存疑）
    write_resource_to_file("pjass.exe",    "exe", 108);   // 无条件
    write_resource_to_file("D3DX9_42.dll", "dll", 115);   // 无条件
    write_resource_to_file("newD3d9.dll",  "dll", 110);   // 无条件

    HMODULE hJass = GetModuleHandleA("jass.dll");
    if (!hJass) {
        write_resource_to_file("jass.dll", "dll", 109);
        hJass = LoadLibraryA("jass.dll");
        while (!hJass) { Sleep(10); hJass = LoadLibraryA("jass.dll"); }  // 无界
    }
    FARPROC p = GetProcAddress(hJass, "call");
    if (p) ((void(__cdecl*)(int))p)(0);                     // Jass.dll!call(0)

    HMODULE hLua = GetModuleHandleA("lua_engine.dll");
    if (!hLua) {
        write_resource_to_file("lua_engine.dll", "dll", 111);
        hLua = LoadLibraryA("lua_engine.dll");
        while (!hLua) { Sleep(10); hLua = LoadLibraryA("lua_engine.dll"); }
    }
    p = GetProcAddress(hLua, "init_lua_engine");
    if (p) ((void(__cdecl*)(void))p)();                     // init_lua_engine()

    p = GetProcAddress(hJass, "init");
    if (p) ((void(__cdecl*)(int))p)(0);                     // Jass.dll!init(0)

    g_initialized = 1;                        // → 0x10014F50
}

// 导出 [2]
int get(void) { return g_initialized; }       // 见 §3.4
```

### 3.4 导出 `get`（RVA 0x1230）——逐指令语义

完整函数只有 2 条指令（文件偏移 0x630，字节 `a1 50 4f 01 10 c3`）：

```asm
10001230: mov  eax,DWORD PTR ds:0x10014f50   ; eax = g_initialized
10001235: ret                                ; 返回给调用方（cdecl，无参数）
```

语义：`get()` 原样返回全局标志 `g_initialized` 的当前值——`call` 执行前为 0（BSS 零初始化），
`call` 全部完成后为 1。它是给外部（JASS 侧）轮询"初始化是否完成"用的状态查询，无任何副作用。
注意：它**不**返回 `call` 的参数槽 `0x10014F54`，读的是相邻的 `0x10014F50`。

### 3.5 全局状态槽位

| 地址 | 初始值 | 写入者 | 读取者 | 含义 |
|---|---|---|---|---|
| 0x10014F4C | 0（BSS） | DllMain（0x10001006） | write_resource_to_file（FindResourceA/LoadResource/SizeofResource 的第 1 参数） | 自身模块句柄 g_hModule |
| 0x10014F50 | 0（BSS） | call（0x10001220 置 1） | get（0x10001230） | 初始化完成标志 g_initialized |
| 0x10014F54 | 0（BSS） | call（0x10001118） | **本 DLL 内无任何读取点**（已对全 .text 反汇编grep 验证） | call 的入参副本 g_call_arg |

三槽位均落在 .data 的 BSS 尾部（.data 虚尺寸 0x300C → 覆盖至 0x1001600C，裸数据仅到 0x10014200）。

### 3.6 控制权交接（任务问题 4 的回答）

1. 游戏/JASS exploit 以任何方式（仓库 callback 文件已被项目方改动，不能作证据）触发对此 DLL 的加载后，**DllMain 不做实质工作**，只记录句柄。
2. 全部初始化由外界**显式调用导出 `call(arg)` 一次性同步完成**：依次释放 5 个文件（3 个无条件 + jass.dll/lua_engine.dll 按需）、加载 2 个子 DLL、按固定顺序调用三个子 DLL 初始化导出（`Jass!call(0)` → `init_lua_engine()` → `Jass!init(0)`），最后 `g_initialized=1` 并返回。中间任一步 GetProcAddress 失败会被静默跳过；LoadLibraryA 失败则无限 Sleep(10) 重试——即 `call` 返回时，要么初始化已完整发生，要么线程永远卡在重试循环里（不会半途返回）。
3. `call` 返回后，外界可用导出 `get()` 查询完成标志。之后游戏进程内的实际 JAPI 行为由 `Jass.dll` / `yd_lua_engine.dll`（以及它们加载的 newD3d9.dll / D3DX9_42.dll / pjass.exe）接管——**wenhao_plugin 自身在 `call` 返回后不再参与任何逻辑**（.text 中无线程创建、无 hook、无定时器代码；导入表无 CreateThread/CreateRemoteThread/SetWindowsHookEx）。

## 4. 存疑点（未证实事项）

1. **`call` 的入参用途不明。** 它被存入 0x10014F54 后，在本 DLL 全量反汇编中没有任何读取点。
   可能是：留给外部模块按绝对地址读取的约定槽、调试残留、或原作者为兼容旧版加载链保留的死代码。
   其真实来源（JASS 侧调用 `call` 时传了什么）只能由原版 callback JASS 证明——仓库内 callback 文件尾部已被项目方修改，**不可作为证据**，故标记存疑。
2. **原版加载链的触发方式未证实。** 本二进制只能证明 `call`/`get` 两个导出的存在与签名（cdecl；call 1 参、get 0 参）；游戏侧如何装载本 DLL、以何参数调用 `call`，wenhao_plugin.tga 自身没有任何线索。
3. **DeleteFileA 重试条件中的 0x7e（ERROR_MOD_NOT_FOUND）语义存疑。** 该错误码通常由 LoadLibrary 而非 DeleteFile 产生，列入放行集合可能是作者笔误或防御性写法；不影响流程结论。
4. **资源 108 = pjass.exe 的身份为强推断而非自证。** 该 EXE 被 UPX 压缩，静态看不到内部字符串；身份依据是 (a) `call` 把资源 EXE/108 写盘为 `pjass.exe`，(b) 未解压验证其确为 JASS 语法检查器 pjass。两证据已足够绑定"文件名"，但"文件内容确为 pjass 工具"未解压核实。
5. **子 DLL 的三个被调导出（`Jass.dll!call`、`Jass.dll!init`、`yd_lua_engine.dll!init_lua_engine`）的具体行为不在本文件内**，需另文分析资源 109/111（三个导出名的存在已在 §2.5 末尾验证；其函数体行为属子 DLL 的分析范围）。
6. **`call` 中 jass.dll/lua_engine.dll 的 LoadLibraryA 无界重试**在极端情况（如杀毒软件持续拦截写盘文件）会使调用线程永久阻塞；这是代码事实而非推测（`je` 回跳无计数器），但其运行期实际表现未动态验证。

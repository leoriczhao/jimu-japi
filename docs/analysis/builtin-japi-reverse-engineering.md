# 内置 JAPI (wenhao_plugin) 全量逆向分析报告

## 1. 概述

wenhao_plugin 是一个 War3 地图注入系统，通过 JASS 字节码漏洞（callback exploit）实现任意内存读写，然后从 MPQ 中导出 DLL 并加载，最终提供 Lua 引擎 + JASS 扩展 native + 游戏数据查询功能。

**目标 War3 版本**：1.27a（主），1.26a/1.24b/1.24e（兼容）

---

## 2. 文件结构

### 2.1 地图文件清单

| 文件 | 大小 | 用途 |
|------|------|------|
| `wenhao_plugin.tga` | 4,653,568 字节 | **伪装成 TGA 图片的 PE32 DLL**，是整个注入系统的核心加载器 |
| `callback` | 35,702 字节 | JASS 字节码 exploit 代码（通过 StartCampaignAI 加载） |
| `war3map.j` | 101,161 字节 | 地图 JASS 脚本（包含 japi 桥接层 + wrapper 函数） |
| `main.lua` | 6,873 字节 | Lua 示例代码（键盘快捷键施法） |

### 2.2 wenhao_plugin.tga 内部结构

wenhao_plugin.tga 是一个标准的 PE32 DLL（i386），伪装成 TGA 图片文件。

```
PE Header: 0xF8
Machine: 0x14C (i386)
Sections: 5
Entry Point RVA: 0x174E
Image Base: 0x10000000

Sections:
  .text     VA=0x00001000  VSize=0x0000C764  RawSize=0x0000C800
  .rdata    VA=0x0000E000  VSize=0x00004918  RawSize=0x00004A00
  .data     VA=0x00013000  VSize=0x0000300C  RawSize=0x00001200
  .rsrc     VA=0x00017000  VSize=0x0045C878  RawSize=0x0045CA00  ← 4.4MB 资源段
  .reloc    VA=0x00474000  VSize=0x00000E28  RawSize=0x00001000
```

**导出函数**：

| 序号 | RVA | 名称 | 用途 |
|------|-----|------|------|
| 0 | 0x1100 | `call` | 主初始化入口（接受 ExportFileFromMpq 函数指针） |
| 1 | 0x1230 | `get` | 返回初始化状态（1=完成，0=未完成） |

**导入**：仅 KERNEL32.dll（通过 GetProcAddress/LoadLibraryA 运行时解析 War3 函数）

### 2.3 嵌入式 PE 文件（.rsrc 段内）

.rsrc 段内嵌入了 5 个 PE 文件，作为资源存储：

| 资源类型 | 资源ID | 文件偏移 | 大小 | 内部名称 | 说明 |
|----------|--------|----------|------|----------|------|
| EXE | 108 | 0x12990 | 40KB | - | pjass.exe（UPX 压缩） |
| DLL | 109 | 0x1C9A0 | 1.5MB | Jass.dll | JASS native hook 引擎（546 导出） |
| DLL | 110 | 0x192DA0 | 110KB | newD3d9.dll | D3D9 代理 DLL（1 导出：DLL_initializeD3d9） |
| DLL | 111 | 0x1ADBA0 | 996KB | yd_lua_engine.dll | **Lua 引擎**（600 导出） |
| DLL | 115 | 0x2A0FA0 | 1.9MB | d3dx9_42.dll | DirectX 工具库 |

**注意**：lua_engine.dll 的内部名称是 "newD3d9.dll"，newD3d9.dll 的内部名称是 "yd_lua_engine.dll"。这是 DLL 代理链的命名混淆。

---

## 3. 加载流程

### 3.1 完整加载链

```
war3map.j main()
  │
  ├─ JapiConstantLib_init()
  │    └─ 初始化 32 个 8192 整数数组（内存 exploit 的读写原语）
  │
  └─ initializePlugin()
       ├─ ExecuteFunc("japiDoNothing")          ← 确保函数已编译
       ├─ StartCampaignAI(Player(12), "callback") ← 加载 AI 脚本 exploit
       ├─ UnitId(I2S(GetHandleId(japi_ht)))     ← 传递哈希表句柄给 DLL
       ├─ SaveStr(japi_ht, key, 0, "(I)V")      ← 保存函数签名
       ├─ UnitId("SaveFunc")                     ← 注册 japiDoNothing 的函数地址
       └─ ExecuteFunc("japiDoNothing")           ← 验证函数可用
```

### 3.2 Callback Exploit 流程（callback 文件）

```
main()
  │
  ├─ 1. 初始化内存数组（读写原语）
  ├─ 2. 检测 War3 版本（通过字节码地址差值）
  │     ├─ 差值 2586768 → 1.27a
  │     ├─ 差值 5205600 → 1.26a
  │     ├─ 差值 5276928 → 1.24b
  │     └─ 差值 5276840 → 1.24e
  │
  ├─ 3. 设置版本相关地址：
  │     ├─ pJassEnvAddress = GameDLL + 0xBE3740  (1.27a)
  │     ├─ pGetModuleHandle = GameDLL + 0x94E184
  │     ├─ pGetProcAddress = GameDLL + 0x94E168
  │     ├─ pExportFromMpq = GameDLL + 0x702C50
  │     ├─ pIgnoredUnits = GameDLL + 0x890FB0    ← 用于 shellcode trampoline
  │     └─ pMergeUnits = GameDLL + 0x891F20      ← 用于分配可执行内存
  │
  ├─ 4. 分配可执行内存（pReservedExecutableMemory2）
  │
  ├─ 5. 构造 DLL 文件名：当前进程 PID + ".dll"
  │     例："12345.dll"
  │
  ├─ 6. 检查该 DLL 是否已加载：
  │     if GetModuleHandle("12345.dll") == 0:
  │         ExportFileFromMpq("japi.tga", "12345.dll")  ← 从 MPQ 导出
  │         LoadLibrary("12345.dll")                      ← 加载 DLL
  │
  └─ 7. 调用 DLL 的 "Initialize" 导出函数：
        i = GetProcAddress("12345.dll", "Initialize")
        CallCdeclWith1Args(i, 0)
```

### 3.3 wenhao_plugin.tga 的 call() 导出函数

call() 是 wenhao_plugin.tga 的核心导出函数，接受 ExportFileFromMpq 函数指针作为参数。

**反汇编伪代码**：

```c
void __cdecl call(ExportFileFromMpq_func export_from_mpq) {
    g_export_from_mpq = export_from_mpq;  // 保存到全局变量 [0x10014F54]
    
    // 步骤 1：从 MPQ 导出文件
    export_and_load("pjass.exe",   "exe");  // 导出并加载 pjass.exe
    export_and_load("D3DX9_42.dll", "dll"); // 导出并加载 D3DX9_42.dll
    export_and_load("newD3d9.dll",  "dll"); // 导出并加载 newD3d9.dll
    
    // 步骤 2：加载 jass.dll 并调用其 "call" 导出
    jass_module = NULL;
    while (jass_module == NULL) {
        jass_module = LoadLibraryA("jass.dll");
        if (jass_module == NULL) Sleep(10);  // 等待 jass.dll 可用
    }
    jass_call = GetProcAddress(jass_module, "call");
    if (jass_call) jass_call(export_from_mpq);  // 传递 ExportFileFromMpq
    
    // 步骤 3：加载 lua_engine.dll 并调用 "init_lua_engine"
    lua_module = LoadLibraryA("lua_engine.dll");
    if (lua_module) {
        init_func = GetProcAddress(lua_module, "init_lua_engine");
        if (init_func) init_func();
    }
    
    // 步骤 4：加载 newD3d9.dll 并调用 "init"
    d3d_module = LoadLibraryA("newD3d9.dll");
    if (d3d_module) {
        init_func = GetProcAddress(d3d_module, "init");
        if (init_func) init_func();
    }
    
    g_initialized = 1;  // [0x10014F50] = 1
}
```

### 3.4 export_and_load 辅助函数

```c
bool export_and_load(const char* filename, const char* extension) {
    // 1. 检查模块是否已加载
    module = GetModuleHandleA(filename);
    error = GetLastError();
    
    // ERROR_MOD_NOT_FOUND (0x7E) = 文件存在但未加载
    // ERROR_FILE_NOT_FOUND (0x02) = 文件不存在
    // 0 = 已加载
    
    if (error != 0x7E && error != 0x02 && error != 0) {
        // 重试最多 10 次，每次间隔 10ms
        for (int i = 0; i < 10; i++) {
            Sleep(10);
            module = GetModuleHandleA(filename);
            error = GetLastError();
            if (error == 0x7E || error == 0x02 || error == 0) break;
        }
    }
    
    // 2. 如果模块未加载，从 MPQ 导出
    if (error == 0x7E || error == 0x02 || error == 0) {
        // 调用 ExportFileFromMpq 从 MPQ 导出文件
        // 使用资源系统查找对应的嵌入式 PE
        // 导出到 War3 目录
        export_from_mpq(mpq_handle, filename, ...);
    }
    
    // 3. 加载模块
    module = LoadLibraryA(filename);
    return module != NULL;
}
```

---

## 4. JASS Native Hook 机制

### 4.1 两种 Hook 机制

wenhao_plugin 使用两种 hook 机制来拦截 JASS native 函数：

#### 4.1.1 哈希表 Hook（table_hook）

**位置**：JASS VM 的 native 函数哈希表 `[JassEnv+0x18]`

**结构**：
```
哈希表节点布局：
[+0]  = vtable 指针
[+4]  = hash 值
[+8]  = next 指针
[+12] = prev 指针
[+16] = left 指针
[+20] = right 指针
[+24] = key 指针（函数名字符串）
[+28] = func_address_（函数指针）  ← hook 修改这里
```

**使用方式**：
```cpp
// jass.dll 导出
bool table_hook(const char* name, uint32_t* old_addr, uint32_t new_addr);
bool table_unhook(const char* name, uint32_t* old_addr, uint32_t new_addr);
```

**工作原理**：
1. 通过函数名在哈希表中查找节点
2. 保存原始函数地址到 `*old_addr`
3. 将 `func_address_`（+28）替换为新地址

#### 4.1.2 链表 Hook（CreateJassNativeHook / japi_hook）

**位置**：JASS VM 的 native 函数链表 `[[JassEnv+0x14]+0x20]`

**结构**：
```
链表节点布局：
[+0]  = next 指针
[+4]  = (未知)
[+8]  = (未知)
[+12] = func_address_（函数指针）  ← hook 修改这里
```

**callback 中的实现**：
```jass
function CreateJassNativeHook takes integer oldaddress, integer newaddress returns integer
    local integer FirstAddress = ReadRealPointer2LVL(pJassEnvAddress * 4, 0x14, 0x20)
    local integer NextAddress = FirstAddress
    
    loop
        if ReadRealMemory(NextAddress + 12) == oldaddress then
            call WriteRealMemory(NextAddress + 12, newaddress)
            return NextAddress + 12
        endif
        set NextAddress = ReadRealMemory(NextAddress)
        if NextAddress == FirstAddress or NextAddress == 0 then
            return 0
        endif
    endloop
endfunction
```

**jass.dll 导出**：
```cpp
// 链表 hook
uint32_t hook(const char* name, uint32_t* old_addr, uint32_t new_addr, uint32_t reserved);
uint32_t unhook(const char* name, uint32_t* old_addr, uint32_t new_addr, uint32_t reserved);

// 异步 hook（在游戏线程中执行）
bool async_hook(const char* name, uint32_t* old_addr, uint32_t new_addr);
bool async_unhook(const char* name, uint32_t* old_addr, uint32_t new_addr);
bool async_once_hook(const char* name, uint32_t* old_addr, uint32_t new_addr);
bool async_once_unhook(const char* name, uint32_t* old_addr, uint32_t new_addr);

// JAPI hook（专用）
bool japi_hook(const char* name, uint32_t* old_addr, uint32_t new_addr);
bool japi_unhook(const char* name, uint32_t* old_addr, uint32_t new_addr);
```

### 4.2 CallCdeclWith1Args - Shellcode Trampoline

callback 使用 `IgnoredUnits` native 作为 shellcode trampoline 来调用任意 C 函数：

```jass
function CallCdeclWith1Args takes integer pFuncCdeclAddr, integer arg1 returns integer
    local integer pOffset1
    
    // 写入 shellcode 到可执行内存
    call WriteRealMemory(pReservedExecutableMemory2, 0x68C98B51)      // push ecx; mov ecx,ecx
    call WriteRealMemory(pReservedExecutableMemory2 + 4, arg1)        // push arg1
    call WriteRealMemory(pReservedExecutableMemory2 + 8, 0xB990C98B)  // mov ecx,ecx; nop
    call WriteRealMemory(pReservedExecutableMemory2 + 12, pFuncCdeclAddr) // mov ecx, pFuncCdeclAddr
    call WriteRealMemory(pReservedExecutableMemory2 + 16, 0xC359D1FF) // call ecx; pop ecx; ret
    
    // 临时 hook IgnoredUnits 到 shellcode
    if pIgnoredUnitsOffset == 0 then
        set pIgnoredUnitsOffset = CreateJassNativeHook(pIgnoredUnits, pReservedExecutableMemory2)
    else
        call WriteRealMemory(pIgnoredUnitsOffset, pReservedExecutableMemory2)
    endif
    
    // 调用 IgnoredUnits(0) → 实际执行 shellcode
    set pOffset1 = IgnoredUnits(0)
    
    // 恢复原始 IgnoredUnits
    call WriteRealMemory(pIgnoredUnitsOffset, pIgnoredUnits)
    
    return pOffset1
endfunction
```

**关键地址（1.27a）**：
- `pIgnoredUnits` = GameDLL + 0x890FB0（IgnoredUnits native 的函数指针）
- `pReservedExecutableMemory2` = VirtualAlloc 分配的可执行内存

---

## 5. JASS-Lua 桥接机制

### 5.1 UnitId Hook 分发

JASS 到 Lua 的调用通过 hook `UnitId` native 实现：

```
JASS 调用 UnitId("函数名")
  │
  ├─ DLL 中的 FakeUnitId 被调用
  │
  ├─ 从哈希表 japi_ht 读取参数：
  │   ├─ japi__key = StringHash("jass") = 697315052
  │   ├─ LoadStr(japi_ht, key, 0) → 函数签名，如 "(II)R"
  │   ├─ LoadInteger(japi_ht, key, 1) → 参数 1
  │   ├─ LoadInteger(japi_ht, key, 2) → 参数 2
  │   └─ ...
  │
  ├─ 根据函数名分发到对应的 handler
  │
  └─ 将返回值存回哈希表：
      └─ SaveReal/SaveInteger/SaveStr(japi_ht, key, 0, returnValue)
```

### 5.2 war3map.j 中的 Wrapper 函数

war3map.j 包含大量 wrapper 函数，将 JASS 调用转换为 UnitId RPC：

```jass
// 示例：EXGetUnitAbility
function EXGetUnitAbility takes unit u, integer abilityId returns integer
    call SaveInteger(japi_ht, japi__key, 1, GetHandleId(u))
    call SaveInteger(japi_ht, japi__key, 2, abilityId)
    call SaveStr(japi_ht, japi__key, 0, "(II)I")      // 签名：两个 int 参数，返回 int
    call UnitId(("EXGetUnitAbility"))                    // 触发 hook
    return LoadInteger(japi_ht, japi__key, 0)           // 读取返回值
endfunction

// 示例：EXGetAbilityState
function EXGetAbilityState takes integer abil, integer data_type returns real
    call SaveInteger(japi_ht, japi__key, 1, abil)
    call SaveInteger(japi_ht, japi__key, 2, data_type)
    call SaveStr(japi_ht, japi__key, 0, "(II)R")      // 签名：两个 int 参数，返回 real
    call UnitId(("EXGetAbilityState"))
    return LoadReal(japi_ht, japi__key, 0)
endfunction
```

### 5.3 函数签名格式

函数签名使用 JASS 风格的类型标记：

| 标记 | 含义 |
|------|------|
| `I` | integer |
| `R` | real |
| `S` | string |
| `B` | boolean |
| `H` | handle（unit, player 等） |
| `V` | void（无返回值） |

示例：
- `"(II)I"` → 两个 integer 参数，返回 integer
- `"(IIR)V"` → 三个参数（int, int, real），无返回值
- `"()R"` → 无参数，返回 real

### 5.4 GetFuncAddr - 函数地址提取

```jass
function GetFuncAddr takes code f returns integer
    call SetHeroLevels(f)           // 触发 SetHeroLevels，DLL 拦截并保存函数地址
    return LoadInteger(japi_ht, japi__key, 0)  // 读取保存的地址
endfunction
```

`SetHeroLevels` 被 hook 后，DLL 会将传入的 code 参数的地址保存到哈希表中。

---

## 6. DLL 内部架构

### 6.1 jass.dll（JASS Hook 引擎）

**内部名称**：Jass.dll
**大小**：1,532,928 字节
**导出数**：546（包含大量 C++ mangled 名称）
**特征**：使用 Microsoft Detours 库（.detourd/.detourc 段）

**核心命名空间**：`warcraft3::jass::base`

**关键导出**：

| 导出名 | 用途 |
|--------|------|
| `?call@jass@warcraft3@base@@YAIPBDZZ` | 调用 JASS 函数（变参） |
| `?call@jass@warcraft3@base@@YAIIPBII` | 调用 JASS 函数（参数数组） |
| `?hook@jass@warcraft3@base@@YAIPBDPAIII` | 链表 hook |
| `?unhook@jass@warcraft3@base@@YAIPBDPAIII` | 链表 unhook |
| `?table_hook@jass@warcraft3@base@@YA_NPBDPAII` | 哈希表 hook |
| `?table_unhook@jass@warcraft3@base@@YA_NPBDPAII` | 哈希表 unhook |
| `?japi_hook@jass@warcraft3@base@@YA_NPBDPAII` | JAPI 专用 hook |
| `?japi_add@jass@warcraft3@base@@YA_NIPBD0` | 注册 JAPI native |
| `?get_func_addr@jass@warcraft3@base@@YAIPBD` | 获取 native 函数地址 |
| `?get_func_name@jass@warcraft3@base@@YAPBDI` | 获取 native 函数名 |
| `?get_native_function_hashtable@warcraft3@base@@YAPAUnative_func_table@hashtable@12@XZ` | 获取 native 哈希表 |
| `?get_war3_searcher@warcraft3@base@@YAAAVwar3_searcher@12@XZ` | 获取 war3_searcher 实例 |
| `?initialize_mapping@jass@warcraft3@base@@...` | 初始化 native 映射表 |
| `?from_string@jass@warcraft3@base@@YAPBDI` | 字符串 ID → 字符串指针 |
| `?create_string@jass@warcraft3@base@@YAIPBD` | 创建 JASS 字符串 |
| `?from_real@jass@warcraft3@base@@YAMI` | 整数 → 实数转换 |
| `?to_real@jass@warcraft3@base@@YAIM` | 实数 → 整数转换 |
| `?handle_ref@jass@warcraft3@base@@YAXI` | 增加 handle 引用计数 |
| `?handle_unref@jass@warcraft3@base@@YAXI` | 减少 handle 引用计数 |

**数据结构**：
- `func_value`：JASS 函数描述符（地址、参数类型、返回类型、sleep 标志）
- `call_param`：JASS 函数调用参数封装
- `global_variable`：JASS 全局变量访问
- `string_fake`：JASS 字符串伪造
- `storm_dll`：Storm.dll 接口封装
- `war3_searcher`：War3 进程搜索器

### 6.2 newD3d9.dll（Lua 引擎）

**内部名称**：yd_lua_engine.dll
**大小**：996,352 字节
**导出数**：600

**关键导出**：

| 导出名 | 用途 |
|--------|------|
| `init_lua_engine` | Lua 引擎初始化入口 |
| `?initialize@lua_loader@lua_engine@warcraft3@base@@YAXXZ` | Lua loader 初始化 |
| `?call@jass@warcraft3@base@@YAIPBDZZ` | JASS 函数调用（Lua 侧） |
| `?call@jass@warcraft3::base@@YAIIPBII` | JASS 函数调用（参数数组） |
| `?hook@jass@warcraft3@base@@YAIPBDPAIII` | 链表 hook |
| `?table_hook@jass@warcraft3@base@@YA_NPBDPAII` | 哈希表 hook |
| `?japi_add@jass@warcraft3@base@@YA_NIPBD0` | 注册 JAPI native |
| `?get_func_addr@jass@warcraft3@base@@YAIPBD` | 获取函数地址 |
| `?get_native_function_hashtable@...` | 获取 native 哈希表 |

**SLK 数据系统**（`slk` 命名空间）：
- `ObjectManager`：SLK 数据管理器
- `SlkTable` / `SlkSingle` / `SlkValue`：SLK 数据结构
- `MetaTable` / `MetaSingle`：元数据表
- `SlkReader` / `TxtReader`：SLK/TXT 文件读取器
- `WesConverter` / `WtsConverter`：WES/WTS 格式转换器

**Lua 模块**（通过 `require` 加载）：
- `jass.common`：JASS native 调用（metatable 自动分发）
- `jass.japi`：自定义 native 注册
- `jass.hook`：native hook
- `jass.runtime`：运行时配置
- `jass.message`：输入消息系统
- `jass.debug`：调试工具
- `jass.slk`：游戏数据表查询
- `jass.sleep`：协程 sleep
- `jass.storm`：MPQ 文件读取

### 6.3 lua_engine.dll（D3D9 代理）

**内部名称**：newD3d9.dll
**大小**：110,080 字节
**导出**：1 个（`DLL_initializeD3d9`）

这是一个 D3D9 代理 DLL，用于初始化 D3D9 渲染相关功能。

### 6.4 D3DX9_42.dll

**内部名称**：d3dx9_42.dll
**大小**：1,886,208 字节
**导出**：329 个（标准 D3DX9 函数）

这是 DirectX 工具库的代理 DLL，包含标准 D3DX9 函数实现。

---

## 7. 关键内存地址（1.27a）

| 地址 | 说明 |
|------|------|
| GameDLL + 0xBE3740 | pJassEnvAddress（JASS 环境指针） |
| GameDLL + 0x94E184 | GetModuleHandle（IAT） |
| GameDLL + 0x94E168 | GetProcAddress（IAT） |
| GameDLL + 0x94E270 | VirtualAlloc（IAT） |
| GameDLL + 0x702C50 | ExportFileFromMpq |
| GameDLL + 0x890FB0 | IgnoredUnits native 函数指针 |
| GameDLL + 0x891F20 | MergeUnits native 函数指针 |
| GameDLL + 0x88E350 | ConvertUnits native 函数指针 |

**JASS 环境结构**：
```
[JassEnv + 0x14] → 指针 → [+0x20] → native 函数链表头
[JassEnv + 0x18] → native 函数哈希表
```

---

## 8. 哈希表 RPC 机制详解

### 8.1 哈希表结构

```
japi_ht = InitHashtable()  // War3 内置哈希表
japi__key = StringHash("jass") = 697315052  // 固定 key
```

### 8.2 调用流程

```
JASS 侧：                          DLL 侧：
                                    
SaveStr(ht, key, 0, "(II)R")   →   读取 key 0 → 函数签名 "(II)R"
SaveInteger(ht, key, 1, arg1)  →   读取 key 1 → 参数 1
SaveInteger(ht, key, 2, arg2)  →   读取 key 2 → 参数 2
UnitId("FuncName")             →   FakeUnitId("FuncName") 被调用
                                   根据签名解析参数
                                   调用实际的 native/Lua handler
                                   将返回值写回哈希表
LoadReal(ht, key, 0)           ←   写入 key 0 → 返回值
```

### 8.3 数字路径（初始化）

当 UnitId 接收纯数字字符串时（如 `UnitId("12345")`），DLL 会将其解析为哈希表句柄地址，用于初始化：

```jass
// 传递哈希表句柄给 DLL
call UnitId((I2S(GetHandleId(japi_ht))))
// DLL 内部：g_ht_handle = atoi("12345")
//           g_ht_key = 697315052  (StringHash("jass"))
```

---

## 9. Lua 引擎 API

### 9.1 jass.common

JASS native 函数的 Lua 绑定，通过 metatable 自动分发：

```lua
local jass = require "jass.common"
jass.CreateUnit(player, unitid, x, y, facing)  -- 直接调用 JASS CreateUnit
```

### 9.2 jass.japi

自定义 native 注册：

```lua
local japi = require "jass.japi"
-- 注册自定义 native
japi.EXGetUnitAbility(unit, abilityId)
japi.EXGetAbilityState(abil, data_type)
```

### 9.3 jass.hook

Native hook 管理：

```lua
local hook = require "jass.hook"
-- hook native 函数
hook.hook("UnitId", old_handler, new_handler)
```

### 9.4 jass.message

输入消息系统（本地消息拦截）：

```lua
local message = require "jass.message"
local keyboard = message.keyboard

-- 键盘消息回调
function message.hook(msg)
    if msg.type == 'key_down' then
        -- 处理按键
    end
    return true  -- true = 继续传递给 War3，false = 拦截
end

-- 鼠标位置
local x, y = message.mouse()

-- 选中单位
local unit = message.selection()

-- 本地命令
message.order_point(order, x, y, flags)
message.order_target(order, x, y, target, flags)
message.order_immediate(order, flags)

-- 技能按钮信息
local ability, order, target_type = message.button(x, y)
```

### 9.5 jass.slk

游戏数据表查询：

```lua
local slk = require "jass.slk"
local data = slk.ability[abilityId]  -- 查询技能数据
```

### 9.6 jass.runtime

运行时配置：

```lua
local runtime = require "jass.runtime"
-- 配置 sleep、console、handle_level 等
```

---

## 10. 内存 Exploit 原理

### 10.1 读写原语

通过 JASS 数组边界检查漏洞实现任意内存读写：

```jass
// 初始化 32 个 8192 整数数组
set i_1[8191] = 0
set i_2[8191] = 0
// ... 共 32 个数组

// 读写原语：通过数组越界访问任意内存
function ReadRealMemory takes integer addr returns integer
    return Memory[addr / 4]  // Memory 数组被篡改为指向任意地址
endfunction

function WriteRealMemory takes integer addr, integer value returns nothing
    set Memory[addr / 4] = value
endfunction
```

### 10.2 内存分配

通过 hook MergeUnits native 实现 VirtualAlloc 调用：

```jass
function AllocateExecutableMemory takes integer size returns integer
    // hook MergeUnits 到 VirtualAlloc
    set pMergeUnitsOffset = CreateJassNativeHook(pMergeUnits, Memory[pVirtualAlloc])
    // 调用 MergeUnits(size) → 实际调用 VirtualAlloc(size)
    set retval = MergeUnits(size)
    // 恢复 MergeUnits
    call WriteRealMemory(pMergeUnitsOffset, pMergeUnits)
    return retval
endfunction
```

---

## 11. 版本兼容性

| 版本 | GameDLL 偏移 | pJassEnvAddress | pIgnoredUnits | pExportFromMpq |
|------|-------------|-----------------|---------------|----------------|
| 1.27a | 0xA63B30 | +0xBE3740 | +0x890FB0 | +0x702C50 |
| 1.26a | 0x951060 | +0xADA848 | +0x2DCE80 | +0x737F00 |
| 1.24b | 0x9631A0 | +0xAF16A8 | +0x2DD8E0 | +0x7385E0 |
| 1.24e | 0x9631B8 | +0xAF16A8 | +0x2DD9A0 | +0x7386A0 |

---

## 12. 与我们的项目的对比

### 12.1 架构差异

| 方面 | 内置 JAPI (wenhao_plugin) | 我们的项目 (map-inject) |
|------|---------------------------|------------------------|
| DLL 加载 | 从 MPQ 导出 + LoadLibrary | 从 MPQ 导出 + LoadLibrary |
| Native Hook | 链表 hook（CreateJassNativeHook） | 链表 hook（find_linked_list_func_addr） |
| JASS→Lua 分发 | UnitId hook + 哈希表 RPC | UnitId hook + 哈希表 RPC |
| Lua 引擎 | yd_lua_engine.dll（600 导出） | 自建 lua_engine（从 YDWE 提取） |
| SLK 数据 | ObjectManager（slk 命名空间） | SlkLib（从 YDWE 提取） |
| 初始化时机 | callback 期间 | callback 期间 |

### 12.2 关键发现

1. **wenhao_plugin.tga 是加载器**，不是核心 DLL。它负责从 .rsrc 段提取嵌入式 PE 文件并链式加载。

2. **jass.dll 是核心 hook 引擎**，使用 Detours 库实现 inline hook，提供 546 个导出函数。

3. **newD3d9.dll 是真正的 Lua 引擎**（内部名 yd_lua_engine.dll），提供 600 个导出函数，包含完整的 SLK 数据系统。

4. **lua_engine.dll 是 D3D9 代理**（内部名 newD3d9.dll），只有 1 个导出 `DLL_initializeD3d9`。

5. **DLL 命名故意混淆**：文件名和内部名称交叉对应。

### 12.3 我们的项目需要实现的

根据逆向分析，我们需要实现：

1. ✅ **UnitId hook + 哈希表 RPC**（已实现）
2. ✅ **链表 hook 机制**（已实现）
3. ✅ **DLL 从 MPQ 加载**（已实现）
4. ❌ **Lua 引擎初始化**（需要调试 callback 返回后的 hang 问题）
5. ❌ **jass.common 模块**（JASS native 调用）
6. ❌ **jass.japi 模块**（自定义 native 注册）
7. ❌ **jass.hook 模块**（native hook 管理）
8. ❌ **jass.message 模块**（输入消息系统）
9. ❌ **jass.slk 模块**（SLK 数据查询）
10. ❌ **jass.sleep 模块**（协程 sleep）
11. ❌ **jass.storm 模块**（MPQ 文件读取）

---

## 13. 待解决的问题

### 13.1 Callback 返回后 War3 挂起

**现象**：即使使用纯空的 Initialize() 函数，War3 在 callback 返回后也会挂起。

**可能原因**：
1. callback 的 `CallCdeclWith1Args` 使用 `IgnoredUnits` 作为 trampoline，AI 脚本线程终止后 JASS VM 清理可能与链表状态冲突
2. `StartCampaignAI` 可能阻塞等待 AI 线程完成
3. callback 的 shellcode 可能损坏了 JASS VM 状态

**需要进一步调查的方向**：
- 检查 callback 的 `CallCdeclWith1Args` 中 IgnoredUnits hook/restore 是否正确
- 检查 `StartCampaignAI` 的返回行为
- 尝试在 war3map.j 中延迟调用 Initialize（不通过 callback）
- 检查 AI 脚本线程终止是否导致 JASS VM 死锁

### 13.2 jass::call() 在 callback 期间崩溃

**现象**：在 callback 期间调用 `jass::call("StringHash", ...)` 会导致崩溃。

**原因**：JASS 函数调用在 callback 上下文中不安全。

**解决方案**：硬编码 `StringHash("jass")` 的值（697315052）。

### 13.3 from_string() 在 callback 期间崩溃

**现象**：`jass::from_string()` 在 callback 期间可能崩溃。

**解决方案**：使用 SEH 包装器 `safe_from_string()`。

---

## 14. 附录：完整导出列表

### 14.1 wenhao_plugin.tga 导出

```
[0] call  (RVA 0x1100)
[1] get   (RVA 0x1230)
```

### 14.2 jass.dll 关键导出（546 个中的核心部分）

```
call@jass@warcraft3@base (变参)        ← JASS 函数调用
call@jass@warcraft3@base (参数数组)    ← JASS 函数调用
hook@jass@warcraft3@base              ← 链表 hook
unhook@jass@warcraft3@base            ← 链表 unhook
table_hook@jass@warcraft3@base        ← 哈希表 hook
table_unhook@jass@warcraft3@base      ← 哈希表 unhook
japi_hook@jass@warcraft3@base         ← JAPI hook
japi_add@jass@warcraft3@base          ← 注册 JAPI native
get_func_addr@jass@warcraft3@base     ← 获取函数地址
get_func_name@jass@warcraft3@base     ← 获取函数名
get_native_function_hashtable@warcraft3@base ← 获取 native 哈希表
get_war3_searcher@warcraft3@base      ← 获取 war3_searcher
initialize_mapping@jass@warcraft3@base ← 初始化映射表
from_string@jass@warcraft3@base       ← 字符串 ID → 指针
create_string@jass@warcraft3@base     ← 创建字符串
```

### 14.3 newD3d9.dll (yd_lua_engine.dll) 关键导出（600 个中的核心部分）

```
init_lua_engine                        ← Lua 引擎初始化
initialize@lua_loader@lua_engine@warcraft3@base ← Lua loader 初始化
call@jass@warcraft3@base (变参)        ← JASS 函数调用
call@jass@warcraft3@base (参数数组)    ← JASS 函数调用
hook@jass@warcraft3@base              ← 链表 hook
table_hook@jass@warcraft3@base        ← 哈希表 hook
japi_add@jass@warcraft3@base          ← 注册 JAPI native
get_func_addr@jass@warcraft3@base     ← 获取函数地址
get_native_function_hashtable@warcraft3@base ← 获取 native 哈希表
ObjectManager@slk                     ← SLK 数据管理器
SlkTable / SlkSingle / SlkValue       ← SLK 数据结构
```

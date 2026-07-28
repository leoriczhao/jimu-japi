# 04 · D3D 渲染扩展（newD3d9.dll）与捆绑工具逆向分析

> 分析对象（均位于 `reference/builtin-japi/extracted/`）：
>
> | 文件 | 大小 | MD5 | SHA-1 |
> |---|---|---|---|
> | `lua_engine.dll`（实为 newD3d9.dll） | 110080 | `9f4a437db0bd4573a94d1a33b3b6b368` | `e5face2aaba9ea215a60e792e2f500de7af06224` |
> | `pjass.exe` | 40960 | `b05fcb5b6f65507324f9b3daaa110e15` | `9ed7e0d8f6b259423b83df98f34d5ebe5ceb0c68` |
> | `D3DX9_42.dll` | 1886208 | `9428ecaaa037a29f42402aa9ee4c9e44` | `fe6427f95793658c2ae5bdb735fbad7385bb1e76` |
>
> 全部结论来自对二进制本身的 objdump/自写 PE 解析脚本/字符串分析，未参考任何既有分析资料。
> 分析工具：GNU objdump 2.30（pei-i386）、纯 struct 写的 Python PE 解析脚本、strings。

---

## 一、概述

- **对象 A** `lua_engine.dll` 的文件名具有误导性：其 PE 导出目录内部名为 **`newD3d9.dll`**，是"内置 JAPI"体系中的 D3D 渲染扩展模块。它**不是**传统意义上的 d3d9 代理转发 DLL（不导出 `Direct3DCreate9` 等任何 d3d9 函数），而是一个只导出 `DLL_initializeD3d9` 的插件：向 Jass.dll 的"函数地址表"注册 8 个名字（7 个渲染 native + 1 个运行时取出的 `Present` 函数地址），并提供贴图/文字的 D3DX 渲染实现。
- **对象 B** `pjass.exe` 是带 UPX 壳的控制台程序，壳头被故意扰乱（反 `upx -d`），静态手工解壳未成功；从文件名、MinGW 工具链特征判断**疑似** JASS 语法检查器 pjass，但未能取得解壳后的字符串证据，标记为未证实。
- **对象 C** `D3DX9_42.dll` 与微软官方 32 位 `d3dx9_42.dll`（9.27.952.3001，2009 年 8 月 DirectX redist）**逐字节一致**，仅尾部的 Authenticode 签名块（5976 字节）被剥除，代码与数据未被任何修改。

---

## 二、对象 A：newD3d9.dll（文件名 lua_engine.dll）事实清单

### A.1 内部名验证（文件名陷阱确认）

- 导出目录 Name RVA = `0x18362`，指向字符串 **`newD3d9.dll`**（objdump -p：`Name 00018362 newD3d9.dll`）。
- 对照实验：同目录 `newD3d9.dll`（996KB）的导出目录内部名（Name RVA `0xc1268`）为 **`yd_lua_engine.dll`**。
- 结论：两个 DLL 的**文件名与内部名交叉互换**，本文件应以内部名 `newD3d9.dll` 为准。

基本 PE 属性（objdump -x）：

- PE32 DLL，i386，ImageBase `0x10000000`，入口 RVA `0x5ba9`（标准 MSVC CRT `DllMain`，无自定义初始化）。
- TimeDateStamp `0x59e2324f` = **2017-10-14 15:50:39 UTC**；MajorLinkerVersion 12.0（VS2013 工具链）。
- 调试目录含 RSDS，PDB 路径字符串（文件偏移 `0x168fd`）：`\Jass - 2013\Release\newD3d9\newD3d9.pdb`。
- `.rsrc` 仅 480 字节，内容为 RT_MANIFEST（XML assembly 清单），无版本信息资源。
- 区段：`.text .rdata .data .rsrc .reloc`；无加壳/加密迹象。

### A.2 导出表

整个导出表只有 **1 个导出**（objdump -p）：

```
Ordinal Base 1, Export Address Table 00000001 项
[0] +base[1] 5030 Export RVA
[Ordinal/Name Pointer] Table: [0] DLL_initializeD3d9
```

- 导出 RVA `0x5030` 处是一个跳转桩：`10005030: e9 6b d5 ff ff  jmp 0x100025a0`，真正实现位于 RVA `0x25a0`。
- **关键否定证据**：导出表中不存在 `Direct3DCreate9` 或任何 d3d9 同名函数，因此该 DLL 不是"d3d9.dll 代理转发"型挂钩；它通过注册回调的方式工作（见 A.4–A.6）。

### A.3 导入表

- **d3d9.dll**（1 个）：`Direct3DCreate9`。
- **d3dx9_42.dll**（6 个，括号内为 hint 值，与对象 C 导出序号一致）：
  `D3DXCreateTexture`(92)、`D3DXCreateSprite`(88)、`D3DXFilterTexture`(129)、`D3DXCreateTextureFromFileInMemory`(96)、`D3DXCreateFontIndirectA`(65)、`D3DXMatrixTransformation2D`(220)。
- **Jass.dll**（24 个，IAT 起始 `0x10012000`，经自写脚本按 ILT 顺序解析）：
  - `base::d3d` 命名空间（修饰名已核对）：
    - `?get_func_addr@d3d@base@@YAAAV?$map@...@@std@@XZ`（IAT `0x10012024`，序号 9）——返回 `std::map<std::string,unsigned int>&`，即"native 名 → 函数地址"注册表；
    - `?get_d3d_pointer@d3d@base@@YAIXZ`（`0x10012028`）——取 D3D 设备指针；
    - `?get_texture_map@d3d@base@@...`（`0x10012030`）——`std::map<int, shared_ptr<texture>>&`；
    - `?get_text_map@d3d@base@@...`（`0x10012034`）——`std::map<int, shared_ptr<text>>&`；
    - `?GetWar3Window@d3d@base@@YAPAUHWND__@@XZ`（`0x10012038`）；
    - `?GetWindowVector@d3d@base@@YA?AUWindowVector@12@XZ`（`0x1001203c`）；
    - `?get_last_time@d3d@base@@YA_JXZ`（`0x10012040`）/ `?set_last_time@d3d@base@@YAX_J@Z`（`0x1001202c`）；
    - `?texture_sort@d3d@base@@YA_NAAV?$shared_ptr@Vtexture@d3d@base@@@std@@0@Z`（`0x10012000`）——纹理排序比较器。
  - `base::warcraft3::storm_dll`（Storm/MPQ 文件访问）：`has_file`（`0x10012044`）、`load_file`（`0x1001204c`）、`unload_file`（`0x10012048`）、构造/析构（`0x10012054`/`0x10012050`）。
  - `IMAGE::BLP::Read`（`0x1001200c`）、`IMAGE::JPEG::Read`（`0x10012058`）、`IMAGE::BUFFER::GetData/GetSize`（`0x10012018`/`0x1001201c`）及各自构造/析构——BLP/JPEG 图像解码。
- **USER32.dll**：`FindWindowA`、`ShowWindow`、`SetWindowPos`、`SetForegroundWindow`、`AttachThreadInput`、`GetForegroundWindow`、`GetWindowThreadProcessId`（窗口前台化/存活性检查）。
- **KERNEL32.dll**：常规 CRT 导入 + `QueryPerformanceCounter/Frequency`。
- **否定证据**：无任何 `VirtualProtect`/`WriteProcessMemory`/`CreateRemoteThread` 导入——本 DLL 自身不具备代码补丁/远程注入能力（导入重建由 Jass.dll/加载器负责，超出本文范围）。

### A.4 `DLL_initializeD3d9`（RVA `0x25a0`–`0x2add`）的行为

反汇编（Intel 语法，节选自 objdump）显示其流程为：

1. `call DWORD PTR ds:0x10012024` —— 调 `base::d3d::get_func_addr()`，取回 `std::map<std::string,uint32_t>&`（存入 edi）。
2. 对每个 native 名构造 `std::string`（SSO 布局：容量 `0xf`），在 map 中查找或插入节点，随后把处理函数地址写入节点 `+0x28`（VC++ std::map 节点：`+0x10` 为 key 字符串，`+0x28` 为 mapped 值）。注册的 7 项（字符串 RVA → 处理函数 RVA，字符串位于 `.rdata`，RVA = 文件偏移 + 0xe00）：

   | 注册名（字符串 RVA / 文件偏移） | 处理函数 RVA |
   |---|---|
   | `InitTexture`（`0x17520` / `0x16720`） | `0x10001280` |
   | `DestroyTexture`（`0x1752c` / `0x1672c`） | `0x100017c0` |
   | `texture_func`（`0x1753c` / `0x1673c`） | `0x100017f0` |
   | `text_func`（`0x1754c` / `0x1674c`） | `0x10002010` |
   | `InitFont`（`0x17558` / `0x16758`） | `0x10001e70` |
   | `DestroyFont`（`0x17564` / `0x16764`） | `0x100017c0` |
   | `UpdateD3dObject`（`0x17570` / `0x16770`） | `0x10001ed0` |

   典型指令序列（第一项）：
   ```
   100025d6: call  DWORD PTR ds:0x10012024      ; get_func_addr()
   100025de: push  0x10017520                   ; "InitTexture"
   ...
   1000266b: mov   DWORD PTR [esi+0x28],0x10001280  ; 节点值 = 处理函数
   ```
3. 末尾 `call 0x10002420`：创建临时 D3D9 设备取出真实 `Present` 地址并注册第 8 项（见 A.5）。

### A.5 真实 `Present` 地址的获取（函数 RVA `0x2420`）

该函数是理解挂钩方式的核心，完整证据：

```
1000244b: call  DWORD PTR ds:0x10012038   ; base::d3d::GetWar3Window()
10002451: push  0x20                       ; D3D_SDK_VERSION = 32
10002455: call  DWORD PTR ds:0x10012180   ; Direct3DCreate9(0x20)
1000245d: mov   ds:0x1001c158,eax         ; 保存 IDirect3D9*
; memset(&params, 0, 0x38)  —— D3DPRESENT_PARAMETERS 共 0x38 字节
10002480: mov   DWORD PTR [ebp-0x5c],0x0  ; BackBufferFormat = D3DFMT_UNKNOWN(0)
10002479: mov   DWORD PTR [ebp-0x4c],0x1  ; SwapEffect = D3DSWAPEFFECT_DISCARD(1)
10002470: mov   DWORD PTR [ebp-0x44],0x1  ; Windowed = TRUE(1)
10002487: call  0x100023a0                ; 窗口前台化辅助（见下）
100024a4: call  DWORD PTR [ecx+0x40]      ; IDirect3D9::CreateDevice
                                          ; (Adapter=0, DeviceType=1=HAL, hFocusWindow=hwnd,
                                          ;  BehaviorFlags=0x20=SOFTWARE_VERTEXPROCESSING, &params, &dev@0x1001c154)
100024a7: mov   eax,ds:0x1001c154
100024ac: mov   eax,DWORD PTR [eax]       ; 设备 vtable
100024ae: mov   ebx,DWORD PTR [eax+0x44]  ; vtable[0x44] = IDirect3DDevice9::Present
100024b1: call  DWORD PTR ds:0x10012024   ; get_func_addr()
100024b9: push  0x10017508                ; "get_d3d_present_addr"
...
10002539: mov   DWORD PTR [esi+0x28],ebx  ; 注册：名字 → Present 真实地址
1000256e: call  DWORD PTR [ecx+0x8]       ; dev->Release()
10002579: call  DWORD PTR [ecx+0x8]       ; d3d9->Release()
```

vtable 偏移核对（Direct3D9 COM 布局）：IDirect3D9 `+0x40` = `CreateDevice`；IDirect3DDevice9 `+0x44` = `Present`，`+0x08` = `Release`。

窗口前台化辅助函数（RVA `0x23a0`，thiscall，ecx=hwnd）：`GetForegroundWindow` → `GetCurrentThreadId` → `GetWindowThreadProcessId` → `AttachThreadInput(当前,前台,TRUE)` → `ShowWindow(hwnd,SW_SHOWNORMAL)` → `SetWindowPos(hwnd,HWND_TOPMOST,...)` → `SetWindowPos(hwnd,HWND_NOTOPMOST,...)` → `SetForegroundWindow(hwnd)` → `AttachThreadInput(...,FALSE)`。这是为临时 CreateDevice 前把游戏窗口提到前台的标准技巧。

**结论（挂钩方式）**：newD3d9.dll **自身不做 inline hook，也不 hook EndScene**。它只是创建一个临时窗口化 D3D9 设备、从其 vtable 读出系统 `d3d9.dll!IDirect3DDevice9::Present` 的真实地址，以 `get_d3d_present_addr` 为名注册进 Jass.dll 的 func_addr 表。对 Present 的实际挂钩/接管由该地址的消费方（Jass.dll 侧，见 `02-jass-dll.md`）实施；渲染则由 `texture_func`/`text_func` 两个被注册的回调完成。

### A.6 各 native 处理函数还原

**`InitTexture`（RVA `0x1280`）** —— 从 MPQ 加载图片并创建 D3D 纹理：

- 首次调用时构造静态 `storm_dll` 对象（实例 `0x1001c178`，初始化守卫 `0x1001c168`，并注册退出析构 `0x10011d90`）。
- `storm_dll::has_file(path)` → `storm_dll::load_file(path,&buf,&size)` 从 MPQ 读文件数据。
- 取文件名末尾 3 个字符与扩展名表比较（`.rdata` 字符串：RVA `0x174e4`=`"blp"`、`0x174e8`=`"jpg"`、`0x174ec`=`"tga"`、`0x174f0`=`"bmp"`、`0x174f4`=`"png"`，文件偏移 `0x166e4`–`0x166f7`）。
- **blp 路径**：`IMAGE::BLP::Read` 解码为像素 BUFFER → `get_d3d_pointer()` 取设备 →
  `D3DXCreateTexture(dev, w, h, MipLevels=-1(D3DX_DEFAULT), Usage=0, Format=0x15(D3DFMT_A8R8G8B8), Pool=1(D3DPOOL_MANAGED), &tex)` →
  `tex->LockRect(0,&rc,NULL,0x2000(D3DLOCK_DISCARD))`（vtable `+0x4c`）→ 按 `BUFFER::GetData/GetSize` 拷贝 → `UnlockRect`（vtable `+0x50`）→
  `D3DXFilterTexture(tex, NULL, -1, -1)` 生成完整 mipmap 链。
- **jpg/tga/bmp/png 路径**：jpg 先经 `IMAGE::JPEG::Read` 处理，随后统一走 `D3DXCreateTextureFromFileInMemory` + `D3DXFilterTexture`。
- `storm_dll::unload_file` 释放文件缓冲；纹理指针写出到调用方提供的指针。

**`DestroyTexture` / `DestroyFont`（RVA `0x17c0`，两者共用）**：

```
100017cb: push 0x100174f8   ; "Warcraft III"（类名）
100017d0: push 0x100174f8   ; "Warcraft III"（窗口名）
100017d5: call FindWindowA
100017df: mov  eax,[esi]    ; 对象 vtable
100017e2: call DWORD PTR [eax+0x8]   ; IUnknown::Release()
```
即以游戏窗口是否还存在为条件的"安全 Release"。

**`texture_func`（RVA `0x17f0`）** —— 每帧贴图绘制：

- `GetWindowVector()` + `get_d3d_pointer()` → `D3DXCreateSprite(dev,&sprite)`；
- `sprite->vtable+0x20`，参数 `0x10` → `ID3DXSprite::Begin(D3DXSPRITE_ALPHABLEND)`；
- 遍历 `get_texture_map()`（`std::map<int, shared_ptr<texture>>`），拷贝到 vector 并以 `base::d3d::texture_sort` 为比较器排序（尾部有 `std::vector` 长度异常 `"vector<T> too long"`，文件偏移 `0x167a8`）；
- 对每个纹理对象：经对象 vtable `+0x10`/`+0x14`（推断为 Get/SetTransform）配合 `D3DXMatrixTransformation2D` 计算 2D 变换矩阵，再经 sprite vtable `+0x24` = `ID3DXSprite::Draw` 绘制；
- 收尾：sprite vtable `+0x2c` 调用一次，然后 vtable `+0x8` = `Release`（`+0x2c` 的语义见"存疑点"）。

**`InitFont`（RVA `0x1e70`）**：坐标换算辅助（RVA `0x1df0`，内部用 `GetWindowVector` + SSE 浮点把逻辑坐标换算为屏幕坐标）→ `get_d3d_pointer()` → `D3DXCreateFontIndirectA(dev,&desc,&font)` → 结果进入 `text_map`。

**`text_func`（RVA `0x2010`）** —— 每帧文字绘制：

- `D3DXCreateSprite` + `Begin`（vtable `+0x20`）；
- `QueryPerformanceCounter`/`QueryPerformanceFrequency` 配合 `get_last_time`/`set_last_time` 计算帧时间差（动画/计时用）；
- 遍历 `get_text_map()`，字体对象经 vtable `+0x38` 调用 —— 按公开 ID3DXFont 布局 `+0x38` = **`DrawTextW`**（宽字符文本渲染）；
- 收尾同样是 vtable `+0x2c` + `Release`。

**`UpdateD3dObject`（RVA `0x1ed0`）** —— 资源清理：

- 遍历 `get_text_map()`；对每个 text 对象：若标记位（对象 `+0x68`）为 0、其关联 COM 指针（对象 `+0x3c`）非空、且 `FindWindowA("Warcraft III","Warcraft III")` 成功，则对该 COM 对象 `Release`（vtable `+0x8`）一次，随后置标记位为 1。
- shared_ptr 引用计数操作（`lock xadd`）贯穿其中。语义上是在设备丢失/窗口销毁场景下对每个对象做一次幂等释放。

### A.7 字符串证据汇总（对象 A）

| 字符串 | 文件偏移 | 用途 |
|---|---|---|
| `get_d3d_present_addr` | `0x16708` | func_addr 注册名：Present 地址 |
| `InitTexture`/`DestroyTexture`/`texture_func`/`text_func`/`InitFont`/`DestroyFont`/`UpdateD3dObject` | `0x16720`–`0x1677f` | func_addr 注册名：7 个 native |
| `Warcraft III` | `0x166f8` | FindWindowA 类名/窗口名 |
| `blp`/`jpg`/`tga`/`bmp`/`png` | `0x166e4`–`0x166f7` | 纹理格式分派 |
| `\Jass - 2013\Release\newD3d9\newD3d9.pdb` | `0x168fd` | PDB 路径（构建机目录） |
| Jass.dll 24 个修饰名（`base::d3d::*`、`storm_dll`、`IMAGE::*`） | `0x17864`–`0x17e0f` | 导入符号 |

二进制内未发现中文字符串，无 GBK 编码问题。

---

## 三、对象 B：pjass.exe 事实清单

### B.1 UPX 壳特征（确认）

- PE32 控制台程序，ImageBase `0x400000`，区段名为 **`UPX0`/`UPX1`/`UPX2`**：
  - `UPX0` vaddr `0x1000` vsize `0x15000` raw size 0（解压后代码空间）；
  - `UPX1` vaddr `0x16000` vsize `0xa000` raw `0x200`–`0x9e00`（压缩数据+壳 stub）；
  - `UPX2` vaddr `0x20000`（导入节）。
- 文件偏移 `0x1f5` 处存在 **`UPX!`** 魔数（`grep -abo 'UPX!'` 唯一命中）。
- 入口 `0x41eec0`，位于 UPX1 内 —— 典型 UPX stub 入口。
- stub 导入表（UPX2）：KERNEL32 的 `LoadLibraryA/GetProcAddress/VirtualProtect/VirtualAlloc/VirtualFree/ExitProcess` + msvcrt `_iob` —— 与 UPX 3.x LZMA stub 的标准导入集完全一致。
- `file` 输出亦标注 `UPX compressed`。

### B.2 壳头被扰乱（反解壳）

按 UPX 3.x PackHeader 布局解析 `0x1f5` 处数据（`55 50 58 21 0d 09 0e 0a 45 f6 9a d7 8c 18 ...`）：

- `lsize=0x090d`、`version=0x0e(14)`、`format=0x0a`（UPX_F_WIN32_PE）均正常；
- 但 `method=0x45`(69)、`level=0xf6`(246) 为**非法值**（UPX 合法 method 仅 2/3/5/8/9/14 等），后续 `u_len/c_len/u_file_size` 字段亦不可解析。
- 结论：PackHeader 被故意扰乱（"UPX scramble"类处理），官方 `upx -d` 无法直接解压（本环境也无 upx 工具）。

### B.3 stub 反汇编证据（LZMA 解压器）

入口 stub（`0x41eec0` 起）要点：

```
41eec1: mov esi,0x416015            ; 压缩源（UPX1 内）
41eec6: lea edi,[esi-0x15015]       ; = 0x401000 解压目的（UPX0）
41eecc: mov DWORD [edi+0x18178],0xd8f4fcb4  ; 解压前修补压缩流 4 字节
                                            ; (raw 0x3378: b4 fc f4 d8 → d8 f4 fc b4，双字循环移位)
41eeea: push 0x1c5b7                ; （数值可疑，疑同被扰乱）
41eef4: push 0x8ea8                 ; 解压长度 0x8ea8 = 36520
41eeff: mov DWORD [ebx],0x3         ; LZMA props 硬编码：lc=3,lp=0,pb=0
; 0x41ef08 起为标准 LZMA 解码器（概率初值 0x400、range decoder 5 字节初始化）
```

stub 尾部（`0x41f98e`–`0x41fa95`）：

- `mov ecx,0xf200` 的 call/jmp 过滤器还原循环（UPX 标准 filter undo）；
- 从 `esi+0x1c000`（=`0x41d000`）区域重建导入（`call [esi+0x1f03c]`=LoadLibraryA、`+0x1f040`=GetProcAddress、`+0x1f050`=VirtualProtect）；该区域（raw `0x7200` 起）内容已被加密/扰乱，无任何可读 DLL/函数名字符串；
- `41fa90: jmp 0x401570` —— 原程序入口（OEP）= RVA `0x1570`。

### B.4 手工解壳尝试（失败，留证）

- 按 UCL 官方算法（`n2b_d.c`/`n2e_d.c`）实现 NRV2B/NRV2E 解压器，对 UPX1 全部 `0x200`–`0x90c0` 起点爆破：无任何有效输出。
- 按 stub 指示的 LZMA（lc=3,lp=0,pb=0，多种 dict_size，起点 `0x214`–`0x218` 及全区间 0x00 字节对齐点，含/不含 4 字节修补）用 Python `lzma.FORMAT_RAW` 解码：无任何有效输出。
- 推断：压缩流除那 4 字节修补外还存在其他变换（扰乱不止一处），或 stub 中的源/长度立即数亦被修改。静态解壳未成功。

### B.5 身份判断

- 支持"是 pjass（JASS 语法检查器）"的间接证据：文件名 `pjass.exe`；MinGW 工具链（MajorLinkerVersion 2 / MinorLinkerVersion 25 = GNU ld 2.25，pjass 官方发布版为 gcc/MinGW 编译）；控制台子系统；与 JASS 插件体系捆绑分发；UPX 压缩后 40KB 的体量与 pjass 相符。
- **但**：因解壳失败，未能取得任何正文/帮助字符串（如 `usage`、`pjass` 横幅、语法错误信息等）作为直接证据。**结论：高度疑似 pjass，未经二进制内容证实。**

---

## 四、对象 C：D3DX9_42.dll 事实清单

### C.1 基本特征

- 内部名（导出目录 Name RVA `0x1ae6b2`）：`d3dx9_42.dll`。
- 导出数量：Export Address Table `0x149` = **329 个导出**（含序号导出）。
- TimeDateStamp `0x4a6d13a7` = **2009-07-27 02:40:39 UTC**；链接器 9.0（VS2008）；CheckSum `0x1dcf21`；SizeOfImage `0x1e5000`。
- 版本资源（自写 struct 脚本解析 `.rsrc`）：
  - CompanyName = `Microsoft Corporation`
  - FileDescription = `Direct3D 9 Extensions`
  - InternalName / OriginalFilename = `D3DX9D.dll`（官方发布版特征）
  - ProductName = `Microsoft® DirectX for Windows®`
  - FileVersion / ProductVersion = **`9.27.952.3001`**
  - LegalCopyright = `Copyright © Microsoft Corp. 1994-2007`
- newD3d9.dll 所需的 6 个 D3DX 函数全部在导出表中，序号与对象 A 导入 hint 一致：
  `[65] D3DXCreateFontIndirectA`、`[88] D3DXCreateSprite`、`[92] D3DXCreateTexture`、`[96] D3DXCreateTextureFromFileInMemory`、`[129] D3DXFilterTexture`、`[220] D3DXMatrixTransformation2D`。

### C.2 与微软官方文件的逐字节比对（决定性证据）

- 本机系统目录存在官方副本 `C:\Windows\SysWOW64\d3dx9_42.dll`（1892184 字节，2009-09-04，即 2009 年 8 月 DirectX End-User Runtime 的 32 位 9.27.952.3001；公开资料记载的官方文件大小同为 1892184 字节）。
- 逐字节比对：**前 1886208 字节 0 处差异**。
- 官方文件仅多出尾部 5976 字节：起始字节 `58 17 00 00 00 02 02 00 30 82 17 4b 06 09 2a 86 …`，即 WIN_CERTIFICATE 结构（dwLength=`0x1758`=5976、wRevision=0x0200、wCertificateType=0x0002=PKCS_SIGNED_DATA、PKCS#7 签名）。
- 本文件的 PE 安全目录条目仍保留（RVA 字段=文件偏移 `0x1cc800`、大小 `0x1758`），但文件大小恰为 `0x1cc800` —— 签名块内容被整体截除。
- 旁证：头部 CheckSum `0x1dcf21` 与公开渠道（游戏崩溃日志）记录的同版本官方文件一致；按 CheckSumMappedFile 算法对截断后文件重算得 `0x1cd563` ≠ 头部值，说明剥除签名后未重算校验和（算法经本机 3 个系统 DLL 校准通过）。

**结论：该 `D3DX9_42.dll` 就是微软官方 32 位 `d3dx9_42.dll`（9.27.952.3001），仅 Authenticode 数字签名块被剥除，代码与数据未被修改。** 复刻项目可直接引用系统官方文件或重新附带签名完整的 redist 版本。

---

## 五、关键机制还原（对象 A 总体工作流）

```
Jass 引擎侧调用 DLL_initializeD3d9（唯一导出）
        │
        ├─ ① base::d3d::get_func_addr() 取回 func_addr 表（std::map<名字,地址>）
        │
        ├─ ② 注册 7 个渲染 native：
        │      InitTexture / DestroyTexture / texture_func /
        │      InitFont   / DestroyFont   / text_func / UpdateD3dObject
        │
        └─ ③ 子函数 0x2420：
               Direct3DCreate9 → 临时窗口化设备 → 读设备 vtable+0x44
               → 以 "get_d3d_present_addr" 为名注册真实 Present 地址
               → 释放临时设备
        │
Jass.dll 侧用该地址接管游戏每帧 Present（挂钩实施在 Jass.dll，见 02 文档）
        │
        ▼
每帧渲染回调：
  texture_func ── D3DXCreateSprite → Begin(ALPHABLEND)
                 → 遍历 texture_map（texture_sort 排序）→ MatrixTransformation2D
                 → SetTransform → sprite.Draw
  text_func    ── 同上遍历 text_map → ID3DXFont::DrawTextW
                 （QPC + get/set_last_time 计算帧时间差）
资源管理：
  InitTexture  ── storm_dll 从 MPQ 读 blp/jpg/tga/bmp/png
                 → blp: BLP::Read + D3DXCreateTexture + LockRect 拷贝 + D3DXFilterTexture
                 → 其他: D3DXCreateTextureFromFileInMemory + D3DXFilterTexture
  InitFont     ── D3DXCreateFontIndirectA
  DestroyX     ── FindWindowA("Warcraft III") 存活检查后 Release
  UpdateD3dObject ── 遍历 text_map 对 COM 对象幂等 Release（设备丢失/销毁清理）
```

设计要点：渲染扩展层与 JASS 引擎之间只通过 Jass.dll 暴露的 4 张表（func_addr、texture_map、text_map、d3d_pointer）和 storm 文件接口交互，自身不碰游戏内存补丁——职责边界清晰，复刻时应保持同样的解耦。

---

## 六、存疑点（未证实事项）

1. **sprite 收尾调用的语义**：`texture_func`/`text_func` 结尾均为 `call DWORD PTR [ecx+0x2c]` 后接 `Release`。按公开 ID3DXSprite 布局 `+0x20=Begin`、`+0x24=Draw`、`+0x28=End`、`+0x2c=OnLostDevice`；全函数未见 `+0x28` 调用。两种可能：作者以旧版/裁剪头文件编译导致偏移含义不同，或有意以 `OnLostDevice` 代替 `End` 收尾。**未证实，复刻时建议按标准 Begin/End 配对实现。**
2. **texture/text 对象的 vtable 含义**（`+0x10`/`+0x14` 等）：这些对象的类定义在 Jass.dll 侧，把 `+0x10`/`+0x14` 解释为 Get/SetTransform 属基于调用时序的推断，未逐一核实。
3. **func_addr 表的消费细节**：谁按名字取地址、以何调用约定传参（native 的 JASS 侧签名），需结合 Jass.dll 分析（02 文档范围），本 DLL 内无直接证据。
4. **pjass.exe 的真实身份与版本**：高度疑似 JASS 语法检查器 pjass，但壳内字符串未取出，**身份未经二进制内容证实**；压缩流的完整扰乱方式（除 raw `0x3378` 的 4 字节循环移位修补外是否还有 XOR/重排）未查明，stub 中 `push 0x1c5b7` 等立即数真实性存疑。
5. **pjass.exe 的 TLS 目录**（RVA `0x1fab4`）：UPX 壳程序含 TLS 属少见，是否与扰乱/反调试有关未查。
6. **D3DX9_42.dll 签名被剥除的环节**：无法从文件本身判断是地图作者、打包工具还是分发渠道所为。
7. **窗口化临时设备的副作用**：`CreateDevice` 参数 `BehaviorFlags=0x20`（D3DCREATE_SOFTWARE_VERTEXPROCESSING）且 `SwapEffect=DISCARD`、`Windowed=TRUE`，对 1.27a 全屏游戏场景是否必然成功，未经动态运行验证。

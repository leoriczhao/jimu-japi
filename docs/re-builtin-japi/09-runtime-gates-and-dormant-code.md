# 09 · 运行时闸门与休眠能力（pjass / 看门狗 / d3d8 / WININET / 注册表）

> 分析对象：`reference/builtin-japi/extracted/jass.dll`（PE32 i386，ImageBase `0x10000000`，546 导出）。
> 方法：`objdump -d -M intel` 全量反汇编（363,861 条指令）+ 导入表逐槽核对，结论全部来自二进制本身。
> 换算（实测节表）：`.text` 文件偏移 + 0xC00 = RVA；`.rdata` 文件偏移 + 0x1200 = RVA。本文 VA = objdump 标注值。
> 目的：把 02 文档里"用途未证实"的三处、以及被误读的一处，按指令级证据定死。

---

## 一、结论摘要

| 机制 | 旧认知 | 本次结论 | 定性 |
|---|---|---|---|
| `pjass.exe` | "只被写盘，未发现被调用，可能只是捆绑工具" | **运行时会真的被 CreateProcess 调用**；输出有错就 `exit(0)` 杀掉整个 war3 | 【证实】 |
| `\*.dll` + `FindFirstFileA` | "插件目录扫描 / 清理历代 `<pid>.dll`" | **只是清理器**，没有任何插件加载；过滤条件是"纯数字名 + 文件大小 4–6MB" | 【证实·纠正】 |
| `%i.dll` + `get` | "插件就绪握手" | 是 `<pid>.dll`（注入器投放的载荷）的布尔握手，返回非 0 → `FreeLibrary` + `DeleteFileA` | 【证实】 |
| `newD3d9.dll` | "jass.dll 从接口表取 `get_d3d_present_addr`" | `LoadLibraryA("newD3d9.dll")` + `DLL_initializeD3d9(0)`，**单向调用**；接口表是 jass.dll 自用 | 【证实·纠正】 |
| `d3d8.dll` | "D3D8 设备查找/绘制钩子" | 仅纯 d3d8 后端：临时 `IDirect3D8` → 临时设备 → 读 vtable`+0x3C`(`Present`) → 两个 `Release` | 【证实】 |
| WININET | "具备 HTTP 联网能力，用途未证实" | **StormLib 的 HTTP 只读文件后端**（`StormLib HTTP MPQ reader`，`GET`，`Range: bytes=%u-%u`，端口 80）；入口只在文件名以 `http:` 开头时成立，二进制里无人构造这种名字 | 【证实】+【推论】 |
| ADVAPI32 `reswidth/resheight` | "被 D3D 钩子/文字坐标消费" | 值读进来写进两个全局后**零次读取**（dead store）；另一族 `RegOpenKeyA` 是 CRT 读 `HKLM\Software\Microsoft\Direct3D\DisableMMX` | 【证实·纠正】 |

---

## 二、pjass.exe：运行时语法闸门，失败直接 `exit(0)`

### 2.1 触发点

```
导出 call  VA 0x100363CF   (无内部 xref，只能被 JASS 侧调用)
 ├─ 0x10036F01  InitJass()
 ├─ 0x100335EC  InitGame()
 │    └─ 0x100337D3..0x100337DD  CreateThread(0,0,0x10041B29,0,0,0)
 │         └─ 线程体 = pjass 流程（pthread 句柄存 0x1016E7D4）
 └─ CreateThread(0,0,0x10036329,...)   ← 看门狗线程（见第三节）
```

`CreateThread` 在一次性 guard 之外：**每次 `call`/`InitGame` 都会再起一个 pjass 线程**。

### 2.2 线程步骤（0x10041B29）

1. `CreateDirectoryW("jass_temp")` / `("jass_temp\Scripts")`（`0x10102C9C → 0x10102E22`，失败忽略）。
2. **硬闸门**：从 MPQ 读名为 `callback` 的文件，按 0x400 分块累加 `string_hash`，必须等于魔数 `0x880B034B`：

```
10041B80: call 0x10041836          ; 读 "callback" 并累加 string_hash
10041B85: cmp  eax,0x880B034B
10041B8A: je   0x10041B93          ; 匹配 → 继续
10041B8C: push 0                     
10041B8E: call 0x100DBF65          ; ★ exit(0)
```

即**原版 jass.dll 拒绝与自己不匹配的 callback**——这正是本项目 callback 尾部被改后无法直接喂给原版 jass.dll 的原因（与 01/05 的"原版 callback 已失"互为印证）。

3. 从 MPQ 抽三个文件落盘（`0x10041743`：`storm_dll` 读 → 递归建目录 → 写文件）：

| 源名（回退名） | 目标 |
|---|---|
| `common.j`（`Scripts\common.j`） | `jass_temp\Scripts\common.j` |
| `blizzard.j`（`Scripts\blizzard.j`） | `jass_temp\Scripts\blizzard.j` |
| `war3map.j`（`Scripts\war3map.j`） | `jass_temp\war3map.j` |

4. 打开地图 MPQ（`0x1004194C → 0x10036A0B`），每项读前 0x1000 字节，含 `globals` 且其后为空格/LF/CR/'/' 的外部 j 文件也一并抽出。
5. 拼命令行：`0x10041C5E` 起 `cmd = "pjass.exe " + Σ("jass_temp\" + 名字 + " ")`（参数顺序 = 抽取成功顺序）。
6. `CreatePipe`（`0x10041654`，`bInheritHandle=TRUE`）→ `CreateProcessA`（**`0x100416BA`**，`lpApplicationName=NULL`、`lpCurrentDirectory=NULL`、`SW_HIDE`、stdout **和 stderr** 同管道）→ 关父端写句柄（`0x100416D4`）→ 逐 1 字节 `ReadFile` 直到 EOF。
7. 判读（`0x10041D0B..0x10041E67`）：把 `returned value from integer to real` / `... real to integer` 两条已知良性警告替换成 `is not error`（`0x10041467`），再统计 `returned` 与 `Index ` 的出现次数。
8. 计数 > 0 → `0x10041F0B` → `0x10041B8E` → `0x100DBF65` = **`exit(0)`**。

### 2.3 性质

- **不阻塞主线程**（独立线程；路径上无 `WaitForSingleObject`，靠管道 EOF 等子进程退出）。
- **不是弹框**：整条路径无 `MessageBoxA`（全量 grep，0 命中）。
- **失败不是软失败**：语法错误 = 进程级 `exit(0)`，连地图都进不去。
- `jass_temp\` 是**相对 CWD 的固定相对路径**（不是 `%TEMP%`），且**从不清理**（未导入 `RemoveDirectory`）。
- 所有文件抽取失败时命令行退化为 `pjass.exe `，pjass 只打印 usage，计数 0，不退出。

---

## 三、看门狗线程与 `\*.dll`：是清理器，不是插件加载

### 3.1 线程体（0x10036329）

```
GetCurrentProcessId → sprintf("%i.dll") → GetModuleHandleA("<pid>.dll")
 → GetProcAddress(h,"get")        ← 无 NULL 检查
 → while(!get()) Sleep(1)         ← 无超时、无次数上限
 → FreeLibrary(h)（失败则不删文件）→ DeleteFileA("<pid>.dll") → CloseHandle(self)
 → Sleep(10000)
 → 0x100361C4：目录清理
```

`<pid>.dll` 就是注入器从地图 MPQ 导出、`LoadLibrary` 的那个载荷（对应本项目 `ExportFileFromMpq("japi.tga", "<pid>.dll")`）：`get()` 只当**布尔就绪位**用，无参数、不进任何表。

### 3.2 清理函数（0x100361C4）

```
GetModuleFileNameA(hInstance,buf,0x100) → strrchr(buf,'\') → 覆盖为 "\*.dll"
FindFirstFileA / FindNextFileA(&wfd)
  name = wfd.cFileName 去尾 4 字节(".dll")
  atoi(name) > 0                       ← "纯数字名"
  && wfd.nFileSizeLow ∈ [0x400001, 0x5FFFFF]   ← 4MB–6MB
  → DeleteFileA(wfd.cFileName)
```

栈帧互证（定死字段偏移）：路径缓冲在 `esp+0x184`；`wfd` 在 `esp+0x44`（长 0x140），因此 `esp+0x70 = wfd+0x2C = cFileName`、`esp+0x64 = wfd+0x20 = nFileSizeLow`。

**纠正 02 §3 的表述**：`edi-0x400001 <= 0x1ffffe` 不是"PID 合法范围"，是**文件大小**过滤。`atoi(name)>0` 才是"名字是数字"的判据。目的仍是清理历代 `<pid>.dll` 残留（崩溃的旧会话不会走 FreeLibrary 路径），而 4–6MB 是这类载荷的经验体积区间（【推测】）。

### 3.3 否证：不存在插件枚举加载

全库 `FindFirstFileA` 仅 **1** 处（0x10036246，就是上面这个清理器）；`LoadLibraryA` 仅 **2** 处（`0x10002411` d3d8/d3d8d、`0x1003C5AB` newD3d9.dll）；`LoadLibraryW` 仅 **1** 处（Storm.dll）；`GetProcAddress(...,"get")` 仅 **1** 处（`0x1003636E`，目标是 `<pid>.dll`）。

**结论：内置 JAPI 没有"目录扫描 → 逐个 LoadLibrary → 按 `get` 注册"的插件机制。** 它的可扩展性来自编译期（546 导出）与 Lua 层，不是 DLL 插件目录。

### 3.4 失败行为（全部静默，无弹框/无日志）

| 失败点 | 行为 | 证据 |
|---|---|---|
| `<pid>.dll` 未加载或无 `get` | `call NULL` → AV（线程无 SEH） | 0x1003636E / 0x10036380 |
| `get()` 长期为假 | 无限自旋，每轮 `Sleep(1)` | 0x10036378 |
| `FreeLibrary` 失败 | 跳过删除，文件残留给 10 秒后的清理器 | 0x1003638F |
| `CreateThread` 失败 | 句柄写 0，清理永不执行 | 0x100363E5 |
| `FindFirstFileA` 失败 | 判据 `test esi,esi` 只拒 0，而失败返回 `-1` → 误进循环读未初始化 `wfd`（缺陷，通常"什么都没删"） | 0x10036250 |

---

## 四、D3D 分支：d3d8 临时设备 vs newD3d9.dll

### 4.1 总闸

```
InitGame → 0x1003F200
  if GetModuleHandleA("QB_inject.dll") != 0 → 整段跳过（已是代理注入场景）
  v = get_d3d_version()      ; -opengl → 0；d3d9.dll 已加载 → 9；d3d8.dll → 8
  v == 8 → 0x1003D2CC        ; d3d8 分支
  v == 9 → 0x1003C59D        ; d3d9 分支
  0x1003F05F                 ; 公共尾巴：dxrender.dll 探测 + Present inline patch
```

### 4.2 d3d8 分支（0x1003D2CC → 0x1003D194）

先注册 7 个名字到内部接口表 `0x1016FC08`（`std::map<string,void*>`）：`InitTexture` / `DestroyTexture` / `texture_func` / `text_func` / `InitFont` / `UpdateD3dObject`（+ d3d9 分支另有 `DestroyFont`）。随后：

```
GetWar3Window()（FindWindowA "Warcraft III"/"Black Warcraft III"）
Direct3DCreate8(0xDC)
 → IDirect3D8: GetAdapterDisplayMode(0)         ; vtable+0x20
 → memset(D3DPRESENT_PARAMETERS,0,0x34)
    BackBufferFormat = mode.Format, Windowed=TRUE, SwapEffect=DISCARD
 → 窗口前台化（AttachThreadInput/ShowWindow/SetWindowPos TOPMOST→NOTOPMOST/SetForegroundWindow）
 → CreateDevice(0, HAL=1, hwnd, 0x20=SW_VERTEXPROCESSING, &pp, &dev)   ; vtable+0x3C【推测：公开头为 +0x38】
 → map["get_d3d_present_addr"] = dev->vtable[0x3C]     ← IDirect3DDevice8::Present
 → dev->Release() ; d3d->Release()                      ← 临时对象，用完即弃
```

`0x1016E790/0x1016E794` 只在函数内出现 → 确认临时性。设备只用来"读一个 vtable 槽"。

`0x1003F05F` 随后对该 Present 做 5 字节 inline patch（`E9 rel32` → `0x1003EFC4`）；若 `GetModuleHandleA("dxrender.dll")` 命中则改成 3 字节 `EB F9 90` 短跳转发（`0x1003F0CD`）。

### 4.3 d3d9 分支（0x1003C59D）

```
g_d3d9 已缓存? 否 → LoadLibraryA("newD3d9.dll") → GetModuleHandleA("newD3d9") → g_d3d9
GetProcAddress(g_d3d9,"DLL_initializeD3d9")
存在 → DLL_initializeD3d9(0) ；不存在 → 静默 return
```

- 方向是**单向**：jass.dll 调 newD3d9，newD3d9 反过来通过 `base::d3d` 的导出改 jass.dll 的 map（04 文档已述）。
- 最终挂钩在 **jass.dll 侧**（`hookPresent` / inline patch），与 d3d8 分支同构。
- 注意 `GetModuleHandleA("newD3d9")` 用的是**无扩展名字面量**（`0x101256D8` 是独立 NUL 结尾串），若模块以 `newD3d9.dll` 载入则该调用返回 NULL，D3D9 钩子会**静默失效**；是否成立取决于 PE 导出名/加载名约定，二进制内无法判定【推测】。

### 4.4 `d3d8d.dll` 与 `-opengl`

- `d3d8d.dll`（VA `0x10109C30`）与 Present 无关：它是 `0x100023DC` 的 `DebugSetMute` 代理——先 `GetModuleHandleA`，没有再 `LoadLibraryA`，优先 `d3d8.dll`，回退 `d3d8d.dll`，取到就转发调用（DC 调试运行库静音）。
- 命令行含 `-opengl` → `get_d3d_version()` 返回 0 → 整个 D3D 分支跳过（不建临时设备、不挂钩）。

---


## 五、WININET：StormLib 的 HTTP 只读文件后端

9 个 IAT 全部有真实调用点（共 17 处），集中在 4 个函数：

| 函数 | 作用 |
|---|---|
| `0x10097330` | 拆 `http://host/path` |
| `0x10097390` | open：连通性检查 → `InternetOpenA` → `InternetConnectA(host,80)` → `HttpOpenRequestA("GET")` → `HttpSendRequestA` → `HttpQueryInfoA`×2 |
| `0x10097570` | read：`sprintf("Range: bytes=%u-%u")` + `HttpAddRequestHeadersA` + `HttpSendRequestA` + `InternetReadFile` 循环 |
| `0x10097720` | close：`InternetCloseHandle`×2 |

细节：
- Agent 字符串 `0x101277CC = "StormLib HTTP MPQ reader"`；协议前缀 `0x101277E8 = "http://"`；方法 `0x10127804 = "GET"`；范围头 `0x101277F0 = "Range: bytes=%u-%u"`；端口 `push 0x50`(80)；`HttpSendRequestA` 五参数全空（无 body）。
- 两次 `HttpQueryInfoA`：`0x4000000B`（低位 `11` = `HTTP_QUERY_LAST_MODIFIED`）写入 `+0x50/+0x54`——**与本地文件分支 `GetFileTime` 填 FILETIME 的同一字段**（`0x10097216`），即"远端文件时间戳"；`0x20000005`（`5`=`CONTENT_LENGTH` + NUMBER 位）写入 `+0x40` = 文件大小。常量符号名为【推测】，字段绑定为【证实】。
- 短读时 `push 0x26` → `SetLastError(ERROR_HANDLE_EOF=38)`；读到的字节直接进调用方缓冲区，**无写盘、无弹框、无解析**。

唯一入口是数据表项 `.rdata 0x1011FBB8 → InstallHttpFile 0x10097760`（代码里 0 引用），表格在 `0x10097B81` 由 `flags & 3` 索引：

```
0x1011FBB0: [0] 0x10097160  本地磁盘（CreateFileA/MapViewOfFile）
0x1011FBB4: [1] 0x100972F0  MPQ/内存内文件
0x1011FBB8: [2] 0x10097760  HTTP  ← InstallHttpFile
```

`flags & 3 == 2` 的唯一来源是文件类型探测器 `0x10099320` 命中字面量 `"http:"`（`0x100993D5` + `strncmp`，命中即 `or esi,2`；同组前缀还有 `file:`/`map:`/`part-`/`flat-`/`blk4-`/`mpqe-`，`file:`→0、`map:`→1）。

**结论**：这是 StormLib 自带的远端文件后端（源码级同源能力），不是本插件的联网功能；二进制里**没有任何代码构造 `http:` 开头的文件名**，也没有硬编码域名，故处于休眠状态。附带观察：`flags&3` 允许 3，而表项 [3] 落在 `0x1002FF10`（JPEG 的 `SourceTerminate`），属表尾串到相邻数据；由于探测器低 2 位只会是 0/1/2，现实不会触发。

---

## 六、ADVAPI32：`reswidth`/`resheight` 读了不用

- 通用取值函数 `0x1003C135`（`__fastcall`，`edx`=值名）：`RegOpenKeyExA(HKEY_CURRENT_USER, "SOFTWARE\Blizzard Entertainment\Warcraft III\Video", KEY_READ)` → `RegQueryValueExA` → `RegCloseKey`。
- 两个存根：`0x1002F3B4`（`resheight`→`0x1016FC00`）、`0x1002F3C4`（`reswidth`→`0x1016FBFC`）。
- 触发时机：**DLL_PROCESS_ATTACH 期**静态初始化表（`_initterm(0x10109334, 0x101094E0)`，调用点 `0x100DBD51`），不是计时器、不是 native。
- **消费方：无。** 全段 4 字节引用扫描：两个全局地址各只出现一次，就是那条 `mov` 本身，读引用 0 条。邻接的 `0x1016FC08/18/38` 都有 12–20 处读写，唯独这两个是"只写一次、从不读"的死存储。
- 另一族 `RegOpenKeyA`（`0x10011BDC` / `0x10011C5B`）读的是 `HKLM\Software\Microsoft\Direct3D\DisableMMX`，属 MSVC CRT 的 CPU 特性探测，与 WC3 无关。
- 顺带否证：钩子也没从 `GetSystemMetrics` 取分辨率——6 个调用点全传 `0x20/0x4`（边框尺寸），真实分辨率来源不在这两族里。

---

## 七、对我们的实际影响

1. **不需要补"插件扫描"**：内置根本没有该机制（第三节）。此前把 `\*.dll` 当成插件枚举是误读；若确实想要"地图自带插件"，那是新设计而不是"对齐"。
2. **运行时 pjass 闸门是内置独有行为**，且失败即 `exit(0)`。我们"打包期 pjass + `-SkipJassCheck` 可选"的路线更可控，不建议搬运行时版本（搬就意味着把 `jass_temp\`、子进程、管道读取一起搬进 DLL）。
3. **`callback` hash 闸门 `0x880B034B`** 解释了原版 JAPI 为什么只认自家 callback：我们的 callback 尾部改动后即使结构对上也会被它 `exit(0)`——这可以当作"callback 与原版不兼容"的硬证据。
4. **WININET 与遥测/更新无关**，是 StormLib 的 `http:` 后端且休眠，不必对齐。
5. **d3d8 分支**只在纯 d3d8 后端（且未加 `-opengl`）时走，机制是"临时设备取 Present"。1.27a 走 d3d9，我们的代理已覆盖；将来要支持 d3d8 老版本可直接照搬（临时 `IDirect3D8` → `IDirect3DDevice8` → vtable`+0x3C`）。
6. **注册表读取是死代码**，不需要"对齐分辨率读取"。

---

## 八、对既有文档的修正清单

| 文档 | 位置 | 原文 | 应改为 |
|---|---|---|---|
| 02 | §2 导入表 ADVAPI32 行 | "读注册表（reswidth/resheight）"（暗示被消费） | 读入后**未被使用**（dead store）；另含 CRT 的 `Direct3D\DisableMMX` 探测 |
| 02 | §2 导入表 WININET 行 | "具备 HTTP 联网能力（用途未证实）" | StormLib 的 HTTP 只读文件后端，入口要求文件名以 `http:` 开头，实际休眠 |
| 02 | §3 看门狗段 | "文件名中数字落在合法 PID 范围（0x400001..0x5fffff）" | 过滤的是 **`nFileSizeLow` ∈ 4MB–6MB**；"名字是数字"由 `atoi(name)>0` 判定 |
| 02 | §5 存疑点 3 | WININET 业务用途未证实 | 已查明（见第五节） |
| README | 修正点 3 | 看门狗"清理历代 `<pid>.dll`"（未提过滤条件） | 补：清理器按"纯数字名 + 4–6MB"删；**不存在插件扫描机制** |
| README | 修正点 8 | "pjass.exe 仅被写盘，未发现被调用" | 运行时经 `CreateProcessA` 调用，语法错误 → `exit(0)`；另有 `callback` hash 闸门 `0x880B034B` |

---

## 九、复现命令（只读）

```bash
cd reference/builtin-japi/extracted
objdump -d -M intel jass.dll > /tmp/jass.dis                  # 363,861 条
objdump -p jass.dll | sed -n '/The Import Tables/,/^$/p'      # IAT → API
grep -n "0x10109058\|0x101090cc\|0x101090d4" /tmp/jass.dis    # CreateProcess / ReadFile / CreatePipe
objdump -d -M intel --start-address=0x10041B29 --stop-address=0x10041F80 jass.dll  # pjass 线程
objdump -d -M intel --start-address=0x100361C4 --stop-address=0x10036310 jass.dll  # 清理器
objdump -d -M intel --start-address=0x1003D194 --stop-address=0x1003D2CC jass.dll  # d3d8 临时设备
objdump -d -M intel --start-address=0x10097390 --stop-address=0x10097760 jass.dll  # HTTP 后端
objdump -d -M intel --start-address=0x1003C135 --stop-address=0x1003C190 jass.dll  # 注册表取值
```

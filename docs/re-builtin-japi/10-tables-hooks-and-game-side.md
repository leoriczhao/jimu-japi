# 10 · 表与钩子：async 队列、hook 位定义、事件双表、game.dll 侧的 fnA/fnB

> 对象：`reference/builtin-japi/extracted/jass.dll`（PE32 i386，ImageBase `0x10000000`）+ 本机 `game.dll`（1.27a，ImageBase `0x6F000000`，`"Warcraft III (build 52240)"`）。
> 换算：jass.dll `.text` 文件偏移 + 0xC00、`.rdata` + 0x1200；game.dll 两节都是 +0xC00。
> 目的：结掉 02 文档 §5 的存疑点 4/5/6/7，并把 fnA/fnB 的 game.dll 语义定死。

---

## 一、结论摘要

| 项 | 旧认知 | 本次结论 |
|---|---|---|
| `0x101701CC` / `0x101701E4` | "只写表、没找到消费点" | **`std::vector<Record>`（0x20B）**；消费点 `0x100565C6`，靠 IAT hook 在 VM 初始化期 flush，最终复用 `table_hook`；once 版靠"第二张表 + flush 后清空" |
| `hook()` flags `0x4` | "找名字引用点 +5 做 inline hook" | **`base::hook::replace_pointer`**：把 game.dll native 注册块里 `mov ecx,imm32` 的 **4 字节立即数**换成新地址；下次注册才生效，**不是 inline hook** |
| `from_string(uint)` | "参数实为表项指针，命名不一致" | **确认**：参数 = 字符串表项指针（`base + id*0x10`）；纯 id 要用 `from_stringid`（另一张表、`+0x14`） |
| `0x1016FC88` vs `0x1016FBC8` | "事件双映射，关系未证实" | **两张完全不同的 map**：前者 = `map<string, shared_ptr<patch_record>>`（安装账本，结点 0x30），后者 = `map<string, vector<uint>>`（事件总线，结点 0x34，导出 `get_map_event`）；唯一联系是运行期按事件名查表 |
| fnA / fnB | "game.dll 语义未证实" | **fnA = `war3_searcher::get_instance(idx)`（TLS 槽表，per-thread）**，`5` = JASS 环境槽；**fnB = `war3_searcher::get_gameui(create, reset)`**（`CGameUI` 单例，`new(0x454)`，`CGameUI.cpp:6831`） |

---

## 二、`async_hook` / `async_once_hook`：有效队列，不是死表

### 2.1 容器与元素

两张表都是 **`std::vector<Record>`**（三指针 begin/end/cap，**元素 0x20 字节**，无计数/容量字段）：

| 表 | begin | end | cap |
|---|---|---|---|
| A（普通） | `0x101701CC` | `0x101701D0` | `0x101701D4` |
| B（once） | `0x101701E4` | `0x101701E8` | `0x101701EC` |

插入 `0x10056B90`（`end += 0x20`）。元素布局（由 flush 循环 + 栈帧互证）：

| 偏移 | 字段 |
|---|---|
| +0x00..0x0F | `std::string name` 的 SSO 缓冲 |
| +0x10 / +0x14 | `name.size()` / `name.capacity()` |
| +0x18 | `unsigned* old`（原样存调用方指针） |
| +0x1C | `unsigned new`（新函数地址） |

`async_hook` 无条件返回 1（`0x100566A4`），**不校验名字是否存在**。

### 2.2 消费点：只有一处

`0x100565C6` 三段循环：先遍历 A 表对每条调 `table_hook(name, old, new)`（`0x10056378`，即 flags `0x1` 那一路），再遍历 B 表同样调用，最后把 B 表逐元素析构并把 `end = begin`：

```
100565c7: mov esi,ds:0x101701cc     ; A.begin
100565e2: push [esi+0x1c] ; push [esi+0x18] ; push name
100565e9: call 0x10056378           ; table_hook
100565f1: add esi,0x20
...
10056653: mov ds:0x101701e8,esi     ; B.end = B.begin  → 清空
```

⇒ **"延迟安装"最终就是 `table_hook`**（改运行期 native 哈希表节点 `+0x1C`），与 inline hook 无关。A 表永久保留、每次 flush 全量重放；B 表只在首次 flush 生效。

### 2.3 触发者：IAT hook（VM 初始化期），不是每帧

- 五个 async 入口（`0x1005666C/BB/704/78C/9B1`）首句都调一次性初始化 `0x100564B8`。
- 它把两个 `std::function` 塞进回调 vector：`0x10170200`（japi native 安装 flush）与 `0x101701F4`（async flush），并调 `0x10057661` 装 IAT hook。
- IAT hook 目标：**`Game.dll!Storm.dll` 序号 401** 与 **`War3.exe`/`Game.dll!kernel32!TlsGetValue`**（`0x10047307` = `base::hook::iat`）。
- 派发器 `0x100577B4` 遍历 `0x101701F4` 调用；`0x10057581`（TlsGetValue 替身）用状态机决定时机：**同一线程第 3 次进入时**才派发 `0x10170200`。

### 2.4 隐患

1. A 表每次 flush 重放 → 同一局若 flush 两次，`*old` 会被写成 `new` 自身。
2. `async_unhook` 即使没找到也返回 true（`0x10056804`），返回值不可信。
3. 全程无临界区（只有 SEH 帧），非线程安全。

---

## 三、`hook()` 的位定义与 `flags=0x4` 的真实算法

`hook()` = `0x10056855`（返回成功位掩码），`unhook()` = `0x10056900` 镜像。

| 位 | 分支 | 机制 | 生效时机 | 写 `*old` | 失败判定 |
|---|---|---|---|---|---|
| `0x1` | `table_hook` `0x10056378` | 改 native 哈希表节点 `+0x1C` | 立即 | 是 | 名字不在表 → false |
| `0x2` | `async_hook` `0x1005665D` | 入队 A 表 | VM 就绪后 flush | 否 | **恒 true** |
| `0x4` | `register_hook` `0x100563E9` | 改 game.dll 注册块立即数（见下） | **下次 native 注册** | 是 | 找不到串/引用 → false |
| `0x8` | `async_once_hook` `0x100566AC` | 入队 B 表，**仅当其它位全失败才登记** | 首次 flush 后清空 | 否 | **恒 true**（含坑） |
| `0x100` | `0x1005A019` | 以新地址重建 func_value 插进 `japi_function` map | 立即（`jass::call` 路径） | 否 | 名字不在 japi map → false |

`0x8` 的坑（`0x100568BE`）：

```
100568be: test esi,esi
100568c0: jne  0x100568da        ; 已有别的位成功 → 不登记 once
100568d5: push 8 ; pop esi
100568da: or   esi,0x8           ; 但仍然把 0x8 报成成功
```

即 `hook(name,&old,new,0x9)` 在 `table_hook` 成功时**根本不登记 once 队列**，返回值却含 `0x8`。

### 3.1 `flags=0x4` 的算法（`0x100563E9`）

```
100563fa: push name
100563fd: call 0x1005ABBA        ; war3_searcher 单例（[0] = GetModuleHandleW(L"Game.dll")）
10056404: call 0x10053252        ; search_string_ptr(name)
10056409: test eax,eax ; je fail
1005640d: mov edx,new
10056410: lea ecx,[eax+0x5]      ; ★ found + 5
10056413: call 0x10045D49        ; base::hook::replace_pointer(target=ecx, new)
1005641c: mov [old],eax          ; 返回原 4 字节
```

- `search_string_ptr`（`0x10053227`）先按内容在 game.dll `.rdata/.data` 找到字符串，再在 **game.dll `.text`** 里找 4 字节引用，返回**引用槽地址**；扫描函数 `0x10055B6F` 是 `inc ecx` **逐字节**推进，不按 4 对齐。
- `replace_pointer`（`0x10045D49`，导出 `0x10047489`）**不是 inline hook**：`VirtualProtect` → `ReadProcessMemory`(4B) → `WriteProcessMemory`(4B) → `FlushInstructionCache`，原地替换 4 字节。

`found+5` 的算术闭合——注册块每条 0x14 字节：

```
+0x00 68 <sig imm32>     ; push 签名
+0x05 BA <name imm32>    ; mov edx, 名字        ← found 指向本指令的 imm（条目 +0x6）
+0x0a B9 <impl imm32>    ; mov ecx, 实现地址     ← found+5 = 条目 +0xb  ★ 被改写的就是这里
+0x0f E8 <rel32>         ; call 注册器
```

### 3.2 哪些名字能成功

| 名字 | 结果 | 依据 |
|---|---|---|
| `UnitId` / `CreateTimer` / `GetWidgetX` 等 game.dll native | 成功（前提成立）【推测·强】 | jass.dll 自己用 `get_func_addr(name)` 解析并直接用（`0x10036874` 拿 `UnitId` 后不做 NULL 检查就 `lea esi,[eax+0x13]`） |
| `EXGetUnitAbility` / `EXDclareButtonIcon` 等 japi/EX 名 | **必然失败**【证实】 | 这些串只在 jass.dll 自己的 `.rdata`，而搜索范围是 Game.dll |

危险面：名字有多个引用且首个命中不是注册块时，`replace_pointer` 会把 4 字节静默写进任意指令/数据并返回 true。

---

## 四、`from_string` vs `from_stringid`

`from_string`（`0x10059764`）三重解引用：

```
10059772: mov eax,[eax+0x8]     ; arg->[+8]
10059779: mov eax,[eax+0x1c]    ; ->[+0x1c] = char*
```

【证实】参数是**字符串表项指针**：`表基址 + id*0x10`，表项 `+0x08` 指向串对象、串对象 `+0x1C` 是 `char*`。硬证据是 `newD3d9.dll` 静态导入该符号（IAT `0x9c074`）后**先自己换算**再传：

```
1000bc0c: shl  eax,0x4                 ; id * 0x10
1000bc0f: add  eax,[ecx+0x8]           ; + 表基址
1000bc12: inc  DWORD PTR [eax+0xc]     ; 引用计数 +1
1000bc16: call ds:0x1009c074           ; from_string(表项指针)
```

`from_stringid`（`0x100598C9`）才是接纯 id 的版本：另一张表（4 字节元素），读表项 `+0x14`。两者**不可互换**。`string_fake` 用"自指针"（`[+8]=self`）让双重解引用塌缩成一次，正是为"栈上假表项"服务的。

---

## 五、事件"双映射"：两张不同的表，靠事件名桥接

### 5.1 对照

| 项 | 表 A | 表 B |
|---|---|---|
| 地址 | `0x1016FC88`（就地对象，`_Mysize` 在 `0x1016FC8C`） | `0x1016FBC8`（就地对象，`_Mysize` 在 `0x1016FBCC`） |
| 类型 | `std::map<std::string, std::shared_ptr<patch_record>>` | `std::map<std::string, std::vector<unsigned int>>`（导出名即此） |
| 结点大小 | **0x30**（0x10 + 0x18 key + 0x8） | **0x34**（0x10 + 0x18 key + 0xC） |
| key | hook 名（`InitTriggerHook`/`InitUnitIdHook`/`InitSaveGameHook`/`InitExitMapHook`/`hookPresent`/`hookPresent_short_jmp`） | 事件名（`endGame` / `brokenNetwork`，插件可自定） |
| value | 8B `shared_ptr` → 补丁记录（target/原始字节备份/len/old_prot，0x10B） | 12B `vector`：`begin/end/cap`，元素 = 4B 函数指针（无参） |
| 语义 | **安装账本 / 可回滚补丁表** | **事件总线 / 回调多播表** |
| 对外 | 无导出 | `jass::get_map_event()`（`0x10037E02` 直接 `mov eax,0x1016FBC8; ret`） |

【证实】两张表**没有任何赋值/别名关系**（28 + 18 处引用全在 `.text`，无一条指令同时出现两个地址；全文件字节扫描也没有指针表项）。头结点分配量 0x34 vs 0x30 本身就证伪"同一对象两个视图"。

### 5.2 桥接方式：处理器执行时按事件名查 B

`InitExitMapHook` 挂上的处理器 `0x10036A74`：

```
10036A8C: push 0x1011b35c         ; "endGame"
10036AA1: call 0x10037ead         ; B.find
10036AB5: cmp  edi,ds:0x1016fbc8  ; == _Myhead → 无订阅
10036ABD: mov  esi,[edi+0x28]     ; value.begin()
10036AC8: call eax                ; 逐个回调（无参）
10036AD7: call ds:0x1016e5cc      ; 再调原始目标
```

反向通道只有一个：`0x1004737A` 按 hook 名读 A，返回 `target + len` 作为"补丁续点"，供 D3D stub 跳回原代码（调用点 `0x1003F00E`/`0x1003F047`）。

### 5.3 四件套 `Init*Hook` 实际做了什么

全部由 `jass::InitJass()`（`0x10036F01`）顺序调用：

| 安装体 | 写 A 的 key | 打在哪 | 是否分发 B | 事件名 |
|---|---|---|---|---|
| `InitTriggerHook` `0x10036638` | `InitTriggerHook` | 脚本片函数（特征串 `"Script function timeout!"` 反查），注入 `mov eax,0x100365D7; call eax`（17 字节，首尾按版本 0x1B58 两套） | 否 | — |
| `InitUnitIdHook` `0x10036868` | `InitUnitIdHook` | `UnitId + 0x13` 的 `call rel32` | 否 | — |
| `InitSaveGameHook` `0x1003693A` | `InitSaveGameHook` | 写 `C3 CC CC CC` **把例程直接 ret 掉** | 否 | — |
| `InitExitMapHook` `0x10036AEE` | `InitExitMapHook` | `EndGame` 派生处的 `call rel32` → `0x10036A74` | **是** | `endGame` |
| `InitJass` 尾 | （不入 A） | `CNetEventConnect` 附近 `+0x88` 打 jmp → `0x10036EF6` | **是** | `brokenNetwork` |

**全 DLL 只有 2 个分发点**：`endGame`（4 个订阅者，全是资源清理）与 `brokenNetwork`（1 个）。所以「`get_map_event()["InitUnitIdHook"]` 订阅永远收不到」——A 的 key 从不进入分发。打包内 `lua_engine.dll`/`newD3d9.dll` 也没导入 `get_map_event`，对外 API 实为空挂。

---

## 六、game.dll 侧：fnA = `get_instance`，fnB = `get_gameui`

### 6.1 搜索链复现（订正 02 §3.2）

| 步 | 内容 | 结果 |
|---|---|---|
| A-0 | `search_string("config",7)` | game.dll `0x6F1E9A0A`（`mov edx,"config"` 的立即数；`"config"` 全库仅 1 个 xref） |
| A-1 | 一级 `call rel32` | `0x6F1E9A10` → `0x6F7E2F60` |
| A-2 | 二级 `call rel32` | `0x6F7E2F66` → `0x6F7E0400` |
| A-3 | **`E9` jmp 跳板**（不是 call） | `0x6F7E0400` 是 `E9 FB 0C 00 00` → `0x6F7E1100` |
| A-4 | 三级 `call rel32` | `0x6F7E1108` → **fnA = `0x6F04EFB0`**（RVA 0x4EFB0） |
| B-1 | `search_string("EnableSelect",13)` → `mov 0x5(eax),eax` | game.dll `0x6F1EDF7F` → 立即数 `0x6F1DFFF0` |
| B-2 | 一级 `call rel32` | `0x6F1DFFF8` → **fnB = `0x6F34F3A0`**（RVA 0x34F3A0） |

两处订正：
1. **第 3 级是 `E9` jmp 跳板**，02 说"连续三级 call"不准确。
2. **`next_opcode`（`0x10053430`）是指令长度解码**（`0x10048A07` 解一条指令，`长度==5 && 首字节==0xE8` 才算命中），不是"在 5 字节窗口内找 E8"——那个 5 是**指令长度**参数。
3. `"config"` 只是结构性地标（`0x6F1E99F0` 里 `obj->open(0,1,1,0x493E0,"config")`），与 JASS 环境**无语义关联**。

### 6.2 fnA：`unsigned get_instance(unsigned idx)`

```
6f04efb0: push %esi
6f04efb1: mov  %ecx,%esi            ; idx
6f04efb3: mov  0x6fbb8628,%ecx      ; g_tlsIndex
6f04efb9: call 0x6f158a30           ; TlsGetValue 包装（带 GetLastError==87 校验）
6f04efbe: test %eax,%eax
6f04efc0: je   6f04efc7             ; TLS 空 → 返回 0
6f04efc2: mov  (%eax,%esi,4),%eax   ; return ((void**)base)[idx]
```

- **就是 `war3_searcher::get_instance`**：jass.dll 的包装 `0x1005A99D` 导出名即 `?get_instance@war3_searcher@warcraft3@base@@QAEII@Z`，解析器 `0x1005AB36` 名为 `search_get_instance`。
- 参数是**槽位号**：game.dll 里 411 个调用点，`mov ecx,imm32` 分布 13→293 次、14→44、5→32、0→17。不是版本（版本另有 `search_version`，归一为 0x1B58=7000）。
- **槽表是 per-thread 的**（`TlsAlloc` 在 `0x6F04EFE0`）。在非游戏线程调 `get_instance(5)` 得到 NULL。

### 6.3 `env`（= `get_instance(5)`）字段表

| 偏移 | 类型 | 语义 | 证据 | 置信度 |
|---|---|---|---|---|
| +0x00 | `void**` vtable | 虚表（首项以 `(this,1)` 调） | `0x6F7E2E4E mov (%eax),%edx; push 1; call *(%edx)` | 高 |
| +0x0C | `thread*[]` | JASS 线程栈数组 | `0x6F7E300D mov 0xc(%eax),%eax` | 高 |
| +0x14 | `uint` | 线程数/栈顶计数 | `0x6F7E300A mov 0x14(%eax),%ecx` | 高 |
| +0x18 | HashTable（内联） | native 函数表 | `0x6F7E2FEE lea 0x18(%eax),%ecx` → `0x6F7E5760` | 高 |
| +0x90 | `void**` | VM 指针表（元素带 `+0x2850` 槽号回写） | `0x6F7E1123` / `0x6F7E6DF7` | 高 |

**最强互证**：`0x6F7E5760`（`this = &env->+0x18`）在 game.dll 里独立复现了 02 §3.4 的节点布局——`+0x24` 桶掩码（-1 = 空表）、`+0x1C` 桶数组、每桶 12 字节、首节点在桶内 `+0x8`、节点 `+0x04` = hash、`+0x18` = name，逐字吻合。

### 6.4 fnB：`get_gameui(unsigned create, unsigned reset)` = CGameUI 单例

```
6f34f3c6: mov %edx,%esi                     ; arg2 = reset
6f34f3c8: mov 0x6fbe6350,%eax               ; g_gameui
6f34f3cd: test %eax,%eax ; jne 6f34f407     ; 已存在 → 跳过创建
6f34f3d1: test %ecx,%ecx ; je  6f34f407     ; create==0 → 不创建
6f34f3d5: push 0 ; push 0x1aaf ; push 0x6f98c4f8   ; __FILE__ 尾部 = "CGameUI.cpp"，行 6831
6f34f3e0: push 0x454 ; call 0x6f120628      ; operator new(0x454)
6f34f407: test %esi,%esi ; cmovne edx,ecx   ; reset!=0 → 清空
6f34f410: mov %ecx,0x6fbe6350
```

- 导出名 `?get_gameui@war3_searcher@...@@QAEIII@Z`，解析器 `search_get_gameui`；同族 `is_gaming()` = `get_gameui(0,0) != 0`。
- 返回值是**指针**，`is_gaming` 才压成布尔。
- 它**不是** `EnableSelect` 本身：`EnableSelect` 的实现在 `0x6F1DFFF0`，第一句就是 `call fnB`（`ecx=1, edx=0`），随后 `call 0x6F34EB70`（写 `ui+0x2A0/+0x2A4`）。解析链取的是"处理函数里第一个 `E8` 调用的目标"，属**启发式**定位（本版本成立，暴雪改动前置调用就会漂移）。

### 6.5 与 02 §3.3 的冲突（未定论，如实记录）

- game.dll 自身：`[env->+0x90[i]] + 0x285C`（不调整）。
- jass.dll（版本归一 7000 → 走 `−4` 分支）：等价于未调整指针 `+0x2858`。
- 两者对同一字段差 4 字节。**要么不是同一张表，要么一方在本版本错位**，静态分析无法判定，需运行时读内存验证。
- 附带订正：02 §3.3 说"版本 ≤6074 时再 −4"，方向反了——实测 `version >= 6074` 才 `−4`（`version < 6074` 调整量为 0）。

---

## 七、对 map-inject 的影响

1. **`env` 是 per-thread 的**（`TlsGetValue` 槽表）。任何"在主线程取一次 `jass_vm` 然后跨线程用"的设计都有拿到 NULL 的风险。我们的 `war3_searcher`（`src/src/yd_core/warcraft3/war3_searcher.cpp`）若缓存了 env/VM 指针，必须确认只在游戏线程使用，或在每次使用前重新取。
2. **`hook()` flags `0x4` 应当禁用**：它改的是 game.dll 注册块里的立即数，只在**下一次 native 注册**生效（当前局无效），且首个 4 字节命中不对时会静默写坏 game.dll。要用就先用 `get_func_addr(name)` 验证名字可解析，并自检 `H+5` 处上下文是 `B9 imm32 E8 rel32`。
3. **`async_hook` 是有效机制**（不是兜底死代码）：它把 `table_hook` 推迟到 VM 就绪。若我们也 hook 了 `Game.dll!Storm.dll#401` / `TlsGetValue` 这两个 IAT 槽，会与原版**抢同一个槽**（`replace_pointer` 无条件覆盖，不链式）。
4. **补丁要可回滚**（2026-11-19 已补）：原版 `0x10045C86` 会备份原始字节（target/backup/len/old_prot），析构可还原。我们的侧已加两件等价物——`warcraft3::jass::inline_hook_info` + `inline_hook_uninstall()`（记录 target/stolen/trampoline/原始字节，`inline_hook_install` 的第 3 个参数可选填）与 `base::hook::patch_guard`（备份后写、`restore()`/析构还原、二次 apply 先隐式还原）；`hook_rollback_test.exe` 56 项合同钉住"装→卸→再装"的字节级可逆性。另外按 target 建了钩子登记表：`inline_hook_install` 幂等（同 target+detour 返回已有 trampoline），地图重开时 `Initialize()` 与 `SimulateMapBoot` 都会调 `inline_hook_reassert_all()`——JMP 还在就不动，被引擎改写的按记录重打（原版是靠 `0x1016FC88` 那张账本做同样的事）。
5. **事件名必须与安装名对齐**：原版 `Init*Hook` 名字只活在安装账本里，从不进入事件分发——"文档有、实则永不触发"的静默失败。我们若提供同类语义，要么把安装名同时当事件名分发，要么在文档写死并加测试。
6. **`from_string` 要传表项指针**（`base + id*0x10` 并 `inc [entry+0xC]`），纯 id 用 `from_stringid`；两者不同表、不同偏移，不可互换。误传纯 id 会立刻 AV。

---

## 八、对既有文档的修正清单

| 文档 | 位置 | 原文 | 应改为 |
|---|---|---|---|
| 02 | §3.2 fnA 链 | "连续跟 3 级 call rel32" | 第 3 级是 **`E9` jmp 跳板**；且 `next_opcode` 是**指令长度解码**，不是 5 字节窗口扫描 |
| 02 | §3.3 版本调整 | "版本 ≤6074 时再 −4" | **`version >= 6074` 才 −4**（归一 0x1B58 = 7000 走此分支） |
| 02 | §5 存疑点 4 | 事件双映射关系未证实 | 两张不同的 map（0x30 / 0x34 结点），靠事件名桥接；只有 `endGame`/`brokenNetwork` 会被分发 |
| 02 | §5 存疑点 5 | register_hook 找"名字引用点 +5 做 inline hook" | 是 `replace_pointer` **改 `mov ecx,imm32` 的 4 字节立即数**，下次注册生效 |
| 02 | §5 存疑点 6 | from_string 参数类型存疑 | 参数 = 字符串表项指针（`base + id*0x10`）；`from_stringid` 才接 id |
| 02 | §5 存疑点 7 | async 表只写不读 | 消费点 `0x100565C6`，IAT hook 触发，最终走 `table_hook` |

---

## 九、复现命令（只读）

```bash
# jass.dll
objdump -d -M intel jass.dll > /tmp/jass.dis
grep -n "0x101701cc\|0x101701e4" /tmp/jass.dis        # async 表全部引用
objdump -d -M intel --start-address=0x100563e9 --stop-address=0x10056430 jass.dll  # register_hook
objdump -d -M intel --start-address=0x10045d49 --stop-address=0x10045e00 jass.dll  # replace_pointer
objdump -d -M intel --start-address=0x10059764 --stop-address=0x10059790 jass.dll  # from_string
grep -n "0x1016fc88\|0x1016fbc8" /tmp/jass.dis        # 两张 map 的全部引用
# game.dll（按窗口，不要全量）
objdump -d -M intel --start-address=0x6f04efb0 --stop-address=0x6f04efd0 game.dll   # fnA
objdump -d -M intel --start-address=0x6f34f3a0 --stop-address=0x6f34f420 game.dll   # fnB
objdump -d -M intel --start-address=0x6f1dfff0 --stop-address=0x6f1e0020 game.dll   # EnableSelect 实现
```

# 08 - 用真 1.27a Game.dll 对 06/07 解析算法做 ground truth 验证

Ground truth：`D:\Warcraft III Frozen Throne 1.27a publish\Game.dll`
（13,187,048 字节，2016-03-07）。PE 头解析：**ImageBase = 0x6F000000**；
`.text` RVA 0x1000–0x94E000，`.rdata` 0x94E000–0xB59000，`.data` 0xB59000–0xBFA63C。
方法同前：objdump + 自写 Python PE 工具（`build/re-scratch/gameverify/pe.py`），
全部验证在磁盘文件上静态完成，按 jass.dll 的算法逐步重放。

**总结论：jass.dll 的解析算法在磁盘 game.dll 上逐步重放全部命中有效目标，
常量无需任何修改。运行时 crash 的最终根因不在算法，见 §7。**

---

## 1. LocalOrder / LocalPointOrder / LocalTargetOrder（07 文档 §1）

### 1.1 锚点与 -0x19 回退

模式 `83 E2 01 C1 E6 05 0B F0` 在 .text 中**唯一命中** RVA **0x3AE4F9**
（与运行时 base+0x3AE4F9 一致）。`0x3AE4F9 - 0x19 = 0x3AE4E0`，恰为一条函数头：

```asm
; ---- wrapper#1, game.dll+0x3AE4E0（stdcall，4 个栈参，ret 0x10）----
6f3ae4e0: push   %ebp
6f3ae4e1: mov    %esp,%ebp
6f3ae4e3: mov    0x14(%ebp),%edx
6f3ae4e6: mov    %edx,%eax
6f3ae4e8: mov    0x10(%ebp),%ecx
6f3ae4ec: mov    %edx,%esi
6f3ae4ee: shr    %eax
6f3ae4f0: shr    $0x2,%esi
6f3ae4f3: and    $0x1,%eax
6f3ae4f6: and    $0x1,%esi
6f3ae4f9: and    $0x1,%edx        <- 锚点起始字节在此（match-0x19 = 函数头，指令边界 ✓）
6f3ae4fc: shl    $0x5,%esi
6f3ae4ff: or     %eax,%esi
   ...（从 [ebp+0x10]/[ebp+0x14] 各位打包到 esi）
6f3ae521: mov    0x8(%ebp),%ecx
6f3ae526: mov    0xc(%ebp),%edx
6f3ae529: push   %esi
6f3ae52a: call   0x6f69ffa0       <- call#1
6f3ae531: ret    $0x10
```

**结论：-0x19 精确落在指令边界（函数头）上，常量和锚点均无问题。**
注意 wrapper#1 本身就是 YDWE 旧硬编码 game.dll+0x3AE4E0——它在 1.27a 上其实是
**函数头**（不是"函数中段"），但它是 stdcall 4 参包装器（自己再调内层 fn#1），
按 japi 的 fastcall 约定直接调它会读错栈参——内层 fn#1 才是正确入口（见下）。

### 1.2 4 条 call rel32（指令对齐已用 objdump 逐条确认）

| # | call 指令 RVA | rel32 | target RVA | target 函数头？ | 对应 native |
|---|---|---|---|---|---|
| 1 | 0x3AE52A | 0x2F1A71 | **0x69FFA0** | ✓ 完整 SEH 序言 | LocalOrder |
| 2 | 0x3AE5BF | 0x2F170C | **0x69FCD0** | ✓ 完整 SEH 序言 | LocalPointOrder |
| 3 | 0x3AE655 | 0x2F1746 | 0x69FDA0 | ✓ | （跳过） |
| 4 | 0x3AE6E2 | 0x2F17C9 | **0x69FEB0** | ✓ 完整 SEH 序言 | LocalTargetOrder |

**运行时报告的 call#2=0x65FCD0、call#4=0x65FEB0 是错的**：真值各高 0x40000
（0x69FCD0 / 0x69FEB0）。call#1=0x69FFA0 正确。0x40000 的固定偏差说明是
你们扫描/上报环节的工具 bug（udis86 同步丢失或 VA→RVA 换算用了错误 base），
**不是 jass.dll 算法的问题**——本算法按字节锚点 + 指令级扫描在磁盘上重放
得到的即是上表。

### 1.3 三个 target 的序言与参数使用（调用约定验证）

三者都是"下单报文"构造函数（报文 id 分别为 0xA0010 / 0xA0011 / 0xA0012，
报文 vtable 0x6F986D7C / 0x6F986D88 / 0x6F986D94），结构高度一致：

```asm
; fn#1 0x69FFA0（ret 0x4 —— 被调方清 1 个栈参）
6f69fff5: mov    %ecx,-0x18(%ebp)   ; ecx 存入报文字段（不解引用）
6f69fff8: test   %edx,%edx          ; edx 空值安全：非空才取 [edx+0xC]/[edx+0x10]，否则 -1
6f6a001c: mov    0x8(%ebp),%eax
6f6a001f: mov    %ax,-0x1c(%ebp)    ; 唯一栈参的低 16 位入报文
   ... 提交链（见 1.4） ...
6f6a004f: ret    $0x4

; fn#2 0x69FCD0（ret 0xC —— 清 3 个栈参）
6f69fd25: mov    %ecx,-0x20(%ebp)   ; ecx
6f69fd28: test   %edx,%edx          ; edx 空值安全
6f69fd4c: mov    0x10(%ebp),%eax
6f69fd4f: mov    %ax,-0x24(%ebp)    ; 第 3 栈参低 16 位（flags）
6f69fd53: mov    0x8(%ebp),%eax
6f69fd56: mov    (%eax),%eax        ; 第 1 栈参按 float* 解引用（x）
6f69fd5b: mov    0xc(%ebp),%eax
6f69fd5e: mov    (%eax),%eax        ; 第 2 栈参按 float* 解引用（y）
6f69fd8f: ret    $0xc

; fn#4 0x69FEB0（ret 0x10 —— 清 4 个栈参）
6f69ff05: mov    %ecx,-0x28(%ebp)   ; ecx
6f69ff08: test   %edx,%edx          ; edx 空值安全
6f69ff26: mov    0x14(%ebp),%eax    ; 第 4 栈参低 16 位（flags）
6f69ff2d: mov    0x10(%ebp),%eax    ; 第 3 栈参 = 对象指针（取 [eax+0xC]/[eax+0x10]，空值安全）
6f69ff54: mov    0x8(%ebp),%eax
6f69ff57: mov    (%eax),%eax        ; 第 1 栈参 float*（x）
6f69ff5c: mov    0xc(%ebp),%eax
6f69ff5f: mov    (%eax),%eax        ; 第 2 栈参 float*（y）
6f69ff90: ret    $0x10
```

与 07 文档从 jass.dll handler 还原的约定**逐字吻合**：

| 函数 | 还原签名 | 栈清理 |
|---|---|---|
| fn#1 0x69FFA0 | `(ecx=orderId, edx=目标或0, stack: flags)` | 被调 ret 4 |
| fn#2 0x69FCD0 | `(ecx=orderId, edx=目标或0, stack: float* x, float* y, flags)` | 被调 ret 0xC |
| fn#4 0x69FEB0 | `(ecx=orderId, edx=目标或0, stack: float* x, float* y, void* widgetObj, flags)` | 被调 ret 0x10 |

### 1.4 报文提交链（三个 fn 共用）

```asm
mov    %ecx,0x6fbe4238          ; 游戏状态全局对象（.data，1.27a 有效）
movzwl 0x28(%ecx),%eax          ; <- 若该全局为 NULL，第一条解引用就在这里崩
push   %eax
call   0x6f1c3330               ; -> 某管理器
mov    0x34(%eax),%ecx
push   $0x0
call   0x6f2735e0
lea    %ecx,packet
call   0x6f699f10 / 0x6f69a640 / 0x6f69a1f0   ; 提交报文
```

### 1.5 call#1 调用即崩的原因排查（可执行结论）

target 0x69FFA0 **是函数头、约定匹配**，算法无需改动。崩溃只可能来自调用侧，按嫌疑排序：

1. **栈参个数/清理方式声明错误（最可能）**：fn#1 只接 **1 个**栈参且**被调方清栈**
   （ret 4）。若实现按 jass 层签名 (order, flags) 压了 2 个栈参、或按 cdecl 在调用方
   再清一次栈，esp 偏移 4 字节，返回后即崩。正确声明：ecx=order、edx=0、
   **恰好 1 个栈参 flags、调用方不做栈清理**。fn#2/fn#4 同理（3/4 个栈参，被调自清）。
2. **调用时机/线程**：fn#1 第一条外部依赖就是 `movzwl [*(0x6FBE4238)+0x28]`，
   该游戏状态全局在对局未建立/错误线程下为空 → 崩在 +0x28 解引用。必须在有活的
   本地玩家、游戏主线程上下文中调用。
3. **call#2/#4 目标算错**（0x40000 偏差）：这两个 native 若按错误地址调用必崩；
   与 call#1 无关，但说明你们的扫描实现需要修（见 §5 总表行动项）。

## 2. GetTargetObject（07 文档 §2）

### 2.1 逐步重放

1. .rdata 中子串 `CPreselectUI.cpp` 唯一命中 RVA 0x98E0D6，完整路径
   `D:\BuildServer\3\work-git\warcraft3-repository\War3\Source\UI/CPreselectUI.cpp`，
   回溯到盘符后路径起点 VA = **0x6F98E098**。
2. .text 中模式 `00 00 00 68 <0x6F98E098>` 唯一命中 RVA **0x374F07**
   （即 `push 0x6F98E098` 前有 3 个 00）。
3. `*(match + 0xAA) = 0x6FBE6560` → **.data 有效全局 ✓**；
   对照 `*(match + 0xA6) = 0xB953FFFF`（无效，证实 1.27a 必须用 +0xAA 分支）。
4. 引用该全局的指令（match+0xAA 正落在其操作数上）：

```asm
6f374fb0: mov    $0x6fbe6560,%ecx   ; this = 全局单例（CPreselectUI 管理器）
6f374fb5: mov    %eax,%esi
6f374fb7: call   0x6f26f490
```

### 2.2 结论

- **G = game.dll+0xBE6560（VA 0x6FBE6560）**，jass.dll 算法与 +0xAA 常量**正确**。
- game.dll 侧把 0x6FBE6560 当对象（管理器单例）用；jass.dll 取 `*G`（其首字段）作为
  当前目标对象指针再转 handle——即该单例**首字段 = 当前鼠标指向对象**，与 07 文档一致。
- 置信度：地址 **确定**（磁盘验证）；"首字段=目标对象" **推断**（与 jass.dll 解引用行为互证）。

### 2.3 运行时崩溃排查

解析数学已证正确，崩溃候选：a) 实现的路径串回溯/xref 搜索与 jass.dll 不一致
（注意必须匹配 8 字节模式 `00 00 00 68 <完整路径 VA>`，串 VA 是**盘符起点**不是子串位置）；
b) `*G == 0`（无指向目标时）传入对象→handle 转换的边界行为；c) VA/RVA 换算错误。

## 3. SetUnitAbilityButtonShow（07 文档 §3）

- 锚点 `6A 01 6A 01 50 6A 01 E8` 在 .text 共 5 处命中：0x3A9ED7、0x3AADDD、0x3AD176、
  0x58628E、0x5E87DA；jass.dll 的 0x10055B8F 从头扫描取**第一处 0x3A9ED7**。
- `fn = match + 0x14 + *(match+0x10)`：match+0xF 处确为对齐的 `E8`（rel32 在 +0x10），
  **fn = game.dll+0x46F440**：

```asm
6f46f440: push   %ebp
6f46f441: mov    %esp,%ebp
6f46f443: push   %esi
6f46f444: mov    0x8(%ebp),%esi    ; 读第 1 栈参（abilId）——函数头 ✓
6f46f447: cmp    $0x4e6275,%esi
```

算法与落点均正确（与实测通过一致）。

## 4. 附带验证：06 文档各 native 的最终落点

全部按 jass.dll 原算法（含 ≥7000 分支常量）在磁盘重放：

| native | 关键落点 | 结果 |
|---|---|---|
| ShowConsole UI root（0x10036BE5：模式 `6A 00 68 6E 02 00 00 68` → -0x20 → 跟随 rel32 → +0x112 → 取操作数） | 模式唯一命中 0xA1899；终值 **0x6FBB9D88** | .data ✓ |
| GetChatState（模式 `6A 00 68 B5 05 00 00 68` → rel@[p-0x15] → *(p+rel-0xA)） | 模式唯一命中 0xAF41B；操作数位于 0x153287，指令为 `mov [0x6FBDAA14], esi`（游戏侧**写入**该标志） | 全局 **0x6FBDAA14**，.data ✓ |
| GetFps（模式 `74 12 6A 00 68 D6 00 00` → -0x81 → rel → +0x11 → rel → +0x283 → 取操作数） | 唯一命中 0xED120；终值 **0x6FB66A78**（FPS float 本体，文件初值 0） | .data ✓ |
| ShowFpsText 对象（模式 `6A 00 68 79 03 00 00 68` → rel@[p-0x131] → *(p+rel-0x12B)） | 唯一命中 0x35295B；终值 **0x6FBBA11C** | .data ✓ |
| ShowFpsText 命令函数（xref `"Unknown map name!"` − 0x9F） | 串 0x98D968，xref 唯一 0x35479F；**fn = 0x354700**：`55 8b ec 81 ec 4c 01 00 00 a1 74 a7`（push ebp; mov ebp,esp; sub esp,0x14C; mov eax,[cookie]）——教科书式函数头 ✓ | ✓（对照 -0x98 落函数中段，证实 ≥7000 用 -0x9F） |

**重要实现注意（GetFps）**：jass.dll 的 0x10055B8F 比较的是**完整 8 字节**模式
`74 12 6A 00 68 D6 00 00`；若只匹配前 5 字节 `74 12 6A 00 68`，.text 里有百余个
假命中（首个在 0x26798，按它解算会得到无效地址）。复刻时必须匹配全部 8 字节。

## 5. 总表（结论 → 行动项）

| 项 | ground truth 结论 | 行动项 |
|---|---|---|
| Order 锚点/-0x19 | 唯一命中 0x3AE4F9，-0x19 恰为 wrapper#1 函数头 | 不改 |
| call#1 target | **0x69FFA0**，函数头，约定 (ecx=order, edx=0, stack×1, ret 4) | 不改算法；检查调用声明（**只压 1 个栈参、调用方不清栈**）与调用时机（[0x6FBE4238] 非空的对局内主线程） |
| call#2 target | **0x69FCD0**（运行时误报 0x65FCD0，低 0x40000） | 修扫描实现（指令同步/RVA 换算），用磁盘值做单元测试基准 |
| call#4 target | **0x69FEB0**（运行时误报 0x65FEB0，低 0x40000） | 同上 |
| GetTargetObject G | **0x6FBE6560**，+0xAA 正确 | 不改；核对自己实现里"子串→盘符回溯→8 字节 push 模式"三步 |
| SetUnitAbilityButtonShow fn | **0x46F440**，函数头 | 不改（实测已通过，注意锚点有 5 处、必须取首命中） |
| UI root / ChatState / Fps / FpsText | 0x6FBB9D88 / 0x6FBDAA14 / 0x6FB66A78 / obj 0x6FBBA11C + fn 0x354700 | 不改；GetFps 模式必须全 8 字节匹配 |

置信度：§1–§4 所有 RVA/VA 落点 **确定**（磁盘静态验证）；报文语义
（0xA0010/0xA0011/0xA0012 下单报文、提交链）**确定**（指令级证据）；
"edx=目标对象、ecx=orderId"的参数语义 **强推断**（wrapper 与报文字段互证）；
崩溃根因 §1.5/§2.3 为 **候选列表**（静态分析无法区分，需按行动项在运行时复核）。

### 未能确认项

1. call#1 崩溃的最终根因未在静态下定死（栈清理声明 / 调用时机 / 线程三选一或叠加）；
   建议先核函数指针声明的栈参个数与清理方式，再核 [0x6FBE4238] 在调用时刻的值。
2. 运行时 call#2/#4 各低 0x40000 的具体工具 bug 位置未定位（不在 jass.dll 算法内）。
3. 三个 wrapper（0x3AE4E0 等）在 game.dll 内的原始调用方（谁以 stdcall 调它们）未追踪；
   不影响 japi 复刻（正确入口是内层 fn#1/#2/#4）。
4. 0x6FBE4238（游戏状态单例）的初始化时机未追踪；0x6FBE6560 单例首字段为
   "当前目标对象"是推断，未在运行时核对类型。

## 6. 下单链 +0x28 初始化时机（第 4 轮，针对"调 fn#1 即 AV"实测）

> 2026-07-29 动态复核更正：本节的解引用链、guard 和初始化时机分析仍然成立，
> 但它不是当次可复现 crash 的最终根因。实机中 guard 已全部通过，真正异常是
> `order_enable_debug` 的 fake→fake 无限递归导致栈溢出，见 §7。

实测现象：[0x6FBE4238] 全局非空，但游戏开始后 0.01s / 1.0s 时调 fn#1（RVA 0x69FFA0）
即 AV（异常地址 0x34）。本轮回答：guard 应等什么条件、内置 japi 靠什么时机保证安全。

### 6.1 fn#1 的 +0x28 依赖链与 AV 点定位（指令级证据）

```asm
; fn#1 = game.dll+0x69FFA0（摘关键指令）
6a0013: mov    ecx,[0x6fbe4238]     ; 主游戏状态单例（无 NULL 检查）
6a0023: movzwl 0x28(%ecx),%eax      ; ← 读的是 WORD（槽位索引），不是指针
        push   %eax
        call   0x6f1c3330

; 0x6F1C3330 全文——无边界、无 NULL 检查的内联指针数组查找：
        mov    eax,[ebp+8]          ; eax = idx（来自 +0x28 的 WORD）
        mov    eax,[ecx+eax*4+0x58] ; 数组在 gameObj+0x58，元素为指针
        ret    4

; 回到 fn#1：
6a002f: mov    ecx,[eax+0x34]       ; ← AV 点①：elem==NULL 时异常地址恰为 0x34 ✓
        push   0
        call   0x6f2735e0           ; ecx = [elem+0x34]

; 0x6F2735E0 开头——对 ecx 同样无 NULL 检查：
6f27360b: mov    %ecx,%ebx
6f273610: pushl  0x1ac(%ebx)        ; ← AV 点②：[elem+0x34]==NULL 时异常地址 0x1AC
```

结论：**+0x28 是"当前下单者"槽位的 WORD 索引（不是指针）**；用户报"+0x28 为 NULL"
应理解为索引无效（哨兵）或索引指向的数组元素为 NULL。实测 AV 地址 0x34 与
AV 点①精确吻合，证明崩溃时 `array[idx]` 为 NULL。

### 6.2 +0x28 的语义与全部写入者

数组规模确证：函数 0x280340 内循环 `esi=0..0xB` 逐一 `call 0x6F1C3330(ebx, esi)`
（0x6F280420–0x6F28044E，ebx=[0x6FBE4238] 见 0x6F2803F7）——**+0x58 数组共
0xC=12 项，每玩家槽位一项**，元素含子对象 +0xF0、状态字段 +0x268（此循环置 5）。

+0x28 全部写入者（WORD 级精确扫描 `66 89 /r`、`66 C7 /0`，disp8=0x28 共 8 处，
逐一甄别）：

| 位置 | 写入值 | 对象确证 | 语义 |
|---|---|---|---|
| **0x1BAC05**（构造函数，vtable 0x6F965D58） | **0x10** | 字段布局（+0x2F0 内嵌对象等）与已确证的 game 方法 0x1C7FE0 完全一致 | **构造初值=0x10（16），越界哨兵="无下单者"**；同时 +0x24=0x17AB、+0x2C/+0x30/+0x34=0，内嵌数组计数 0xC（+0xA8/+0x2BC） |
| **0x280500**（函数 0x280340） | cx=玩家 id | **ebx=[0x6FBE4238]（0x6F2803F7），确证** | 槽位同步：本地字节表（0x6F30DB40(0)：模块#0xD 对象 idx*0x304+0x2DC 处字节）匹配时写 **+0x28=本地玩家 id** |
| 0x280604（同函数） | cx | ebx 已 +0x2BC | 写的是 gameObj+**0x2E4**，非 +0x28（甄别排除） |
| 0x2827D1（函数 0x282510） | ax=局部量 | ebx 疑似 game 对象（未确证） | 同类条件槽位写；调用方 0x280B67 |
| **0x1C8324**（函数 0x1C7FE0） | +0x28→+0x2A | **确证**：唯一调用方 0x285055 为 `mov [0x6FBE4238],%ecx; call` | 模态打开：备份当前下单者；同函数还写 **+0x3C8**=0x6F30E9A0() 并发 UI 消息 0x4009007F（回调 0x6F284B10） |
| **0x2BF634**（虚方法 0x2BED30，vtable 0x6F984AAC slot 0xDC） | +0x2A→+0x28 | edi=[0x6FBE4238]，确证 | 模态关闭：恢复下单者；门控 **+0x3C8 != 0** 且 0x6F30F150()（模块#0xD → [[m+0x10]+8] 字节标志 +0xAD8 != 0） |
| 0x6611BB | dword | 带跳转表 0x6F661BF0 的标签流反序列化器 | 读档/录像路径恢复 |
| 0x286FD7 | 栈参 | 独立 setter 小函数 | **无调用方、无 vtable 引用**（死代码或仅虚调） |

+0x28/+0x2A 为"当前/备份"成对字段（读者 0x1E3170 相邻分支分别读二者互证）。

### 6.3 可执行 guard（复刻 fn#1 完整解引用链，四层全查）

```c
uint32_t g    = *(uint32_t*)0x6FBE4238;   // 单例由工厂 0x6F026190(ecx=6) get-or-create
if (!g)                       return FAIL;
uint16_t idx  = *(uint16_t*)(g + 0x28);   // 当前下单者槽位索引
if (idx >= 12)                  return FAIL;  // 构造哨兵 0x10；有效槽位 0..11
uint32_t elem = *(uint32_t*)(g + 0x58 + idx*4);  // 0x6F1C3330 无界/无 NULL 检查
if (!elem)                      return FAIL;  // AV 点①（fn#1 @0x6A002F 读 [elem+0x34]）
uint32_t ctx  = *(uint32_t*)(elem + 0x34);
if (!ctx)                       return FAIL;  // AV 点②（0x6F2735E0 @0x6F273610 读 [ctx+0x1AC]）
// 通过后即可按 fn#1 原序列下报文
```

### 6.4 内置 japi 为什么不做任何检查——安全性来自时机

- jass.dll LocalOrder handler（0x10032D89）全文仅取参转发（07 文档已录），
  **零前置条件**——它不是靠检查，而是靠**只能在对局内被触发**保证安全。
- native 只能从 jass 触发器动作调用；触发器只在对局会话进行中执行。会话槽位
  同步路径（0x280340 家族，由 UI 事件处理器在 0x6F1C5BB0() 非零时调 0x284A74
  触发，随后广播消息 0x4009007F）早已把本地玩家绑定进 +0x28 并填好 +0x58 数组
  （元素状态 +0x268=5）。
- 用户的崩溃是**时机问题而非参数问题**：开局 +0.01s/+1.0s 手动直调时尚在
  槽位绑定完成之前——+0x28 仍为构造哨兵 0x10（越界读到 NULL）或数组元素未填。

### 6.5 +0x28 生命周期时间线（综合 §6.2）

1. **创建**：工厂 0x6F026190 get-or-create → 构造置 +0x28=0x10（"无下单者"哨兵）。
2. **会话/槽位同步**（开局后某时刻， lobby 落定/进入对局时）：0x280340（及疑似
   0x282510）写 +0x28=本地玩家 id，+0x58 十二项元素就绪。← **fn#1 从此刻起安全**
3. **模态 UI 打开**（0x1C7FE0）：+0x28→+0x2A 备份，+0x3C8=同步对象。
4. **模态 UI 关闭**（虚方法 0x2BED30）：+0x3C8!=0 且模块#0xD 标志 → +0x2A→+0x28 恢复。
5. **读档/录像**：反序列化器 0x6611BB 从存档流恢复 +0x28。

置信度：+0x28 为 WORD 槽位索引、数组 12 项、AV 点①②、构造初值 0x10、
写入者 0x280500/0x1C8324/0x2BF634 的对象归属——**确定**（指令级证据）；
0x2827D1 对象归属、0x280340 的确切触发事件——**强推断**；
模块#0xD 与标志 +0xAD8、+0x3C8 对象类型——**未确认**。

### 6.6 未能确认项（本轮新增）

1. 0x280340 的触发事件未定位到具体消息（调用方 0x284A74 在 UI 消息处理器内，
   gate 0x6F1C5BB0 为大型会话状态查询、语义未细分）——即"+0x28 何时变有效"的
   精确时刻未知，只确证它发生在开局之后、下单之前的会话同步阶段。
2. +0x58 数组元素（每玩家指针对象）的分配点未定位，推测同在该会话同步路径。
3. 用户观测"+0x28==0"与构造初值 0x10 不一致：可能读法/字段别名差异，或崩溃时
   idx=0x10 越界读 gameObj+0x98 得 NULL——两种情形 §6.3 guard 均覆盖，不影响结论。
4. 虚方法 0x2BED30（模态关闭恢复）的运行时触发点未追踪（无直接调用者，纯虚派发）。

## 7. 动态收口：debug hook 递归与 LocalPointOrder 的测试边界

### 7.1 crash 的最终根因

给 `LocalOrder` 外层临时加 SEH 和栈回溯后，异常不是 §6 所推测的空上下文 AV，
而是 **0xC00000FD（stack overflow）**。栈帧从注入的 PID DLL RVA 0xF5F0 开始重复，
静态反汇编对应 `order::fake::immediate_order` 的转发调用。

根因是当前精简工程的 `src/src/stubs.cpp` 中 `base::hook::install` 只做函数指针替换：

```cpp
if (old_func) *old_func = (void*)*target;
*target = new_func;
```

它不生成 trampoline。旧代码把 `real::immediate_order` 替换为 `fake::immediate_order` 后，
fake 再调用 real，实际就是 fake 调自己，直到栈溢出；point/target 同理。

最终修复：

1. 用项目中已验证的 `warcraft3::jass::inline_hook_install` 安装三个代码 detour；
2. 把返回的 trampoline 分别保存回 `real::immediate_order/point_order/target_order`；
3. hook 只安装一次，`order_enable_debug(true/false)` 后续只切换日志开关；
4. 删除诊断期 SEH，运行时只保留 §6.3 的提交链 readiness guard。

修复后启用 debug hook 再调用 LocalOrder 不再崩溃。

### 7.2 实机 ABI 与上下文复核

1.27a 实机解析结果与静态 ground truth 一致：

- immediate = game.dll RVA 0x69FFA0
- point = RVA 0x69FCD0
- target = RVA 0x69FEB0

调用时 `[base+0xBE4238]` 的本地槽位 `idx=0`，`elem+0x34` 非空；selection 对象
`+0x1C4` 和 `+0x1E8` 两个链表的 count 均为 1。Point 动态实参也正确：
`order=851986`、坐标与 Lua 侧一致、flags=36。因此函数解析、fast-call 栈布局、
real 桥传参和选中上下文均已排除。

### 7.3 LocalPointOrder 的自动化测试边界

`LocalTargetOrder(attack, target, 36)` 在下一游戏更新后真实进入 attack，已实机通过。
但在 timer 中合成的 `LocalPointOrder(move/blizzard, x, y, flags)` 有以下结果：

- C++ bridge 与 `jass.message.order_point` 直调都安全返回，但单位不进入对应命令；
- 同单位的标准 `IssuePointOrder(move, x, y)` 正常执行，排除单位、地形和所有权；
- flags 0、4、36 结果相同；把当前选中单位对象实验性传入 edx 也无效（已撤回）；
- game.dll 的真实 UI 调用点 0x3C3FFC 会把 0x3C4260 解析出的命令来源对象放入 edx，
  而内置 jass.dll handler 明确固定 edx=0；其 Lua 示例只在真实 `message.hook` 的
  UI 输入上下文中调用 point 路径。

所以当前自动化用例不能把 timer 下 `GetUnitCurrentOrder` 的变化当作原版等价契约。
最终测试对 LocalPointOrder 验证“原版 ABI 安全转发、不崩溃”；LocalTargetOrder 保留
可观测的 attack 语义断言。若后续要求证明 point 的 UI 效果，应在真实消息 hook 中做
交互式输入回放，并捕获 0x3C4260 的命令来源对象，不能用同步 IssuePointOrder 兜底，
否则会破坏 Local* API 的本地性。

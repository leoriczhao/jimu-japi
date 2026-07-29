# 07 - 内置 JAPI（wenhao_plugin）LocalOrder 系 / GetTargetObject / SetUnitAbilityButtonShow 的解析算法与语义

证据来源：`reference/builtin-japi/extracted/jass.dll`（32 位 PE，ImageBase 0x10000000），
方法同 06 文档：objdump 反汇编 + 自写 Python PE 工具（节区换算、字符串/引用/rel32-call 扫描），
未参考既有分析文档。基础设施（searcher 单例 0x1005ABBA、8 字节模式扫描 0x10055B8F、
字符串 xref 0x10053227、注册函数 0x100569FE）见 06 文档 §0，本文只补充新出现的设施。

5 个目标 native 全部在 jass.dll 注册块 A（0x100337E3 起）内找到，无需查 newD3d9.dll。

| 名字 | 字符串 VA | 签名串 VA | 注册点 | handler |
|---|---|---|---|---|
| GetTargetObject | 0x1011B7DC | 0x1011B7D4 `()Hunit` | 0x100338DC | 0x10032D45 |
| LocalOrder | 0x1011B7F4 | 0x1011B7EC `(II)V` | 0x100338F3 | 0x10032D89 |
| LocalPointOrder | 0x1011B808 | 0x1011B800 `(IRRI)V` | 0x1003390A | 0x10032D9C |
| LocalTargetOrder | 0x1011B828 | 0x1011B818 `(IHwidget;I)V` | 0x10033921 | 0x10032DD1 |
| SetUnitAbilityButtonShow | 0x1011B878 | 0x1011B870 `(IIB)V` | 0x10033976 | 0x10032CC7 |

war3map.j 侧语义（`reference/builtin-japi/war3map.j:773-839`）：
`LocalOrder(order, flags)` 本地无目标命令；`LocalPointOrder(order, x, y, flags)` 本地坐标命令；
`LocalTargetOrder(order, widget, flags)` 本地目标命令；`GetTargetObject()` 当前鼠标指向对象
（unit/item/destructable 三 wrapper 共用）；`SetUnitAbilityButtonShow(u, id, show)` 隐藏/显示技能按钮，
"false 即隐藏，隐藏之后无法发布命令，跟玩家禁用相同"。

## 0. 本文新出现的辅助设施

- **0x10053430(start, opcode, len)** — 指令级扫描：内置长度反汇编器（0x10048A07），从 `start`
  逐条指令前进，返回第一条"首字节 == opcode 且指令长度 == len"的指令地址。
  找 `call rel32` = `0x10053430(p, 0xE8, 5)`；找 3 字节移位指令 = `0x10053430(p, 0xC1, 3)`。
- **0x10053295(str)** — 在 game.dll .rdata 中找子串（经 0x100531C4），再向前回溯到 `:`（0x3A）
  之前一个字符，返回完整路径串起始 VA。用于 game.dll 内嵌 assert 路径
  （jass.dll 存的是 `'War3\Source\UI/CPreselectUI.cpp'` 这样的尾部子串）。
- **0x1005ADC8(handle)** — jass handle 整数 → game 对象指针（查 handle 表，校验 `+0xC` 处
  magic `0x2B61676C` 与 `+0x20==0`），失败返回 NULL。
- **0x1005AE1E(objptr)** — game 对象指针 → handle 整数（在 handle 表中反查对象指针）。
- **0x10059C19(name)** / **0x1003658F(argc, arg1..argn, func)** — 按名取 jass 函数指针并
  variadic 调用（cdecl）。LocalTargetOrder 用它回调 jass native `GetWidgetX`/`GetWidgetY`。

---

## 1. LocalOrder / LocalPointOrder / LocalTargetOrder

### 1.1 handler 反汇编全文

```asm
; ---- LocalOrder (II)V, handler 0x10032D89 ----
10032d89: push   %ebp
10032d8a: mov    %esp,%ebp
10032d8c: pushl  0xc(%ebp)              ; flags
10032d8f: mov    0x8(%ebp),%ecx         ; ecx = order
10032d92: xor    %edx,%edx              ; edx = 0（固定）
10032d94: call   *0x1016e5e4            ; g_fnOrderNoTarget
10032d9a: pop    %ebp
10032d9b: ret

; ---- LocalPointOrder (IRRI)V, handler 0x10032D9C ----
10032d9c: push   %ebp
10032d9d: mov    %esp,%ebp
10032d9f: mov    0x10(%ebp),%eax        ; arg3 = y（real，float* 传入）
10032da2: xor    %edx,%edx
10032da4: pushl  0x14(%ebp)             ; flags
10032da7: mov    0x8(%ebp),%ecx         ; ecx = order
10032daa: mov    (%eax),%eax            ; 解引用 y
10032dac: mov    %eax,0x10(%ebp)
10032daf: mov    0xc(%ebp),%eax         ; arg2 = x
10032db2: movss  0x10(%ebp),%xmm0       ; （经由 xmm 的位拷贝，无意  义副作用）
10032db7: movss  %xmm0,0x10(%ebp)
10032dbc: mov    (%eax),%eax            ; 解引用 x
10032dbe: mov    %eax,0xc(%ebp)
10032dc1: lea    0x10(%ebp),%eax
10032dc4: push   %eax                   ; push &y
10032dc5: lea    0xc(%ebp),%eax
10032dc8: push   %eax                   ; push &x
10032dc9: call   *0x1016e5e0            ; g_fnOrderPoint
10032dcf: pop    %ebp
10032dd0: ret

; ---- LocalTargetOrder (IHwidget;I)V, handler 0x10032DD1 ----
10032dd1: push   %ebp
10032dd2: mov    %esp,%ebp
10032dd4: sub    $0xc,%esp
10032dd7: push   $0x1011b43c            ; "GetWidgetY"
10032ddc: call   0x10059c19             ; 取 jass native
10032de1: pop    %ecx
10032de2: push   %eax
10032de3: pushl  0xc(%ebp)              ; widget handle
10032de6: push   $0x2
10032de8: call   0x1003658f             ; GetWidgetY(widget) -> float
10032ded: add    $0xc,%esp
10032df0: mov    %eax,-0x4(%ebp)        ; [ebp-4] = y
10032df3: push   $0x1011b430            ; "GetWidgetX"
10032df8: call   0x10059c19
10032dfd: pop    %ecx
10032dfe: push   %eax
10032dff: pushl  0xc(%ebp)
10032e02: push   $0x2
10032e04: call   0x1003658f             ; GetWidgetX(widget) -> float
10032e09: movss  -0x4(%ebp),%xmm0
10032e0e: add    $0xc,%esp
10032e11: mov    %eax,-0x8(%ebp)        ; [ebp-8] = x
10032e14: movss  %xmm0,-0x4(%ebp)
10032e19: pushl  0xc(%ebp)
10032e1c: call   0x1005adc8             ; widget handle -> game 对象
10032e21: pop    %ecx
10032e22: pushl  0x10(%ebp)             ; flags
10032e25: mov    0x8(%ebp),%ecx         ; ecx = order
10032e28: xor    %edx,%edx
10032e2a: push   %eax                   ; widget 对象指针
10032e2b: lea    -0x4(%ebp),%eax
10032e2e: push   %eax                   ; &y
10032e2f: lea    -0x8(%ebp),%eax
10032e32: push   %eax                   ; &x
10032e33: call   *0x1016e5dc            ; g_fnOrderTarget
10032e39: mov    %ebp,%esp
10032e3b: pop    %ebp
10032e3c: ret
```

### 1.2 运行时解析算法 — resolver 0x10036DBA（重点）

三个函数指针（0x1016E5E4 / 0x1016E5E0 / 0x1016E5DC）由 resolver **0x10036DBA** 一次性解析，
在插件初始化路径（0x10036F7B 处被调，同一 init 函数还建立其他全局）中**提前执行**，
handler 自身无懒初始化守卫。完整反汇编：

```asm
0x10036DBA:
10036dbd: call   0x1005abba             ; searcher（game.dll 扫描器）
10036dc2: cmpl   $0x1b58,0x1c(%eax)     ; build >= 7000 ?
10036dc9: jb     0x10036de7

; ============ 分支 A：build >= 7000（1.27a 走这里）============
10036dcb: mov    0x18(%eax),%edx        ; .text 末
10036dce: mov    0x14(%eax),%ecx        ; .text 始
10036dd1: push   $0xf00b05e6
10036dd6: push   $0xc101e283            ; 8 字节模式:
                                        ;   83 E2 01    and  edx, 1
                                        ;   C1 E6 05    shl  esi, 5
                                        ;   0B F0       or   esi, eax
10036ddb: call   0x10055b8f             ; p = .text 命中地址
10036de2: sub    $0x19,%eax             ; 回退 0x19
10036de5: jmp    0x10036e16             ; 进共享尾部

; ============ 分支 B：build < 7000 ============
10036de7: push   $0x1c
10036de9: push   $0x1012547c            ; "SimpleDestructableNameValue"（长 0x1C）
10036df0: call   0x10053227             ; .text 中引用该串的操作数地址
10036df5: add    $0x4,%eax
; 扫描锚点指令 "C1 E2 05"（shl edx, 5，长度 3）
10036df8: push   $0x3
10036dfa: push   $0xc1
10036dff: push   %eax
10036e00: call   0x10053430             ; 找下一条 [C1] 且长度 3 的指令
10036e05: add    $0x3,%eax
10036e08: mov    $0x5e2,%ecx
10036e10: cmp    %cx,-0x2(%eax)         ; 其后两字节 == E2 05 ?
10036e14: jne    0x10036df8             ; 否则继续扫

; ============ 共享尾部：连续跟随 4 条 call rel32 ============
10036e16: push   $0x5
10036e18: pop    %edi                   ; edi = 5
10036e1a: mov    $0xe8,%esi             ; esi = 0xE8
10036e1f: push   %esi
10036e20: push   %eax
10036e21: call   0x10053430             ; call#1: 5 字节内找 E8（长度5）
10036e29: mov    0x1(%eax),%ecx
10036e2c: add    %edi,%ecx
10036e2e: add    %eax,%ecx              ; target = insn + 5 + rel32
10036e35: mov    %ecx,0x1016e5e4        ; -> g_fnOrderNoTarget (LocalOrder)
10036e30: add    %edi,%eax              ; 越过 call#1
10036e3b: call   0x10053430             ; call#2
10036e43: mov    0x1(%eax),%ecx
10036e48: add    %eax,%ecx              ; （+5 经 edi）
10036e4f: mov    %ecx,0x1016e5e0        ; -> g_fnOrderPoint (LocalPointOrder)
10036e4a: add    %edi,%eax
10036e55: call   0x10053430             ; call#3（找到但跳过不用）
10036e5d: add    %edi,%eax
10036e62: call   0x10053430             ; call#4
10036e6a: mov    0x1(%eax),%ecx
10036e6d: add    %edi,%ecx
10036e6f: add    %ecx,%eax
10036e72: mov    %eax,0x1016e5dc        ; -> g_fnOrderTarget (LocalTargetOrder)
10036e79: ret
```

### 1.3 算法逐步分解（1.27a 路径）

1. 在 game.dll .text 中找 8 字节锚点 `83 E2 01 C1 E6 05 0B F0`
   （`and edx,1 ; shl esi,5 ; or esi,eax` —— 标志位打包代码）。
2. `p = match - 0x19`。
3. 从 p 起用指令级扫描（长度反汇编器，不是裸字节扫）连续定位 `call rel32`（0xE8，长度 5）：
   - **call#1 target → g_fnOrderNoTarget**（LocalOrder 用）
   - **call#2 target → g_fnOrderPoint**（LocalPointOrder 用）
   - call#3 跳过
   - **call#4 target → g_fnOrderTarget**（LocalTargetOrder 用）
   每条 target 均按 `insn_addr + 5 + rel32` 精确计算，无任何硬编码绝对地址。
4. build < 7000 时锚点不同：改为 xref 字符串 `"SimpleDestructableNameValue"`（+4 起）再扫
   `shl edx,5`（`C1 E2 05`，注意与 ≥7000 锚点的 `shl esi,5` 寄存器不同），之后共享同一套
   4-call 跟随逻辑。

### 1.4 调用约定（game.dll 目标函数）

三个目标都是自定义 fastcall 变体（ecx + edx + 栈）：

| 函数 | 签名（还原） |
|---|---|
| fnOrderNoTarget | `(ecx=orderId, edx=0, stack: int flags)` |
| fnOrderPoint | `(ecx=orderId, edx=0, stack: float* x, float* y, int flags)` |
| fnOrderTarget | `(ecx=orderId, edx=0, stack: float* x, float* y, void* widgetObj, int flags)` |

- edx 恒为 0（japi 侧固定传 0，语义未明——可能是保留参数）。
- PointOrder 的 x/y 以 **float 指针** 传入（handler 把 jass real 的位模式放在栈局部再传地址）。
- TargetOrder 的坐标由 handler 回调 jass native `GetWidgetX`/`GetWidgetY` 现取，
  widget 对象经 handle→object 转换（0x1005ADC8）后一并传入。
- 这四个 call 在 game.dll 内相邻出现，属于一组外层 flag 打包 wrapper。后续真
  Game.dll 验证（08 文档 §1.1）确认 0x3AE4E0 是第一个 wrapper 的函数头，并非中段；
  但它是 stdcall 4 栈参函数，不能按 JAPI handler 的 fastcall 约定直接调用。正确入口
  仍是这组 call 的 target。

置信度：解析算法与调用约定 **确定**（反汇编直接可见）；目标函数在 game.dll 中的
具体身份/名字 **推断**；绝对地址 **未验证**（本就要求运行时解析）。

---

## 2. GetTargetObject — handler 0x10032D45（签名 `()Hunit`）

```asm
; ---- handler ----
10032d45: push   $0x4
10032d47: mov    $0x10103557,%eax
10032d4c: call   0x100e1820             ; SEH prolog
10032d51: mov    0x1017184c,%eax        ; 懒初始化守卫
10032d56: test   $0x1,%al
10032d58: jne    0x10032d76
10032d66: call   0x10032cfb             ; resolver（见下）
10032d6f: mov    %eax,0x10171848        ; 缓存 G
10032d76: mov    0x10171848,%eax
10032d7b: pushl  (%eax)                 ; *G = 当前目标对象指针
10032d7d: call   0x1005ae1e             ; 对象 -> handle
10032d82: pop    %ecx
10032d83: call   0x100e17ee
10032d88: ret

; ---- resolver 0x10032CFB ----
10032d03: call   0x1005abba             ; searcher
10032d0a: push   $0x1011b654            ; "War3\Source\UI/CPreselectUI.cpp"
10032d0f: mov    %esi,%ecx
10032d11: call   0x10053295             ; 找子串并回溯到完整路径起点 -> 串 VA
10032d16: mov    0x18(%esi),%edx
10032d19: mov    0x14(%esi),%ecx
10032d1c: push   %eax                   ; 模式高 4 字节 = 完整路径串 VA
10032d1d: push   $0x68000000            ; 模式低 4 字节 = 00 00 00 68
10032d22: call   0x10055b8f             ; 找 "00 00 00 | 68 <pathVA>"
                                        ;   即 push <pathVA>（前有 3 个 00）
10032d27: cmpl   $0x1b58,0x1c(%esi)
10032d30: jae    0x10032d39
10032d32: add    $0xa6,%eax             ; build < 7000
10032d39: add    $0xaa,%eax             ; build >= 7000 (1.27a)
10032d3e: mov    (%eax),%eax            ; G = *(match + 0xAA)
10032d44: ret
```

结论：

- 解析算法：找 CPreselectUI.cpp 路径串 → 找 `push <串 VA>` 代码点 → 1.27a 取
  `*(match + 0xAA)` 得全局地址 G（存入 jass.dll 0x10171848）。
- 返回 `ObjectToHandle(*G)`：*G 是 CPreselectUI 的"当前目标对象"（鼠标指向的
  unit/item/destructable），0x1005AE1E 转 handle 后作为 Hunit 返回（jass 侧
  三个 wrapper GetTargetUnit/GetTargetItem/GetTargetDestructable 共用此 native）。
- 置信度：机制 **确定**；G 的 game.dll 地址 **未验证**；"当前目标=鼠标指向对象"语义
  由字符串（CPreselectUI）与 war3map.j 注释双重佐证。

---

## 3. SetUnitAbilityButtonShow — handler 0x10032CC7（签名 `(IIB)V`）

```asm
; ---- handler ----
10032cc7: push   %ebp
10032cc8: mov    %esp,%ebp
10032cca: push   %ecx
10032ccb: mov    0x8(%ebp),%ecx         ; arg1 = unit handle
10032cce: test   %ecx,%ecx
10032cd0: je     0x10032cf8
10032cd2: mov    0xc(%ebp),%edx         ; arg2 = ability rawcode id
10032cd5: test   %edx,%edx
10032cd7: je     0x10032cf8
10032cd9: sub    $0x10,%esp
10032cdc: call   0x10032c2a             ; resolver+调用（见下）-> 按钮对象
10032ce1: add    $0x10,%esp
10032ce4: test   %eax,%eax
10032ce6: je     0x10032cf8
10032ce8: cmpl   $0x0,(%eax)            ; *(obj) != 0（vtable/首字段校验）
10032ceb: je     0x10032cf8
10032ced: xor    %ecx,%ecx
10032cef: cmp    %cl,0x10(%ebp)
10032cf2: sete   %cl                    ; cl = (arg3 show == 0)
10032cf5: mov    %ecx,0x40(%eax)        ; *(btn + 0x40) = !show
10032cf8: pop    %ecx
10032cf9: pop    %ebp
10032cfa: ret

; ---- 内部函数 0x10032C2A（ecx=unit handle, edx=ability id；自定义 fastcall）----
10032c6d: call   0x1005abba             ; searcher（懒初始化，守卫 0x10171828 bit1）
10032c72: push   $0xe8016a50
10032c77: push   $0x16a016a             ; 8 字节模式:
                                       ;   6A 01  push 1
                                       ;   6A 01  push 1
                                       ;   50     push eax
                                       ;   6A 01  push 1
                                       ;   E8     call ...（锚点，非目标 call）
10032c82: call   0x10055b8f             ; p = 命中地址
10032c89: mov    0x10(%eax),%ecx        ; rel32（p+0xF 处真正目标 call 的位移）
10032c8c: add    $0x14,%eax
10032c8f: add    %ecx,%eax              ; fn = p + 0x14 + rel32
10032c96: mov    %eax,0x10171834        ; 缓存
10032c9b: push   %edi
10032c9c: call   0x1005adc8             ; unit handle -> unit 对象
10032ca2: push   $0x1
10032ca4: push   $0x1
10032ca6: push   $0x1
10032ca8: push   $0x0
10032caa: push   %esi                   ; ability rawcode id
10032cab: xor    %edx,%edx
10032cad: mov    %eax,%ecx              ; ecx = unit 对象
10032caf: call   *0x10171834            ; fn(unitObj, 0, abilId, 0, 1, 1, 1)
```

结论：

- 解析算法（无版本分支，单一模式）：找锚点 `6A 01 6A 01 50 6A 01 E8`，
  目标函数 = `match + 0x14 + *(match+0x10)`（即 match+0xF 处那条 `call rel32` 的 target）。
  缓存于 jass.dll 0x10171834。
- 目标函数签名还原：`(ecx=unitObj, edx=0, stack: int abilId, int 0, int 1, int 1, int 1)`，
  返回一个按钮/技能 UI 对象指针（推断为 game.dll 的"取单位技能按钮"内部函数）。
- handler 语义：**`*(button + 0x40) = (show == 0 ? 1 : 0)`**（写整个 dword）。
  即按钮对象 **+0x40** 是"禁用/隐藏"标志——与 war3map.j 注释"false 即隐藏，隐藏后无法
  发布命令，跟玩家禁用相同"一致（存的是反向值）。
- 防护：unit handle 为 0、abilId 为 0、对象解析失败、或对象首字段为 0 时静默返回。
- 置信度：机制与 +0x40 偏移 **确定**；目标函数身份与 5 个栈参数含义 **推断**；
  game.dll 地址 **未验证**。

---

## 总表

| native | 语义 | 解析算法 / 偏移 | 置信度 |
|---|---|---|---|
| LocalOrder | 本地无目标命令：fn(order, 0, flags) | 锚点 `83 E2 01 C1 E6 05 0B F0`（≥7000）→ -0x19 → 第 1 条 call rel32 target（缓存 0x1016E5E4） | 机制确定；目标身份推断 |
| LocalPointOrder | 本地坐标命令：fn(order, 0, &x, &y, flags) | 同上锚点 → 第 2 条 call target（0x1016E5E0） | 同上 |
| LocalTargetOrder | 本地目标命令：先回调 GetWidgetX/Y 取坐标，fn(order, 0, &x, &y, widgetObj, flags) | 同上锚点 → 跳过第 3 条 → 第 4 条 call target（0x1016E5DC） | 同上 |
| GetTargetObject | 返回当前鼠标指向对象 handle | `push <CPreselectUI.cpp 路径串 VA>` 代码点 +0xAA（≥7000）/ +0xA6（<7000）解引用得全局 G（0x10171848），返回 ObjectToHandle(*G) | 机制确定；G 未验证 |
| SetUnitAbilityButtonShow | 隐藏/显示单位技能按钮（隐藏=禁用） | 锚点 `6A 01 6A 01 50 6A 01 E8` → fn = match+0x14+rel32（0x10171834）；fn(unitObj, 0, abilId, 0, 1, 1, 1) 返回按钮对象，写 `*(btn+0x40) = !show` | 机制/+0x40 确定；参数语义推断 |

### 版本分支表

| 用途 | build < 7000 | build ≥ 7000（1.27a） |
|---|---|---|
| Order 系锚点定位 | xref `"SimpleDestructableNameValue"` +4，扫 `C1 E2 05`（shl edx,5） | 字节模式 `83 E2 01 C1 E6 05 0B F0`（and edx,1; shl esi,5; or esi,eax），-0x19 |
| Order 系 call 跟随 | 共享：4 × `0x10053430(p, 0xE8, 5)`，target = insn+5+rel32，取 #1/#2/#4 | 同左 |
| GetTargetObject 偏移量 | match + 0xA6 | match + 0xAA |
| SetUnitAbilityButtonShow | 无分支 | 无分支 |

### 关于 YDWE 锚点 game.dll+0x3AE4E0 崩溃的说明

内置 japi 不直接调用包含锚点的外层 wrapper，而是解析其内部连续 4 条 `call rel32`
各自的 target（真正的下单入口）。0x3AE4E0 在 1.27a 上虽然是 wrapper 函数头，
却采用 stdcall 4 栈参并负责 flag 打包；按 handler 的 fastcall 约定调用它会读错寄存器/栈参。
复刻时应按 §1.2 的算法做运行时解析（模式 + 指令级 call 扫描 + rel32 跟随），
1.27a 走 ≥7000 分支；最终运行时 crash 根因另见 08 文档 §7。

### 未能确认项

1. 所有 game.dll 内部绝对地址 **未验证**（仓库无 1.27a Game.dll）；三个下单函数、
   取按钮函数、目标对象全局 G 的身份均为推断，实现时必须复刻运行时解析。
2. 下单函数 `edx=0` 的语义未明（japi 恒传 0；可能是保留/默认参数）。
3. SetUnitAbilityButtonShow 目标函数的 5 个栈参数（abilId, 0, 1, 1, 1）含义未全部确认；
   按钮对象 +0x40 写整个 dword 而非字节，字段的确切类型（标志位集或独立 bool dword）未确认。
4. Order 系解析在插件 init（0x10036F7B 的调用者）中**预先执行**，handler 无懒初始化守卫；
   该 init 的完整触发时机（推断为插件加载/游戏就绪回调）未逐一追踪。
5. GetTargetObject 返回的对象类型（unit/item/destructable）jass.dll 不区分，
   由 jass wrapper 按预期类型解释 handle，对象判别逻辑在 game.dll/引擎侧。

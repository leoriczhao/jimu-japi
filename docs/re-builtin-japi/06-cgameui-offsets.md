# 06 - 内置 JAPI（wenhao_plugin）7 个 CGameUI 相关 native 的偏移与语义

证据来源：`reference/builtin-japi/extracted/jass.dll`（32 位 PE，ImageBase 0x10000000），
全部结论由 objdump 反汇编 + 自写 Python（PE 节区 RVA↔文件偏移换算、字符串/引用扫描）得出，
未参考任何既有分析文档。仓库中没有 Game.dll，因此凡涉及 game.dll 内部最终地址的环节
只能还原"解析方法"，不能给出 1.27a 下的绝对地址（文中标注为"推断/未验证"）。

## 0. 公共基础设施

### 0.1 native 注册

注册函数：`0x100569fe(handler, name, signature)`（cdecl，3 参数）。
名字/签名字符串都在 .rdata，注册代码以 `push 签名; push 名字; push handler; call 0x100569fe`
三元组形式成块出现，共两块：

- 块 A：`0x100337e3` 起（含 ShowFpsText / GetFps / GetChatState）
- 块 B：`0x1004f1f3` 起（含 ShowConsole / LittleMap 系列，以及相邻的 BigMap/ConsoleUI 系列）

8 个目标字符串的 VA 与注册点：

| 名字 | 字符串 VA | 签名串 VA | 注册点（push 处） | handler |
|---|---|---|---|---|
| ShowFpsText | 0x1011B738 | 0x1011B384 `(B)V` | 0x10033817 | 0x10032AFA |
| GetFps | 0x1011B748 | 0x1011B744 `()R` | 0x1003382E | 0x10032A54 |
| GetChatState | 0x1011B754 | 0x1011B750 `()B` | 0x10033846 | 0x10032BD1 |
| ShowConsole | 0x101265C8 | 0x1011B384 `(B)V` | 0x1004F1F3 | 0x1004F0DA |
| GetLittleMapX | 0x10126600 | 0x1011B744 `()R` | 0x1004F260 | 0x1004EFDC |
| SetLittleMapX | 0x1012662C | 0x101265D4 `(R)V` | 0x1004F273 | 0x1004EFFE |
| GetLittleMapY | 0x1012661C | 0x1011B744 `()R` | 0x1004F286 | 0x1004F014 |
| SetLittleMapY | 0x1012664C | 0x101265D4 `(R)V` | 0x1004F299 | 0x1004F037 |

块 B 同一批还注册了 `GetBigMapX/Y`、`SetBigMapX/Y`（handler 0x1004EF5D/0x1004EF95/0x1004EF7F/0x1004EFB8）
与 `GetConsoleUIX/Y`、`SetConsoleUIX/Y`（0x1004F05B/0x1004F093/0x1004F07D/0x1004F0B6），
它们与 LittleMap 共用同一套指针全局，下文一并说明。

### 0.2 "searcher" 单例（game.dll 扫描器）— 0x1005ABBA

`0x1005ABBA()` 返回位于 `0x10171930` 的单例对象（首次调用时由 `0x1005A92B` 构造）：

- `+0x00` = `GetModuleHandleW("Game.dll")`
- `+0x04/+0x08` = game.dll `.rdata` 起始/结束 VA
- `+0x0C/+0x10` = `.data` 起始/结束 VA
- `+0x14/+0x18` = `.text` 起始/结束 VA
- `+0x1C` = 游戏 build 号：在 game.dll .rdata 中找 `"Warcraft III (build "`（串 VA 由 0x10126DCC 给出，
  长 0x14），从其 +0x14 起解析十进制数字；若解析结果为 52240(0xCC10) 则钳为 7000。
  全文用阈值 **0x1B58 = 7000** 分新旧两套常量（<7000 = 1.26 及更早；≥7000 = 1.27+，本项目目标 1.27a 走 ≥ 分支）。

辅助函数：

- `0x10055B8F(ecx=.text始, edx=.text末, [esp+4..+0xC]=8字节模式)` — 在 game.dll .text 中线性扫描 8 字节模式，返回命中地址。
  模式全部形如机器码片段，例如 `6A 00 68 xx xx 00 00 68` = `push 0; push imm32; push ...`。
- `0x10053227(this=searcher, 字符串, 长度)` — 先在 .rdata 找字符串，再在 .text 找引用该串 VA 的 4 字节
  （即 `push 串址` 的操作数位置），返回该**操作数的地址**。
- 解析出函数/全局后，各 resolver 按 build 号加/减手工常量微调（±几个字节到几百字节）。

### 0.3 handler 调用约定（japi 层）

- 参数：cdecl；jass boolean → `[ebp+8]` 低字节；jass real → `[ebp+8]` 是 **float 指针**（handler 先 `mov eax,[ebp+8]` 再 `mov eax,[eax]`）。
- 返回：bool/int 直接 eax；real 返回 **float 位模式** 于 eax（`fstps`/`movss` 到局部再 `mov eax`）。

---

## 1. GetChatState ()B — handler 0x10032BD1

注册证据：串 0x1011B754，注册块 0x10033846–0x1003385A。

完整反汇编（handler + 其懒初始化 helper 0x10036E7A）：

```asm
; ---- handler 0x10032BD1 ----
10032bd1: push   $0x4
10032bd3: mov    $0x10103505,%eax
10032bd8: call   0x100e1820              ; SEH prolog
10032bdd: mov    0x10171854,%eax         ; 初始化守卫
10032be2: test   $0x1,%al
10032be4: jne    0x10032bfe
10032be6: or     $0x1,%eax
10032be9: mov    %eax,0x10171854
10032bf2: call   0x10036e7a              ; 解析 game.dll 全局地址
10032bf7: mov    %eax,0x1017182c         ; 缓存: pChatFlag
10032bfe: mov    0x1017182c,%eax
10032c03: mov    (%eax),%eax             ; return *pChatFlag (dword)
10032c05: call   0x100e17ee              ; SEH epilog
10032c0a: ret

; ---- helper 0x10036E7A（仅首次调用）----
10036eb7: call   0x1005abba              ; searcher
10036ebc: push   $0x68000005
10036ec1: push   $0xb568006a             ; 模式: 6A 00 68 B5 05 00 00 68
                                         ;   = push 0; push 0x5B5; push ...
10036ec6: mov    0x18(%eax),%edx
10036ec9: mov    0x14(%eax),%ecx
10036ecc: call   0x10055b8f              ; p = .text 中命中地址
10036ed3: mov    -0x15(%eax),%ecx        ; rel32（p 附近一条 call 的位移）
10036ed6: mov    -0xa(%eax,%ecx,1),%eax  ; eax = *(p + rel32 - 0xA)
10036eda: mov    %eax,0x10171874         ; 缓存
```

结论：

- handler 返回 `*(dword*)pChatFlag`，其中 `pChatFlag` 是从 game.dll 代码中解析出的一个
  **全局变量地址**（模式 `push 0; push 0x5B5` 命中点附近跟随一条 call，在 call 目标内
  固定偏移处取出一个 game.dll .data 地址）。该 dword 非零 = 聊天框打开。
- 置信度：**机制确定**（jass.dll 侧全部还原）；**最终全局的 game.dll 地址未验证**（无 Game.dll 可对照）。
  按代码形状推断：这是 CGameUI 相关的"聊天输入框是否打开"全局标志，读偏移 = 全局自身（+0x00）。

---

## 2. ShowConsole (B)V — handler 0x1004F0DA

注册证据：串 0x101265C8，注册块 0x1004F1F3–0x1004F202。

### 2.1 handler 反汇编

```asm
1004f0da: push   %ebp
1004f0db: mov    %esp,%ebp
1004f0dd: mov    0x8(%ebp),%al           ; 参数 B
1004f0e0: mov    %al,0x1016e824          ; g_consoleVisible = arg
1004f0e5: test   %al,%al
1004f0e7: mov    0x1016e80c,%eax         ; pBigMapPos
1004f0ec: jne    0x1004f110              ; arg!=0 -> 恢复分支
; ---- 隐藏分支 (arg==0) ----
1004f0ee: andl   $0x0,(%eax)             ; BigMap.X = 0.0f
1004f0f1: mov    0x1016e81c,%eax         ; pLittleMapPos
1004f0f6: movl   $0xc0000000,(%eax)      ; LittleMap.X = -2.0f
1004f0fc: movl   $0x40000000,0x4(%eax)   ; LittleMap.Y = +2.0f
1004f103: mov    0x1016e830,%eax         ; pConsoleUIPos
1004f108: movl   $0x40000000,(%eax)      ; ConsoleUI.X = +2.0f
1004f10e: pop    %ebp
1004f10f: ret
; ---- 恢复分支 (arg!=0) ----
1004f110: movss  0x1016e834,%xmm0        ; saved BigMap.X
1004f118: movss  %xmm0,(%eax)
1004f11c: mov    0x1016e81c,%eax
1004f121: movss  0x1016e808,%xmm0        ; saved LittleMap.X
1004f129: movss  %xmm0,(%eax)
1004f12d: movss  0x1016e810,%xmm0        ; saved LittleMap.Y
1004f135: movss  %xmm0,0x4(%eax)
1004f13a: mov    0x1016e830,%eax
1004f13f: movss  0x1016e82c,%xmm0        ; saved ConsoleUI.X
1004f147: movss  %xmm0,(%eax)
1004f14b: mov    0x1016e828,%eax         ; pExtraPos
1004f150: movss  0x1016e818,%xmm0        ; saved *pExtraPos
1004f158: movss  %xmm0,(%eax)
1004f15c: pop    %ebp
1004f15d: ret
```

### 2.2 指针全局的初始化 — 0x1004EE85

该函数在块 A 注册函数内（0x100337BD 处 `push 0x1004ee85`）作为回调交给 `0x100380E2`
（事件注册，推断为"游戏 UI 就绪"类事件），并启动一个看门狗线程：

```asm
1004ee8a: call   0x10036be5              ; A = 解析 game.dll 的 UI 根对象（见 2.3）
1004ee8f: movb   $0x1,0x1016e824         ; g_consoleVisible = true
1004ee96: mov    (%eax),%edx             ; B = *A
1004ee98: mov    0x1c(%edx),%eax         ; C = *(B+0x1C)
1004ee9b: mov    0xc(%eax),%eax          ; D = *(C+0x0C)
1004ee9e: mov    0x1a0(%eax),%edi        ; E = *(D+0x1A0)      <- LittleMap frame
1004eea4: lea    0xf8(%eax),%esi         ; pBigMapPos    = D + 0xF8
1004eeaa: mov    0x374(%edx),%eax        ; F = *(B+0x374)
1004eeb0: add    $0xf8,%edi              ; pLittleMapPos = E + 0xF8
1004eeb6: movss  (%esi),%xmm0
1004eeba: movss  %xmm0,0x1016e834        ; 保存 BigMap.X 原值
1004eec2: mov    %esi,0x1016e80c         ; [0x1016E80C] = pBigMapPos
1004eec8: mov    0x68(%eax),%ecx         ; G = *(F+0x68)       <- ConsoleUI frame
1004eecb: movss  (%edi),%xmm0
1004eecf: add    $0xf8,%ecx              ; pConsoleUIPos = G + 0xF8
1004eed5: mov    0x3f4(%edx),%eax        ; H = *(B+0x3F4)       <- Extra frame
1004eedb: movss  %xmm0,0x1016e808        ; 保存 LittleMap.X 原值
1004eee3: add    $0xf8,%eax              ; pExtraPos = H + 0xF8
1004eee8: movss  0x4(%edi),%xmm0
1004eeed: movss  %xmm0,0x1016e810        ; 保存 LittleMap.Y 原值
1004eef5: movss  (%ecx),%xmm0
1004eef9: movss  %xmm0,0x1016e82c        ; 保存 ConsoleUI.X 原值
1004ef01: movss  (%eax),%xmm0
1004ef05: mov    %eax,0x1016e828         ; [0x1016E828] = pExtraPos
1004ef16: mov    %edi,0x1016e81c         ; [0x1016E81C] = pLittleMapPos
1004ef1c: mov    %ecx,0x1016e830         ; [0x1016E830] = pConsoleUIPos
1004ef22: movss  %xmm0,0x1016e818        ; 保存 *pExtraPos 原值
1004ef2a: mov    %al,0x1016e1ab          ; 线程退出标志 = 0
1004ef2f: call   *0x101091f0             ; CreateThread(0,0,0x1004EE57,0,0,0)
1004ef35: mov    %eax,0x1016e814         ; 线程句柄
```

看门狗线程 0x1004EE57：当 `g_consoleVisible==0`（隐藏状态）时每 1ms 强制
`*pExtraPos = g_scale`（0x1016E820：build<7000 为 0.5f=0x3F000000，≥7000 为 2.0f=0x40000000，
该值在块 B 注册函数 0x1004F1D6–0x1004F1F0 按 build 设置），直到 0x1016E1AB 置 1 退出
（卸载路径 0x1004F15E 置位并 CloseHandle）。说明 Extra frame 的位置每帧被游戏重写，
必须持续回写才能保持隐藏——推断它是底部控制台/命令面板的 frame。

### 2.3 UI 根对象的解析 — 0x10036BE5

```asm
10036bf4: push   $0x68000002
10036bf9: push   $0x6e68006a             ; 模式: 6A 00 68 6E 02 00 00 68
                                         ;   = push 0; push 0x26E; push ...
10036c04: call   0x10055b8f              ; p
10036c09: sub    $0x20,%eax
10036c0e: add    0x1(%eax),%eax          ; 跟随一条 rel32 跳转/call
10036c11: cmpl   $0x1b58,0x1c(%esi)
10036c1a: add    $0x102,%eax             ; build < 7000
10036c21: add    $0x112,%eax             ; build >= 7000  (1.27a 走这里)
10036c26: mov    (%eax),%eax             ; A = *(解析出的全局)
```

### 2.4 结论

- ShowConsole 不调用 game.dll 函数，纯写内存：把三个 UI frame 的位置 float 挪出屏幕
  （LittleMap→(-2.0, 2.0)、ConsoleUI.X→2.0、BigMap.X→0.0），恢复时写回初始化时保存的原值；
  另有看门狗线程在隐藏期间持续强制第 4 个 frame 的位置。
- frame 位置结构 = frame 对象 **+0xF8** 处 `{ float X; float Y; }`（X=+0xF8，Y=+0xFC）。
- 各 frame 的对象链（A = 0x10036BE5 解析的 UI 根）：
  - BigMap frame = `*(*(*(A+0x00)+0x1C)+0x0C)`（记为 D；其位置直接在 D+0xF8）
  - LittleMap frame = `*(D+0x1A0)`
  - ConsoleUI frame = `*(*(A+0x374... )` 即 `*(*(B+0x374)+0x68)`，B=`*A`
  - Extra frame = `*(B+0x3F4)`
- 置信度：jass.dll 侧链路与偏移 **确定**；各 frame 的语义命名 **推断**；
  A 在 game.dll 中的最终地址 **未验证**。

---

## 3. GetFps ()R — handler 0x10032A54

注册证据：串 0x1011B748，注册块 0x1003382E–0x10033843。

```asm
; ---- handler ----
10032a54: push   %ebp
10032a55: mov    %esp,%ebp
10032a57: push   %ecx
10032a58: push   %ecx
10032a59: call   0x1003679e              ; st0 = FPS float
10032a5e: fstps  -0x4(%ebp)
10032a61: mov    -0x4(%ebp),%eax         ; 返回 float 位模式
10032a64: mov    %ebp,%esp
10032a66: pop    %ebp
10032a67: ret

; ---- 0x1003679E（懒初始化后 flds [g_pFps]）----
100367bf: call   0x10036731
100367c4: mov    %eax,0x10171864         ; g_pFps = 解析出的 float*
...
100367d0: flds   (%eax)                  ; return *g_pFps

; ---- resolver 0x10036731 ----
10036740: push   $0xd668
10036745: push   $0x6a1274               ; 模式: 74 12 6A 00 68 D6 00 00
                                         ;   = je +0x12; push 0; push ...
10036750: call   0x10055b8f              ; p
10036763: sub    $0x8c,%ecx              ; build < 7000
1003676b: sub    $0x81,%ecx              ; build >= 7000  (1.27a)
10036771: add    0x1(%ecx),%ecx          ; 跟随 rel32
10036779: add    $0x12,%ecx              ; build < 7000
1003677e: add    $0x11,%ecx              ; build >= 7000
10036781: mov    0x1(%ecx),%eax
10036784: add    %ecx,%eax               ; 再跟随一个 rel32
1003678b: add    $0x211,%eax             ; build < 7000
10036792: add    $0x283,%eax             ; build >= 7000
10036797: mov    (%eax),%eax             ; g_pFps = *(最终地址)
```

结论：

- FPS 值是 game.dll 内的一个 **float**，经两级代码内解析取到其指针（`g_pFps = *(...)`，
  即 game.dll 中某处存放着指向 FPS float 的指针），每次调用读 `*g_pFps`。
- jass.dll 侧机制 **确定**；game.dll 内最终地址 **未验证**。
- 备注：块 B 注册函数把全局 0x1016E820 按 build 设为 0.5f/2.0f，那是 ShowConsole 看门狗
  用的缩放值，与 GetFps 无关。

---

## 4. ShowFpsText (B)V — handler 0x10032AFA

注册证据：串 0x1011B738，注册块 0x10033817–0x10033826。

```asm
; ---- 懒初始化 1（守卫 0x1017183C bit1）：解析"聊天命令执行"函数 ----
10032b22: call   0x1005abba              ; searcher
10032b29: push   $0x12
10032b2b: push   $0x1011b638             ; "Unknown map name!" (17+NUL=0x12)
10032b32: call   0x10053227              ; 找 game.dll .text 中引用该串的位置
10032b37: cmpl   $0x1b58,0x1c(%esi)
10032b40: sub    $0x98,%eax              ; build < 7000
10032b47: sub    $0x9f,%eax              ; build >= 7000  (1.27a)
10032b50: mov    %eax,0x10171838         ; g_fnChatCmd = 串引用点 - 0x9F（函数头）

; ---- 懒初始化 2（bit2）：解析目标对象全局 ----
10032b6d: call   0x1005abba
10032b72: push   $0x68000003
10032b77: push   $0x7968006a             ; 模式: 6A 00 68 79 03 00 00 68
                                         ;   = push 0; push 0x379; push ...
10032b82: call   0x10055b8f              ; p
10032b89: mov    -0x131(%eax),%ecx       ; rel32（p-0x135 附近 call 的位移）
10032b8f: mov    -0x12b(%eax,%ecx,1),%eax ; eax = *(p + rel32 - 0x12B)
10032b9a: mov    %eax,0x10171850         ; g_ppObj（game.dll 全局，内容=对象指针）

; ---- 主体 ----
10032ba6: mov    (%eax),%eax             ; obj = *g_ppObj
10032ba8: mov    (%eax),%eax             ; t0  = *(obj+0x00)
10032baa: mov    0x3cc(%eax),%ecx        ; sub = *(t0+0x3CC)
10032bae: mov    0x8(%ebp),%eax
10032bb1: movzbl %al,%eax
10032bb4: cmp    %eax,0x144(%ecx)        ; 当前 FPS 文本可见标志 == 期望？
10032bba: je     0x10032bcb              ; 相等则不动
10032bbc: pushl  -0x10(%ebp)             ; "/fps"（串 VA 0x1011B64C）
10032bbf: mov    0x10171850,%ecx         ; this = g_ppObj（即保存对象指针的那个全局）
10032bc5: call   *0x10171838             ; g_fnChatCmd(this, "/fps")
```

结论：

- 可见性标志 = `*(byte*)( *(obj + 0x3CC) + 0x144 )`，obj = `*(game.dll 全局)`。
  即 CGameUI **+0x3CC** 处是一个子对象指针（推断为 FPS 统计/显示对象），其 **+0x144** 字节是开关。
  【运行时订正（yd_japi 实测，1.27a）】上文反汇编 snippet 里 `mov (%eax),%eax` 出现两次，
  文档原结论多解引用了一层（`*(vtable+0x3CC)` 读到的是 .rdata 字符串区，实测为 "MapC" ASCII）。
  实测正确链路为 `obj+0x3CC` 直接取子对象；且该 game.dll 全局就是 **CGameUI 单例**
  （与 YDWE `get_gameui(0,0)` 返回值逐字节一致），标志字节随 /fps 命令 0↔1 真实翻转。
- 需要改变状态时不是直接写字节，而是以 `thiscall` 调 game.dll 的聊天斜杠命令处理函数
  （用 `"Unknown map name!"` 的代码引用反定位到函数头，1.27a 为引用点 **-0x9F**），
  参数 = `"/fps"`（串 VA 0x1011B64C）——即模拟玩家输入 /fps 命令。
- 调用时 `ecx = [0x10171850]`：注意传的是**全局变量里保存的那个对象指针**（与读标志路径同源）。
  【实测确认】ecx 传的是 **CGameUI 单例全局的地址**（g_pp_obj 本身，不是 *g_pp_obj），可正常执行。
- 置信度：机制与偏移（+0x3CC、+0x144、-0x9F、"/fps"）**确定且已经 yd_japi 运行时验证**；
  子对象的具体类型名 **推断**。

---

## 5/6. GetLittleMapX/Y ()R、SetLittleMapX/Y (R)V

注册证据：串 0x10126600 / 0x1012661C / 0x1012662C / 0x1012664C，
注册块 0x1004F260–0x1004F2A9。四个 handler 共用一个指针全局 **0x1016E81C = pLittleMapPos**
（初始化见 §2.2：`= *(D+0x1A0) + 0xF8`，D = `*(*(*(A)+0x1C)+0x0C)`）。

```asm
; GetLittleMapX 0x1004EFDC
1004efe0: mov    0x1016e81c,%eax
1004efe5: test   %eax,%eax
1004efe7: jne    0x1004efee
1004efe9: and    %eax,-0x4(%ebp)         ; ptr==NULL -> return 0.0f
1004efee: movss  (%eax),%xmm0            ; X = *pLittleMapPos        (frame+0xF8)
1004eff2: movss  %xmm0,-0x4(%ebp)
1004eff7: mov    -0x4(%ebp),%eax         ; 返回位模式

; SetLittleMapX 0x1004EFFE
1004f001: mov    0x1016e81c,%ecx
1004f007: test   %ecx,%ecx
1004f009: je     0x1004f012
1004f00b: mov    0x8(%ebp),%eax
1004f00e: mov    (%eax),%eax             ; real 参数是 float*
1004f010: mov    %eax,(%ecx)             ; *pLittleMapPos = X

; GetLittleMapY 0x1004F014
1004f026: movss  0x4(%eax),%xmm0         ; Y = *(pLittleMapPos+4)    (frame+0xFC)

; SetLittleMapY 0x1004F037
1004f052: movss  %xmm0,0x4(%ecx)         ; *(pLittleMapPos+4) = Y
```

结论：

- 小地图图像位置 = LittleMap frame 对象 **+0xF8 (X) / +0xFC (Y)** 的两个 float，
  读写在 frame 存活（指针已初始化）时直接生效；指针为 NULL 时 Get 返回 0.0f、Set 静默忽略。
- 偏移 **确定**（+0xF8/+0xFC，经 0x1016E81C 指针）；frame 对象链 `*(D+0x1A0)` 中各节点语义 **推断**。
- 同一套机制：GetBigMapX/Y 用 0x1016E80C（= D+0xF8），GetConsoleUIX/Y 用 0x1016E830。

---

## 总表

| native | 语义 | 偏移 / 全局 | 置信度 |
|---|---|---|---|
| GetChatState | 返回聊天框是否打开 | `*(dword*)g`，g = game.dll 全局（模式 `push 0;push 0x5B5` + call 跟随解析，缓存于 jass.dll 0x1017182C/0x10171874） | 机制确定；g 的绝对地址未验证 |
| ShowConsole | B=0 隐藏：BigMap.X=0、LittleMap=(-2,2)、ConsoleUI.X=2 并启看门狗；B≠0 恢复初始化时保存的原值 | 写 frame+0xF8 系列：pBigMap=D+0xF8(0x1016E80C)、pLittleMap=*(D+0x1A0)+0xF8(0x1016E81C)、pConsoleUI=*(*(B+0x374)+0x68)+0xF8(0x1016E830)、pExtra=*(B+0x3F4)+0xF8(0x1016E828)；原值存 0x1016E808/10/18/2C/34；标志 0x1016E824 | 偏移确定；frame 命名推断 |
| GetFps | 返回 FPS float | `*g_pFps`，g_pFps = 模式 `je+0x12;push 0;push` + 两级 rel32 跟随（1.27a 常量 -0x81/+0x11/+0x283），缓存 0x10171864 | 机制确定；最终地址未验证 |
| ShowFpsText | 读当前 FPS 文本开关，不同则模拟 "/fps" 命令切换 | 标志字节 = `*(*(obj+0x3CC)+0x144)`【运行时订正，非 *(vtable+0x3CC)】，obj=*(game.dll 全局)=CGameUI 单例（模式 `push 0;push 0x379`，缓存 0x10171850）；切换函数 = xref("Unknown map name!")-0x9F（1.27a），缓存 0x10171838，thiscall(this=&单例全局, "/fps") | 确定，已运行时验证 |
| GetLittleMapX | 小地图图像 X | `*(float*)pLittleMapPos` = frame+0xF8 | 确定 |
| SetLittleMapX | 设置小地图图像 X | 写 frame+0xF8（参数为 float*） | 确定 |
| GetLittleMapY | 小地图图像 Y | `*(float*)(pLittleMapPos+4)` = frame+0xFC | 确定 |
| SetLittleMapY | 设置小地图图像 Y | 写 frame+0xFC | 确定 |

### 版本分支说明（1.27a 取 build≥7000 分支）

| 用途 | build<7000 | build≥7000 |
|---|---|---|
| ShowFpsText 命令函数回退量 | -0x98 | -0x9F |
| GetFps 解析常量 | -0x8C / +0x12 / +0x211 | -0x81 / +0x11 / +0x283 |
| UI 根解析回退量 | +0x102 | +0x112 |
| 看门狗缩放值 (0x1016E820) | 0.5f | 2.0f |

### 未能确认项

1. 所有"模式搜索 + rel32 跟随 + 手工常量"解析出的 **game.dll 内部绝对地址** 均未验证
   （仓库无 1.27a Game.dll）；实现时需复刻同样的运行时解析，不能硬编码地址。
2. GetChatState / GetFps / ShowFpsText 三处 rel32 跟随的精确指令边界是按字节布局推断的，
   可能有 ±几字节误差；语义（跟随 call、取出全局地址）不受影响。
3. 各 frame 对象（D、*(D+0x1A0)、*(*(B+0x374)+0x68)、*(B+0x3F4)）在 CGameUI 类体系中的
   确切类型/成员名为推断；0x10036BE5 解析的根对象 A 是否即 CGameUI 本体亦未最终确认。
4. 8 个 native 全部在 jass.dll 内找到注册，无需到 newD3d9.dll（yd_lua_engine）查找。

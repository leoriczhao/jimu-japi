# 02 native hook + 输入回调

> 日期：2026-11-16 ｜ 模块：`jass.common` `jass.hook` `jass.message` ｜ 额外开关：无 ｜ D3D：不需要 ｜ 入口：`war3map.lua`

## 用途

- 演示 map 作者最常用的两件事：**拦截一个已有 native**（改行为、加日志、做兼容），和**在 Lua 里接键盘/鼠标**。
- hook 段是完全自动的（不需要人按键）；输入段只验证回调装上了、能被消息表驱动。

## 怎么跑

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 02

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\02-input-hook `
    -WorkDir build\scratch\ex-02\work `
    -OutFile build\scratch\ex-02\out.w3x

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\02-input-hook -MapName vx-02-input-hook.w3x
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 02] ...
  [PASS] jass.hook / jass.message 已加载
  [PASS] hook 接管 native，并把原实现交给 orig
  [PASS] 重复 hook 同一个 native 会报错
  [PASS] hook 不存在的 native 会报错
  [PASS] message.hook 可安装、可清除
  [PASS] message.keyboard 表可读写
  [PASS] message.mouse 返回世界坐标
  [PASS] 输入回调能被 msg 表调用（无人按键时只证明安装路径）
========================================
 Results: 8 passed, 0 failed, 8 total
========================================
```

- 健康环境 **8 passed / 0 failed / 8 total**。

## 代码要点

- hook 三件套：`hook.hook(name, function(...args, orig) ... end)` 装、回调最后多一个 `orig` 是原实现、`hook.unhook(name)` 摘。
- `orig(...)` 可以按需调用：不调就是完全屏蔽原实现；示例把 `GetPlayerId` 的返回值 +100 再摘钩还原，证明接管和还原都干净。
- 重复 hook 同一个 native 会**报错**（`pcall` 断言）；hook 不存在的 native 也会报错 —— 这两条是排查拼写错误的最快手段。
- 输入：`message.hook = on_message` 装、`= nil` 摘；回调收到 `msg` 表，`msg.type` 是 `key_down`/`key_up`，`msg.code` 是 **WARK 键码**。
- 返回 `false` 表示**吞掉**这个键（游戏收不到），返回 `true` 交给游戏。示例吞 `Q`（`0x51`）。
- `message.keyboard[code]` 是可以自己读写的表（例如做"按住 Shift"状态），不是只读快照；`message.mouse()` 返回世界坐标 `x, y`。

## 三段结构

- **(A) 头注释**：编号 / 用途 / 需要的开关 / 预期日志 / 验证状态。
- **(B) 可粘贴段**：`-- ============ 以下这段可以粘进自己的 war3map.lua ============` 之后是真正的功能代码，
  只有 `require "jass.*"`，不依赖 `lib\`，不跨目录 require。
- **(C) 自检段**：`-- ============ 以下为示例自检，粘到自己地图时可以删掉 ============` 之后是内联的
  `check` / `finish` harness 和 `3.8s` 的收尾 timer。删掉就没有 `Results` 行了。

## 已验证 / 未验证

| 项 | 状态 |
|----|------|
| 文件结构、`Results` 格式（恰好一行、可被 `Results:.*total` 解析） | **已验证**：`tools\verify-examples.ps1` 静态检查通过 |
| 用到的 `jass.*` 模块全部可 `require`、API 调用在仓库内有出处 | **已验证**：逐个符号在 `map\` / `docs\guide\` / `src\` 里检索到 |
| `-MapDir` 打包产出非平凡 w3x | **已验证**：`tools\verify-examples.ps1` 打包通过 |
| 游戏内 `0 failed` 的实跑结果 | **已验证**：2026-11-16 `tools\verify-examples.ps1 -Live` 实机跑出 `Results: 8 passed, 0 failed, 8 total`（DLL `87C83BA1…`，deploy 参数 `-Timeout 120`） |

风险与注意事项：

- **真实按键事件需要真人按**：`msg` 由 Windows 输入经 CGameUI 过滤后派发，Lua 侧没有伪造按键的接口。示例因此只断言"装得上、能处理 msg 表"，不假装收到过按键 —— 最后一项的 message 里就写明了这一点。
- 键码不是 Win32 VK：`Q` 恰好同为 `0x51`，但 `F2` 是 `0x301`（Win32 是 `0x71`）。照搬 Win32 键码表会失效。
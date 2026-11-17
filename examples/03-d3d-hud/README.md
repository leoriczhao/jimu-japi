# 03 D3D HUD：Font / Text / Texture

> 日期：2026-11-16 ｜ 模块：`jass.common` `jass.d3d` ｜ 额外开关：无 ｜ D3D：**需要**（要装 d3d9 proxy） ｜ 入口：`war3map.lua`

## 用途

- 在游戏画面上叠一块 BLP 底板 + 一行会变的文字，用 `0.1s` timer 每帧 `set_text`。
- 这是 D3D 侧"能不能画东西"的最小闭环：字体、文字、贴图三种对象各建一次并读回属性。

## 怎么跑

> **必须先装 d3d9 proxy**（否则 `d3d.is_available()` 永远假）：War3 完全退出后执行 `\.\tools\d3d-proxy.ps1 -Install -War3Dir 'D:\Warcraft III Frozen Throne 1.27a publish'`，要求 `D3DX9_42.dll` 在 War3 目录或 SysWOW64/System32。
> `deploy.ps1` 只在 `-InteractiveD3D` / `-Demo` / `-TestReboot` 模式下自动装 proxy；用 `-MapDir` 跑示例时要自己先装。

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 03

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\03-d3d-hud `
    -WorkDir build\scratch\ex-03\work `
    -OutFile build\scratch\ex-03\out.w3x

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\03-d3d-hud -MapName vx-03-d3d-hud.w3x
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 03] ...
  [PASS] D3D 已就绪（d3d.is_available）
  [PASS] window_size 返回正的客户区尺寸
  [PASS] Font / Text / Texture 都构造成功
  [PASS] Text 属性按构造值读回
  [PASS] Texture 读回构造属性（源 URI 已归一化）
  [PASS] 0.1s timer 反复 set_text 生效
========================================
 Results: 6 passed, 0 failed, 6 total
========================================
```

- 健康环境 **6 passed / 0 failed / 6 total**；proxy 没装时是 **0 passed / 1 failed / 1 total**（只有一条 FAIL，message 里就是上面那两条命令）。

## 代码要点

- `d3d.is_available()` 可能比 Lua 脚本晚就绪，所以用 `0.1s` timer **轮询最多 2s**，而不是加载时判一次就放弃。
- War3 顶栏 + 左上单位面板占掉客户区前 ~110 像素，正文从 `y = 120` 起才不会被盖住；坐标是**客户区像素**，不是世界坐标。
- `z` 小的先画：底板 `z=99`、文字 `z=100`。
- **Font 必须比引用它的 Text 活得久**：销毁顺序是 `Text:destroy()` → `Font:destroy()` → `Texture:destroy()`。先销毁 Font 会返回 `nil, 错误` 并失败。
- `d3d.rgba(r, g, b[, a])` 内部是 ARGB；`Texture.new` 的 `source` 支持 `asset://`（本图 MPQ）和 `game://`（游戏安装目录）两种 URI，文件名统一用正斜杠。

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
| 游戏内 `0 failed` 的实跑结果 | **已验证**：2026-11-16 `tools\verify-examples.ps1 -Live` 实机跑出 `Results: 6 passed, 0 failed, 6 total`（DLL `87C83BA1…`，deploy 参数 `-Timeout 120`） |

风险与注意事项：

- 依赖 proxy 装在游戏目录里 → 若别的会话用 `-Uninstall` 摘掉了 proxy，本示例一定 FAIL（这是最容易被误判成"示例写错"的情况）。
- `d3d.window_size()` 在极端的全屏/缩放环境下可能返回 0 → 示例会把它当失败，属于环境问题。
- 实测结论来自仓库的 D3D 回归（`-InteractiveD3D -Hold` + `tools\drive-interactive-d3d.ps1`：170/170，含 D3D 48 项）；示例本身在 `-Live` 里跑。
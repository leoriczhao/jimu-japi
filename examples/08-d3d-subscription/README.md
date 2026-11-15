# 08 D3D 订阅：点击命中 + 生命周期

> 日期：2026-11-16 ｜ 模块：`jass.common` `jass.d3d` ｜ 额外开关：无 ｜ D3D：**需要**（要装 d3d9 proxy） ｜ 入口：`war3map.lua`

## 用途

- 给 D3D 面板加交互：鼠标进/出/按下/抬起/点击，以及键盘事件。
- 同时演示**订阅管理**：计数、幂等 cancel、销毁对象时订阅自动失效 —— 这是长生命周期 HUD 不泄漏的关键。

## 怎么跑

> 同 03：先 `\.\tools\d3d-proxy.ps1 -Install -War3Dir 'D:\Warcraft III Frozen Throne 1.27a publish'`，War3 必须完全退出后再装（脚本会检查）。
> 输入事件要求 **War3 窗口在前台**（被别的窗口挡住时游戏收不到消息）。

```powershell
# 1) 静态检查 + 打包（不启动游戏）
.\tools\verify-examples.ps1 -Filter 08

# 2) 只打包
.\tools\pack.ps1 -MapDir examples\08-d3d-subscription `
    -WorkDir build\scratch\ex-08\work `
    -OutFile build\scratch\ex-08\out.w3x

# 3) 进游戏，等 Results 行
.\tools\deploy.ps1 -MapDir examples\08-d3d-subscription -MapName vx-08-d3d-subscription.w3x
```

日志在 `C:\ProgramData\japi_debug.txt`；如果那个文件被占用，DLL 会退化成
`C:\ProgramData\japi_debug_<pid>.txt`，两个都要看。

## 预期日志

```text
[example 08] ...
  [PASS] D3D 已就绪（d3d.is_available）
  [PASS] hit_test 面板能被 contains 命中（中心真 / 远处假）
  [PASS] click 订阅已建立并计入 stats().subscriptions
  [PASS] 非法事件名 / 非法回调会抛错
  [PASS] cancel 幂等，取消后计数回落
  [PASS] 模块级 d3d.on("resize") 建立/取消对称
  [PASS] 销毁 Texture 会让它的 owned 订阅失效
========================================
 Results: 7 passed, 0 failed, 7 total
========================================
```

- 健康环境 **7 passed / 0 failed / 7 total**；proxy 没装时是 **0 passed / 1 failed / 1 total**，message 里给出安装命令。

## 代码要点

- `Texture.new{..., hit_test = true}` 之后才有命中测试：`texture:contains(x, y)` 可以自己查，旋转过的纹理也会按旋转算。
- 订阅：`texture:on("click", fn, {button = d3d.mouse.LEFT})` 返回一个订阅对象（userdata）。事件名只有 `enter` / `leave` / `mouse_down` / `mouse_up` / `click` / `key_down` / `key_up`。
- `sub:is_active()` 看是否还在；`sub:cancel()` **幂等**（取消两次都返回真）。
- `d3d.stats().subscriptions` 是当前活订阅数：示例断言"订阅后 == 基线 + 1"、"取消后回到基线"。
- 参数校验会抛错：非法事件名（`"bogus"`）、非函数回调都会抛 —— 用 `pcall` 断言。
- 销毁 `Texture` 会让它 **owned** 的订阅一起失效（不用手动 cancel），计数自动回落。
- 模块级事件也走同一套：`d3d.on("resize", fn)` 返回订阅，可以 cancel。

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
| 游戏内 `0 failed` 的实跑结果 | **已验证**：2026-11-16 `tools\verify-examples.ps1 -Live` 实机跑出 `Results: 7 passed, 0 failed, 7 total`（7/7，DLL `87C83BA1…`）。与另外几个示例**不在同一批**跑完：另一会话占了 war3 单实例锁和共享日志，重跑时被打断，撞车原因见 `examples\README.md` 的「-Live 撞车」一节 |

风险与注意事项：

- **click 事件本身需要真人点**：Lua 侧没有伪造鼠标点击的接口，示例不伪造 —— 只验证"订阅建立 + 命中测试 + 计数 + 失效"这条链路。真人点一下才算端到端。
- `stats().subscriptions` 是**全局**计数：如果地图里还有别的代码在订阅（或别的会话正在跑 D3D 回归），基线的差值断言可能被干扰。示例在同一段同步代码里取基线和增量，正常不会被插队。
- 与 03 一样依赖 proxy 在游戏目录里。
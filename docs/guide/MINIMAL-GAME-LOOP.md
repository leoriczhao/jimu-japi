# 用一个最小闭环开局：波次防守 demo 怎么搭的

这篇是给地图作者看的"从空图到能玩一局"的实战说明，配套代码是
[`map/game/wave.lua`](../../map/game/wave.lua)（游戏循环）和
[`map/game/demo.lua`](../../map/game/demo.lua)（自检）。它同时是 `deploy.ps1 -Demo` 跑的那份切片：
27 条断言，实机全过。

## 1. 目录与职责

| 文件 | 职责 |
|---|---|
| `map/war3map.lua` | 入口。模块 `require`、初始化、把 `game.demo` 拉起来 |
| `map/game/wave.lua` | 游戏本体：世界构建、波次循环、伤害/击杀/计分、技能与 CD、HUD、相机、restart |
| `map/game/demo.lua` | 自检：按时间点驱动同一套入口，最后打印一行 `Results:` |
| `map/lib/scene.lua` | 确定性场景复位（清场 + 建一个 10 级 `Hrif` 火枪手） |
| `tools/drive-demo.ps1` | 真实键鼠驱动：`deploy.ps1 -Demo -Hold` 的会话里送真左键、真 Q、真 R 并截图 |

原则：**游戏代码只调 `jass.common` / `jass.message` / `jass.d3d` 三组公开入口**，不碰 `UnitId`、
hashtable 或手写 spec。这样这份代码换任何一张地图都能直接搬。

## 2. 一局的生命周期

```
wave.setup(true)   -- 建世界：英雄、基地、HUD、0.25s 时钟 timer
   ↓
phase = "prep"     -- 倒计时 prep_first(4s) / 清波后 prep_break(7s)
   ↓
phase = "wave"     -- 生成 N 只怪，全部带 attack 命令冲向基地
   ↓
清完本波 → 还有下一波？回 prep : 结束（victory）
基地血量到 0 → defeat
victory/defeat → 等 R（或 F2）→ wave.restart(true) 重建整局
```

`M.tick(dt)` 由 0.25 秒的 `jass.TimerStart` 周期调用；HUD 刷新、计时、CD 递减都在这里，
不要在输入回调里做重活。

## 3. 输入的三个真相（1.27a 实测，最容易踩）

1. **键盘能进 `message.hook`，鼠标按钮不能。** 1.27a 窗口模式的 CGameUI 分发只送键盘码，
   真实左键只经窗口 `WM_*` 走到 d3d 输入队列。所以**移动交给引擎自带的左键命令**（hook 直接
   `return true` 放行），脚本侧只处理 `Q`/`R`/`F2`。
2. **技能用 `message.order_point`，移动用 `jass.IssuePointOrder`。** 实测 `message.order_point`
   下 `move` 命令会返回 true 但部队不动（`GetUnitCurrentOrder` 恒 0）；而 `blizzard` 走同一路径真的
   会触发 `EVENT_UNIT_SPELL_EFFECT`。两条路各管一件事，别混用。
3. **`message.order_point` 的落点必须在当前镜头里。** 它经相机解析屏幕坐标；把相机锁到英雄后，
   仍按"基地坐标 − 200"取点就会静默失败（返回值照样是 true，法术不落地、蓝不掉）。
   玩家瞄准的本来就是镜头内的东西，所以按 `message.mouse()` 或英雄附近的点来算。

自检里为了确定性保留了 `wave.set_cursor_override(x, y)`：headless 跑的时候把光标钉死，
真实会话里传 `nil` 回到 `message.mouse()`。

## 4. HUD：用 d3d 静态 API 画一行信息

```lua
local d3d = require "jass.d3d"
local font = assert(d3d.Font.new { face = "Arial", height = 17, weight = 700 })
local panel = assert(d3d.Texture.new {
    source = "game://ReplaceableTextures\\CommandButtons\\BTNRifleman.blp",
    x = 12, y = 100, width = 800, height = 240,
    color = d3d.rgba(8, 8, 10, 200), z = 99,
})
local line = assert(d3d.Text.new { font = font, text = "", x = 26, y = 112, z = 100 })
line:set_text("Wave 1/5   time 180s   kills 0   score 0")
```

D3D 层只有一块底板和几行文字。头顶血条不在这里画，见 §5。

布局纪律（第一版就踩过）：面板从 `y=100` 附近往下排，每行 24 px 起步，长文本先算宽度再定面板宽；
`MP` 这种带小数的值容易被截断，字号 17 时一行控制在 ~90 字符内。

## 5. 血条：用引擎原生条，不要自己画

1.27a 社区通行的做法是打开客户端的「始终显示生命条」——注册表
`HKCU\Software\Blizzard Entertainment\Warcraft III\Gameplay` 的 `healthbars = 1`。
引擎随后给屏幕上**每个**单位画原生条：锚在模型的 overhead 附着点，跟随和遮挡都在渲染帧完成，
按归属分色（自己人绿、敌人红），不需要我们做投影、采样或按类型拟合高度。

demo 走这条路线，`map/game/wave.lua` 不创建任何血条纹理；自检会断言 D3D 层只有 1 张底板贴图，
并且相机没有被锁。`tools/deploy.ps1 -Demo` 在启动前把 `healthbars` 置 1，会话结束还原成玩家原来的值
（War3 只在启动时读一次，所以这个开关必须落在启动前，运行中改无效）。

如果地图不能依赖玩家的客户端设置（例如平台赛要求开箱即见），才需要回到自绘 overlay：
`map/lib/camera.lua` 保留了那套世界→屏幕投影；历史实现按模型实测锚点（`hfoo` 88、`hrif` 93、
`hkni` 161、基地 409 世界单位，与原生条中心差 ≤1.4 px），代价是采样滞后和常量兜底。

## 6. 瞄准预览、目标信息与伤害数字

"手感"靠世界坐标 + HUD 文本，不用自己画圈：

```lua
-- 1) 瞄准预览：把游戏自己的圈型特效钉在光标的**世界**坐标上
S.aim_effect = jass.AddSpecialEffect(
    "Abilities\\Spells\\Human\\Blizzard\\BlizzardTarget.mdx", x, y)
-- 2) 目标信息：光标附近最近的怪 → HUD 一行文字（原生血条本来就画在它头上）
-- 3) 伤害数字：CreateTextTag 世界文字，1.1s 生命 + 0.045 向上的速度
```

纪律：

- **特效不会自己缩放**，技能半径就写在 HUD 的 `AIM ... radius 200` 那行里，别指望模型尺寸等于范围。
- **特效路径先用 `jass.storm.has(path)` 验一遍**：1.27a 里 `UI\\Feedback\\PointTarget\\PointTarget.mdx`
  根本不存在，`AddSpecialEffect` 照样返回有效句柄、只是什么都不显示（第一版就是这样静默漏掉的）。
  实测存在的是 `Abilities\\Spells\\Human\\Blizzard\\BlizzardTarget.mdx`。
- **预览只是视觉，状态要落到可断言的数字上**：`wave.float_count()`（伤害数字计数）、
  `wave.base_hits()`、`wave.aim_point()`，headless 才能验证。
- 伤害数字与受击闪白都由 tick 里的"血量下降"触发，脚本伤害和 AI 伤害走同一条路，
  不需要在每次攻击处埋点。
- 瞄准特效走独立的 0.10s timer：0.25s 的游戏 tick 会让准星看起来拖影。

## 7. 相机

```lua
jass.SetCameraPosition(hx, hy) -- 开局把镜头放到英雄身上，仅此一次
```

**不锁相机**。`SetCameraTargetController` 会把视角从玩家手里抢走，滚轮、拖屏、小地图全部失效，
社区地图也普遍不这么做。镜头只在建世界（含 `restart`）时对准英雄一次，之后完全交给玩家；
自检用 `wave.camera_locked()` 钉住这个约定，避免以后又被加回去。

## 8. 自检怎么写才不坑自己

- **只在最后打印一次 `Results: ...`**：`deploy.ps1` 看到这一行就收尾杀游戏，中途打印会让后面的
  断言全部消失，看起来像"卡住"。
- **`after(秒, fn)` 串行时间点**：世界建好（1.5s）→ 世界断言（2.2s）→ 循环断言（2.3s，同步跑）→
  血条归属与伤害数字（2.35s，自己拉一波怪来当靶子）→ 移动（2.5s）→ 移动结果（3.0s）→
  施法（3.0s）→ 法术事件（5.6s，等 `EVENT_UNIT_SPELL_EFFECT`）。
  等"引擎真的做到"的断言必须留时间窗口，断言的是"提交成功"就当场断言。
- **失败也要跑完**：`check()` 用 `pcall` 包住，失败只计数不抛；否则后面的清理和 `Results` 都没了。
- **别写死动态值**：击杀数、得分、血量会随节奏变化，断言用 `>= ` 或拿当前状态拼字符串去比对 HUD。
- **headless 与真人共用同一套入口**：自检注入的 `key_down` 事件表和真实键盘走同一个 `on_message`，
  区别只在光标（`set_cursor_override`）和等待时间。

## 9. 建世界时踩过的两个坑

- `SetUnitState(MAX_LIFE)` 对刚建好的建筑不生效：按 `hcas` → `hkee` → `hhou` 顺序试，
  取第一个建成的，再**读回真实的 max life**（`hcas` = 2500）当作本局基地血量，别假设自己设的值生效。
- 模块表里的 `hud` 必须先由 `setup()` 填好再被别的模块引用：`wave.setup()` 之后才
  `M.hud = S.hud`，`demo.lua` 里也要在 setup 之后重新绑定，否则 upvalue 是 `nil`。

## 10. 怎么跑

```powershell
cd src; .\build.bat          # 只在改了 DLL 时需要

cd ..
.\tools\deploy.ps1 -Demo           # 跑完 27 条断言自动关游戏
.\tools\deploy.ps1 -Demo -Hold     # 自检后留着，供下面这行驱动
.\tools\drive-demo.ps1             # 真左键 + 真 Q + 真 R，截图在 build\demo-live-*.png
```

结果判读：

- `Results: 27 passed, 0 failed, 27 total` + `WAVE DEFENSE SLICE OK` = 自检全过。
- 驱动脚本的日志尾应出现 `[game] Q: cast submitted (cd 6.0s, mana ...)` 和 `[game] restart requested`，
  那是**真实键盘**被同一套 hook 收到的证据。
- 想留一局给玩家：`deploy.ps1 -Demo -NoKill`；要结束会话就 `New-Item build\war3.kill`（`-Hold`
  模式下 deploy 会自己收尾）。

## 11. 已知边界

- 只支持 Warcraft III 1.27a。
- 鼠标按钮不进 `message.hook`（见 §3），要自定义鼠标交互就用 `jass.d3d` 的 Subscription/hit-test。
- 单局内没有"重启 Lua VM"的入口，重开一局是脚本层 `wave.restart()`；换图才会重建 VM。
- demo 的数值（波次血量、CD、蓝耗）是示例配置，`wave.config` 里改。

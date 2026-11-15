# 用一个最小闭环开局：波次防守 demo 怎么搭的

这篇是给地图作者看的"从空图到能玩一局"的实战说明，配套代码是
[`map/game/wave.lua`](../../map/game/wave.lua)（游戏循环）和
[`map/game/demo.lua`](../../map/game/demo.lua)（自检）。它同时是 `deploy.ps1 -Demo` 跑的那份切片：
33 条断言，实机全过。

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

血条是"两张贴图叠着，靠 `set_rect` 改宽度"：

```lua
bar_bg:set_rect(x, y, w, h)                 -- 底
bar:set_rect(x, y, math.floor(w * frac), h) -- 前景，宽度按比例
```

布局纪律（第一版就踩过）：**文字一行、条一行，条不要压在文字上**。面板从 `y=100` 附近往下排，
每行 24 px 起步，长文本先算宽度再定面板宽；`MP` 这种带小数的值容易被截断，字号 17 时
一行控制在 ~90 字符内。

## 5. 每个单位头顶的血条：锚点高度怎么来

War3 只给「当前选中的单位」画血条，所以要让每个单位都有条就得自己画：三张白色 quad 叠起来
（外框 / 轨道 / 填充，`asset://japi-bar-white.blp` 由 `pack.ps1 -Demo` 打进图），每帧把位置挪到单位的投影头上。
难点只有一个：**1.27a 没有模型包围盒查询**，锚点高度只能实测。

实测方法（就是 `build/` 里那套截图 + 彩色尺子脚本）：

1. 注册表 `HKCU\Software\Blizzard Entertainment\Warcraft III\Gameplay` 的 `healthbars` 设 1，
   引擎会给屏幕上**每个**单位画原生条——这就是「官方答案」，量完立刻改回 0（那是用户自己的设置）。
2. 同一帧里，在目标上方叠几根已知世界高度的纯色小方块当尺子，记下各自的像素 y。
3. 世界高度到屏幕 y 是**射影映射** `y = (A*h + B) / (C*h + 1)`，四点最小二乘拟合；
   别用线性拟合，地面点与 110~200 世界单位段外推能差 4 px。
4. 把原生条的中心行反解成世界高度；再拿「我们自己条」的反解做差，抵消矩形取整那 1-2 px 的系统偏差。

结果（写进 `map/game/wave.lua` 的 `BAR_HEAD` / `BAR_HEAD_BY_TYPE`）：`hfoo` 88、`hrif` 93、`hkni` 161、
基地 409 世界单位；同帧对比，我们的条与引擎原生条中心差 ≤1.4 px。

代码侧三条纪律：

- **类型 id 大小写不统一**：引擎报 `Hrif`，表里按小写 fourcc 存。查表时两个方向都归一
  （`id | 0x20202020` 转小写、`id & 0xDFDFDFDF` 转大写），否则英雄会静默回落到按类别的默认高度。
- **锚点 = `camera.ground_z(x, y) + head`**：地形起伏会带着条一起上下，所以 head 永远相对单位脚下量。
- **落在界面上的条就别画**：顶部信息条（`BAR_TOP_MARGIN = 112`）与控制台（`BAR_BOTTOM_FRAC = 0.755`，
  即约 73%~76% 之间那条折中线——左右石板框顶 ~692 px、中间信息板 ~735 px，一个阈值不可能同时贴合）之下的条
  直接丢弃，并用 `wave.bar_skip(kind)` 记下原因，自检里才能区分「故意丢弃」和「根本没生成」。

## 6. 瞄准预览、目标血条与伤害数字

三件"手感"都靠世界坐标 + HUD 文本，不用自己画圈：

```lua
-- 1) 瞄准预览：把游戏自己的圈型特效钉在光标的**世界**坐标上
S.aim_effect = jass.AddSpecialEffect(
    "Abilities\\Spells\\Human\\Blizzard\\BlizzardTarget.mdx", x, y)
-- 2) 目标血条：光标 110 单位内最近的怪 → HUD 一行文字 + 一条 set_rect 血条
-- 3) 伤害数字：CreateTextTag 世界文字，1.1s 生命 + 0.045 向上的速度
```

纪律：

- **特效不会自己缩放**，技能半径就写在 HUD 的 `AIM ... radius 200` 那行里，别指望模型尺寸等于范围。
- **特效路径先用 `jass.storm.has(path)` 验一遍**：1.27a 里 `UI\\Feedback\\PointTarget\\PointTarget.mdx`
  根本不存在，`AddSpecialEffect` 照样返回有效句柄、只是什么都不显示（第一版就是这样静默漏掉的）。
  实测存在的是 `Abilities\\Spells\\Human\\Blizzard\\BlizzardTarget.mdx`。
- **预览只是视觉，状态要落到可断言的数字上**：`wave.float_count()`（伤害数字计数）、
  `wave.base_hits()`、`wave.hovered()`、`wave.aim_point()`，headless 才能验证。
- 伤害数字与受击闪白都由 tick 里的"血量下降"触发，脚本伤害和 AI 伤害走同一条路，
  不需要在每次攻击处埋点。
- 瞄准特效走独立的 0.10s timer：0.25s 的游戏 tick 会让准星看起来拖影。
## 7. 相机

```lua
jass.SetCameraPosition(bx, by)                       -- 开局对准基地
jass.SetCameraTargetController(hero, 0.0, 0.0, false) -- 之后锁定英雄
```

不锁相机的话，英雄一追怪就出画（第一版截图就是这样：HUD 全对，画面里找不到英雄）。
`restart` 会重建英雄，所以锁相机的调用要放在"建世界"的函数里，每次重开都重新锁。

## 8. 自检怎么写才不坑自己

- **只在最后打印一次 `Results: ...`**：`deploy.ps1` 看到这一行就收尾杀游戏，中途打印会让后面的
  断言全部消失，看起来像"卡住"。
- **`after(秒, fn)` 串行时间点**：世界建好（1.5s）→ 世界断言（2.2s）→ 循环断言（2.3s，同步跑）→
  瞄准/目标血条/伤害数字（2.35s，自己拉一波怪来当靶子）→ 移动（2.5s）→ 移动结果（3.0s）→
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
.\tools\deploy.ps1 -Demo           # 跑完 33 条断言自动关游戏
.\tools\deploy.ps1 -Demo -Hold     # 自检后留着，供下面这行驱动
.\tools\drive-demo.ps1             # 真左键 + 真 Q + 真 R，截图在 build\demo-live-*.png
```

结果判读：

- `Results: 33 passed, 0 failed, 33 total` + `WAVE DEFENSE SLICE OK` = 自检全过。
- 驱动脚本的日志尾应出现 `[game] Q: cast submitted (cd 6.0s, mana ...)` 和 `[game] restart requested`，
  那是**真实键盘**被同一套 hook 收到的证据。
- 想留一局给玩家：`deploy.ps1 -Demo -NoKill`；要结束会话就 `New-Item build\war3.kill`（`-Hold`
  模式下 deploy 会自己收尾）。

## 11. 已知边界

- 只支持 Warcraft III 1.27a。
- 鼠标按钮不进 `message.hook`（见 §3），要自定义鼠标交互就用 `jass.d3d` 的 Subscription/hit-test。
- 单局内没有"重启 Lua VM"的入口，重开一局是脚本层 `wave.restart()`；换图才会重建 VM。
- demo 的数值（波次血量、CD、蓝耗）是示例配置，`wave.config` 里改。

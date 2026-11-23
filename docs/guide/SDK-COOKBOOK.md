# WAR3 Lua SDK 配方集（Cookbook）

> **给谁看**：已经按 [SDK-QUICKSTART.md](SDK-QUICKSTART.md) 把地图打包、在游戏里跑出过一次 Results 行的地图作者。
> 每个配方都是自包含的：只用 jass.* 模块 + 标准 JASS native，不依赖 map/ 里的任何工厂代码，可以整段粘进你自己的 war3map.lua。
> 每个配方后面都有一行验证方式，以及一张坑表——那些坑都是本仓库实机踩出来的，不是推测。
> 怎么用：按需要跳读，不要按顺序读；把代码块里标了 `-- 改成你的...` 的常量和名字换掉，就能跑。

| 项目 | 值 |
|---|---|
| 适用游戏版本 | Warcraft III 1.27a（Windows） |
| SDK 版本 | 0.5.0（jass.d3d.version()；钉在 src/src/lua_engine/lua_engine/libs_d3d.cpp:35） |
| 本文档日期 | 2026-11-16 |
| 验证状态 | 配方 1-12 的 API 全部来自已发布的模块源码；配方 1 与 3/4/5/7 的调用形态在实机回归中覆盖（默认套件 Results: 122 passed, 0 failed, 122 total） |
| 参考的实机证据 | docs/STATUS.md（2026-11-16）、map/game/demo.lua（垂直切片 11/11）、map/tests/test_suite.lua |

---

## 0. 所有配方共用的验证循环

每个配方都靠同一个闭环验证：打包 → 部署 → 读日志里的 Results 行。

```powershell
# 1) 确认没有残留的 war3 进程（1.27a 单实例锁：第二个实例起不来，表现为「日志根本不存在」）
Get-Process war3 -ErrorAction SilentlyContinue
# 2) 打包 + 部署 + 启动 + 等结果（deploy.ps1 内部会调 pack.ps1）
.\tools\deploy.ps1 -MapDir build\scratch\hello-sdk -BaseMap build\scratch\hello-sdk\base-map -MapName cookbook -Timeout 180
# 3) 用 UTF-8 读日志，找 Results 行（每次启动前 deploy 会删日志，所以还要看时间戳）
Get-Content C:\ProgramData\japi_debug.txt -Encoding UTF8 | Select-String 'PASS|FAIL|Results:'
```

判据两条：日志里出现 ` Results: N passed, 0 failed, N total`（行首那个空格是格式的一部分，`map/game/demo.lua` 与 `map/tests/test_suite.lua` 都这么打）；且日志文件时间戳晚于本次启动（`tools/deploy.ps1:198` 启动前会删默认日志，「日志里有内容」不等于「这次跑过」）。

---

## 1. 配方：给地图加一段会打印 Results 的自检

**目标**：让地图自己在游戏里跑断言，并把结果打成 `deploy.ps1` 能识别的格式。整套 SDK 的自动化全靠这一行。 **用到**：`jass.common`（`CreateTimer` / `TimerStart` / `DestroyTimer` / `GetLocalPlayer`）与标准 `print`（DLL 把它重定向进日志，见 `src/src/lua_engine/lua_engine/fix_baselib.cpp:18-31`）。

```lua
-- 注意：pack.ps1 内联 require 的正则只匹配「行首（第 0 列）的双引号 require」，
-- 所以下面这行必须顶格写（见 map/war3map.lua:5-7 的注释）。
local jass = require "jass.common"

local pass, fail = 0, 0

-- 与 map/game/demo.lua 的 check() 同构：pcall 包住，绝不因为一条断言炸掉整张图。
local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print(string.format('  [PASS] %s', name))
    else
        fail = fail + 1
        print(string.format('  [FAIL] %s : %s', name, tostring(err)))
    end
end

-- 一次性延迟执行：Lua 函数可以直接当 TimerStart 的 code 参数用，不必套 jass.code()。
-- （map/war3map.lua:102 也是这样直接把 test_mod.run 传进 TimerStart 的。）
local function after(seconds, fn)
    local timer = jass.CreateTimer()
    jass.TimerStart(timer, seconds, false, function()
        jass.DestroyTimer(timer)
        pcall(fn)
    end)
end

local function finish()
    print('========================================')
    -- 这一行的形状是 deploy.ps1 的匹配契约（tools/deploy.ps1:245 匹配 Results 加 total）
    print(string.format(' Results: %d passed, %d failed, %d total', pass, fail, pass + fail))
    print('========================================')
end

-- 不要用 0.01 秒：刚进图时命令提交链还没就绪，1 秒是回归里验证过的安全值。
after(1.0, function()
    print('----------------------------------------')
    print(' my map self check')
    print('----------------------------------------')

    check('本地玩家存在', function()
        local p = jass.GetLocalPlayer()
        assert(p ~= nil, 'GetLocalPlayer() returned nil')
        assert(jass.GetPlayerId(p) >= 0, 'player id out of range')
    end)

    check('jass.call 与 jass.X 等价', function()
        local p = jass.GetLocalPlayer()
        assert(jass.GetPlayerId(p) == jass.call('GetPlayerId', p))
    end)

    finish()
end)
```

**验证方式**：`.\tools\deploy.ps1 -MapDir <你的工程> -MapName <名字>` 跑完后，日志里有 ` Results: 2 passed, 0 failed, 2 total`，并且 deploy 的输出里出现 `  Map packed OK` 和回显的日志尾部。

| 坑 | 说明 |
|---|---|
| require 被静默丢弃 | `tools/pack.ps1` 的打包器（`Bundle-Lua`，第 98-172 行）只匹配行首、双引号的 `require "模块名"`。写成单引号或缩进后写，就不会被内联，游戏里才报模块不存在。 |
| jass.* 不需要你的 lib/ | 12 个 `jass.*` 模块由 DLL 注册成 `package.preload`（`src/src/lua_engine/lua_engine/open_lua_engine.cpp:36-47`），`require` 在运行时命中，不进 MPQ。只有你自己的模块（`lib.util` 之类）才会被打进地图。 |
| 断言失败看不出原因 | `check()` 把 `tostring(err)` 打到 `[FAIL]` 行；如果行里只有 `nil`，说明 `error()` 没带消息，改成 `assert(cond, '为什么')`。 |
| 多条自检互相干扰 | 每个 `check` 都独立 `pcall`，但共享全局状态（选中的单位、相机）。要么所有检查只读，要么在最后一个 `check` 里恢复现场。 |

---

## 2. 配方：定时心跳，以及「开局后多久才能干活」

**目标**：周期性刷新逻辑，并保证首次执行落在「游戏已经真正开局」之后。 **用到**：`jass.CreateTimer` / `jass.TimerStart` / `jass.PauseTimer` / `jass.DestroyTimer`。

```lua
local jass = require "jass.common"

local ticks = 0
local timer = jass.CreateTimer()

-- 周期性回调：第三个参数 true = 循环。回调里不要做重活，也不要 sleep。
jass.TimerStart(timer, 0.10, true, function()
    ticks = ticks + 1
    if ticks == 1 then
        print('[tick] first tick')
    end
    if ticks >= 20 then
        jass.PauseTimer(timer)   -- 先停，下个 tick 再销毁，避免在回调里销毁自己
        jass.DestroyTimer(timer)
        print(string.format('[tick] stopped after %d ticks', ticks))
    end
end)

-- 一次性「开局后 N 秒」动作：1.5 秒是本仓库 demo 用的值（map/game/demo.lua 的 M.run）。
local boot = jass.CreateTimer()
jass.TimerStart(boot, 1.5, false, function()
    jass.DestroyTimer(boot)
    print('[boot] world is ready for gameplay calls')
end)
```

**验证方式**：日志里依次出现 `[tick] first tick`、`[boot] world is ready for gameplay calls`、`[tick] stopped after 20 ticks`（0.1 秒 x 20 = 2 秒，所以 stopped 晚于 boot）。

| 坑 | 说明 |
|---|---|
| 用 0.01 秒想「尽快」 | 进图瞬间命令提交链（`game.dll` 的 `[base+0xBE4238]+0x28`）还没建好，`order_*` 类调用会静默失败。`map/war3map.lua:94-107` 的注释专门写了这件事，回归里用 1.0-1.5 秒。 |
| 在回调里销毁自己 | 官方语义允许，但销毁后再被访问会出错。稳妥写法就是上面的「先 Pause，下个 tick 再 Destroy」。 |
| 回调里 sleep() | 裸 timer 回调不是持久 JASS 线程，`sleep()` 会报 `sleep() must be called from a coroutine` 或 `TriggerSleepAction is not available`。要 sleep 见配方 11。 |
| 回调里抛错静默 | `TimerStart` 回调里的 Lua 错误不会让游戏崩，但会走 `runtime.error_handle`；自检代码里要么 `pcall`，要么装一个 `error_handle`。 |

---

## 3. 配方：把一块 HUD 底板 + 两行文字贴到屏幕上

**目标**：屏幕左侧出现一块半透明底板和两行文字，任何分辨率下都不被 War3 顶栏盖住。 **用到**：`jass.d3d`（`is_available` / `status` / `window_size` / `rgba` / `Font.new` / `Text.new` / `Texture.new` / `stats`）。完整签名见 [D3D-LUA-API.md](D3D-LUA-API.md)。

```lua
local d3d = require "jass.d3d"

local hud = {}

function hud.create()
    if not d3d.is_available() then
        return false, tostring(d3d.status().error or 'proxy unavailable')
    end
    local width, height = d3d.window_size()
    if not width or width <= 0 or not height or height <= 0 then
        return false, 'window size unavailable'
    end

    -- War3 顶栏 + 单位面板占掉前约 110 个客户区像素；demo 用 120 做安全下界。
    -- （map/game/demo.lua 的 hud_create：local top = 120）
    local top = 120

    -- Font 必须比引用它的 Text 活得久：先建 Font，销毁时后销毁 Font。
    hud.font_big = assert(d3d.Font.new({ face = 'Arial', height = 18, weight = 700 }))
    hud.font_small = assert(d3d.Font.new({ face = 'Arial', height = 14, weight = 400 }))

    -- 底板是 Texture：一张纯色贴图也能当矩形用（game:// 指向游戏目录里的 BLP）。
    hud.panel = assert(d3d.Texture.new({
        source = 'game://ReplaceableTextures/CommandButtons/BTNRifleman.blp',
        x = 12, y = top - 12, width = 600, height = 126,
        color = d3d.rgba(8, 8, 8, 190),
        z = 99,
    }))

    hud.title = assert(d3d.Text.new({
        font = hud.font_big, text = 'My SDK Map',
        x = 24, y = top, color = d3d.rgba(255, 230, 120, 255), z = 100,
    }))
    hud.status = assert(d3d.Text.new({
        font = hud.font_small, text = 'booting...',
        x = 24, y = top + 34, color = d3d.rgba(200, 200, 200, 255), z = 100,
    }))

    print(string.format('[hud] client %dx%d, panel y=%d..%d', width, height, top - 12, top + 114))
    return true
end

function hud.destroy()
    -- 销毁顺序：Text 先，Font 后；Texture 独立。全部幂等，重复调用安全。
    for _, key in ipairs({ 'status', 'title', 'panel', 'font_small', 'font_big' }) do
        local obj = hud[key]
        if obj then obj:destroy() end
        hud[key] = nil
    end
end

local ok, err = hud.create()
if not ok then print('[hud] unavailable: ' .. tostring(err)) end
```

**验证方式**：日志里出现 `[hud] client 1024x768, panel y=108..234` 这样的行（数字随分辨率变），并且 `d3d.stats().counts.textures >= 1 and counts.texts >= 2`。

| 坑 | 说明 |
|---|---|
| 以为 d3d 一定可用 | 0.5.0 支持 D3D9 模式下零重启进程内激活，但在 `-opengl` 等模式下仍不可用。`d3d.is_available()` 为 false 时 `status().error` 里是原因；`d3d.version()` 永远返回 0.5.0（它是常量），**不要**用版本来判断可用性。 |
| 坐标从 0 开始贴 | 0..110 这段是 War3 自己的顶栏和单位面板，贴在那儿会被盖住。用 `top = 120` 起步。 |
| Font 提前销毁 | `Text:set_font` 之后 Font 仍须存活；销毁 Font 会让引用它的 Text 进入失效状态，后续调用报 `... is destroyed or belongs to a closed session`。 |
| z 相同就靠创建顺序 | 同一个 z 上，先创建的先画（后者盖前者）。底板给 99、文字给 100 就是靠这个约定。 |
| 换分辨率后位置错乱 | 坐标是客户区像素，不是百分比。要么在 `d3d.on('resize', fn)` 里重排，要么自己按 `window_size()` 换算。 |

---

## 4. 配方：让 HUD 跟着英雄状态每 0.1 秒刷新

**目标**：HUD 上实时显示等级 / 生命 / 魔法，数据来自 JASS native，不是缓存。 **用到**：`jass.GetHeroLevel`、`jass.GetUnitState` + `jass.ConvertUnitState`、`jass.d3d` 的 `Text:set_text`。

```lua
local jass = require "jass.common"
local d3d = require "jass.d3d"

-- 读取单位状态要 pcall：单位已死/句柄失效时 native 会抛错。
local function state_value(unit, index)
    local ok, value = pcall(jass.GetUnitState, unit, jass.ConvertUnitState(index))
    if ok and type(value) == 'number' then return value end
    return 0.0
end

-- 占位：换成你自己的单位（这里取玩家 1 的第一个单位）。
local function first_unit_of_player(player_id)
    local group = jass.CreateGroup()
    jass.GroupEnumUnitsOfPlayer(group, jass.Player(player_id), nil)
    local unit = jass.FirstOfGroup(group)
    jass.DestroyGroup(group)
    return unit
end

local hero = first_unit_of_player(0)
if hero == nil then
    print('[hud] no unit to watch yet')
    return
end

local font = assert(d3d.Font.new({ face = 'Arial', height = 16, weight = 700 }))
local label = assert(d3d.Text.new({
    font = font, text = '',
    x = 24, y = 200, color = d3d.rgba(255, 230, 120, 255), z = 100,
}))

local timer = jass.CreateTimer()
jass.TimerStart(timer, 0.10, true, function()
    -- 0 = 生命，1 = 魔法上限，2 = 魔法，3 = 护甲（ConvertUnitState 的下标，见 JASS 手册 UNIT_STATE_*）
    label:set_text(string.format('Lv %d   HP %.0f/%.0f   MP %.0f/%.0f',
        jass.GetHeroLevel(hero),
        state_value(hero, 0), state_value(hero, 1),
        state_value(hero, 2), state_value(hero, 3)))
end)
```

**验证方式**：进入游戏后 HUD 出现 `Lv 10   HP ...`；在自检里断言 `label:get_text():find('Lv 10', 1, true) ~= nil`（`map/game/demo.lua` 的 HUD 检查就是这么写的）。

| 坑 | 说明 |
|---|---|
| 每帧重建 Text | 只 `set_text`，不要 `d3d.Text.new`。每帧新建对象会让 `d3d.stats().counts.texts` 一路涨，最终触发资源清理与闪烁。 |
| 直接调 GetUnitState 崩脚本 | 单位死亡后句柄仍存在但状态读取可能失败，必须 `pcall`（`map/game/demo.lua` 的 `state_value`）。 |
| 用 %d 打浮点 | `GetUnitState` 返回 real，`string.format('%.0f')` 才不会变形；等级用 `GetHeroLevel` 返回 integer。 |
| 0.1 秒太密 | 单次刷新只读 4 个 native + 一次 `set_text`，实测无压力；但不要把 SLK 查询或 `GroupEnum` 放进这个回调。 |

---

## 5. 配方：用一个热键开关面板，并吞掉这个键

**目标**：按 F2 显示/隐藏 HUD，且这个键不再传给游戏（不会误触技能）。 **用到**：`jass.message` 的 `hook`（安装输入过滤器）、`jass.d3d` 的 `Text:set_visible`。回调返回 `false` = 吞掉按键，返回 `true` = 交还游戏。

```lua
local jass = require "jass.common"
local d3d = require "jass.d3d"
local message = require "jass.message"

-- WARK 键码，不是 Win32 VK 码（map/game/demo.lua:22-23 的注释：WARK_F2 不是 VK_F2）
local KEY_F2 = 0x301

local font = assert(d3d.Font.new({ face = 'Arial', height = 16, weight = 700 }))
local panel = assert(d3d.Text.new({
    font = font, text = 'panel visible (F2 toggles)',
    x = 24, y = 240, color = d3d.rgba(120, 230, 255, 255), z = 100,
}))

local visible = true
local f2_held = false

-- 赋值 message.hook 即安装过滤器；赋 nil 卸载。回调收到一张表（不是多个参数）。
message.hook = function(msg)
    if msg.type == 'key_down' and msg.code == KEY_F2 then
        if not f2_held then
            f2_held = true
            visible = not visible
            panel:set_visible(visible)
            print(string.format('[panel] visible = %s', tostring(visible)))
        end
        return false          -- 吞掉：游戏收不到这个键
    end
    if msg.type == 'key_up' and msg.code == KEY_F2 then
        f2_held = false
        return false
    end
    return true               -- 其它键照常交给游戏
end

-- 卸载：message.hook = nil
```

**验证方式**：游戏里按 F2，日志出现两行 `[panel] visible = false` / `= true`，面板真的消失/出现，并且英雄不会因为这个键放技能。

| 坑 | 说明 |
|---|---|
| 窗口不在前台 | 输入过滤器挂在游戏的消息分发上，窗口失焦时收不到任何按键——这是环境限制，不是 bug。测试时点一下游戏窗口。 |
| 返回 nil 以为「没处理」 | `nil` 等价于 false，等于吞掉。**必须显式 `return true`** 才是放行（`libs_message.cpp` 的 filter 开头就写着 `return true` 表示 pass through）。 |
| key_down 重复触发 | 按住 F2 会连续触发 `key_down`，必须自己用 `held` 标志去重（`map/game/demo.lua` 的 `q_held`）。 |
| 用 message.keyboard[0x41] 当状态表 | 那张表反映的是 DLL 认为的按键状态，可以用 `pairs` 读，但不要当成实时输入源；实时输入走 `message.hook` 回调。 |
| 卸载后还以为在拦 | `message.hook = nil` 立刻恢复放行；重复赋值会替换而不是叠加，多个面板要自己合成一个分发函数。 |

---

## 6. 配方：读鼠标位置，以及判断鼠标停在命令卡哪一格

**目标**：拿到鼠标的世界坐标；并能判断光标当前悬停在命令卡（0..3 列 x 0..2 行）的哪一格、那一格对应什么技能。 **用到**：`jass.message` 的 `mouse()`（世界坐标）、`mouse_screen()`（归一化 0..1）、`button(x, y)`。

```lua
local message = require "jass.message"

-- 世界坐标：返回两个 number。光标在窗口外时可能一个都不返回，所以用 pcall + 判空。
local ok, wx, wy = pcall(message.mouse)
if ok and wx and wy then
    print(string.format('[mouse] world %.1f, %.1f', wx, wy))
end

-- 归一化屏幕坐标（0..1），适合做分辨率无关的 UI 命中判定。
local ok2, sx, sy = pcall(message.mouse_screen)
if ok2 and sx and sy then
    print(string.format('[mouse] screen %.3f, %.3f', sx, sy))
end

-- 命令卡：x = 0..3（列），y = 0..2（行），越界返回 0 个值。
-- 返回 ability_id, order_id, target_type；空格子上没有技能时返回 nil。
for row = 0, 2 do
    local line = {}
    for col = 0, 3 do
        local ok3, ability_id, order_id = pcall(message.button, col, row)
        if ok3 and ability_id then
            line[#line + 1] = string.format('[%d,%d]=%08X', col, row, ability_id)
        end
    end
    if #line > 0 then print('[buttons] ' .. table.concat(line, ' ')) end
end
```

**验证方式**：进入游戏后日志里出现世界坐标行；把鼠标移到自己英雄的命令卡上再跑一次，`[buttons]` 行里出现一个非零的 `ability_id`（`map/tests/test_suite.lua` 的 message 段对 12 个格子逐个断言过「number 或 nil」）。

| 坑 | 说明 |
|---|---|
| 世界坐标不是屏幕坐标 | `mouse()` 给的是地图世界坐标（内部走了 4:3 黑边补偿 + `convert_xy`），可以直接喂给 `order_point`。屏幕像素用 `mouse_screen()`。 |
| 把 4x3 当成 1 维下标 | 参数顺序是 `(col, row)`，即 `(x, y)`；`x` 最大 3、`y` 最大 2。写反了大概率返回 nil。 |
| 以为 button() 能点技能 | 它只做「读」，不会触发命令。要真正施法见配方 7。 |
| 光标在窗口外 | 两种取值都可能不返回，务必 `pcall` + 判空，不要直接参与算术。 |

---

## 7. 配方：让选中的英雄在鼠标位置放一次暴风雪

**目标**：用纯 Lua 提交一个本地点目标命令（不走 JASS 触发器）。这是 jass.message 最实战的一块。 **用到**：`GroupEnumUnitsSelected` / `GroupEnumUnitsOfPlayer`、`GetUnitAbilityLevel` / `UnitAddAbility` / `SetUnitAbilityLevel`、`message.order_point` + `FLAG_LOCAL_CAST`、`jass.OrderId`。

```lua
local jass = require "jass.common"
local message = require "jass.message"

local FLAG_LOCAL_CAST = (1 << 2) | (1 << 5)
local ORDER_BLIZZARD = jass.OrderId('blizzard')

-- 把 4 字节字符串转成 fourcc 整数（与 map/game/demo.lua 的 fourcc 同构）。
local function fourcc(value)
    local a, b, c, d = value:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local ABILITY_BLIZZARD = fourcc('AHbz')

-- 选中单位：1.27a 的 message.selection() 有 offset 问题，用 GroupEnumUnitsSelected 绕开
-- （map/lib/util.lua 的 get_selected_unit 就是因此这么写的）。
local function get_selected_unit()
    local group = jass.CreateGroup()
    jass.GroupEnumUnitsSelected(group, jass.GetLocalPlayer(), nil)
    local unit = jass.FirstOfGroup(group)
    jass.DestroyGroup(group)
    return unit
end

local hero = get_selected_unit()
if hero == nil then
    print('[cast] nothing selected')
    return
end

-- 保证英雄真的有这个技能（1 级），并给它一点蓝。
if jass.GetUnitAbilityLevel(hero, ABILITY_BLIZZARD) == 0 then
    jass.UnitAddAbility(hero, ABILITY_BLIZZARD)
    jass.SetUnitAbilityLevel(hero, ABILITY_BLIZZARD, 1)
end
pcall(jass.SetUnitState, hero, jass.ConvertUnitState(3), 500.0)   -- 3 = 魔法值

local ok, wx, wy = pcall(message.mouse)
if not ok or not wx then
    print('[cast] cursor not over the window')
    return
end

-- order_point(order, x, y, flags) 要求当前有选中的单位，否则直接返回 false。
local cast_ok, submitted = pcall(message.order_point, ORDER_BLIZZARD, wx, wy, FLAG_LOCAL_CAST)
print(string.format('[cast] submitted = %s', tostring(cast_ok and submitted)))
```

**验证方式**：日志出现 `[cast] submitted = true`，并且游戏里真的落下暴风雪；`map/game/demo.lua` 的垂直切片（11/11 通过）用的就是这一套：选中英雄 → Q 键 → 在鼠标位置施法。

| 坑 | 说明 |
|---|---|
| 没有选中单位 | `order_*` 内部读的是「当前选中单位」，没有选中就返回 false（不报错）。先 `SelectUnit` 或让玩家点一下。 |
| 第一秒就施法 | 刚进图的 1 秒内命令提交链还没就绪，`order_point` 会假成功或无效。用配方 2 的 `after(1.5, ...)` 包住。 |
| 忘了 flags | 本地命令要带 `FLAG_LOCAL_CAST = (1 << 2) \| (1 << 5)`；不带 flags 时在网络层语义不同，单机也常常不生效。 |
| 技能 ID 写错 | `jass.OrderId('blizzard')` 是命令字符串，`ability_id` 是 fourcc `AHbz`。两个都要对：一个决定「放什么」，一个决定「英雄会不会」。 |
| 1.27a 之前的版本 | `order_immediate` / `order_point` / `order_target` 只在 `get_version() >= 1.24e` 时注册，1.27a 满足；别把这套代码拿去做 1.20e 地图。 |

---

## 8. 配方：用 SLK 数据表查游戏数据（不写死数字）

**目标**：在 Lua 里直接查技能 / 单位 / 物品 / 升级 / 可破坏物的原始数据表，用来做校验表、图鉴、平衡面板。 **用到**：`jass.slk`（7 张子表：`ability` / `buff` / `unit` / `item` / `upgrade` / `doodad` / `destructable`，注意 `doodad` 是单数）。

```lua
local slk = require "jass.slk"

local function row_count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- 每张表在第一次访问时才加载，之后命中 registry 缓存（rawget 第二次是同一张表）。
print(string.format('[slk] ability rows = %d', row_count(slk.ability)))

-- 按对象 id 取行：行是一张普通的 Lua 表，字段名大小写不敏感，值统一是字符串。
local blizzard = slk.ability['AHbz']
if blizzard then
    print('[slk] AHbz.code = ' .. tostring(blizzard.code))
end

local peasant = slk.unit['hpea']
if peasant then
    print('[slk] hpea.race = ' .. tostring(peasant.race))
end

-- 查不到就是 nil（同时在 DLL 日志里留一行 '[slk] MISS'，前 6 次会打印表名/尺寸）。
if slk.unit['this_id_does_not_exist'] == nil then
    print('[slk] missing id returns nil, as expected')
end

-- 遍历：键是对象 id 字符串，值是行表。前 5 个示例。
local shown = 0
for object_id, row in pairs(slk.ability) do
    print(string.format('[slk] %s -> code=%s', object_id, tostring(row.code)))
    shown = shown + 1
    if shown >= 5 then break end
end
```

**验证方式**：日志里出现 `[slk] ability rows = <正数>`、`[slk] AHbz.code = AHbz`、`[slk] hpea.race = human`——这三条断言是 `map/tests/test_suite.lua` 的 slk 段（415-453 行）已经在实机上跑通的。

| 坑 | 说明 |
|---|---|
| 以为是 `jass.slk` 的函数 | 它是一张**表**，没有 `slk.get(...)`；取值就是 `slk.unit[id].字段`。 |
| 字段名大小写 | 表名和字段名都按大小写不敏感匹配（内部 `_stricmp`），但对象 id 是精确匹配的。 |
| 值是字符串不是数字 | SLK 原始值统一 `to_string()`：比较数字要自己 `tonumber`，比较字符串可以直接比。 |
| 每帧全表遍历 | 7 张表可能上千行，遍历放开局或菜单里做一次；`pairs` 每次都走表，不会自动缓存结果。 |
| 在非对局状态查询 | 只在游戏内（地图脚本执行后）可用；编辑器/主菜单阶段没有数据。 |

---

## 9. 配方：给 JASS 加一个只能由 JASS 显式调用、实现写在 Lua 里的函数

**目标**：JASS 侧像调 native 一样调到一个纯 Lua 函数（同步返回）。这是本 SDK 最核心的玩法，也是 `UnitId` 桥的用法。 **用到**：`jass.japi`（Lua 侧注册 handler）、`UnitId` + `hashtable`（JASS 侧 RPC 客户端）。注意 `UnitId` 是 1.27a 自带 native，声明在 `tools/w3x2lni/data/enUS-1.27.1/mpq/Scripts/Common.j:146`（`constant native UnitId takes string unitIdString returns integer`），所以地图里**不需要**再声明它。

**Lua 侧**（`war3map.lua`，必须在 LoadScript 阶段完成注册）：

```lua
local japi = require "jass.japi"

-- 第一个参数是桥名字（JASS 侧 UnitId 的字符串），第二个是 JASS 类型签名。
japi('LuaAddTwo', '(II)I', function(a, b)
    local result = (a or 0) + (b or 0)
    print(string.format('[bridge] LuaAddTwo(%d, %d) = %d', a or 0, b or 0, result))
    return result
end)

-- 重复注册同名会报错：japi: LuaAddTwo is already registered
-- 与已有 bridge handler 重名会报错：japi: <name> conflicts with an existing bridge handler
```

**JASS 侧**（`war3map.j`）：

```jass
globals
    hashtable japi_ht = null
    integer japi__key = 0
endglobals

// 槽位约定：0 = 类型签名 / 返回值，1..n = 实参。
// 返回类型决定用 LoadInteger / LoadReal / LoadStr / LoadBoolean 读回。
function LuaAddTwoCall takes integer a, integer b returns integer
    call SaveStr(japi_ht, japi__key, 0, "(II)I")
    call SaveInteger(japi_ht, japi__key, 1, a)
    call SaveInteger(japi_ht, japi__key, 2, b)
    call UnitId("LuaAddTwo")
    return LoadInteger(japi_ht, japi__key, 0)
endfunction

// 触发点：随便在哪调用，比如一个 1 秒的 timer action。
function Trig_Bridge_Actions takes nothing returns nothing
    call SaveInteger(japi_ht, japi__key, 0, LuaAddTwoCall(10, 32))
endfunction
```

**验证方式**：日志里出现 `[bridge] LuaAddTwo(10, 32) = 42`；`map/tests/test_suite.lua` 的 bridge_preflight 段（513-551 行）就是这么验证的（`udg_lua_bridge_result == 42`）。

| 坑 | 说明 |
|---|---|
| 把桥名字当 native 名声明 | 只有**引擎已有**的 native 名能声明成 `native X takes ...`；`japi('LuaAddTwo', ...)` 注册的名字不是引擎 native，声明它 = 违反声明规则（见 [docs/planning/JASS-NATIVE-DECLARATIONS.md](../planning/JASS-NATIVE-DECLARATIONS.md)），表现为静默回主菜单。 |
| 槽位写错 | 0 号槽永远放签名/收返回值，参数从 1 开始。签名写错（比如实参是 real 却写 `(II)I`）不会报错，只会读到垃圾值。 |
| 忘了初始化 hashtable | `japi_ht` 必须在 `main` 里 `InitHashtable()`，`japi__key = StringHash("jass")`；基座地图 `reference/empty-map/war3map.j:59-64` 就是这么做的。 |
| 在 handler 里睡 | handler 在 JASS 线程里同步执行，`sleep()` 在这里会报错。要异步就 return，后续逻辑交给 timer / trigger。 |
| handler 报错无人管 | Lua 侧错误会被 `runtime.error_handle` 接住并写日志；JASS 侧只会读到「没写过的槽」= 上一次的值。发布前装一个 `error_handle` 把它变大声。 |
| 句柄怎么传 | 传 `GetHandleId(player)` 这类整数，签名写 `(Hplayer;)Hplayer;` 之类；`handle_level` 决定 Lua 看到的是数字还是 userdata（默认 2 = userdata）。 |

---

## 10. 配方：拦截一个既有 native（观测或改写）

**目标**：不改 JASS 代码，在 Lua 层给 `GetPlayerId` 之类的高频 native 加计数/日志，或者临时改掉它的返回值。 **用到**：`jass.hook`（`hook.hook(name, fn)` / `hook.unhook(name)`，也可以写 `hook.GetPlayerId = fn`）。

```lua
local jass = require "jass.common"
local hook = require "jass.hook"

local calls = 0

-- 回调签名：实参按 native 原顺序，**最后多一个参数 orig**（原始实现）。
hook.hook('GetPlayerId', function(player, orig)
    calls = calls + 1
    return orig(player)          -- 原样透传返回值
end)

-- hook 生效后，jass.call 和元表调用（jass.GetPlayerId）都会走 Lua 版本。
local id = jass.GetPlayerId(jass.GetLocalPlayer())
print(string.format('[hook] player id = %d, lua calls = %d', id, calls))

-- 改写返回值也可以（先想清楚影响面：这个 native 可能被引擎内部大量调用）
-- hook.hook('GetPlayerId', function(player, orig) return 0 end)

hook.unhook('GetPlayerId')        -- 还原；还原后再调就是原实现
print('[hook] unhooked')
```

**验证方式**：日志里 `[hook] player id = 0, lua calls = 1`（数字随玩家座位变），并且 `map/tests/test_suite.lua` 的 hook 段（205-291 行）覆盖了「hook 后 jass.call 与 jass.X 都走 Lua、unhook 后还原」这两条。

| 坑 | 说明 |
|---|---|
| orig 位置记反 | `orig` 是**最后一个**参数，不是第一个。写 `function(orig, player)` 会在调用时把 player 当函数调，报 attempt to call a userdata。 |
| 重复 hook | 同名再 hook 会报 `hook: '<name>' is already hooked`；不存在的 native 报 `hook: unknown native <name>`。 |
| hook 高频 native | `GetPlayerId` 一局被调几次；`GetUnitState`、`GetWidgetLife` 可能每帧上百次——回调里别做字符串拼接或 SLK 查询。 |
| hook 后忘了还原 | 地图切场景/重开逻辑里 `unhook`，或者接受「一局内永久生效」。hook 也会改写 jass_function 缓存地址，所以 `jass.call` 一样被拦。 |
| 用 hook 修 bug | hook 只改 Lua/C++ 侧的调用结果，引擎内部直接调函数指针的路径拦不到；要保证行为一致就改 JASS 或改 src。 |

---

## 11. 配方：用 sleep 写一段有节奏的演出

**目标**：按时间顺序推进一段剧情/教学提示，代码是线性可读的，而不是一堆嵌套 timer。 **用到**：`jass.runtime` 的 `sleep = true` 与 `error_handle`、`require "jass.sleep"` 的 `sleep()`、`jass.CreateTrigger` + `jass.code`。

```lua
local jass = require "jass.common"
local runtime = require "jass.runtime"
local sleep = require("jass.sleep").sleep
runtime.sleep = true          -- 1) 开关默认 false；错误回调的写法见配方 1 的 runtime.error_handle
-- 2) 一个 action 里只等一次，进度写状态字段，判定交给独立定时器轮询（同 map/tests/bridge_preflight.lua:67-101）
local state = { stage = 0 }
local trigger = jass.CreateTrigger()
jass.TriggerAddAction(trigger, jass.code(function()
    state.stage = 1
    sleep(0.30)               -- 恢复耗时 ≈ 参数 + 0.1 s，别当秒表
    state.stage = 2
end))
jass.TriggerRegisterTimerEvent(trigger, 0.10, false)

-- 3) 多段节奏用 timer 链（模式同配方 2 的 boot timer），不要连写两个 sleep
local function later(s, text)
    local t = jass.CreateTimer()
    jass.TimerStart(t, s, false, jass.code(function() jass.DestroyTimer(t); print(text) end))
end
later(0.10, '[show] step 1'); later(0.40, '[show] step 2'); later(0.70, '[show] step 3')

-- 4) 3 秒内见到 stage == 2 才算恢复；加一次性守卫会让 action 永不恢复
local watch, ticks = jass.CreateTimer(), 0
jass.TimerStart(watch, 0.02, true, jass.code(function()
    ticks = ticks + 1
    if state.stage == 2 or ticks > 150 then
        print(string.format('[show] sleep %s after %d ticks', state.stage == 2 and 'resumed' or 'TIMEOUT', ticks)); jass.PauseTimer(watch); jass.DestroyTimer(watch); runtime.sleep = false
    end
end))
```

**验证方式**：日志依次出现 `[show] step 1/2/3` 与 `[show] sleep resumed after N ticks`（打成 `TIMEOUT` 就是没恢复）；`map/tests/bridge_preflight.lua` 用同一形态在每次 122/122 回归里断言 sleep 在 trigger action 里恢复执行。

| 坑 | 说明 |
|---|---|
| 没开 runtime.sleep | 报 `TriggerSleepAction is not available`。开关默认 false 是安全设计。 |
| 在 timer 回调里 sleep | 报 `sleep() must be called from a coroutine`：裸 timer 回调不是持久线程。要么用 trigger action（如上），要么在 `coroutine` 里。 |
| sleep(0) | `seconds <= 0` 会被当成 0.001 秒，不是「立刻返回」。 |
| 睡着时游戏照常跑 | sleep 期间单位会死、地图会切；醒来后先检查句柄是否还有效（`IsUnitType` / `GetUnitTypeId` 兜底）。 |
| 拿 sleep 当秒表 | 恢复耗时 ≈ 参数 + 0.1 s（实测 0.05→0.075 s、0.30→0.433 s），分辨率约 0.1 s（2026-11-16，6 个探针地图）；精度要 0.1 秒级就用 `CreateTimer` + `TimerStart`。 |
| 一个 action 里连写两个 sleep | 同一形态一次 3.5 s 跑完、另一次 15 s 没恢复；action 还会被从头重入（某次 3.8 s 内进 6 次，阶段被打回 1）→ 一个 action 只等一次，多段用上面的 timer 链。 |
| **给 sleeping action 加一次性守卫** | 加了 `if state.started then return end` 后第一段恢复、第二段永不恢复（实测 15 s 不动）——续跑依赖 action 被重新进入。不要加守卫，判定放独立定时器轮询；见 [SDK-GUIDE.md](SDK-GUIDE.md) 第 7 节「实测」。 |

---

## 12. 配方：读地图文件做兼容性闸门

**目标**：地图脚本一启动就确认「我跑在预期的地图 / 版本上」，不对就早退并留下原因，而不是跑到一半才崩。 **用到**：`jass.storm` 的 `has()` / `load()`、`jass.d3d.version()`、`jass.globals`。

```lua
local jass = require "jass.common"
local storm = require "jass.storm"
local globals = require "jass.globals"

-- 1) 闸门：地图信息文件必须存在且大小像样
if not storm.has('war3map.w3i') then
    print('[gate] war3map.w3i missing - refusing to continue')
    return
end

local info = storm.load('war3map.w3i'); print(string.format('[gate] war3map.w3i = %d bytes, format byte = %d', #info, string.byte(info, 1)))

-- 2) DLL 存活标志：war3map.lua 能跑起来就说明 DLL 已加载（reference/empty-map/war3map.j:40）。这里只写标量：数组全局要等开局后 1.0 秒（见坑表 / SDK-GUIDE 第 2 节）
globals.udg_lua_japi_alive = 1; print(string.format('[gate] japi alive flag = %s', tostring(globals.udg_lua_japi_alive)))

-- 3) 版本闸门：SDK 版本是编译期常量，可用来断言「玩家装的 DLL 是不是配套的」
local d3d = require "jass.d3d"
local sdk = d3d.version()
print(string.format('[gate] SDK %s, d3d available = %s', sdk, tostring(d3d.is_available())))
if sdk ~= '0.5.0' then
    print('[gate] SDK version mismatch: expected 0.5.0')
end
```

**验证方式**：日志里出现 `[gate] war3map.w3i = <N> bytes`、`[gate] SDK 0.5.0, d3d available = true/false`；版本不符时出现 `SDK version mismatch` 行。

| 坑 | 说明 |
|---|---|
| 以为 storm 能写文件 | `storm.load()` 读 MPQ、`storm.replace_path()` 做运行时路径重定向；不能修改只读 `.w3x`。 |
| 拿 d3d 版本来判断可用性 | `d3d.version()` 是常量，没有 D3D9 也返回 0.5.0；可用性看 `d3d.is_available()`。 |
| 用 globals 存大数组 | 数组全局必须在 JASS 里声明且被预分配（`tools/pack.ps1` 的 `JapiForceAllocArrays`，每数组 32KB）；整数组赋值会被忽略并写日志，只能逐元素写。 |
| **在脚本加载期读写数组** | 加载期 `#arr == 0`、元素读 `nil`、写被静默丢弃（同一时刻标量正常），1.0 秒后才恢复；数组 I/O 要放进一次性 `TimerStart(timer, 1.0, false, ...)`，时序表见 [SDK-GUIDE.md](SDK-GUIDE.md) 第 2 节的「时序」小节 |
| 字符串数组槽没写过就读 | 开局后也返回 `nil`（JASS 空字符串，不是 `""`），所以要先写后读 |

### 发布前再确认这几条

| 检查 | 命令 / 判据 |
|---|---|
| DLL 与 d3d proxy 都是配套的 | DLL：`Get-FileHash src\build\bin\Release\yd_japi.dll -Algorithm SHA256` 对 `docs/STATUS.md`；proxy：`Get-FileHash '<游戏目录>\d3d9.dll'` 对 `<游戏目录>\.japi_d3d_proxy.sha256`（`tools\d3d-proxy.ps1 -Install` 装的） |

发布前打包记得给独立的 `-WorkDir` / `-OutFile`（`pack.ps1` 会先清空 `-WorkDir`，第 177 行）。完整发布清单（版本钉法、产物清单、CHANGELOG 约定）见 [../RELEASE.md](../RELEASE.md)。

---

## 13. 下一步

| 想做的事 | 去看 |
|---|---|
| 第一次从零跑通一张图 | [SDK-QUICKSTART.md](SDK-QUICKSTART.md)，或用脚手架 `tools/new-project.ps1` 生成最小工程（war3map.lua / lib/ / tests/ / base-map/） |
| 每个模块的完整语义、坑、生命周期 | [SDK-GUIDE.md](SDK-GUIDE.md) |
| 可直接打包运行的 10 个示例（`01-hello-jass` … `10-getfunc-addr`） | [../../examples/](../../examples/)，清单（若已生成）见 `examples\manifest.json` |
| D3D 的完整 API 签名 | [D3D-LUA-API.md](D3D-LUA-API.md)、[D3D-LUA-QUICKSTART.md](D3D-LUA-QUICKSTART.md) |
| 版本历史 / 发布流程 / 当前完成度与验证强度（唯一权威） | [../../CHANGELOG.md](../../CHANGELOG.md)、[../RELEASE.md](../RELEASE.md)、[../STATUS.md](../STATUS.md) |

> 本文件写的每一条 API 都能在 `src/src/lua_engine/lua_engine/libs_*.cpp` 里找到出处；每个「验证方式」都指向本仓库真实跑过的输出格式。发现文档与代码不一致时，以代码和 `docs/STATUS.md` 为准，并请提 issue。

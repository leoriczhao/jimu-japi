-- ============================================================
-- 示例 02 · native hook + 输入回调
-- 编号      : 02-input-hook
-- 用途      : 两件事。其一，用 jass.hook 接管一个 JASS native，把返回值和原实现
--             一起改掉（hook.hook(name, fn)，fn 的最后一个参数是 orig）；其二，
--             用 message.hook 安装输入回调，msg.type / msg.code 来自游戏内分发。
-- 需要的开关: 无
-- 前置条件  : 空地图
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 8 项）；
--             若真人按 Q，会额外打一行 "[example 02] Q pressed"
-- 说明      : 没有人按键时 message.hook 不会被调用。示例只断言"回调已安装、
--             能被 msg 表调用"，不伪造按键事件（详见 README）。
-- 验证状态  : 2026-11-16 静态 + 打包验证通过（tools\verify-examples.ps1）
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"
local hook = require "jass.hook"
local message = require "jass.message"

local input = { events = 0, last_type = nil, last_code = nil }

-- 输入回调：msg.type 是 "key_down" / "key_up"，msg.code 是 WARK 键码
-- （不是 Win32 VK；例如 Q 是 0x51，F2 是 0x301）。
-- 返回 false 表示吞掉这次输入，返回 true 表示照常交给游戏。
local function on_message(msg)
    input.events = input.events + 1
    input.last_type = msg.type
    input.last_code = msg.code
    if msg.type == "key_down" and msg.code == 0x51 then
        print("[example 02] Q pressed")
        return false
    end
    return true
end

message.hook = on_message

-- 接管一个 native：GetPlayerId 的返回值 +100。
-- 回调最后一个参数 orig 是原实现，必须由它来取真实值。
local function install_player_id_probe()
    hook.hook("GetPlayerId", function(player, orig)
        return orig(player) + 100
    end)
end

local function remove_player_id_probe()
    hook.unhook("GetPlayerId")
end

install_player_id_probe()

-- ============ 以下为示例自检，粘到自己地图时可以删掉 ============

-- 自检 harness：输出约定与 map/game/demo.lua 一致（[PASS]/[FAIL] + 一行 Results）。
local pass, fail = 0, 0

local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("  [PASS] " .. name)
    else
        fail = fail + 1
        print("  [FAIL] " .. name .. " : " .. tostring(err))
    end
end

local function finish()
    message.hook = nil
    print("")
    print("========================================")
    print(string.format(" Results: %d passed, %d failed, %d total", pass, fail, pass + fail))
    print("========================================")
end

check("jass.hook / jass.message 已加载", function()
    assert(type(hook.hook) == "function" and type(hook.unhook) == "function",
        "hook.hook / hook.unhook 缺失")
    assert(type(message.keyboard) == "table", "message.keyboard 缺失")
    assert(type(message.mouse) == "function", "message.mouse 缺失")
end)

check("hook 接管 native，并把原实现交给 orig", function()
    local lp = jass.GetLocalPlayer()
    local hooked = jass.GetPlayerId(lp)     -- 加载时已安装，+100
    remove_player_id_probe()
    local plain = jass.GetPlayerId(lp)
    install_player_id_probe()
    assert(hooked == plain + 100,
        string.format("挂钩后 %s，摘钩后 %s", tostring(hooked), tostring(plain)))
    assert(jass.GetPlayerId(lp) == hooked, "重新安装后没有恢复接管")
end)

check("重复 hook 同一个 native 会报错", function()
    local ok = pcall(hook.hook, "GetPlayerId", function(player, orig) return orig(player) end)
    assert(not ok, "重复 hook 竟然成功了")
end)

check("hook 不存在的 native 会报错", function()
    local ok = pcall(hook.hook, "NonExistentNativeForExample02", function() end)
    assert(not ok, "hook 不存在的 native 竟然成功了")
end)

check("message.hook 可安装、可清除", function()
    local saved = message.hook
    message.hook = function(msg) return true end
    assert(type(message.hook) == "function", "安装后读不到函数")
    message.hook = nil
    assert(message.hook == nil, "清除后读到的不是 nil")
    message.hook = saved
    assert(type(message.hook) == "function", "恢复失败")
end)

check("message.keyboard 表可读写", function()
    message.keyboard[0x41] = true
    assert(message.keyboard[0x41] == true, "写入后读不到")
    message.keyboard[0x41] = nil
    assert(message.keyboard[0x41] == nil or message.keyboard[0x41] == false,
        "清除后仍然为真")
end)

check("message.mouse 返回世界坐标", function()
    local wx, wy = message.mouse()
    assert(type(wx) == "number" and type(wy) == "number",
        string.format("鼠标坐标 %s,%s", type(wx), type(wy)))
end)

check("输入回调能被 msg 表调用（无人按键时只证明安装路径）", function()
    local before = input.events
    local ok = pcall(on_message, { type = "key_down", code = 0x51 })
    assert(ok, "回调抛错")
    assert(input.events == before + 1, "回调没有被调用")
    assert(input.last_code == 0x51, "回调没收到 msg.code")
end)

remove_player_id_probe()

local finish_timer = jass.CreateTimer()
jass.TimerStart(finish_timer, 3.8, false, function()
    jass.DestroyTimer(finish_timer)
    finish()
end)

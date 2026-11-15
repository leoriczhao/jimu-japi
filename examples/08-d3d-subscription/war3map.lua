-- ============================================================
-- 示例 08 · D3D 订阅（点击/悬停）+ 生命周期
-- 编号      : 08-d3d-subscription
-- 用途      : 建一块可命中（hit_test）的 Texture，挂 click 订阅，并演示订阅对象的
--             生命周期：is_active / cancel（幂等）/ stats().subscriptions 计数 /
--             销毁 Texture 时 owned 订阅自动失效；另外演示模块级 d3d.on("resize")。
-- 需要的开关: d3d=true（同示例 03：War3 必须由 deploy.ps1 -InteractiveD3D/-Demo/
--             -TestReboot 启动，或先跑 tools\d3d-proxy.ps1 -Install）
-- 前置条件  : 空地图；D3D 可用
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 7 项）
-- 说明      : click 回调只有真人点面板才会触发，Lua 侧没有伪造输入的接口。
--             所以示例只验证"订阅已建立、参数校验、计数与失效"这些确定性部分，
--             不假装模拟点击（详见 README）。
-- 验证状态  : 2026-11-16 静态 + 打包验证通过；D3D 实机路径由 lead 跑
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"
local d3d = require "jass.d3d"

local PANEL_X, PANEL_Y, PANEL_W, PANEL_H = 100, 140, 256, 128

-- 建可点的面板：hit_test=true 才能被鼠标命中，事件按 z 从上往下分派。
local function create_click_panel()
    local texture = d3d.Texture.new({
        source = "game://ReplaceableTextures/CommandButtons/BTNFootman.blp",
        x = PANEL_X, y = PANEL_Y, width = PANEL_W, height = PANEL_H,
        color = d3d.rgba(255, 255, 255, 255),
        z = 150,
        hit_test = true,
    })
    if texture == nil then
        return nil, "Texture.new 返回 nil"
    end

    local clicks = { count = 0, last = nil }
    local ok, subscription = pcall(texture.on, texture, "click", function(event)
        clicks.count = clicks.count + 1
        clicks.last = event
        print(string.format("[example 08] click %s,%s button=%s",
            tostring(event.x), tostring(event.y), tostring(event.button)))
    end, { button = d3d.mouse.LEFT })
    if not ok then
        texture:destroy()
        return nil, "texture:on 抛错: " .. tostring(subscription)
    end
    if subscription == nil then
        texture:destroy()
        return nil, "texture:on 返回 nil"
    end

    return { texture = texture, clicks = clicks, click_sub = subscription }
end

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
    print("")
    print("========================================")
    print(string.format(" Results: %d passed, %d failed, %d total", pass, fail, pass + fail))
    print("========================================")
end

local state = { tick = 0, ready = false, error = nil, baseline = nil }
local panel = nil

local run_checks = function()
    check("D3D 已就绪（d3d.is_available）", function()
        assert(state.ready, state.error or "d3d.is_available() 为假")
    end)
    if not state.ready then
        return
    end

    check("hit_test 面板能被 contains 命中（中心真 / 远处假）", function()
        assert(panel.texture:get_hit_test(), "get_hit_test() 为假")
        assert(panel.texture:contains(PANEL_X + PANEL_W / 2, PANEL_Y + PANEL_H / 2),
            "面板中心没有被命中")
        assert(not panel.texture:contains(10, 10), "面板外的点被命中了")
    end)

    check("click 订阅已建立并计入 stats().subscriptions", function()
        assert(panel.click_sub:is_active(), "订阅不是 active")
        local now = d3d.stats().subscriptions
        assert(now == state.baseline + 1,
            string.format("subscriptions %s，基线 %s", tostring(now), tostring(state.baseline)))
    end)

    check("非法事件名 / 非法回调会抛错", function()
        local ok1 = pcall(panel.texture.on, panel.texture, "bogus",
            function() end, { button = d3d.mouse.LEFT })
        assert(not ok1, "事件名 bogus 竟然被接受")
        local ok2 = pcall(d3d.on, "resize", "not a function")
        assert(not ok2, "非函数回调竟然被接受")
    end)

    check("cancel 幂等，取消后计数回落", function()
        assert(panel.click_sub:cancel(), "第一次 cancel 失败")
        assert(panel.click_sub:cancel(), "第二次 cancel 失败（不是幂等）")
        assert(not panel.click_sub:is_active(), "取消后仍然 active")
        assert(d3d.stats().subscriptions == state.baseline,
            "取消后 subscriptions = " .. tostring(d3d.stats().subscriptions()))
    end)

    check("模块级 d3d.on(\"resize\") 订阅可创建、可取消", function()
        local sub = d3d.on("resize", function(event) end)
        assert(sub ~= nil and sub:is_active(), "resize 订阅不可用")
        assert(d3d.stats().subscriptions == state.baseline + 1, "resize 订阅没有计数")
        assert(sub:cancel() and sub:cancel(), "resize 订阅 cancel 不幂等")
        assert(not sub:is_active(), "resize 取消后仍 active")
        assert(d3d.stats().subscriptions == state.baseline, "resize 订阅释放后计数不对")
    end)

    check("销毁 Texture 会让它的 owned 订阅失效", function()
        local sub = panel.texture:on("enter", function(event) end, { hover_only = true })
        assert(sub ~= nil and sub:is_active(), "enter 订阅不可用")
        assert(d3d.stats().subscriptions == state.baseline + 1, "enter 订阅没有计数")
        assert(panel.texture:destroy(), "texture:destroy() 失败")
        assert(not sub:is_active(), "Texture 销毁后订阅仍然 active")
        assert(d3d.stats().subscriptions == state.baseline, "owned 订阅没有释放计数")
        panel = nil
    end)
end

local probe_timer
local function on_tick()
    state.tick = state.tick + 1
    local n = state.tick

    if not state.ready and n <= 20 then
        if d3d.is_available() then
            state.baseline = d3d.stats().subscriptions
            local created, err = create_click_panel()
            if created ~= nil then
                panel = created
                state.ready = true
            else
                state.error = tostring(err)
            end
        elseif state.error == nil then
            state.error = string.format(
                "d3d 不可用: %s。先运行 .\\tools\\d3d-proxy.ps1 -Install -War3Dir 'D:\\Warcraft III Frozen Throne 1.27a publish'，" ..
                "并用 tools\\deploy.ps1 -InteractiveD3D/-Demo/-TestReboot 启动 War3",
                tostring(d3d.status().error))
        end
        return
    end

    if n == 38 then
        run_checks()
        if panel ~= nil then
            panel.texture:destroy()
            panel = nil
        end
        jass.PauseTimer(probe_timer)
        jass.DestroyTimer(probe_timer)
        finish()
    end
end

probe_timer = jass.CreateTimer()
jass.TimerStart(probe_timer, 0.1, true, on_tick)

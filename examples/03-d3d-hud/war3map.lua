-- ============================================================
-- 示例 03 · D3D HUD（Font / Text / Texture）
-- 编号      : 03-d3d-hud
-- 用途      : 最小 D3D HUD：一块 BLP 底板 + 一行文字，并用 0.1s timer 每帧刷新文字。
--             覆盖 d3d.is_available / window_size / rgba / Font.new / Text.new /
--             Texture.new 以及 get_/set_ 属性访问。
-- 需要的开关: d3d=true —— 打包本身不需要额外开关，但 War3 进程里必须有 d3d9 proxy，
--             而且必须由 tools\deploy.ps1 的 -InteractiveD3D / -Demo / -TestReboot
--             模式启动（只有这些模式会安装 proxy 并校验 hash）。
--             手工安装：.\tools\d3d-proxy.ps1 -Install -War3Dir 'D:\Warcraft III Frozen Throne 1.27a publish'
-- 前置条件  : 空地图；D3D 可用
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 6 项）。
--             d3d 不可用时只打一条 [FAIL]，message 里写明怎么装 proxy。
-- 验证状态  : 2026-11-16 静态 + 打包验证通过；D3D 实机路径由 lead 用
--             -InteractiveD3D 跑（本示例不自己启动 war3，见 examples\README.md）
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"
local d3d = require "jass.d3d"

-- War3 顶栏 + 左上单位面板占掉客户区前面约 110 像素，正文从 y=120 起才不被挡住。
local HUD_TEXT_X, HUD_TEXT_Y = 24, 120
local HUD_PANEL_X, HUD_PANEL_Y = 12, 108
local HUD_PANEL_W, HUD_PANEL_H = 320, 64

local hud = { frames = 0 }

-- 建 HUD。注意生命周期：Font 必须比引用它的 Text 活得久，
-- 所以销毁顺序是 Text -> Font（反过来 font:destroy() 会返回 nil, 错误字符串）。
local function create_hud()
    if not d3d.is_available() then
        return nil, tostring(d3d.status().error)
    end
    local width, height = d3d.window_size()
    if width <= 0 or height <= 0 then
        return nil, string.format("window_size=%sx%s", tostring(width), tostring(height))
    end

    local font = d3d.Font.new({ face = "Arial", height = 18, weight = 700 })
    if font == nil then
        return nil, "Font.new 返回 nil"
    end

    -- 底板：game:// 指向 War3 安装目录，不用往地图里塞图片。
    local panel = d3d.Texture.new({
        source = "game://ReplaceableTextures/CommandButtons/BTNRifleman.blp",
        x = HUD_PANEL_X, y = HUD_PANEL_Y, width = HUD_PANEL_W, height = HUD_PANEL_H,
        color = d3d.rgba(8, 8, 8, 190),   -- 近黑半透明，压住 BLP 让文字可读
        z = 99,
    })
    if panel == nil then
        return nil, "Texture.new 返回 nil"
    end

    local label = d3d.Text.new({
        font = font,
        text = "japi d3d hud",
        x = HUD_TEXT_X, y = HUD_TEXT_Y,
        color = d3d.rgba(255, 230, 120, 255),
        z = 100,                          -- z 小的先画
    })
    if label == nil then
        return nil, "Text.new 返回 nil"
    end

    hud.font, hud.label, hud.panel = font, label, panel
    hud.width, hud.height = width, height
    return hud
end

-- 每帧刷新：把帧号写进文字。Text 是 userdata，set_text 直接改内容，不重建对象。
local function update_hud()
    if hud.label == nil then
        return
    end
    hud.frames = hud.frames + 1
    hud.label:set_text(string.format("japi d3d hud - frame %d", hud.frames))
end

local function destroy_hud()
    if hud.label ~= nil then
        hud.label:destroy()               -- 先销毁引用 Font 的 Text
        hud.label = nil
    end
    if hud.font ~= nil then
        hud.font:destroy()
        hud.font = nil
    end
    if hud.panel ~= nil then
        hud.panel:destroy()
        hud.panel = nil
    end
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

local state = { tick = 0, ready = false, error = nil }

local run_checks = function()
    check("D3D 已就绪（d3d.is_available）", function()
        assert(state.ready, state.error or "d3d.is_available() 为假")
    end)
    if not state.ready then
        return
    end

    check("window_size 返回正的客户区尺寸", function()
        assert(hud.width > 0 and hud.height > 0,
            string.format("%sx%s", tostring(hud.width), tostring(hud.height)))
    end)

    check("Font / Text / Texture 都构造成功", function()
        assert(hud.font ~= nil and not hud.font:is_destroyed(), "Font 不可用")
        assert(hud.label ~= nil and not hud.label:is_destroyed(), "Text 不可用")
        assert(hud.panel ~= nil and not hud.panel:is_destroyed(), "Texture 不可用")
    end)

    check("Text 属性按构造值读回", function()
        local x, y = hud.label:get_position()
        assert(x == HUD_TEXT_X and y == HUD_TEXT_Y,
            string.format("position=%s,%s", tostring(x), tostring(y)))
        assert(hud.label:get_z() == 100, "z = " .. tostring(hud.label:get_z()))
        assert(hud.label:get_color() == d3d.rgba(255, 230, 120, 255), "color 不一致")
    end)

    check("Texture 读回构造属性（源 URI 已归一化）", function()
        assert(hud.panel:get_source() == "game://ReplaceableTextures/CommandButtons/BTNRifleman.blp",
            "source = " .. tostring(hud.panel:get_source()))
        local x, y, w, h = hud.panel:get_rect()
        assert(x == HUD_PANEL_X and y == HUD_PANEL_Y and w == HUD_PANEL_W and h == HUD_PANEL_H,
            string.format("rect=%s,%s,%s,%s", tostring(x), tostring(y), tostring(w), tostring(h)))
        local pw, ph = hud.panel:pixel_size()
        assert(type(pw) == "number" and pw > 0, "pixel_size 没有返回正数")
    end)

    check("0.1s timer 反复 set_text 生效", function()
        assert(hud.frames >= 5, "只刷新了 " .. tostring(hud.frames) .. " 次")
        local text = hud.label:get_text()
        assert(string.find(text, "frame ", 1, true) ~= nil, "text = " .. tostring(text))
    end)
end

-- 0.1s 一拍：前 20 拍等 d3d 就绪（最多 2s），36 拍（3.6s）清理，38 拍（3.8s）出结果行。
local probe_timer
local function on_tick()
    state.tick = state.tick + 1
    local n = state.tick

    if not state.ready and n <= 20 then
        local ok, err = create_hud()
        if ok ~= nil then
            state.ready = true
        elseif state.error == nil then
            state.error = tostring(err)      -- 保留启动时写的诊断信息
        end
        return
    end

    if state.ready then
        update_hud()
    end

    if n == 38 then
        run_checks()
        destroy_hud()          -- 断言都跑完了，再按 Text -> Font 的顺序销毁
        jass.PauseTimer(probe_timer)
        jass.DestroyTimer(probe_timer)
        finish()
    end
end

if not d3d.is_available() then
    state.error = string.format(
        "d3d 不可用: %s。先运行 .\\tools\\d3d-proxy.ps1 -Install -War3Dir 'D:\\Warcraft III Frozen Throne 1.27a publish'，" ..
        "并用 tools\\deploy.ps1 -InteractiveD3D/-Demo/-TestReboot 启动 War3（只有这些模式会安装并校验 proxy）",
        tostring(d3d.status().error))
end

probe_timer = jass.CreateTimer()
jass.TimerStart(probe_timer, 0.1, true, on_tick)

-- ============================================================
-- Example 12: local pixel buttons and row/column layouts.
-- Requires D3D proxy / -InteractiveD3D. Real input is required to pass.
-- Expected: disabled attempt, enabled click, client resize, second click.
-- ============================================================
-- ============ Paste into your war3map.lua ============
local jass = require "jass.common"
local d3d = require "jass.d3d"
local ui = require "lib.ui"

-- Callbacks run on this client. They only update presentation/local state.
-- Gameplay changes require a separate synchronized command protocol.
local context, button, attempt_subscription
local clicks, disabled_attempts, disabled_clicks = 0, 0, nil
local phase = "starting"
local before, first_width, first_height, first_x, first_y
local relayout_x, relayout_y
local timer, ticks, finished = nil, 0, false
local pass, fail = 0, 0
local error_message
local function marker(name)
    local x,y,w,h = button:get_rect()
    local cw,ch = d3d.window_size()
    print(string.format("UI12 %s phase=%s x=%.0f y=%.0f width=%.0f height=%.0f client_width=%d client_height=%d",
        name, phase, x,y,w,h,cw,ch))
end
local function setup()
    before = assert(d3d.stats())
    context = assert(ui.new())
    local column = assert(context:column {padding=12, spacing=10,
        position=function(w,h) return math.max(0,w-360), math.max(0,h-240) end})
    local row = assert(column:row {padding=4, spacing=12})
    button = assert(row:button {text="Try disabled first",width=200,height=48,enabled=false,
        on_click=function(self)
            clicks=clicks+1
            if phase=="enabled" then
                first_width,first_height=d3d.window_size()
                first_x,first_y=self:get_rect()
                phase="resize"
                self:set_text("Resize client window")
                marker("WAIT_RESIZE")
            elseif phase=="relayout" then
                phase="complete"
            else
                error_message="unexpected enabled click during " .. phase
            end
        end})
    assert(row:button {text="Hidden",hidden=true,width=80,height=48})
    assert(column:button {text="Local UI only",enabled=false,width=200,height=32})
    -- Low-level observation proves a real click hit the disabled target while
    -- the component's on_click stayed suppressed. This subscription is example-owned.
    attempt_subscription=assert(button.texture:on("click",function()
        if phase=="disabled" then disabled_attempts=disabled_attempts+1 end
    end,{button=d3d.mouse.LEFT}))
    phase="disabled"
    marker("READY")
end
-- ============ Example self-check harness ============
local function check(name, fn)
    local ok,err=pcall(fn)
    if ok then pass=pass+1; print("  [PASS] "..name)
    else fail=fail+1; print("  [FAIL] "..name.." : "..tostring(err)) end
end
local function finish(reason)
    if finished then return end
    finished=true
    if timer then jass.PauseTimer(timer); jass.DestroyTimer(timer); timer=nil end
    check("real disabled attempt suppressed callback",function()
        assert(disabled_attempts>=1,"no real disabled-button attempt")
        assert(disabled_clicks==0,"disabled button on_click fired")
        assert(button and button:get_blocked_clicks()>=1,
            "component did not record a blocked click")
        assert(not error_message,error_message)
    end)
    check("two real enabled clicks separated by resize",function()
        assert(not reason,reason)
        assert(phase=="complete" and clicks==2,"input sequence incomplete: "..phase)
        assert(relayout_x and relayout_y,"RELAYOUT was never observed")
        assert(relayout_x~=first_x or relayout_y~=first_y,
            "button did not move after the client resize")
    end)
    check("explicit idempotent cleanup restores resource baseline",function()
        if attempt_subscription then assert(attempt_subscription:cancel()); attempt_subscription=nil end
        if context then assert(context:destroy()); assert(context:destroy()) end
        local after=assert(d3d.stats())
        assert(before,"D3D never became ready")
        for _,key in ipairs({"textures","texts","fonts","subscriptions"}) do
            assert(after[key]==before[key],key.." did not return to baseline")
        end
        print(string.format("UI12 CLEANUP fonts=%d/%d texts=%d/%d textures=%d/%d subscriptions=%d/%d",
            after.fonts,before.fonts,after.texts,before.texts,
            after.textures,before.textures,after.subscriptions,before.subscriptions))
    end)
    print(string.format(" Results: %d passed, %d failed, %d total",pass,fail,pass+fail))
end
local function tick()
    ticks=ticks+1
    if error_message then finish(error_message); return end
    if ticks>=1800 then finish("timeout waiting for real input/resize"); return end
    if phase=="starting" then
        if not d3d.is_available() then return end
        local ok,err=pcall(setup)
        if not ok then finish(tostring(err)) end
    elseif phase=="disabled" and disabled_attempts>0 then
        disabled_clicks=clicks
        if disabled_clicks~=0 then finish("disabled callback fired"); return end
        assert(button:set_enabled(true)); assert(button:set_text("Click enabled"))
        phase="enabled"; marker("ENABLED")
    elseif phase=="resize" then
        local w,h=d3d.window_size()
        if w~=first_width or h~=first_height then
            -- Reflow is driven by the library's native resize subscription.
            local x,y=button:get_rect()
            if x~=first_x or y~=first_y then
                relayout_x,relayout_y=x,y
                phase="relayout"; button:set_text("Click new position"); marker("RELAYOUT")
            end
        end
    elseif phase=="complete" then finish() end
end
timer=jass.CreateTimer()
jass.TimerStart(timer,0.05,true,function()
    local ok,err=pcall(tick)
    if not ok then finish(tostring(err)) end
end)

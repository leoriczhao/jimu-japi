-- OFFLINE MOCK: run the actual example through fake native hit-testing/timers.
-- This checks the gate protocol; it does not validate Win32 input or D3D output.
local Fake = dofile("tests/ui/fake_d3d.lua")
local saved_print = print
local function scenario(drive)
    local d3d = Fake.new {width=1024,height=768}
    local timers, logs = {}, {}
    local jass = {}
    function jass.CreateTimer() local t={}; timers[#timers+1]=t; return t end
    function jass.TimerStart(t,_,_,fn) t.fn=fn; t.active=true end
    function jass.PauseTimer(t) t.active=false end
    function jass.DestroyTimer(t) t.active=false; t.destroyed=true end
    local function tick() for _,t in ipairs(timers) do if t.active then t.fn() end end end
    package.loaded["jass.d3d"],package.loaded["jass.common"]=d3d,jass
    package.loaded["lib.ui"]=dofile("examples/12-ui-components/lib/ui.lua")
    _G.print=function(line) logs[#logs+1]=line end
    local ok,err=pcall(function()
        dofile("examples/12-ui-components/war3map.lua")
        local function find(marker)
            for _,line in ipairs(logs) do if line:find(marker,1,true) then return line end end
        end
        local function click(marker)
            local line=assert(find(marker),"missing "..marker)
            local x,y,w,h=line:match("x=(%-?%d+) y=(%-?%d+) width=(%d+) height=(%d+)")
            assert(x,"missing rectangle")
            d3d._mouse_click(tonumber(x)+tonumber(w)/2,tonumber(y)+tonumber(h)/2)
        end
        tick(); assert(find("UI12 READY")); assert(not find("Results:"))
        if drive then
            click("UI12 READY"); assert(not find("Results:")); tick()
            assert(find("UI12 ENABLED")); click("UI12 ENABLED"); tick()
            assert(find("UI12 WAIT_RESIZE")); assert(not find("Results:"))
            -- A click before resize cannot advance the gate.
            d3d._resize(1280,900); tick()
            assert(find("UI12 RELAYOUT")); assert(not find("Results:"))
            click("UI12 RELAYOUT"); assert(not find("Results:")); tick()
            assert(find("Results: 3 passed, 0 failed, 3 total"))
            assert(find("UI12 CLEANUP"))
        else
            for _=1,2400 do tick() end
            assert(find("Results: 1 passed, 2 failed, 3 total"),"timeout must fail input checks and still clean up")
            assert(find("UI12 CLEANUP"))
        end
        local n=0; for _,line in ipairs(logs) do if line:find("Results:",1,true) then n=n+1 end end
        assert(n==1,"expected exactly one summary")
        assert(#d3d._state.callback_errors==0,table.concat(d3d._state.callback_errors,"; "))
        for _,key in ipairs({"fonts","texts","textures","subscriptions"}) do assert(d3d.stats()[key]==0,key.." leaked") end
        for _,t in ipairs(timers) do assert(t.destroyed and not t.active) end
    end)
    _G.print=saved_print
    assert(ok,err)
end
scenario(true)
saved_print("[PASS mock] actual example READY / disabled / enabled / resize / relayout / cleanup protocol")
scenario(false)
saved_print("[PASS mock] actual example timeout fails and releases all resources")

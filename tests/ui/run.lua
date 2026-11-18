-- OFFLINE ONLY: fake native resources/events, exercising the actual shipped library.
local fake = {mouse = {LEFT = 1}, width = 800, height = 600,
    counts = {fonts = 0, texts = 0, textures = 0, subscriptions = 0}, objects = {}, calls = 0}
local function step()
    fake.calls = fake.calls + 1
    if fake.fail_at == fake.calls then error("injected native failure") end
end
local function sub(owner, event, cb)
    step()
    local s = {active = true, owner = owner, event = event, callback = cb}
    fake.counts.subscriptions = fake.counts.subscriptions + 1
    function s:cancel()
        if self.active then fake.counts.subscriptions = fake.counts.subscriptions - 1; self.active = false end
        return true
    end
    fake.objects[#fake.objects + 1] = s
    return s
end
function fake.emit(owner, event, e)
    local snapshot = {}; for _, s in ipairs(fake.objects) do snapshot[#snapshot + 1] = s end
    for _, s in ipairs(snapshot) do
        if s.active and s.owner == owner and s.event == event then s.callback(e or {}) end
    end
end
for _, pair in ipairs({{"Font", "fonts"}, {"Text", "texts"}, {"Texture", "textures"}}) do
    local class, counter = pair[1], pair[2]
    fake[class] = {new = function(o)
        step(); fake.counts[counter] = fake.counts[counter] + 1
        local r = {options = o, visible = o.visible, hit_test = o.hit_test}
        local function valid() assert(not r.destroyed, "native use after destroy"); step() end
        function r:destroy()
            if not self.destroyed then self.destroyed = true; fake.counts[counter] = fake.counts[counter] - 1 end
            return true
        end
        function r:set_rect(x,y,w,h) valid(); self.rect = {x,y,w,h}; return true end
        function r:set_position(x,y) valid(); self.position = {x,y}; return true end
        function r:set_visible(v) valid(); self.visible = v; return true end
        function r:set_hit_test(v) valid(); self.hit_test = v; return true end
        function r:set_color(v) valid(); self.color = v; return true end
        function r:set_text(v) valid(); self.label = v; return true end
        function r:on(event, cb) valid(); return sub(self, event, cb) end
        return r
    end}
end
function fake.window_size() step(); return fake.width, fake.height end
function fake.on(event, cb) return sub(fake, event, cb) end
package.preload["jass.d3d"] = function() return fake end
local UI = dofile("map/lib/ui.lua")
local passed = 0
local function test(name, fn)
    fn(); passed = passed + 1; print("[PASS mock] " .. name)
end
local function baseline()
    for key, n in pairs(fake.counts) do assert(n == 0, key .. " leaked: " .. n) end
end
test("nested row/column spacing padding hidden and viewport resize", function()
    local ctx = assert(UI.new())
    local col = assert(ctx:column {padding = 10, spacing = 5, position = function(w,h) return w-300,h-200 end})
    local row = assert(col:row {padding = 2, spacing = 7})
    local a = assert(row:button {width = 40,height = 30})
    local b = assert(row:button {width = 50,height = 20})
    local c = assert(col:button {width = 20,height = 10})
    local x,y,w,h = a:get_rect(); assert(x==512 and y==412 and w==40 and h==30)
    x,y = b:get_rect(); assert(x==559 and y==412)
    x,y = c:get_rect(); assert(x==510 and y==449)
    a:set_hidden(true); x = b:get_rect(); assert(x==512 and not a.texture.visible)
    fake.width,fake.height=1000,700; fake.emit(fake,"resize")
    x,y=b:get_rect(); assert(x==712 and y==512)
    assert(ctx:destroy()); assert(ctx:destroy()); baseline()
end)
test("hover press release disabled hidden and local callback", function()
    local ctx=assert(UI.new()); local clicks=0
    local row=assert(ctx:row())
    local b=assert(row:button {text="test",on_click=function() clicks=clicks+1 end})
    local t=b.texture
    fake.emit(t,"enter"); assert(t.color==b.colors.hover)
    fake.emit(t,"mouse_down"); assert(t.color==b.colors.pressed)
    fake.emit(t,"mouse_up"); assert(t.color==b.colors.hover)
    fake.emit(t,"click"); assert(clicks==1)
    row:set_enabled(false); fake.emit(t,"click"); assert(clicks==1 and t.color==b.colors.disabled)
    row:set_enabled(true); b:set_hidden(true); fake.emit(t,"click"); assert(clicks==1 and not t.hit_test)
    b:set_hidden(false); fake.emit(t,"click"); assert(clicks==2)
    assert(b:destroy()); assert(b:destroy()); assert(not pcall(b.set_enabled,b,true))
    assert(ctx:destroy()); baseline()
end)
test("destroy whole context inside click callback", function()
    local ctx=assert(UI.new())
    local b=assert(ctx:button {text="destroy",on_click=function() assert(ctx:destroy()) end})
    fake.emit(b.texture,"click"); baseline(); assert(ctx:destroy())
end)
test("rollback every constructor and native setup failure", function()
    for failure=1,45 do
        local ctx=assert(UI.new()); fake.calls=0; fake.fail_at=failure
        local b,err=ctx:button {text="rollback"}
        fake.fail_at=nil
        if not b then assert(type(err)=="string") end
        assert(ctx:destroy()); baseline()
    end
    fake.calls=0; fake.fail_at=2
    local ctx,err=UI.new(); fake.fail_at=nil
    assert(not ctx and err); baseline()
end)
test("constructor nil/error return rolls back prior resources", function()
    local ctx=assert(UI.new()); local saved=fake.Text.new
    fake.Text.new=function() return nil,"allocation failed" end
    local b,err=ctx:button {text="fail"}; fake.Text.new=saved
    assert(not b and err:find("allocation failed",1,true)); assert(ctx:destroy()); baseline()
end)
local f=assert(io.open("map/lib/ui.lua","rb")); local source=f:read("a"); f:close()
f=assert(io.open("examples/12-ui-components/lib/ui.lua","rb")); local copy=f:read("a"); f:close()
assert(source==copy,"example library copy diverged")
print(string.format("OFFLINE MOCK: %d passed; no live input or rendering validated",passed))

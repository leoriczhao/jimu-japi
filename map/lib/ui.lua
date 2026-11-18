-- lib/ui.lua — minimal author-level button / row / column UI on top of jass.d3d.
--
-- This library only calls the public jass.d3d API (Font / Text / Texture,
-- window_size, ARGB color integers, module resize subscription and texture
-- mouse subscriptions). It never calls gameplay natives and makes no
-- multiplayer-synchronization claims: click callbacks are local presentation
-- code chosen by the author.
--
-- Coordinate model
--   * Every number is a War3 CLIENT-AREA pixel: origin = client top-left,
--     +x right, +y down. This is exactly the space of d3d.Texture rects and
--     d3d event x/y; no normalization is applied.
--   * A top-level node is positioned by `x`/`y`, or by
--     `position = function(window_w, window_h) return x, y end`. The callback is
--     re-evaluated on every reflow, so a resize can re-anchor it.
--   * A container content box starts at (node.x + padding, node.y + padding).
--     Row children advance along +x; column children advance along +y. The gap
--     between two visible children is `spacing`.
--   * Container size is intrinsic: sum/max of visible children + 2 * padding.
--     Buttons use explicit width/height (default 160x40). get_rect() always
--     returns absolute client pixels.
--   * Hidden or destroyed children are removed from the flow: they do not
--     contribute to container size and do not advance the cursor. They can be
--     shown again with set_hidden(false).
--   * Button labels are left-aligned at rect.x + text_padding and vertically
--     centred with floor((rect.h - font_height) / 2). jass.d3d has no text
--     measurement primitive, so label width never influences layout; pick
--     button sizes explicitly.
--
-- Interaction model (native SDK hit-testing, asynchronous input)
--   * Each button owns 5 Texture subscriptions: enter, leave, mouse_down,
--     mouse_up (hover/pressed visuals) and click (d3d.mouse.LEFT filter).
--     Events are delivered by the SDK's own dispatcher; this library never
--     polls or fakes input.
--   * visible/hidden = native Texture visible + hit_test. Hidden buttons cannot
--     be hovered or clicked.
--   * enabled/disabled keeps hit_test ON while visible: a disabled button
--     consumes pointer events (no click-through) but never invokes on_click.
--     It counts such attempts in blocked_clicks and may call on_blocked_click.
--   * Disabling/hiding a container propagates to its descendants.
--   * A click callback may destroy its button or the whole Context. The
--     callback wrapper checks `destroyed` after user code and never touches a
--     native object that may have been released.
--
-- Resource lifetime
--   * A button with a label owns Font -> Text plus one Texture. Release order is
--     Text, Texture, Font, after cancelling that button's subscriptions.
--   * Before releasing, the library hides the native Texture/Text and clears
--     hit_test, so a failed native destroy cannot leave a visible, clickable
--     orphan. A failed release returns nil, err and leaves the node in its
--     parent so a later destroy() can retry the remaining handles; layout
--     ignores the destroyed node in the meantime.
--   * destroy() is idempotent. Context:destroy() also cancels the module resize
--     subscription. Creation failures roll back every partially created native
--     object/subscription.
--
-- Usage
--   local ui = require "lib.ui"
--   local ctx = assert(ui.new(d3d))                 -- or ui.new { d3d = d3d }
--   local root = assert(ctx:column {
--       position = function(w, h) return math.floor((w - 296) / 2),
--                                        math.floor((h - 92) / 2) end,
--       padding = 12, spacing = 10,
--   })
--   local row = assert(root:row { padding = 0, spacing = 10 })
--   local ok = assert(row:button {
--       text = "OK", width = 120, height = 34,
--       colors = { normal = 0xE0181E2C, hover = 0xF0304C78,
--                  pressed = 0xFF6094D0, disabled = 0xBE1E1E1E },
--       on_click = function(button, event) button:set_text("clicked") end,
--       on_blocked_click = function(button, event) end,   -- optional
--   })
--   local x, y, w, h = ok:get_rect()
--   ok:set_enabled(false); ok:set_hidden(false); ok:set_text("new")
--   ctx:destroy()
--
-- Not included on purpose: text measurement, borders, scrolling, dragging,
-- keyboard focus, theming across a whole application, and multiplayer sync.

local native = require "jass.d3d"
local UI = {VERSION = "0.1.0"}
local Context, Node = {}, {}
Context.__index, Node.__index = Context, Node

local defaults = { normal = 0xFF808080, hover = 0xFFB0B0B0,
    pressed = 0xFF505050, disabled = 0xFF383838 }
local default_text_colors = { normal = 0xFFFFFFFF, hover = 0xFFFFFFFF,
    pressed = 0xFFFFFFFF, disabled = 0xFF808080 }
local default_source = "game://ReplaceableTextures/CommandButtons/BTNFootman.blp"
local min_int32, max_int32 = -2147483648, 2147483647

local function need(value, err)
    assert(value, err or "native operation failed")
    return value
end

local function alive(self)
    assert(not self.destroyed, "UI object is destroyed")
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function number(value, fallback, label)
    if value == nil then return fallback end
    assert(finite(value) and value >= 0,
        (label or "value") .. " must be a finite nonnegative pixel size")
    return value
end

local function coordinate(value, fallback, label)
    if value == nil then return fallback end
    assert(finite(value), (label or "coordinate") .. " must be finite")
    return value
end

local function integer(value, fallback, label)
    if value == nil then return fallback end
    assert(finite(value) and value == math.floor(value)
        and value >= min_int32 and value <= max_int32,
        (label or "value") .. " must be a signed 32-bit integer")
    return value
end

local function color(value, fallback, label)
    if value == nil then return fallback end
    assert(finite(value) and value == math.floor(value)
        and value >= 0 and value <= 0xFFFFFFFF,
        (label or "color") .. " must be an ARGB integer 0..0xFFFFFFFF")
    return value
end

local function remove(list, item)
    for i, v in ipairs(list) do
        if v == item then table.remove(list, i); return end
    end
end

local function size(node)
    if node.kind == "button" then return node.width, node.height end
    local main, cross, count = 0, 0, 0
    for _, child in ipairs(node.children) do
        if not child.hidden and not child.destroyed then
            local w, h = size(child)
            main = main + (node.kind == "row" and w or h)
            cross = math.max(cross, node.kind == "row" and h or w)
            count = count + 1
        end
    end
    main = main + math.max(0, count - 1) * node.spacing
    local w, h = main, cross
    if node.kind == "column" then w, h = cross, main end
    return node.width or w + 2 * node.padding, node.height or h + 2 * node.padding
end

function Node:_paint()
    if self.destroyed or self.kind ~= "button" then return end
    local state = not self.effective_enabled and "disabled"
        or self.pressed and "pressed" or self.hovered and "hover" or "normal"
    need(self.texture:set_color(self.colors[state]))
    if self.text then
        need(self.text:set_color(self.text_colors[state]))
    end
end

local function place(node, x, y, visible, enabled)
    if node.destroyed then return end
    node.x, node.y = x, y
    node.effective_visible = visible and not node.hidden
    node.effective_enabled = enabled and node.enabled
    if not node.effective_visible then
        node.hovered, node.pressed = false, false
    elseif not node.effective_enabled then
        -- Keep `hovered`: disabling must not lose the fact that the native
        -- hover stack still contains this texture, otherwise re-enabling under
        -- a stationary cursor would show the normal state until leave+enter.
        node.pressed = false
    end
    if node.kind == "button" then
        need(node.texture:set_rect(x, y, node.width, node.height))
        need(node.texture:set_visible(node.effective_visible))
        -- Disabled buttons still consume input, but cannot invoke on_click.
        need(node.texture:set_hit_test(node.effective_visible))
        if node.text then
            local font_height = node.font_height or 16
            need(node.text:set_position(
                x + node.text_padding,
                y + math.floor((node.height - font_height) / 2)))
            need(node.text:set_visible(node.effective_visible))
        end
        node:_paint()
    else
        local cursor = node.padding
        for _, child in ipairs(node.children) do
            local cx = x + (node.kind == "row" and cursor or node.padding)
            local cy = y + (node.kind == "column" and cursor or node.padding)
            place(child, cx, cy, node.effective_visible, node.effective_enabled)
            if not child.hidden and not child.destroyed then
                local w, h = size(child)
                cursor = cursor + (node.kind == "row" and w or h) + node.spacing
            end
        end
    end
end

function Context:_report_error(message)
    if self.destroyed then return end
    local handler = self.on_error
    if type(handler) == "function" then
        local ok, err = pcall(handler, self, message)
        if ok then return end
        message = message .. " (on_error failed: " .. tostring(err) .. ")"
    end
    print("[lib.ui] " .. tostring(message))
end

function Context:set_on_error(handler)
    alive(self)
    assert(handler == nil or type(handler) == "function", "on_error must be a function")
    self.on_error = handler
    return true
end

function Context:reflow()
    alive(self)
    local w, h = self.d3d.window_size(); need(w, h)
    self.width, self.height = w, h
    for _, node in ipairs(self.children) do
        local x, y = node.left, node.top
        if node.position then x, y = node.position(w, h) end
        assert(finite(x) and finite(y), "position must return finite x,y")
        place(node, x, y, true, true)
    end
    return true
end

function Node:get_rect()
    alive(self)
    local w, h = size(self)
    return self.x, self.y, w, h
end

function Node:get_state()
    if self.destroyed then return "destroyed" end
    if not self.effective_visible then return "hidden" end
    if not self.effective_enabled then return "disabled" end
    if self.pressed then return "pressed" end
    if self.hovered then return "hover" end
    return "normal"
end

function Node:get_colors()
    if self.destroyed or self.kind ~= "button" then return nil, nil end
    local ok_bg, bg = pcall(function() return self.texture:get_color() end)
    local ok_fg, fg = pcall(function()
        if self.text then return self.text:get_color() end
        return nil
    end)
    if not ok_bg then bg = nil end
    if not ok_fg then fg = nil end
    return bg, fg
end

function Node:get_blocked_clicks()
    return self.blocked_clicks or 0
end

function Node:set_enabled(value)
    alive(self)
    self.enabled = not not value
    local ok, err = pcall(self.context.reflow, self.context)
    if not ok then return nil, tostring(err) end
    return true
end

function Node:set_hidden(value)
    alive(self)
    self.hidden = not not value
    local ok, err = pcall(self.context.reflow, self.context)
    if not ok then return nil, tostring(err) end
    return true
end

function Node:set_visible(value)
    return self:set_hidden(not value)
end

function Node:set_text(value)
    alive(self)
    assert(self.text, "button has no label")
    return self.text:set_text(value)
end

function Node:get_text()
    alive(self)
    if self.text then return self.text:get_text() end
    return nil
end

function Node:is_destroyed()
    return self.destroyed == true
end

-- Cleanup attempts every release even when a native release fails. Retry destroy
-- releases any remaining handles; ordinary repeated calls are successful no-ops.
local function release(self, errors)
    for i = #self.subscriptions, 1, -1 do
        local ok, err = pcall(function() need(self.subscriptions[i]:cancel()) end)
        if ok then table.remove(self.subscriptions, i) else errors[#errors + 1] = tostring(err) end
    end
    -- Best-effort hide before release: a native destroy failure must not leave a
    -- visible or clickable orphan behind.
    if self.texture then
        pcall(function() self.texture:set_visible(false) end)
        pcall(function() self.texture:set_hit_test(false) end)
    end
    if self.text then pcall(function() self.text:set_visible(false) end) end
    for _, key in ipairs({"text", "texture", "font"}) do
        if self[key] then
            local ok, err = pcall(function() need(self[key]:destroy()) end)
            if ok then self[key] = nil else errors[#errors + 1] = tostring(err) end
        end
    end
end

function Node:destroy()
    self.destroyed, self.on_click, self.on_blocked_click = true, nil, nil
    local errors = {}
    for i = #self.children, 1, -1 do
        local ok, err = self.children[i]:destroy()
        if not ok then errors[#errors + 1] = err end
    end
    release(self, errors)
    -- Keep failed-release nodes in the parent so Context:destroy() can retry
    -- them; size()/place() ignore destroyed nodes in the meantime.
    if #errors == 0 then remove(self.parent.children, self) end
    if not self.context._rolling_back and not self.context.destroyed
        and not self.parent.destroyed then
        local ok, err = pcall(self.context.reflow, self.context)
        if not ok then
            self.context:_report_error("destroy reflow failed: " .. tostring(err))
        end
    end
    if #errors > 0 then return nil, table.concat(errors, "; ") end
    return true
end

function Context:destroy()
    self.destroyed = true
    local errors = {}
    for i = #self.children, 1, -1 do
        local ok, err = self.children[i]:destroy()
        if not ok then errors[#errors + 1] = err end
    end
    release(self, errors)
    self.on_error = nil
    if #errors > 0 then return nil, table.concat(errors, "; ") end
    return true
end

function Context:is_destroyed()
    return self.destroyed == true
end

local function create(parent, kind, options)
    alive(parent)
    local ctx = parent.context or parent
    local node
    local ok, err = pcall(function()
        local o = options or {}
        assert(type(o) == "table", "options must be a table")
        assert(o.position == nil or type(o.position) == "function",
            "position must be a function")
        assert(o.source == nil or type(o.source) == "string", "source must be a string")
        assert(o.text == nil or type(o.text) == "string", "text must be a string")
        assert(o.on_click == nil or type(o.on_click) == "function",
            "on_click must be a function")
        assert(o.on_blocked_click == nil or type(o.on_blocked_click) == "function",
            "on_blocked_click must be a function")
        local colors = o.colors or {}
        local text_colors = o.text_colors or {}
        assert(type(colors) == "table", "colors must be a table")
        assert(type(text_colors) == "table", "text_colors must be a table")

        local font_size = integer(o.font_size, 16, "font_size")
        assert(font_size > 0, "font_size must be positive")
        local z = integer(o.z, 1000, "z")
        node = setmetatable({context = ctx, parent = parent, kind = kind,
            children = {}, subscriptions = {},
            left = coordinate(o.x, 0, "x"), top = coordinate(o.y, 0, "y"),
            position = o.position, enabled = o.enabled ~= false, hidden = o.hidden == true,
            width = number(o.width, kind == "button" and 160 or nil, "width"),
            height = number(o.height, kind == "button" and 40 or nil, "height"),
            padding = number(o.padding, 0, "padding"),
            spacing = number(o.spacing, 0, "spacing"),
            text_padding = number(o.text_padding, 8, "text_padding"),
            on_click = o.on_click, on_blocked_click = o.on_blocked_click,
            blocked_clicks = 0, colors = {}, text_colors = {}}, Node)
        if kind == "button" then
            for key, value in pairs(defaults) do
                node.colors[key] = color(colors[key], value, "colors." .. key)
            end
            for key, value in pairs(default_text_colors) do
                node.text_colors[key] = color(text_colors[key], value,
                    "text_colors." .. key)
            end
            node.texture = need(ctx.d3d.Texture.new {source = o.source or default_source,
                x = 0, y = 0, width = node.width, height = node.height, z = z,
                color = node.colors.normal, visible = false, hit_test = false})
            if o.text then
                node.font = need(ctx.d3d.Font.new {height = font_size})
                -- Font:get_height exists in jass.d3d, but a test adapter may omit
                -- it. Fall back to the requested size so layout stays defined.
                local height_ok, font_height = pcall(function() return node.font:get_height() end)
                node.font_height = (height_ok and type(font_height) == "number"
                    and font_height > 0) and font_height or font_size
                node.text = need(ctx.d3d.Text.new {font = node.font, text = o.text,
                    x = 0, y = 0, color = node.text_colors.normal,
                    z = math.min(z + 1, max_int32), visible = false})
            end
            local function listen(event, callback)
                node.subscriptions[#node.subscriptions + 1] = need(node.texture:on(event,
                    function(event_table)
                        if node.destroyed or not node.effective_visible then return end
                        callback(event_table)
                    end, {button = ctx.d3d.mouse.LEFT}))
            end
            listen("enter", function() node.hovered = true; node:_paint() end)
            listen("leave", function() node.hovered = false; node.pressed = false; node:_paint() end)
            listen("mouse_down", function() node.pressed = node.effective_enabled; node:_paint() end)
            listen("mouse_up", function() node.pressed = false; node:_paint() end)
            listen("click", function(e)
                if node.destroyed or not node.effective_visible then return end
                if node.effective_enabled then
                    if node.on_click then
                        local called, call_err = pcall(node.on_click, node, e)
                        if not called and not node.destroyed then
                            node.context:_report_error("on_click failed: " .. tostring(call_err))
                        end
                    end
                else
                    node.blocked_clicks = node.blocked_clicks + 1
                    if node.on_blocked_click then
                        local called, call_err = pcall(node.on_blocked_click, node, e)
                        if not called and not node.destroyed then
                            node.context:_report_error("on_blocked_click failed: "
                                .. tostring(call_err))
                        end
                    end
                end
            end)
        end
        parent.children[#parent.children + 1] = node
        ctx:reflow()
    end)
    if not ok then
        if not node then return nil, tostring(err) end
        ctx._rolling_back = true
        local cleaned, cleanup_err = node:destroy()
        ctx._rolling_back = false
        return nil, tostring(err) .. (not cleaned and "; rollback: " .. tostring(cleanup_err) or "")
    end
    return node
end

for _, kind in ipairs({"row", "column", "button"}) do
    Context[kind] = function(self, options) return create(self, kind, options) end
    Node[kind] = function(self, options)
        alive(self)
        assert(self.kind ~= "button", "button cannot contain children")
        return create(self, kind, options)
    end
end

function UI.new(adapter)
    local d3d = adapter
    local options = nil
    if type(adapter) == "table" and adapter.d3d ~= nil then
        d3d = adapter.d3d
        options = adapter
    end
    local on_error = options and options.on_error
    if on_error ~= nil and type(on_error) ~= "function" then
        return nil, "on_error must be a function"
    end
    local ctx = setmetatable({d3d = d3d or native, children = {},
        subscriptions = {}, on_error = on_error, _rolling_back = false}, Context)
    local ok, err = pcall(function()
        ctx:reflow()
        ctx.subscriptions[1] = need(ctx.d3d.on("resize", function()
            if ctx.destroyed then return end
            -- A resize callback error would make the native SDK cancel this
            -- subscription, so contain reflow failures here and keep listening.
            local reflow_ok, reflow_err = pcall(ctx.reflow, ctx)
            if not reflow_ok then
                ctx:_report_error("resize reflow failed: " .. tostring(reflow_err))
            end
        end))
    end)
    if not ok then
        local cleaned, cleanup_err = ctx:destroy()
        return nil, tostring(err)
            .. (not cleaned and "; rollback: " .. tostring(cleanup_err) or "")
    end
    return ctx
end

return UI

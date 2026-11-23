-- std/ui.lua — upgraded author-level D3D9 UI component library.
--
-- Components:
--   * ctx:column(opts) / ctx:row(opts)  -- auto-flowing layout containers (responsive resize)
--   * node:panel(opts)                  -- styled background box container (optional column/row layout)
--   * node:label(opts)                  -- standalone text node with set_text / set_color / fade_to
--   * node:button(opts)                 -- hover/pressed/disabled button with on_click & built-in tooltip
--   * node:progress_bar(opts)           -- background + fill bar + optional label + smooth tweened set_value
--   * ctx:show_tooltip(text, x, y) / ctx:hide_tooltip() -- shared viewport-clamped floating tooltip
--
-- Dependency injection:
--   UI.new()                     -- uses jass.d3d + std.tween automatically
--   UI.new({ d3d = fake_d3d })   -- offline testable with mock D3D adapter

local util  = require "std.util"
local Tween = require "std.tween"

local UI = { VERSION = "0.6.0" }

local DEFAULT_TEX = "game://ReplaceableTextures/CommandButtons/BTNFootman.blp"
local DEFAULT_BTN_COLORS = {
    normal   = 0xE0202838,
    hover    = 0xF0344A6E,
    pressed  = 0xFF4A6FA5,
    disabled = 0xB81C1C22,
}
local DEFAULT_TXT_COLORS = {
    normal   = 0xFFFFFFFF,
    hover    = 0xFFFFF4C2,
    pressed  = 0xFFE0E0E0,
    disabled = 0xFF888888,
}

local Context = {}
local Node = {}
Context.__index = Context
Node.__index = Node

local function replace_alpha(argb, alpha)
    local a = util.clamp(math.floor(alpha), 0, 255)
    return (a << 24) | (argb & 0x00FFFFFF)
end

local function make_font(d3d, opts)
    opts = opts or {}
    return assert(d3d.Font.new({
        face = opts.face or "Arial",
        height = opts.height or 16,
        weight = opts.weight or 600,
    }))
end

local function safe_destroy(obj)
    if obj and obj.destroy then
        pcall(obj.destroy, obj)
    end
end

local function cancel_subs(list)
    if not list then return end
    for i = 1, #list do
        if list[i] and list[i].cancel then
            pcall(list[i].cancel, list[i])
        end
    end
end

-- ── Context ────────────────────────────────────────────────────────────────

function UI.new(opts)
    opts = opts or {}
    local d3d = opts.d3d or (opts.is_available and opts) or require("jass.d3d")
    assert(d3d and d3d.is_available(), "std.ui: D3D is not available")

    local self = setmetatable({
        d3d = d3d,
        roots = {},
        destroyed = false,
        _tooltip = nil,
        _resize_sub = nil,
        _tweens = {},
    }, Context)

    if d3d.on then
        self._resize_sub = d3d.on("resize", function()
            if not self.destroyed then
                self:reflow()
            end
        end)
    end

    return self
end

function Context:_track_tween(tw)
    if tw then
        self._tweens[#self._tweens + 1] = tw
    end
    return tw
end

function Context:_ensure_tooltip()
    if self._tooltip then return self._tooltip end
    local d3d = self.d3d
    local font = make_font(d3d, { height = 14, weight = 500 })
    local bg = assert(d3d.Texture.new({
        source = DEFAULT_TEX,
        x = 0, y = 0, width = 180, height = 32,
        color = 0xEC10141E,
        z = 900,
        visible = false,
        hit_test = false,
    }))
    local txt = assert(d3d.Text.new({
        font = font,
        text = "",
        x = 8, y = 8,
        color = 0xFFFFF4C8,
        z = 901,
        visible = false,
    }))
    self._tooltip = { font = font, bg = bg, txt = txt, visible = false }
    return self._tooltip
end

function Context:show_tooltip(text, x, y, width, height)
    if self.destroyed or not text or #text == 0 then return end
    local tip = self:_ensure_tooltip()
    local tw = width or math.max(120, math.min(340, #text * 9 + 20))
    local th = height or 32
    local cw, ch = self.d3d.window_size()
    local px = util.clamp(math.floor(x or 0), 4, math.max(4, cw - tw - 4))
    local py = util.clamp(math.floor(y or 0), 4, math.max(4, ch - th - 4))
    tip.bg:set_rect(px, py, tw, th)
    tip.bg:set_visible(true)
    tip.txt:set_text(tostring(text))
    tip.txt:set_position(px + 10, py + math.floor((th - 14) / 2))
    tip.txt:set_visible(true)
    tip.visible = true
end

function Context:hide_tooltip()
    if self._tooltip and self._tooltip.visible then
        self._tooltip.bg:set_visible(false)
        self._tooltip.txt:set_visible(false)
        self._tooltip.visible = false
    end
end

function Context:reflow()
    if self.destroyed then return end
    local cw, ch = self.d3d.window_size()
    for i = 1, #self.roots do
        local root = self.roots[i]
        if not root.destroyed then
            root:_measure()
            local rx, ry = root.x, root.y
            if root.position then
                rx, ry = root.position(cw, ch, root.w, root.h)
            end
            root:_arrange(rx or 0, ry or 0)
        end
    end
end

function Context:destroy()
    if self.destroyed then return true end
    self.destroyed = true
    for i = 1, #self._tweens do
        self._tweens[i]:cancel()
    end
    self._tweens = {}
    if self._resize_sub and self._resize_sub.cancel then
        pcall(self._resize_sub.cancel, self._resize_sub)
        self._resize_sub = nil
    end
    if self._tooltip then
        safe_destroy(self._tooltip.txt)
        safe_destroy(self._tooltip.bg)
        safe_destroy(self._tooltip.font)
        self._tooltip = nil
    end
    for i = #self.roots, 1, -1 do
        self.roots[i]:destroy()
    end
    self.roots = {}
    return true
end

-- ── Node constructors ──────────────────────────────────────────────────────

local function create_node(ctx, parent, kind, opts)
    opts = opts or {}
    local self = setmetatable({
        ctx = ctx,
        parent = parent,
        kind = kind,
        children = {},
        subs = {},
        x = opts.x or 0,
        y = opts.y or 0,
        w = opts.width or 0,
        h = opts.height or 0,
        padding = opts.padding or 0,
        spacing = opts.spacing or 8,
        direction = opts.direction or (kind == "row" and "row" or "column"),
        position = opts.position,
        z = opts.z or (parent and (parent.z + 2) or 100),
        hidden = opts.hidden == true,
        enabled = opts.enabled ~= false,
        destroyed = false,
        hovered = false,
        pressed = false,
        tooltip = opts.tooltip,
    }, Node)

    if parent then
        parent.children[#parent.children + 1] = self
    else
        ctx.roots[#ctx.roots + 1] = self
    end
    return self
end

function Context:column(opts)
    local n = create_node(self, nil, "column", opts)
    self:reflow()
    return n
end

function Context:row(opts)
    local n = create_node(self, nil, "row", opts)
    self:reflow()
    return n
end

function Context:panel(opts)
    opts = opts or {}
    local n = create_node(self, nil, "panel", opts)
    n._bg_color = opts.color or 0xD8141A26
    n._bg = assert(self.d3d.Texture.new({
        source = opts.source or DEFAULT_TEX,
        x = n.x, y = n.y, width = math.max(1, n.w), height = math.max(1, n.h),
        color = n._bg_color,
        z = n.z,
        visible = not n.hidden,
        hit_test = opts.hit_test == true,
    }))
    n._fixed_w = opts.width
    n._fixed_h = opts.height
    self:reflow()
    return n
end

function Node:column(opts)
    local n = create_node(self.ctx, self, "column", opts)
    self.ctx:reflow()
    return n
end

function Node:row(opts)
    local n = create_node(self.ctx, self, "row", opts)
    self.ctx:reflow()
    return n
end

function Node:panel(opts)
    opts = opts or {}
    local n = create_node(self.ctx, self, "panel", opts)
    n._bg_color = opts.color or 0xD8141A26
    n._bg = assert(self.ctx.d3d.Texture.new({
        source = opts.source or DEFAULT_TEX,
        x = n.x, y = n.y, width = math.max(1, n.w), height = math.max(1, n.h),
        color = n._bg_color,
        z = n.z,
        visible = not n:is_effectively_hidden(),
        hit_test = opts.hit_test == true,
    }))
    n._fixed_w = opts.width
    n._fixed_h = opts.height
    self.ctx:reflow()
    return n
end

function Node:label(opts)
    opts = opts or {}
    local n = create_node(self.ctx, self, "label", opts)
    n._font_height = opts.font_height or 16
    n.w = opts.width or 180
    n.h = opts.height or (n._font_height + 6)
    n._text_color = opts.color or 0xFFFFFFFF
    n._font = make_font(self.ctx.d3d, {
        face = opts.face or "Arial",
        height = n._font_height,
        weight = opts.weight or 600,
    })
    n._text = assert(self.ctx.d3d.Text.new({
        font = n._font,
        text = tostring(opts.text or ""),
        x = n.x, y = n.y,
        color = n._text_color,
        z = n.z + 1,
        visible = not n:is_effectively_hidden(),
    }))
    self.ctx:reflow()
    return n
end

function Node:button(opts)
    opts = opts or {}
    local n = create_node(self.ctx, self, "button", opts)
    n.w = opts.width or 160
    n.h = opts.height or 38
    n._font_height = opts.font_height or 16
    n._text_padding = opts.text_padding or 12
    n._colors = {
        normal   = (opts.colors and opts.colors.normal)   or DEFAULT_BTN_COLORS.normal,
        hover    = (opts.colors and opts.colors.hover)    or DEFAULT_BTN_COLORS.hover,
        pressed  = (opts.colors and opts.colors.pressed)  or DEFAULT_BTN_COLORS.pressed,
        disabled = (opts.colors and opts.colors.disabled) or DEFAULT_BTN_COLORS.disabled,
    }
    n._text_colors = {
        normal   = (opts.text_colors and opts.text_colors.normal)   or DEFAULT_TXT_COLORS.normal,
        hover    = (opts.text_colors and opts.text_colors.hover)    or DEFAULT_TXT_COLORS.hover,
        pressed  = (opts.text_colors and opts.text_colors.pressed)  or DEFAULT_TXT_COLORS.pressed,
        disabled = (opts.text_colors and opts.text_colors.disabled) or DEFAULT_TXT_COLORS.disabled,
    }
    n._on_click = opts.on_click
    n._on_hover = opts.on_hover
    n._blocked_clicks = 0

    local vis = not n:is_effectively_hidden()
    n._bg = assert(self.ctx.d3d.Texture.new({
        source = opts.source or DEFAULT_TEX,
        x = n.x, y = n.y, width = n.w, height = n.h,
        color = n._colors.normal,
        z = n.z,
        visible = vis,
        hit_test = vis,
    }))
    n._font = make_font(self.ctx.d3d, {
        face = opts.face or "Arial",
        height = n._font_height,
        weight = opts.weight or 700,
    })
    n._text = assert(self.ctx.d3d.Text.new({
        font = n._font,
        text = tostring(opts.text or ""),
        x = n.x + n._text_padding,
        y = n.y + math.floor((n.h - n._font_height) / 2),
        color = n._text_colors.normal,
        z = n.z + 1,
        visible = vis,
    }))

    n.subs[#n.subs + 1] = n._bg:on("enter", function()
        if n.destroyed then return end
        n.hovered = true
        n:_sync_visuals()
        if n.tooltip then
            n.ctx:show_tooltip(n.tooltip, n.x, n.y - 36)
        end
        if n._on_hover then util.safe_call(n._on_hover, n, true) end
    end)
    n.subs[#n.subs + 1] = n._bg:on("leave", function()
        if n.destroyed then return end
        n.hovered = false
        n.pressed = false
        n:_sync_visuals()
        if n.tooltip then n.ctx:hide_tooltip() end
        if n._on_hover then util.safe_call(n._on_hover, n, false) end
    end)
    n.subs[#n.subs + 1] = n._bg:on("mouse_down", function()
        if n.destroyed or not n:is_effectively_enabled() then return end
        n.pressed = true
        n:_sync_visuals()
    end, { button = self.ctx.d3d.mouse.LEFT })
    n.subs[#n.subs + 1] = n._bg:on("mouse_up", function()
        if n.destroyed then return end
        n.pressed = false
        n:_sync_visuals()
    end, { button = self.ctx.d3d.mouse.LEFT })
    n.subs[#n.subs + 1] = n._bg:on("click", function(ev)
        if n.destroyed then return end
        if not n:is_effectively_enabled() then
            n._blocked_clicks = n._blocked_clicks + 1
            return
        end
        if n._on_click then util.safe_call(n._on_click, n, ev) end
    end, { button = self.ctx.d3d.mouse.LEFT })

    n:_sync_visuals()
    self.ctx:reflow()
    return n
end

function Node:progress_bar(opts)
    opts = opts or {}
    local n = create_node(self.ctx, self, "progress_bar", opts)
    n.w = opts.width or 200
    n.h = opts.height or 20
    n._value = opts.value or 0
    n._max = opts.max or 100
    n._ratio = (n._max > 0) and util.clamp(n._value / n._max, 0, 1) or 0
    n._bg_color = opts.bg_color or 0xD0141820
    n._fill_color = opts.fill_color or 0xFF28B864
    n._pad = opts.bar_padding or 2
    n._font_height = opts.font_height or 13
    n._label_format = opts.label_format -- e.g. "%d / %d"

    local vis = not n:is_effectively_hidden()
    n._bg = assert(self.ctx.d3d.Texture.new({
        source = opts.source or DEFAULT_TEX,
        x = n.x, y = n.y, width = n.w, height = n.h,
        color = n._bg_color,
        z = n.z,
        visible = vis,
        hit_test = opts.tooltip ~= nil and vis,
    }))
    local inner_w = math.max(1, math.floor((n.w - n._pad * 2) * n._ratio))
    n._fill = assert(self.ctx.d3d.Texture.new({
        source = opts.fill_source or opts.source or DEFAULT_TEX,
        x = n.x + n._pad, y = n.y + n._pad,
        width = inner_w, height = math.max(1, n.h - n._pad * 2),
        color = n._fill_color,
        z = n.z + 1,
        visible = vis and n._ratio > 0,
        hit_test = false,
    }))

    if opts.text or opts.label_format then
        n._font = make_font(self.ctx.d3d, { height = n._font_height, weight = 700 })
        local txt = opts.text or string.format(opts.label_format, math.floor(n._value), math.floor(n._max))
        n._text = assert(self.ctx.d3d.Text.new({
            font = n._font,
            text = txt,
            x = n.x + 8, y = n.y + math.floor((n.h - n._font_height) / 2),
            color = opts.text_color or 0xFFFFFFFF,
            z = n.z + 2,
            visible = vis,
        }))
    end

    if opts.tooltip then
        n.subs[#n.subs + 1] = n._bg:on("enter", function()
            if not n.destroyed and n.tooltip then
                n.ctx:show_tooltip(n.tooltip, n.x, n.y - 36)
            end
        end)
        n.subs[#n.subs + 1] = n._bg:on("leave", function()
            if not n.destroyed then n.ctx:hide_tooltip() end
        end)
    end

    self.ctx:reflow()
    return n
end

-- ── Layout & property helpers ──────────────────────────────────────────────

function Node:is_effectively_hidden()
    local cur = self
    while cur do
        if cur.hidden or cur.destroyed then return true end
        cur = cur.parent
    end
    return false
end

function Node:is_effectively_enabled()
    local cur = self
    while cur do
        if not cur.enabled or cur.destroyed then return false end
        cur = cur.parent
    end
    return true
end

function Node:_measure()
    if self.hidden or self.destroyed then
        return 0, 0
    end
    if self.kind == "button" or self.kind == "label" or self.kind == "progress_bar" then
        return self.w, self.h
    end

    local is_row = (self.direction == "row")
    local total_main, max_cross, visible_n = 0, 0, 0
    for i = 1, #self.children do
        local c = self.children[i]
        if not c.hidden and not c.destroyed then
            local cw, ch = c:_measure()
            visible_n = visible_n + 1
            if is_row then
                total_main = total_main + cw
                if ch > max_cross then max_cross = ch end
            else
                total_main = total_main + ch
                if cw > max_cross then max_cross = cw end
            end
        end
    end
    if visible_n > 1 then
        total_main = total_main + self.spacing * (visible_n - 1)
    end
    local auto_w = (is_row and total_main or max_cross) + self.padding * 2
    local auto_h = (is_row and max_cross or total_main) + self.padding * 2
    self.w = self._fixed_w or auto_w
    self.h = self._fixed_h or auto_h
    return self.w, self.h
end

function Node:_arrange(x, y)
    self.x = math.floor(x)
    self.y = math.floor(y)

    if self.kind == "panel" and self._bg then
        self._bg:set_rect(self.x, self.y, math.max(1, self.w), math.max(1, self.h))
    elseif self.kind == "label" and self._text then
        self._text:set_position(self.x, self.y)
    elseif self.kind == "button" then
        if self._bg then self._bg:set_rect(self.x, self.y, self.w, self.h) end
        if self._text then
            self._text:set_position(
                self.x + self._text_padding,
                self.y + math.floor((self.h - self._font_height) / 2)
            )
        end
    elseif self.kind == "progress_bar" then
        if self._bg then self._bg:set_rect(self.x, self.y, self.w, self.h) end
        self:_sync_bar_fill()
        if self._text then
            self._text:set_position(self.x + 8, self.y + math.floor((self.h - self._font_height) / 2))
        end
    end

    local is_row = (self.direction == "row")
    local cx = self.x + self.padding
    local cy = self.y + self.padding
    for i = 1, #self.children do
        local c = self.children[i]
        if not c.hidden and not c.destroyed then
            c:_arrange(cx, cy)
            if is_row then
                cx = cx + c.w + self.spacing
            else
                cy = cy + c.h + self.spacing
            end
        end
    end
    self:_sync_visuals()
end

function Node:_sync_bar_fill()
    if self.kind ~= "progress_bar" or not self._fill then return end
    local vis = not self:is_effectively_hidden()
    local max_w = math.max(1, self.w - self._pad * 2)
    local fw = math.floor(max_w * util.clamp(self._ratio, 0, 1))
    self._fill:set_visible(vis and fw > 0)
    if fw > 0 then
        self._fill:set_rect(self.x + self._pad, self.y + self._pad, fw, math.max(1, self.h - self._pad * 2))
    end
end

function Node:_sync_visuals()
    if self.destroyed then return end
    local vis = not self:is_effectively_hidden()
    if self.kind == "button" then
        local en = self:is_effectively_enabled()
        local state = not en and "disabled" or (self.pressed and "pressed" or (self.hovered and "hover" or "normal"))
        if self._bg then
            self._bg:set_color(self._colors[state])
            self._bg:set_visible(vis)
            self._bg:set_hit_test(vis)
        end
        if self._text then
            self._text:set_color(self._text_colors[state])
            self._text:set_visible(vis)
        end
    elseif self.kind == "panel" then
        if self._bg then self._bg:set_visible(vis) end
    elseif self.kind == "label" then
        if self._text then self._text:set_visible(vis) end
    elseif self.kind == "progress_bar" then
        if self._bg then
            self._bg:set_visible(vis)
            self._bg:set_hit_test(vis and self.tooltip ~= nil)
        end
        self:_sync_bar_fill()
        if self._text then self._text:set_visible(vis) end
    end
    for i = 1, #self.children do
        self.children[i]:_sync_visuals()
    end
end

function Node:get_rect()
    return self.x, self.y, self.w, self.h
end

function Node:set_text(text)
    if self.destroyed or not self._text then return end
    self._text:set_text(tostring(text))
end

function Node:set_color(argb)
    if self.destroyed then return end
    if self.kind == "label" and self._text then
        self._text_color = argb
        self._text:set_color(argb)
    elseif self.kind == "panel" and self._bg then
        self._bg_color = argb
        self._bg:set_color(argb)
    elseif self.kind == "progress_bar" and self._fill then
        self._fill_color = argb
        self._fill:set_color(argb)
    end
end

function Node:set_hidden(flag)
    if self.destroyed then return end
    self.hidden = flag == true
    if self.hidden and self.tooltip then self.ctx:hide_tooltip() end
    self.ctx:reflow()
end

function Node:set_enabled(flag)
    if self.destroyed then return end
    self.enabled = flag == true
    if not self.enabled then self.pressed = false end
    self:_sync_visuals()
end

function Node:set_tooltip(text)
    self.tooltip = text
    self:_sync_visuals()
end

--- Update a progress_bar's value (pass `duration > 0` for smooth easing animation!).
function Node:set_value(value, max_val, duration)
    if self.destroyed or self.kind ~= "progress_bar" then return end
    if max_val ~= nil then self._max = max_val end
    self._value = value
    local target = (self._max > 0) and util.clamp(value / self._max, 0, 1) or 0

    if self._bar_tween then
        self._bar_tween:cancel()
        self._bar_tween = nil
    end

    if self._text and self._label_format then
        self._text:set_text(string.format(self._label_format, math.floor(value), math.floor(self._max)))
    end

    if duration and duration > 0 then
        local start_ratio = self._ratio
        self._bar_tween = self.ctx:_track_tween(Tween.to({
            from = start_ratio,
            to = target,
            duration = duration,
            ease = "out_cubic",
            on_update = function(r)
                if not self.destroyed then
                    self._ratio = r
                    self:_sync_bar_fill()
                end
            end,
        }))
    else
        self._ratio = target
        self:_sync_bar_fill()
    end
end

--- Smoothly fade this node's alpha [0..255] over `duration` seconds.
function Node:fade_to(target_alpha, duration, on_complete)
    if self.destroyed then return nil end
    local base_color = self._bg_color or self._text_color or (self._colors and self._colors.normal) or 0xFFFFFFFF
    local from_alpha = (base_color >> 24) & 0xFF
    return self.ctx:_track_tween(Tween.to({
        from = from_alpha,
        to = util.clamp(target_alpha, 0, 255),
        duration = duration or 0.25,
        ease = "out_quad",
        on_update = function(a)
            if self.destroyed then return end
            if self._bg and self._bg_color then
                self._bg_color = replace_alpha(self._bg_color, a)
                self._bg:set_color(self._bg_color)
            end
            if self._text and self._text_color then
                self._text_color = replace_alpha(self._text_color, a)
                self._text:set_color(self._text_color)
            end
            if self.kind == "button" and self._bg then
                self._colors.normal = replace_alpha(self._colors.normal, a)
                self._bg:set_color(self._colors.normal)
            end
        end,
        on_complete = on_complete,
    }))
end

function Node:get_blocked_clicks()
    return self._blocked_clicks or 0
end

function Node:destroy()
    if self.destroyed then return true end
    self.destroyed = true
    if self._bar_tween then
        self._bar_tween:cancel()
        self._bar_tween = nil
    end
    cancel_subs(self.subs)
    self.subs = {}
    for i = #self.children, 1, -1 do
        self.children[i]:destroy()
    end
    self.children = {}
    safe_destroy(self._text)
    safe_destroy(self._fill)
    safe_destroy(self._bg)
    safe_destroy(self._font)
    self._text, self._fill, self._bg, self._font = nil, nil, nil, nil
    return true
end

return UI

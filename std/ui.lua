-- std/ui.lua — General-purpose declarative & fine-grained reactive UI framework.
--
-- Architecture (Fusion / SolidJS model over War3 native DzFrame):
--   * Zero business assumptions & zero hardcoded art/skin assets.
--   * Declarative Lua Table DSL: build the native frame tree ONCE on mount.
--   * Fine-grained reactivity via std.signal: any prop may be a static value or
--     a Signal/Computed; state changes update only the bound native attribute.
--   * Universal primitives:
--       Elements : UI.Box, UI.Text, UI.Image, UI.Button, UI.Model, UI.Input, UI.Raw
--       Layout   : UI.Row, UI.Column, UI.Grid, UI.Scroll, UI.Overlay
--       Flow     : UI.Show, UI.For (fixed-slot pooled list — zero frame churn!)
--       Compose  : UI.component(fn), UI.provide(k, v) / UI.use(k, default)
--   * Pluggable backend: defaults to std.frame (DzFrame), injectable for offline tests.

local Signal = require "std.signal"
local Frame  = require "std.frame"

local UI = { VERSION = "0.6.0" }

local NODE_TAG = {}

-- Active mount context stack (supports nested mounts & provide/use inheritance).
local active_ctx = nil

local function is_node(v)
    return type(v) == "table" and v._tag == NODE_TAG
end

local function make_node(kind, props)
    props = props or {}
    local children = {}
    for i = 1, #props do
        children[i] = props[i]
    end
    return {
        _tag = NODE_TAG,
        kind = kind,
        props = props,
        children = children,
    }
end

-- ── Universal DSL constructors ─────────────────────────────────────────────

function UI.Box(props)     return make_node("Box", props) end
function UI.Text(props)    return make_node("Text", props) end
function UI.Image(props)   return make_node("Image", props) end
function UI.Button(props)  return make_node("Button", props) end
function UI.Model(props)   return make_node("Model", props) end
function UI.Input(props)   return make_node("Input", props) end
function UI.Raw(props)     return make_node("Raw", props) end

function UI.Row(props)     return make_node("Row", props) end
function UI.Column(props)  return make_node("Column", props) end
function UI.Grid(props)    return make_node("Grid", props) end
function UI.Scroll(props)  return make_node("Scroll", props) end
function UI.Overlay(props) return make_node("Overlay", props) end

function UI.Show(props)    return make_node("Show", props) end
function UI.For(props)     return make_node("For", props) end

--- Define a reusable functional component: `local Card = UI.component(function(props, children) ... end)`.
function UI.component(fn)
    assert(type(fn) == "function", "UI.component expects a function")
    return function(props)
        props = props or {}
        local children = {}
        for i = 1, #props do children[i] = props[i] end
        return make_node("Component", {
            _fn = fn,
            _props = props,
            _children = children,
        })
    end
end

-- Re-export signal helpers on UI for ergonomics (`UI.state`, `UI.computed`, `UI.effect`, `UI.batch`).
UI.state    = Signal.state
UI.computed = Signal.computed
UI.effect   = Signal.effect
UI.batch    = Signal.batch
UI.untrack  = Signal.untrack

-- ── Context provide / use (theme, store, i18n, etc.) ───────────────────────

function UI.provide(key, value)
    assert(active_ctx, "UI.provide must be called inside a component or mount scope")
    active_ctx.env[key] = value
end

function UI.use(key, fallback)
    local env = active_ctx and active_ctx.env
    if env and env[key] ~= nil then
        return env[key]
    end
    return fallback
end

-- ── Reactive property binding helper ───────────────────────────────────────

local function bind_prop(val, apply_fn)
    if val == nil then return end
    if Signal.is_signal(val) then
        Signal.effect(function()
            apply_fn(val:get())
        end)
    else
        apply_fn(val)
    end
end

-- Resolve a value that may be a Signal, or return fallback if nil.
local function read_or(val, fallback)
    local v = Signal.read(val)
    if v == nil then return fallback end
    return v
end

-- ── Anchor positioning & layout helpers ────────────────────────────────────

-- War3 DzFrame uses 0.8 x 0.6 coordinates with origin (0,0) at bottom-left,
-- +x right, +y up. Inside flow containers (Row / Column / Grid), children are
-- anchored to TOPLEFT of the container with negative Y advancing downward.
local function apply_common_frame_props(backend, f, props, inst, managed_pos)
    local on_size_change = inst._on_metrics_change

    -- Size (w, h)
    if props.w ~= nil or props.h ~= nil then
        if Signal.is_signal(props.w) or Signal.is_signal(props.h) then
            Signal.effect(function()
                local w = read_or(props.w, 0.0)
                local h = read_or(props.h, 0.0)
                inst.w, inst.h = w, h
                backend.set_size(f, w, h)
                if on_size_change then on_size_change() end
            end)
        else
            inst.w = props.w or 0.0
            inst.h = props.h or 0.0
            backend.set_size(f, inst.w, inst.h)
        end
    end

    -- Positioning (skipped when a parent flow container owns the child's position)
    if not managed_pos then
        if props.fill then
            backend.set_all_points(f, props.rel or inst.parent_frame)
        elseif props.abs_x ~= nil or props.abs_y ~= nil then
            local anchor = props.anchor or "TOPLEFT"
            if Signal.is_signal(props.abs_x) or Signal.is_signal(props.abs_y) then
                Signal.effect(function()
                    backend.set_abs_point(f, anchor, read_or(props.abs_x, 0.0), read_or(props.abs_y, 0.0))
                end)
            else
                backend.set_abs_point(f, anchor, props.abs_x or 0.0, props.abs_y or 0.0)
            end
        elseif props.anchor ~= nil or props.x ~= nil or props.y ~= nil or props.rel ~= nil then
            local anchor = props.anchor or "TOPLEFT"
            local rel = props.rel or inst.parent_frame or backend.game_ui()
            local rel_anchor = props.rel_anchor or anchor
            if Signal.is_signal(props.x) or Signal.is_signal(props.y) then
                Signal.effect(function()
                    backend.set_point(f, anchor, rel, rel_anchor, read_or(props.x, 0.0), read_or(props.y, 0.0))
                end)
            else
                backend.set_point(f, anchor, rel, rel_anchor, props.x or 0.0, props.y or 0.0)
            end
        end
    end

    -- Visibility
    if props.visible ~= nil then
        bind_prop(props.visible, function(v)
            inst.visible = v and true or false
            backend.show(f, inst.visible)
            if on_size_change then on_size_change() end
        end)
    else
        inst.visible = true
    end

    -- Optional visual & native properties
    bind_prop(props.alpha, function(a) backend.set_alpha(f, a) end)
    bind_prop(props.color, function(c) backend.set_color(f, c) end)
    bind_prop(props.scale, function(s) backend.set_scale(f, s) end)
    bind_prop(props.priority or props.level, function(lv) backend.set_priority(f, lv) end)
    bind_prop(props.clip, function(cl) backend.set_clip(f, cl) end)
    bind_prop(props.enabled, function(en) backend.set_enable(f, en) end)

    -- Event hooks (using stable event slots on backend)
    local EV = backend.EVENT or Frame.EVENT
    if props.on_click then
        backend.on(f, EV.CLICK, function() props.on_click(inst) end)
    end
    if props.on_enter then
        backend.on(f, EV.ENTER, function() props.on_enter(inst) end)
    end
    if props.on_leave then
        backend.on(f, EV.LEAVE, function() props.on_leave(inst) end)
    end
    if props.on_down then
        backend.on(f, EV.DOWN, function() props.on_down(inst) end)
    end
    if props.on_up then
        backend.on(f, EV.UP, function() props.on_up(inst) end)
    end
    if props.on_wheel then
        backend.on(f, EV.WHEEL, function()
            local delta = backend.get_wheel_delta and backend.get_wheel_delta() or 0
            props.on_wheel(inst, delta)
        end)
    end
    if props.on_double_click and EV.DOUBLE_CLICK then
        backend.on(f, EV.DOUBLE_CLICK, function() props.on_double_click(inst) end)
    end
end

-- ── Recursive mounter ──────────────────────────────────────────────────────

local mount_node

local function layout_flow(backend, container_inst, is_row)
    local p = container_inst.props
    local pad = read_or(p.padding, 0.0)
    local gap = read_or(p.gap, 0.0)
    local align = p.align or "start"     -- cross-axis: "start" | "center" | "end"
    local justify = p.justify or "start" -- main-axis:  "start" | "center" | "end" | "space_between"

    local vis = {}
    local n = 0
    local sum_main, max_cross = 0.0, 0.0
    for i = 1, #container_inst.children do
        local c = container_inst.children[i]
        if c.visible ~= false and c.frame then
            n = n + 1
            vis[n] = c
            local cm = is_row and (c.w or 0.0) or (c.h or 0.0)
            local cc = is_row and (c.h or 0.0) or (c.w or 0.0)
            sum_main = sum_main + cm
            if cc > max_cross then max_cross = cc end
        end
    end

    local total_gaps = (n > 1) and (gap * (n - 1)) or 0.0
    local auto_w = (is_row and (sum_main + total_gaps) or max_cross) + pad * 2
    local auto_h = (is_row and max_cross or (sum_main + total_gaps)) + pad * 2

    local box_w = read_or(p.w, nil) or auto_w
    local box_h = read_or(p.h, nil) or auto_h
    if container_inst.w ~= box_w or container_inst.h ~= box_h then
        container_inst.w, container_inst.h = box_w, box_h
        backend.set_size(container_inst.frame, box_w, box_h)
        if container_inst._on_metrics_change then
            container_inst._on_metrics_change()
        end
    end

    local inner_main = (is_row and box_w or box_h) - pad * 2
    local inner_cross = (is_row and box_h or box_w) - pad * 2
    local extra_main = math.max(0.0, inner_main - sum_main - total_gaps)

    local cursor = pad
    local step_gap = gap
    if justify == "center" then
        cursor = pad + extra_main * 0.5
    elseif justify == "end" then
        cursor = pad + extra_main
    elseif justify == "space_between" and n > 1 then
        step_gap = math.max(0.0, (inner_main - sum_main) / (n - 1))
    end

    for i = 1, n do
        local c = vis[i]
        local cw, ch = c.w or 0.0, c.h or 0.0
        local cross_size = is_row and ch or cw
        local cross_off = pad
        if align == "center" then
            cross_off = pad + math.max(0.0, (inner_cross - cross_size) * 0.5)
        elseif align == "end" then
            cross_off = pad + math.max(0.0, inner_cross - cross_size)
        end

        local ox = is_row and cursor or cross_off
        local oy = is_row and -cross_off or -cursor
        c.layout_x, c.layout_y = ox, oy
        backend.set_point(c.frame, "TOPLEFT", container_inst.frame, "TOPLEFT", ox, oy)
        cursor = cursor + (is_row and cw or ch) + step_gap
    end
end

local function layout_grid(backend, container_inst)
    local p = container_inst.props
    local cols = math.max(1, math.floor(read_or(p.cols, 4)))
    local pad = read_or(p.padding, 0.0)
    local gap_x = read_or(p.gap_x or p.gap, 0.0)
    local gap_y = read_or(p.gap_y or p.gap, 0.0)
    local cell_w = read_or(p.cell_w, 0.04)
    local cell_h = read_or(p.cell_h, 0.04)

    local idx = 0
    for i = 1, #container_inst.children do
        local c = container_inst.children[i]
        if c.visible ~= false and c.frame then
            local col = idx % cols
            local row = math.floor(idx / cols)
            local ox = pad + col * (cell_w + gap_x)
            local oy = -(pad + row * (cell_h + gap_y))
            c.layout_x, c.layout_y = ox, oy
            backend.set_point(c.frame, "TOPLEFT", container_inst.frame, "TOPLEFT", ox, oy)
            idx = idx + 1
        end
    end

    local rows = (idx > 0) and math.ceil(idx / cols) or 0
    local auto_w = pad * 2 + cols * cell_w + math.max(0, cols - 1) * gap_x
    local auto_h = pad * 2 + rows * cell_h + math.max(0, rows - 1) * gap_y
    local box_w = read_or(p.w, nil) or auto_w
    local box_h = read_or(p.h, nil) or auto_h
    if container_inst.w ~= box_w or container_inst.h ~= box_h then
        container_inst.w, container_inst.h = box_w, box_h
        backend.set_size(container_inst.frame, box_w, box_h)
        if container_inst._on_metrics_change then
            container_inst._on_metrics_change()
        end
    end
end

local function mount_children(ctx, parent_inst, vchildren, managed_pos, on_child_metrics)
    for i = 1, #vchildren do
        local child_v = vchildren[i]
        if is_node(child_v) then
            local child_inst = mount_node(ctx, parent_inst.frame, child_v, managed_pos, on_child_metrics)
            if child_inst then
                if child_inst._flatten then
                    for j = 1, #child_inst.children do
                        parent_inst.children[#parent_inst.children + 1] = child_inst.children[j]
                    end
                else
                    parent_inst.children[#parent_inst.children + 1] = child_inst
                end
            end
        end
    end
end

mount_node = function(ctx, parent_frame, vnode, managed_pos, on_metrics_change)
    local backend = ctx.backend
    local kind = vnode.kind
    local props = vnode.props

    -- Functional component: execute inside inherited child env
    if kind == "Component" then
        local prev_env = ctx.env
        ctx.env = setmetatable({}, { __index = prev_env })
        local ok, rendered = pcall(props._fn, props._props, props._children)
        if not ok then
            ctx.env = prev_env
            error(rendered, 2)
        end
        local res = is_node(rendered)
            and mount_node(ctx, parent_frame, rendered, managed_pos, on_metrics_change)
            or nil
        ctx.env = prev_env
        return res
    end

    -- Overlay: re-parent to top-level game_ui() with high priority
    if kind == "Overlay" then
        local wrapper = {
            kind = "Overlay",
            props = props,
            parent_frame = backend.game_ui(),
            frame = backend.create("FRAME", backend.game_ui(), props.template or ""),
            children = {},
            visible = true,
        }
        ctx.scope:on_cleanup(function() backend.destroy(wrapper.frame) end)
        backend.set_all_points(wrapper.frame, backend.game_ui())
        backend.set_priority(wrapper.frame, props.priority or props.level or 100)
        apply_common_frame_props(backend, wrapper.frame, props, wrapper, true)
        mount_children(ctx, wrapper, vnode.children, false, nil)
        return wrapper
    end

    -- Control flow: UI.Show { when = signal, ... }
    if kind == "Show" then
        local wrapper = {
            kind = "Show",
            props = props,
            parent_frame = parent_frame,
            frame = parent_frame,
            children = {},
            _flatten = true,
        }
        mount_children(ctx, wrapper, vnode.children, managed_pos, on_metrics_change)
        bind_prop(props.when, function(show)
            local vis = show and true or false
            for i = 1, #wrapper.children do
                local c = wrapper.children[i]
                c.visible = vis
                if c.frame then backend.show(c.frame, vis) end
            end
            if on_metrics_change then on_metrics_change() end
        end)
        return wrapper
    end

    -- Control flow: UI.For { each = list_sig, max = N, render = function(item_sig, idx, vis_sig) ... end }
    -- Fixed-slot pooled list: creates at most `max` reusable frame subtrees, never recreates on update!
    if kind == "For" then
        local render_fn = assert(props.render, "UI.For requires a 'render' function")
        local each = props.each
        local max_slots = props.max
        local wrapper = {
            kind = "For",
            props = props,
            parent_frame = parent_frame,
            frame = parent_frame,
            children = {},
            _flatten = true,
            _slots = {},
        }

        local function ensure_slot(i)
            local slot = wrapper._slots[i]
            if slot then return slot end
            local item_sig = Signal.state(nil)
            local vis_sig = Signal.state(false)
            local slot_vnode = render_fn(item_sig, i, vis_sig)
            local child_inst = mount_node(ctx, parent_frame, slot_vnode, managed_pos, on_metrics_change)
            slot = { item = item_sig, visible = vis_sig, inst = child_inst }
            wrapper._slots[i] = slot
            if child_inst then
                wrapper.children[#wrapper.children + 1] = child_inst
            end
            return slot
        end

        if max_slots and max_slots > 0 then
            for i = 1, max_slots do ensure_slot(i) end
        end

        local function sync_list(list)
            list = list or {}
            local count = #list
            if max_slots and count > max_slots then count = max_slots end
            Signal.batch(function()
                for i = 1, count do
                    local slot = ensure_slot(i)
                    slot.item:set(list[i])
                    slot.visible:set(true)
                    if slot.inst then
                        slot.inst.visible = true
                        if slot.inst.frame then backend.show(slot.inst.frame, true) end
                    end
                end
                for i = count + 1, #wrapper._slots do
                    local slot = wrapper._slots[i]
                    slot.visible:set(false)
                    if slot.inst then
                        slot.inst.visible = false
                        if slot.inst.frame then backend.show(slot.inst.frame, false) end
                    end
                end
            end)
            if on_metrics_change then on_metrics_change() end
        end

        if Signal.is_signal(each) then
            Signal.effect(function() sync_list(each:get()) end)
        else
            sync_list(each)
        end
        return wrapper
    end

    -- ── Concrete frame-backed nodes ────────────────────────────────────────

    local f
    local owns_frame = true
    if kind == "Raw" then
        if props.handle then
            f = props.handle
            owns_frame = false
        else
            f = backend.create(props.tag or "FRAME", parent_frame, props.template, props.name, props.id)
        end
    elseif kind == "Text" then
        f = backend.create("TEXT", parent_frame, props.template, props.name)
    elseif kind == "Image" then
        f = backend.create("BACKDROP", parent_frame, props.template, props.name)
    elseif kind == "Button" then
        f = backend.create(props.tag or "BUTTON", parent_frame, props.template, props.name)
    elseif kind == "Model" then
        f = backend.create("SPRITE", parent_frame, props.template, props.name)
    elseif kind == "Input" then
        f = backend.create("EDITBOX", parent_frame, props.template, props.name)
    else
        -- Box, Row, Column, Grid, Scroll
        local tag = (props.tex ~= nil or props.color ~= nil) and "BACKDROP" or "FRAME"
        f = backend.create(props.tag or tag, parent_frame, props.template, props.name)
    end

    local inst = {
        kind = kind,
        props = props,
        frame = f,
        parent_frame = parent_frame,
        children = {},
        w = 0.0,
        h = 0.0,
        visible = true,
        _on_metrics_change = on_metrics_change,
    }

    if owns_frame then
        ctx.scope:on_cleanup(function() backend.destroy(f) end)
    end
    if props.ref then
        ctx.refs[props.ref] = inst
    end

    -- Element-specific reactive properties
    if kind == "Box" or kind == "Image" or kind == "Row" or kind == "Column" or kind == "Grid" or kind == "Scroll" then
        bind_prop(props.tex, function(t) backend.set_texture(f, t, props.tex_flag or 0) end)
    end
    if kind == "Text" or kind == "Input" then
        local theme = UI.use("theme", nil)
        local default_font = (theme and theme.font) or "Fonts\\dfst-m3u.ttf"
        local default_size = (theme and theme.font_size) or 0.011
        if props.font ~= nil or props.size ~= nil or theme then
            if Signal.is_signal(props.font) or Signal.is_signal(props.size) then
                Signal.effect(function()
                    backend.set_font(f, read_or(props.font, default_font), read_or(props.size, default_size), props.font_flags or 0)
                end)
            else
                backend.set_font(f, props.font or default_font, props.size or default_size, props.font_flags or 0)
            end
        end
        if props.align ~= nil then
            bind_prop(props.align, function(a) backend.set_align(f, a) end)
        end
        bind_prop(props.text, function(t) backend.set_text(f, t) end)
    end
    if kind == "Model" then
        bind_prop(props.model, function(m) backend.set_model(f, m, props.model_type or 0, props.model_flag or 0) end)
    end

    apply_common_frame_props(backend, f, props, inst, managed_pos)

    -- Layout container mounting
    if kind == "Row" or kind == "Column" then
        local is_row = (kind == "Row")
        local function do_reflow() layout_flow(backend, inst, is_row) end
        inst.reflow = do_reflow
        mount_children(ctx, inst, vnode.children, true, do_reflow)
        do_reflow()
        ctx.reflowers[#ctx.reflowers + 1] = do_reflow
    elseif kind == "Grid" then
        local function do_reflow() layout_grid(backend, inst) end
        inst.reflow = do_reflow
        mount_children(ctx, inst, vnode.children, true, do_reflow)
        do_reflow()
        ctx.reflowers[#ctx.reflowers + 1] = do_reflow
    elseif kind == "Scroll" then
        backend.set_clip(f, true)
        local content = backend.create("FRAME", f, "")
        ctx.scope:on_cleanup(function() backend.destroy(content) end)
        local scroll_y = Signal.state(0.0)
        local step = props.step or 0.025
        inst.scroll_y = scroll_y
        local content_inst = {
            kind = "ScrollContent",
            props = {},
            frame = content,
            parent_frame = f,
            children = {},
            w = inst.w,
            h = read_or(props.content_h, inst.h),
            visible = true,
        }
        backend.set_size(content, inst.w, content_inst.h)
        Signal.effect(function()
            local max_scroll = math.max(0.0, read_or(props.content_h, content_inst.h) - inst.h)
            local off = math.max(0.0, math.min(max_scroll, scroll_y:get()))
            backend.set_point(content, "TOPLEFT", f, "TOPLEFT", 0.0, off)
        end)
        local EV = backend.EVENT or Frame.EVENT
        backend.on(f, EV.WHEEL, function()
            local delta = backend.get_wheel_delta and backend.get_wheel_delta() or 0
            local max_scroll = math.max(0.0, read_or(props.content_h, content_inst.h) - inst.h)
            local next_y = scroll_y:peek() - delta * step
            scroll_y:set(math.max(0.0, math.min(max_scroll, next_y)))
        end)
        mount_children(ctx, content_inst, vnode.children, false, nil)
        inst.children[1] = content_inst
    else
        mount_children(ctx, inst, vnode.children, false, nil)
    end

    if props.on_mount then
        props.on_mount(inst)
    end
    if props.on_cleanup then
        ctx.scope:on_cleanup(function() props.on_cleanup(inst) end)
    end

    return inst
end

-- ── Public Mount Entry Point ───────────────────────────────────────────────

--- Mount a declarative UI tree into War3 DzFrame (or an injected mock backend).
--- Returns a handle with `:destroy()`, `:ref(name)`, `:root()`, `:reflow()`.
function UI.mount(vnode, opts)
    opts = opts or {}
    local backend = opts.backend or Frame
    assert(backend and backend.is_available(), "std.ui: frame backend (DzFrame) is not available")

    local scope = Signal.scope()
    local ctx = {
        backend = backend,
        scope = scope,
        refs = {},
        reflowers = {},
        env = {},
    }
    if opts.theme then ctx.env.theme = opts.theme end
    if opts.context then
        for k, v in pairs(opts.context) do ctx.env[k] = v end
    end

    local prev_ctx = active_ctx
    active_ctx = ctx
    local ok, root_inst = pcall(function()
        return scope:run(function()
            return mount_node(ctx, opts.parent or backend.game_ui(), vnode, false, nil)
        end)
    end)
    active_ctx = prev_ctx
    if not ok then
        scope:destroy()
        error(root_inst, 2)
    end

    local mounted = {}
    function mounted:root() return root_inst end
    function mounted:ref(name) return ctx.refs[name] end
    function mounted:reflow()
        for i = 1, #ctx.reflowers do ctx.reflowers[i]() end
    end
    function mounted:destroy()
        return scope:destroy()
    end
    function mounted:is_destroyed()
        return scope:is_destroyed()
    end
    return mounted
end

return UI

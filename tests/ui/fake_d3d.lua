-- tests/ui/fake_d3d.lua
--
-- OFFLINE MOCK of the public `jass.d3d` surface used by lib/ui.lua.
-- This file is NOT a game test and does not touch the native D3D SDK. It exists
-- only to exercise layout, event dispatch, hit-testing, creation rollback and
-- resource lifetime deterministically without launching Warcraft III.
--
-- The fake mirrors the documented native semantics that lib/ui.lua relies on:
--   * texture hit_test/visible gates hit-testing;
--   * z ordering (higher z wins, ties by creation order);
--   * pointer capture on mouse_down and click = down+up within 6 px inside;
--   * enter/leave driven by a hover stack of subscribed textures;
--   * subscriptions are owned by their Texture and cancelled with it;
--   * Font -> Text is a strong reference (Font destroy fails while Text lives);
--   * construction/subscription failures are returned as nil, err.

local M = {}

local TEXTURE_EVENTS = {
    enter = true, leave = true,
    mouse_down = true, mouse_up = true, click = true,
    key_down = true, key_up = true,
}
local MODULE_EVENTS = {
    resize = true, device_lost = true, device_reset = true,
}
local MOUSE_EVENTS = {
    mouse_down = true, mouse_up = true, click = true,
}

local function check_alive(object, label)
    assert(not object._destroyed, "fake " .. label .. " is destroyed")
end

local function new_state(options)
    return {
        width = options.width or 1024,
        height = options.height or 768,
        available = options.available ~= false,
        shutdown = false,
        fail = options.fail or {},
        calls = {
            font = 0, text = 0, texture = 0,
            subscription = 0, module_on = 0,
        },
        fonts = 0,
        texts = 0,
        textures = 0,
        subscriptions = 0,
        next_id = 0,
        textures_list = {},
        subs = {},
        hover = {},
        capture = nil,
        cursor_x = -1,
        cursor_y = -1,
        callback_errors = {},
        destroyed_natives = { fonts = 0, texts = 0, textures = 0 },
        destroy_calls = { font = 0, text = 0, texture = 0 },
        fail_destroy = { font = nil, text = nil, texture = nil },
    }
end

local function should_fail(state, kind)
    state.calls[kind] = state.calls[kind] + 1
    local at = state.fail[kind]
    if at == nil then return false end
    if at == true then return true end
    return state.calls[kind] == at
end

local function should_fail_destroy(state, kind)
    state.destroy_calls[kind] = state.destroy_calls[kind] + 1
    local at = state.fail_destroy[kind]
    if at == nil then return false end
    if at == true then return true end
    if state.destroy_calls[kind] == at then
        state.fail_destroy[kind] = nil
        return true
    end
    return false
end

local function contains(list, value)
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

local Sub = {}
Sub.__index = Sub

function Sub:is_active()
    return self.active == true
end

function Sub:cancel()
    if not self.active then return true end
    self.active = false
    self._state.subs[self.id] = nil
    if self.texture ~= nil then
        self.texture._subs[self.id] = nil
    end
    self._state.subscriptions = self._state.subscriptions - 1
    return true
end

function Sub:__tostring()
    return string.format("fake.Subscription(id=%d, %s, %s)",
        self.id, tostring(self.event), self.active and "active" or "cancelled")
end

local Font = {}
Font.__index = Font

function Font:is_destroyed() return self._destroyed end

function Font:destroy()
    if self._destroyed then return true end
    assert(self._refs == 0, "fake Font.destroy called while a Text still references it")
    if should_fail_destroy(self._state, "font") then
        return nil, "injected Font.destroy failure"
    end
    self._destroyed = true
    self._state.fonts = self._state.fonts - 1
    self._state.destroyed_natives.fonts = self._state.destroyed_natives.fonts + 1
    return true
end

function Font:get_face() check_alive(self, "Font") return self.face end
function Font:set_face(value) check_alive(self, "Font") self.face = value return true end
function Font:get_height() check_alive(self, "Font") return self.height end
function Font:set_height(value) check_alive(self, "Font") self.height = value return true end
function Font:get_width() check_alive(self, "Font") return self.width end
function Font:set_width(value) check_alive(self, "Font") self.width = value return true end
function Font:get_weight() check_alive(self, "Font") return self.weight end
function Font:set_weight(value) check_alive(self, "Font") self.weight = value return true end
function Font:get_italic() check_alive(self, "Font") return self.italic end
function Font:set_italic(value) check_alive(self, "Font") self.italic = value return true end

local Text = {}
Text.__index = Text

function Text:is_destroyed() return self._destroyed end
function Text:is_alive() return not self._destroyed end

function Text:destroy()
    if self._destroyed then return true end
    if should_fail_destroy(self._state, "text") then
        return nil, "injected Text.destroy failure"
    end
    self._destroyed = true
    self._state.texts = self._state.texts - 1
    self._state.destroyed_natives.texts = self._state.destroyed_natives.texts + 1
    self._font._refs = self._font._refs - 1
    return true
end

function Text:get_text() check_alive(self, "Text") return self.text end
function Text:set_text(value) check_alive(self, "Text") self.text = value return true end
function Text:get_position() check_alive(self, "Text") return self.x, self.y end
function Text:set_position(x, y) check_alive(self, "Text") self.x, self.y = x, y return true end
function Text:get_color() check_alive(self, "Text") return self.color end
function Text:set_color(value) check_alive(self, "Text") self.color = value return true end
function Text:get_visible() check_alive(self, "Text") return self.visible end
function Text:set_visible(value) check_alive(self, "Text") self.visible = value and true or false return true end
function Text:get_z() check_alive(self, "Text") return self.z end
function Text:set_z(value) check_alive(self, "Text") self.z = value return true end
function Text:get_font() check_alive(self, "Text") return self._font end

function Text:set_font(font)
    check_alive(self, "Text")
    assert(font and not font._destroyed, "fake Text.set_font requires a live Font")
    self._font._refs = self._font._refs - 1
    font._refs = font._refs + 1
    self._font = font
    return true
end

local Texture = {}
Texture.__index = Texture

function Texture:is_destroyed() return self._destroyed end

function Texture:get_source() check_alive(self, "Texture") return self.source end
function Texture:set_source(value) check_alive(self, "Texture") self.source = value return true end
function Texture:state() check_alive(self, "Texture") return "ready" end
function Texture:error() check_alive(self, "Texture") return nil end
function Texture:reload() check_alive(self, "Texture") return true end
function Texture:get_rect() check_alive(self, "Texture") return self.x, self.y, self.w, self.h end

function Texture:set_rect(x, y, w, h)
    check_alive(self, "Texture")
    self.x, self.y, self.w, self.h = x, y, w, h
    return true
end

function Texture:get_color() check_alive(self, "Texture") return self.color end
function Texture:set_color(value) check_alive(self, "Texture") self.color = value return true end
function Texture:get_z() check_alive(self, "Texture") return self.z end
function Texture:set_z(value) check_alive(self, "Texture") self.z = value return true end
function Texture:get_rotation() check_alive(self, "Texture") return self.rotation end
function Texture:set_rotation(value) check_alive(self, "Texture") self.rotation = value return true end

function Texture:get_visible() check_alive(self, "Texture") return self.visible end

function Texture:set_visible(value)
    check_alive(self, "Texture")
    value = value and true or false
    local was = self.visible
    self.visible = value
    if was and not value then
        self._state:drop_hover(self)
    end
    return true
end

function Texture:get_hit_test() check_alive(self, "Texture") return self.hit_test end

function Texture:set_hit_test(value)
    check_alive(self, "Texture")
    value = value and true or false
    local was = self.hit_test
    self.hit_test = value
    if was and not value then
        self._state:drop_hover(self)
    end
    return true
end

function Texture:contains(x, y)
    check_alive(self, "Texture")
    return x >= self.x and x <= self.x + self.w
        and y >= self.y and y <= self.y + self.h
end

function Texture:pixel_size()
    check_alive(self, "Texture")
    return self.w, self.h
end

function Texture:on(event, callback, options)
    check_alive(self, "Texture")
    assert(TEXTURE_EVENTS[event] == true, "fake Texture.on: unsupported event " .. tostring(event))
    assert(type(callback) == "function", "fake Texture.on: callback must be a function")
    assert(options == nil or type(options) == "table",
        "fake Texture.on: options must be a table")
    local state = self._state
    if should_fail(state, "subscription") then
        return nil, "injected subscription failure"
    end

    state.next_id = state.next_id + 1
    local sub = setmetatable({
        id = state.next_id,
        _state = state,
        texture = self,
        event = event,
        callback = callback,
        active = true,
        filter_code = options and options.button or nil,
        propagate = options and options.propagate == true,
        hover_only = options == nil or options.hover_only ~= false,
        keep_on_error = options and options.keep_on_error == true,
    }, Sub)
    state.subs[sub.id] = sub
    self._subs[sub.id] = sub
    state.subscriptions = state.subscriptions + 1
    return sub
end

function Texture:destroy()
    if self._destroyed then return true end
    local state = self._state
    local owned = {}
    for _, sub in pairs(self._subs) do owned[#owned + 1] = sub end
    for i = 1, #owned do owned[i]:cancel() end
    if should_fail_destroy(state, "texture") then
        return nil, "injected Texture.destroy failure"
    end
    self._destroyed = true
    state.textures = state.textures - 1
    state.destroyed_natives.textures = state.destroyed_natives.textures + 1
    for i = #state.textures_list, 1, -1 do
        if state.textures_list[i] == self then table.remove(state.textures_list, i) end
    end
    for i = #state.hover, 1, -1 do
        if state.hover[i] == self then table.remove(state.hover, i) end
    end
    return true
end

-- ---------------------------------------------------------------- dispatch

local function has_subscriptions(state, texture)
    for _, sub in pairs(state.subs) do
        if sub.active and sub.texture == texture then return true end
    end
    return false
end

local function propagates_hover(state, texture)
    for _, sub in pairs(state.subs) do
        if sub.active and sub.texture == texture and sub.propagate then return true end
    end
    return false
end

local function subscription_matches(sub, event, code)
    if not sub.active or sub.event ~= event then return false end
    if MOUSE_EVENTS[event] and sub.filter_code ~= nil and sub.filter_code ~= code then
        return false
    end
    return true
end

local function fire_texture_subscription(sub, event, x, y, code)
    if not sub.active then return false end
    local texture = sub.texture
    local event_table = {
        type = event,
        target = texture,
        x = x,
        y = y,
        local_x = x - (texture and texture.x or 0),
        local_y = y - (texture and texture.y or 0),
        timestamp = 0,
    }
    if MOUSE_EVENTS[event] then event_table.button = code end
    local ok, err = pcall(sub.callback, event_table)
    if not ok then
        sub._state.callback_errors[#sub._state.callback_errors + 1] = tostring(err)
        if not sub.keep_on_error then sub:cancel() end
        return false
    end
    return true
end

local function dispatch_to_texture(state, texture, event, x, y, code)
    local result = { matched = false, propagate = false }
    if texture == nil or texture._destroyed then return result end
    local matching = {}
    for _, sub in pairs(state.subs) do
        if sub.texture == texture and subscription_matches(sub, event, code) then
            matching[#matching + 1] = sub
        end
    end
    table.sort(matching, function(a, b) return a.id < b.id end)
    for i = 1, #matching do
        local sub = matching[i]
        if sub.active then
            result.matched = true
            result.propagate = result.propagate or sub.propagate
            fire_texture_subscription(sub, event, x, y, code)
        end
    end
    return result
end

local function dispatch_hit_stack(state, hits, event, x, y, code)
    for i = 1, #hits do
        local result = dispatch_to_texture(state, hits[i], event, x, y, code)
        if not result.matched or not result.propagate then break end
    end
end

local function collect_hits(state, x, y)
    local hits = {}
    for index, texture in ipairs(state.textures_list) do
        if not texture._destroyed and texture.visible and texture.hit_test
            and texture:contains(x, y) then
            hits[#hits + 1] = { texture = texture, index = index, z = texture.z }
        end
    end
    table.sort(hits, function(a, b)
        if a.z ~= b.z then return a.z > b.z end
        return a.index > b.index
    end)
    local ordered = {}
    for i = 1, #hits do ordered[i] = hits[i].texture end
    return ordered
end

local function compute_hover(state, x, y)
    local hits = collect_hits(state, x, y)
    local hovered = {}
    for i = 1, #hits do
        local texture = hits[i]
        if has_subscriptions(state, texture) then hovered[#hovered + 1] = texture end
        if not propagates_hover(state, texture) then break end
    end
    return hovered
end

local function drop_hover(self, texture)
    local index = nil
    for i = 1, #self.hover do
        if self.hover[i] == texture then index = i break end
    end
    if index == nil then return end
    table.remove(self.hover, index)
    dispatch_to_texture(self, texture, "leave", self.cursor_x, self.cursor_y, nil)
end

-- ---------------------------------------------------------------- module

function M.new(options)
    options = options or {}
    local state = new_state(options)
    state.drop_hover = drop_hover
    local d3d = { _state = state, Font = {}, Text = {}, Texture = {} }

    d3d.mouse = { LEFT = 0, RIGHT = 1, MIDDLE = 2, X1 = 3, X2 = 4 }
    d3d.key = { Q = 0x51, F2 = 0x301, SHIFT = 0x00 }

    function d3d.rgba(r, g, b, a)
        a = a or 255
        assert(type(r) == "number" and r >= 0 and r <= 255, "fake.d3d.rgba red out of range")
        assert(type(g) == "number" and g >= 0 and g <= 255, "fake.d3d.rgba green out of range")
        assert(type(b) == "number" and b >= 0 and b <= 255, "fake.d3d.rgba blue out of range")
        assert(type(a) == "number" and a >= 0 and a <= 255, "fake.d3d.rgba alpha out of range")
        return (a << 24) | (r << 16) | (g << 8) | b
    end

    function d3d.is_available()
        return state.available and not state.shutdown
    end

    function d3d.status()
        return {
            available = state.available and not state.shutdown,
            shutdown = state.shutdown,
            error = state.available and "" or "mock jass.d3d unavailable",
            session_id = 1,
            device_ready = state.available,
            device_generation = 1,
            state = state.available and "active" or "unavailable",
        }
    end

    function d3d.window_size()
        if state.fail.window_size then
            return nil, "injected window_size failure"
        end
        return state.width, state.height
    end

    function d3d.stats()
        if state.shutdown then return nil, "mock jass.d3d shutdown" end
        return {
            session_id = 1,
            fonts = state.fonts,
            texts = state.texts,
            textures = state.textures,
            subscriptions = state.subscriptions,
            device_ready = state.available,
            device_generation = 1,
        }
    end

    function d3d.version() return "0.4.0-mock" end
    function d3d.abi_version() return 1 end

    function d3d.on(event, callback, opts)
        assert(MODULE_EVENTS[event] == true,
            "fake d3d.on: unsupported lifecycle event " .. tostring(event))
        assert(type(callback) == "function", "fake d3d.on: callback must be a function")
        assert(opts == nil or type(opts) == "table", "fake d3d.on: options must be a table")
        if should_fail(state, "module_on") then
            return nil, "injected module subscription failure"
        end
        state.next_id = state.next_id + 1
        local sub = setmetatable({
            id = state.next_id,
            _state = state,
            texture = nil,
            event = event,
            callback = callback,
            active = true,
            filter_code = nil,
            propagate = false,
            hover_only = false,
            keep_on_error = opts and opts.keep_on_error == true,
        }, Sub)
        state.subs[sub.id] = sub
        state.subscriptions = state.subscriptions + 1
        return sub
    end

    function d3d.Font.new(spec)
        if not state.available or state.shutdown then
            return nil, "mock jass.d3d unavailable"
        end
        if should_fail(state, "font") then
            return nil, "injected Font.new failure"
        end
        spec = spec or {}
        assert(type(spec) == "table", "fake Font.new expects a table")
        local height = spec.height or 16
        assert(height > 0, "fake Font.new height must be > 0")
        state.fonts = state.fonts + 1
        return setmetatable({
            _state = state,
            _destroyed = false,
            _refs = 0,
            face = spec.face or "Arial",
            height = height,
            width = spec.width or 0,
            weight = spec.weight or 400,
            italic = spec.italic == true,
        }, Font)
    end

    function d3d.Text.new(spec)
        if not state.available or state.shutdown then
            return nil, "mock jass.d3d unavailable"
        end
        assert(type(spec) == "table", "fake Text.new expects a table")
        local font = spec.font
        assert(font ~= nil, "fake Text.new requires a Font")
        assert(not font._destroyed, "fake Text.new received a destroyed Font")
        if should_fail(state, "text") then
            return nil, "injected Text.new failure"
        end
        font._refs = font._refs + 1
        state.texts = state.texts + 1
        return setmetatable({
            _state = state,
            _destroyed = false,
            _font = font,
            text = spec.text or "",
            x = spec.x or 0,
            y = spec.y or 0,
            color = spec.color or 0xFFFFFFFF,
            visible = spec.visible ~= false,
            z = spec.z or 0,
        }, Text)
    end

    function d3d.Texture.new(spec)
        if not state.available or state.shutdown then
            return nil, "mock jass.d3d unavailable"
        end
        assert(type(spec) == "table", "fake Texture.new expects a table")
        assert(type(spec.source) == "string" and spec.source ~= "",
            "fake Texture.new requires a source")
        if should_fail(state, "texture") then
            return nil, "injected Texture.new failure"
        end
        state.textures = state.textures + 1
        local texture = setmetatable({
            _state = state,
            _destroyed = false,
            _subs = {},
            source = spec.source,
            x = spec.x or 0,
            y = spec.y or 0,
            w = spec.width or 0,
            h = spec.height or 0,
            color = spec.color or 0xFFFFFFFF,
            rotation = spec.rotation or 0,
            z = spec.z or 0,
            visible = spec.visible ~= false,
            hit_test = spec.hit_test ~= false,
        }, Texture)
        state.textures_list[#state.textures_list + 1] = texture
        return texture
    end

    -- Test-only input helpers. They mimic the SDK dispatcher, not Win32 input.
    function d3d._mouse_move(x, y)
        state.cursor_x, state.cursor_y = x, y
        local previous = state.hover
        local current = compute_hover(state, x, y)
        state.hover = current
        for i = 1, #previous do
            if not contains(current, previous[i]) then
                dispatch_to_texture(state, previous[i], "leave", x, y, nil)
            end
        end
        for i = 1, #current do
            if not contains(previous, current[i]) then
                dispatch_to_texture(state, current[i], "enter", x, y, nil)
            end
        end
    end

    function d3d._mouse_down(x, y, button)
        button = button or d3d.mouse.LEFT
        state.cursor_x, state.cursor_y = x, y
        local hits = collect_hits(state, x, y)
        if #hits > 0 then
            state.capture = { texture = hits[1], x = x, y = y, button = button }
        end
        dispatch_hit_stack(state, hits, "mouse_down", x, y, button)
    end

    function d3d._mouse_up(x, y, button)
        button = button or d3d.mouse.LEFT
        state.cursor_x, state.cursor_y = x, y
        local hits = collect_hits(state, x, y)
        local capture = state.capture
        if capture == nil then
            dispatch_hit_stack(state, hits, "mouse_up", x, y, button)
            return
        end
        state.capture = nil
        dispatch_to_texture(state, capture.texture, "mouse_up", x, y, button)
        local dx = x - capture.x
        local dy = y - capture.y
        if dx * dx + dy * dy <= 36 and contains(hits, capture.texture) then
            dispatch_to_texture(state, capture.texture, "click", x, y, button)
        end
    end

    function d3d._mouse_click(x, y, button)
        d3d._mouse_down(x, y, button)
        d3d._mouse_up(x, y, button)
    end

    function d3d._resize(width, height)
        state.width, state.height = width, height
        local subs = {}
        for _, sub in pairs(state.subs) do
            if sub.active and sub.texture == nil and sub.event == "resize" then
                subs[#subs + 1] = sub
            end
        end
        table.sort(subs, function(a, b) return a.id < b.id end)
        for i = 1, #subs do
            local sub = subs[i]
            if sub.active then
                local event = { type = "resize", width = width, height = height, timestamp = 0 }
                local ok, err = pcall(sub.callback, event)
                if not ok then
                    state.callback_errors[#state.callback_errors + 1] = tostring(err)
                    if not sub.keep_on_error then sub:cancel() end
                end
            end
        end
    end

    -- Test-only failure injection: fail the `after`-th future call of `kind`.
    function d3d._fail_next(kind, after)
        state.fail[kind] = state.calls[kind] + (after or 1)
    end

    function d3d._clear_fail(kind)
        state.fail[kind] = nil
    end

    -- Test-only failure injection: fail the `after`-th future destroy of `kind`
    -- (font / text / texture). Mirrors a native destroy returning nil, err.
    function d3d._fail_next_destroy(kind, after)
        assert(state.destroy_calls[kind] ~= nil,
            "unknown destroy kind " .. tostring(kind))
        state.fail_destroy[kind] = state.destroy_calls[kind] + (after or 1)
    end

    function d3d._clear_fail_destroy(kind)
        state.fail_destroy[kind] = nil
    end

    return d3d
end

return M

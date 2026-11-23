-- std/util.lua — pure zero-dependency math, color, fourcc, and safe-call helpers.

local util = {}

local fourcc_cache = {}
local id2str_cache = {}

--- Convert a 4-character War3 rawcode (e.g. "hfoo") to its 32-bit integer ID.
--- Accepts an existing integer unchanged so callers can pass either form.
function util.fourcc(v)
    if type(v) == "number" then return v end
    local cached = fourcc_cache[v]
    if cached then return cached end
    assert(type(v) == "string" and #v == 4, "fourcc expects a 4-char string, got: " .. tostring(v))
    local a, b, c, d = v:byte(1, 4)
    local id = ((a * 256 + b) * 256 + c) * 256 + d
    fourcc_cache[v] = id
    id2str_cache[id] = v
    return id
end

--- Convert a 32-bit War3 integer ID back to its 4-character rawcode string.
function util.id2str(id)
    if type(id) == "string" then return id end
    local cached = id2str_cache[id]
    if cached then return cached end
    local d = id % 256
    local r = (id - d) // 256
    local c = r % 256
    r = (r - c) // 256
    local b = r % 256
    local a = (r - b) // 256
    local s = string.char(a & 0xFF, b & 0xFF, c & 0xFF, d & 0xFF)
    id2str_cache[id] = s
    fourcc_cache[s] = id
    return s
end

function util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function util.lerp(a, b, t)
    return a + (b - a) * t
end

function util.dist2(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return dx * dx + dy * dy
end

function util.dist(x1, y1, x2, y2)
    return math.sqrt(util.dist2(x1, y1, x2, y2))
end

--- Angle in degrees from (x1, y1) to (x2, y2).
function util.angle(x1, y1, x2, y2)
    return math.deg(math.atan(y2 - y1, x2 - x1))
end

--- Point at distance `d` and angle `deg` (degrees) from (x, y).
function util.polar(x, y, d, deg)
    local rad = math.rad(deg)
    return x + d * math.cos(rad), y + d * math.sin(rad)
end

--- Pack (r, g, b, a) [0..255] into 0xAARRGGBB integer (matches jass.d3d & StatBar).
function util.rgba(r, g, b, a)
    a = (a == nil) and 255 or util.clamp(math.floor(a), 0, 255)
    r = util.clamp(math.floor(r), 0, 255)
    g = util.clamp(math.floor(g), 0, 255)
    b = util.clamp(math.floor(b), 0, 255)
    return (a << 24) | (r << 16) | (g << 8) | b
end

--- Pack (a, r, g, b) [0..255] into 0xAARRGGBB integer.
function util.argb(a, r, g, b)
    return util.rgba(r, g, b, a)
end

--- Protected call that logs errors cleanly without killing callers or timers.
function util.safe_call(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        print("[std] callback error: " .. tostring(err))
    end
    return ok, err
end

return util

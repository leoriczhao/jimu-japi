-- map/lib/camera.lua
-- World -> screen projection for overlay graphics drawn with jass.d3d.
--
-- War3 exposes the camera eye and target but no world-to-screen native, and
-- the D3D proxy draws in client pixels, so the projection is rebuilt here:
--
--   * basis: eye -> target gives forward, right = normalize(forward x up),
--     up = right x forward;
--   * the frustum is fixed and was measured on 1.27a by pointing the cursor at
--     grid points and fitting the engine-corrected ground point against the
--     client pixel: the engine renders a 4:3 frustum stretched across the
--     client, so the vertical focal length follows the height, the horizontal
--     one is 0.75 of it, and the principal point sits above the geometric
--     centre instead of on it:
--
--         sx = 0.5 * width  + KX * width  * qx
--         sy = KY * height - KZ * height * qy      (q = camera-space x/z, y/z)
--
--     Measured over 1600x900, 1280x960 and 1902x963 and over panned/zoomed
--     cameras: KX = 0.91092, KZ = 1.21454, KY = 0.40835 (residual < 0.05 px).
--     1280x960 is 4:3 and lands on KX * 1280 == KZ * 960, which is exactly the
--     "4:3 picture stretched sideways" behaviour.
--
-- Do not re-solve these from the cursor at runtime: the cursor contributes one
-- constraint per sample and a wrong principal-point model absorbs it into a
-- wrong focal length (that is what used to push the overhead bars ~95 px down).

local jass = require "jass.common"
local d3d = require "jass.d3d"

local M = {}

local KX = 0.91092   -- fx = KX * width  (== 0.75 * KZ)
local KZ = 1.21454   -- fy = KZ * height
local KY = 0.40835   -- principal point y = KY * height

local S = {
    ready = false,
    width = 0, height = 0,
    ex = 0.0, ey = 0.0, ez = 0.0,
    tx = 0.0, ty = 0.0, tz = 0.0,
    rx = 1.0, ry = 0.0, rz = 0.0,
    ux = 0.0, uy = 0.0, uz = 1.0,
    fx = 0.0, fy = 1.0, fz = 0.0,
    focal_x = 0.0,
    focal_y = 0.0,
    center_x = 0.0,
    center_y = 0.0,
    synced = 0,
}
M.state_table = S
M.constants = { kx = KX, kz = KZ, ky = KY }

local function read_xyz(prefix)
    local ok, x = pcall(jass[prefix .. "X"])
    if not ok or type(x) ~= "number" then return nil end
    local oky, y = pcall(jass[prefix .. "Y"])
    if not oky or type(y) ~= "number" then return nil end
    local okz, z = pcall(jass[prefix .. "Z"])
    if not okz or type(z) ~= "number" then return nil end
    return x, y, z
end

-- Terrain height under a world point. Used to lift overlay anchors off the
-- ground on slopes; a failed probe is treated as flat ground.
function M.ground_z(x, y)
    local ok, loc = pcall(jass.Location, x, y)
    if not ok or not loc then return 0.0 end
    local okz, z = pcall(jass.GetLocationZ, loc)
    pcall(jass.RemoveLocation, loc)
    if not okz or type(z) ~= "number" then return 0.0 end
    return z
end

-- Refresh size, basis and projection scale. Cheap enough for a 10 Hz tick.
function M.sync()
    if not d3d.is_available() then
        S.ready = false
        return false
    end
    local width, height = d3d.window_size()
    if type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then
        S.ready = false
        return false
    end
    local ex, ey, ez = read_xyz("GetCameraEyePosition")
    if not ex then S.ready = false; return false end
    local tx, ty, tz = read_xyz("GetCameraTargetPosition")
    if not tx then S.ready = false; return false end

    local dx, dy, dz = tx - ex, ty - ey, tz - ez
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length < 1.0 then S.ready = false; return false end

    S.width, S.height = width, height
    S.ex, S.ey, S.ez = ex, ey, ez
    S.tx, S.ty, S.tz = tx, ty, tz
    S.fx, S.fy, S.fz = dx / length, dy / length, dz / length

    -- right = normalize(forward x world_up); a camera looking straight down
    -- degenerates there, so that frame keeps the previous basis.
    local rx, ry = S.fy, -S.fx
    local rlength = math.sqrt(rx * rx + ry * ry)
    if rlength < 1e-4 then
        rx, ry = S.rx, S.ry
        rlength = math.sqrt(rx * rx + ry * ry)
        if rlength < 1e-4 then rx, ry, rlength = 1.0, 0.0, 1.0 end
    end
    S.rx, S.ry, S.rz = rx / rlength, ry / rlength, 0.0

    -- up = right x forward
    S.ux = S.ry * S.fz - S.rz * S.fy
    S.uy = S.rz * S.fx - S.rx * S.fz
    S.uz = S.rx * S.fy - S.ry * S.fx

    S.focal_x = KX * width
    S.focal_y = KZ * height
    S.center_x = width * 0.5
    S.center_y = KY * height
    S.synced = S.synced + 1
    S.ready = true
    return true
end

-- Project a world point. Returns client x, client y, on-screen flag, camera depth.
function M.project(x, y, z)
    if not S.ready then return 0.0, 0.0, false, 0.0 end
    local vx, vy, vz = x - S.ex, y - S.ey, (z or 0.0) - S.ez
    local zc = vx * S.fx + vy * S.fy + vz * S.fz
    if zc <= 16.0 then return 0.0, 0.0, false, zc end
    local xc = vx * S.rx + vy * S.ry + vz * S.rz
    local yc = vx * S.ux + vy * S.uy + vz * S.uz
    local sx = S.center_x + S.focal_x * xc / zc
    local sy = S.center_y - S.focal_y * yc / zc
    local margin = 48.0
    local visible = sx > -margin and sx < S.width + margin
        and sy > -margin and sy < S.height + margin
    return sx, sy, visible, zc
end

function M.snapshot()
    return {
        ready = S.ready,
        width = S.width, height = S.height,
        eye_x = S.ex, eye_y = S.ey, eye_z = S.ez,
        target_x = S.tx, target_y = S.ty, target_z = S.tz,
        forward_x = S.fx, forward_y = S.fy, forward_z = S.fz,
        focal_x = S.focal_x, focal_y = S.focal_y,
        center_x = S.center_x, center_y = S.center_y,
        kx = KX, ky = KY, kz = KZ,
        synced = S.synced,
    }
end

return M

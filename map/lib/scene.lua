-- Deterministic visual scene used by the test map.
-- Every reset removes all units and recreates exactly one Human Rifleman.
local jass = require "jass.common"

local scene = {}

local function fourcc(value)
    local a, b, c, d = value:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function clear_units()
    local bounds = jass.GetWorldBounds()
    local group = jass.CreateGroup()
    jass.GroupEnumUnitsInRect(group, bounds, nil)

    while true do
        local unit = jass.FirstOfGroup(group)
        if unit == nil then break end
        jass.GroupRemoveUnit(group, unit)
        jass.RemoveUnit(unit)
    end

    jass.DestroyGroup(group)
end

function scene.reset()
    clear_units()

    local player = jass.Player(0)
    local x = jass.GetPlayerStartLocationX(player)
    local y = jass.GetPlayerStartLocationY(player)
    local rifleman = jass.CreateUnit(player, fourcc("hrif"), x, y, 270.0)
    assert(rifleman ~= nil, "failed to create the scene rifleman")
    jass.SetUnitInvulnerable(rifleman, true)
    jass.PanCameraToTimed(x, y, 0.0)

    scene.rifleman = rifleman
    return rifleman
end

return scene

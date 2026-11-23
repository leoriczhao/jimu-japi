-- std/player.lua — cached OO Player wrapper (players 0..15).

local jass = require "jass.common"
local Event = require "std.event"

local Player = {}
Player.__index = Player

local cache = {} -- [pid] = Player instance

function Player.get(pid)
    assert(type(pid) == "number" and pid >= 0 and pid <= 15,
        "Player.get: pid must be 0..15, got " .. tostring(pid))
    local existing = cache[pid]
    if existing then return existing end
    local handle = jass.Player(pid)
    if not handle then return nil end
    local self = setmetatable({
        _id = pid,
        _handle = handle,
        data = {},
    }, Player)
    cache[pid] = self
    return self
end

function Player.from_handle(h)
    if not h or h == 0 then return nil end
    if getmetatable(h) == Player then return h end
    return Player.get(jass.GetPlayerId(h))
end

function Player.local_player()
    return Player.from_handle(jass.GetLocalPlayer())
end

function Player.all()
    local out = {}
    for pid = 0, 15 do
        local p = Player.get(pid)
        if p then out[#out + 1] = p end
    end
    return out
end

function Player:id()
    return self._id
end

function Player:handle()
    return self._handle
end

function Player:name()
    return jass.GetPlayerName(self._handle)
end

function Player:set_name(name)
    jass.SetPlayerName(self._handle, tostring(name))
end

function Player:is_local()
    return jass.GetLocalPlayer() == self._handle
end

function Player:gold()
    return jass.GetPlayerState(self._handle, jass.PLAYER_STATE_RESOURCE_GOLD)
end

function Player:set_gold(amount)
    jass.SetPlayerState(self._handle, jass.PLAYER_STATE_RESOURCE_GOLD, math.floor(amount))
end

function Player:add_gold(delta)
    self:set_gold(self:gold() + delta)
end

function Player:lumber()
    return jass.GetPlayerState(self._handle, jass.PLAYER_STATE_RESOURCE_LUMBER)
end

function Player:set_lumber(amount)
    jass.SetPlayerState(self._handle, jass.PLAYER_STATE_RESOURCE_LUMBER, math.floor(amount))
end

function Player:add_lumber(delta)
    self:set_lumber(self:lumber() + delta)
end

function Player:say(text, duration, x, y)
    jass.DisplayTimedTextToPlayer(self._handle, x or 0.0, y or 0.0, duration or 8.0, tostring(text))
end

function Player:is_enemy(other)
    local h = (getmetatable(other) == Player) and other._handle or other
    return jass.IsPlayerEnemy(self._handle, h)
end

function Player:is_ally(other)
    local h = (getmetatable(other) == Player) and other._handle or other
    return jass.IsPlayerAlly(self._handle, h)
end

function Player:start_x()
    return jass.GetPlayerStartLocationX(self._handle)
end

function Player:start_y()
    return jass.GetPlayerStartLocationY(self._handle)
end

function Player:set_hp_bar_color(argb)
    local ok, japi = pcall(require, "jass.japi")
    if ok and japi and japi.EXSetPlayerHPBarColor then
        japi.EXSetPlayerHPBarColor(self._handle, argb)
    end
end

-- Register player wrapper with Event bus for "player:chat".
Event._set_wrappers(nil, Player.from_handle)

return Player

-- std/init.lua — convenience facade for the map-inject Lua standard library.
--
-- For minimal bundle size (tree-shaking), import individual modules directly:
--   local Signal  = require "std.signal"
--   local Frame   = require "std.frame"
--   local UI      = require "std.ui"
--   local Timer   = require "std.timer"
--   local Unit    = require "std.unit"
--   local StatBar = require "std.statbar"
--
-- Or import everything via `local std = require "std"`.

return {
    util    = require "std.util",
    signal  = require "std.signal",
    timer   = require "std.timer",
    event   = require "std.event",
    player  = require "std.player",
    group   = require "std.group",
    effect  = require "std.effect",
    unit    = require "std.unit",
    statbar = require "std.statbar",
    tween   = require "std.tween",
    frame   = require "std.frame",
    ui      = require "std.ui",
    d3d_ui  = require "std.d3d_ui",
}

-- ============================================================
-- japi game entry point (war3map.lua)
-- Edit this file to write your game logic.
-- ============================================================

-- Built-in C modules (registered by japi.dll)
local jass    = require "jass.common"
local message = require "jass.message"
local runtime = require "jass.runtime"
local japi    = require "jass.japi"
local hook    = require "jass.hook"
local util    = require "lib.util"

-- Run test suite via timer (deferred execution)
local test_mod = require "tests.test_suite"
local timer = jass.CreateTimer()
jass.TimerStart(timer, 0.01, false, test_mod.run)

-- P1 verification: start the DAP debugger listener (actboy168/lua-debug core)
-- Resources must be packed with -WithDebugger; failure is non-fatal.
local ok, err = pcall(function()
    (require "jass.debugger").listen("127.0.0.1", 4278)
end)
if not ok then
    print("[japi-lua] debugger not started: " .. tostring(err))
else
    print("[japi-lua] debugger listening on 127.0.0.1:4278")
end

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

-- Start the DAP debugger listener (actboy168/lua-debug core).
-- Resources must be packed with -WithDebugger; failure is non-fatal.
-- Try several ports (a leftover game instance may already hold 4278).
local dbg_port = nil
for _, p in ipairs({4278, 4279, 4280}) do
    local ok = pcall(function()
        (require "jass.debugger").listen("127.0.0.1", p)
    end)
    if ok then
        dbg_port = p
        break
    end
end

-- Run test suite via timer (deferred execution).
-- When the debugger is listening, delay the suite so there is time to
-- attach and set breakpoints (P3 verification; P5 will make it configurable).
local test_mod = require "tests.test_suite"
local timer = jass.CreateTimer()
jass.TimerStart(timer, dbg_port and 40.0 or 0.01, false, test_mod.run)

if dbg_port then
    print("[japi-lua] debugger listening on 127.0.0.1:" .. dbg_port)
else
    print("[japi-lua] debugger not started")
end

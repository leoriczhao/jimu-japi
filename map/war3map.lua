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

-- Start the DAP debugger via runtime config (VS Code: attach to 127.0.0.1:4278).
-- Requires the map packed with -WithDebugger; failure is non-fatal.
local debugger = require "jass.debugger"
local dbg_port = nil
for _, p in ipairs({4278, 4279, 4280}) do
    runtime.debugger = p
    if debugger.connected() then
        dbg_port = p
        break
    end
end

-- Run test suite via timer (deferred execution).
-- When the debugger is listening, delay the suite so there is time to
-- attach and set breakpoints (dev mode). Without debugger: run at once.
local test_mod = require "tests.test_suite"
local timer = jass.CreateTimer()
jass.TimerStart(timer, dbg_port and 40.0 or 0.01, false, test_mod.run)

if dbg_port then
    print("[japi-lua] debugger listening on 127.0.0.1:" .. dbg_port)
else
    print("[japi-lua] debugger not started")
end

local thread = require "bee.thread"
local channel = require "bee.channel"

local m = {}

local function rawlog(s)
    local f = io.open("D:/Warcraft III Frozen Throne 1.27a publish/japi-debugger/bootstrap_debug.log", "a")
    if f then f:write(os.date("%H:%M:%S") .. " " .. s .. "\n") f:close() end
end

local function hasMaster()
    return channel.query "DbgMaster" ~= nil
end

local function initMaster(rootpath, address)
    if hasMaster() then
        rawlog("initMaster: already has master, skip")
        return
    end
    rawlog("initMaster: create channel DbgMaster")
    local chan = channel.create "DbgMaster"
    rawlog("initMaster: thread.create master chunk")
    thread.create(([[
        local rootpath = %q
        package.path = rootpath.."/script/?.lua"
        local log = require "common.log"
        log.file = rootpath.."/master.log"
        local function rawlog(s)
            local f = io.open(rootpath.."/bootstrap_debug.log", "a")
            if f then f:write(os.date("%%H:%%M:%%S").." [master] "..s.."\n") f:close() end
        end
        rawlog("master chunk started")
        local ok, err = xpcall(function()
            local socket = require "common.socket"(%q)
            rawlog("socket created")
            local master = require "backend.master.mgr"
            master.init(socket)
            rawlog("mgr.init done, entering update loop")
            master.update()
            rawlog("update loop EXITED")
        end, debug.traceback)
        if not ok then
            rawlog("ERROR: " .. tostring(err))
            log.error("ERROR:" .. err)
        end
    ]]):format(
        rootpath,
        address
    ))
    rawlog("initMaster: thread.create returned")
end

local function startWorker(rootpath)
    rawlog("startWorker: require backend.worker ...")
    local log = require 'common.log'
    log.file = rootpath..'/worker.log'
    require 'backend.worker'
    rawlog("startWorker: backend.worker loaded")
end

function m.start(rootpath, address)
    rawlog("m.start: rootpath=" .. tostring(rootpath) .. " address=" .. tostring(address))
    initMaster(rootpath, address)
    startWorker(rootpath)
    rawlog("m.start: done")
end

function m.attach(rootpath)
    if hasMaster() then
        startWorker(rootpath)
    end
end

return m

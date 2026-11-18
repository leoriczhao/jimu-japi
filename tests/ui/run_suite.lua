-- tests/ui/run_suite.lua
--
-- OFFLINE MOCK SUITE RUNNER. Starts no Warcraft III process, loads no native
-- jass.d3d module and sends no input. It runs tests/ui/test_ui.lua against both
-- the shipped map/lib/ui.lua and the example's private copy using the fake
-- adapter in tests/ui/fake_d3d.lua, then checks that the two copies are
-- byte-identical.
--
-- Run from the repository root:
--   .\tools\w3x2lni\bin\w3x2lni-lua.exe tests/ui/run_suite.lua
-- or use the wrapper (recommended):
--   .\tests\ui\run-offline.ps1

local Fake = dofile("tests/ui/fake_d3d.lua")
local Tests = dofile("tests/ui/test_ui.lua")

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("a")
    file:close()
    return contents
end

local function load_ui(path)
    -- The library captures `require "jass.d3d"` at load time. Every test case
    -- passes its own adapter to ui.new(), so this module-level fake only needs
    -- to satisfy the require. Keep the preload installed for both copies;
    -- w3x2lni-lua resolves the module through package.preload.
    package.preload["jass.d3d"] = function()
        return Fake.new { width = 320, height = 240 }
    end
    local chunk, err = loadfile(path)
    assert(chunk, err)
    return chunk()
end

local copies = {
    { path = "map/lib/ui.lua", label = "map/lib/ui.lua" },
    { path = "examples/12-ui-components/lib/ui.lua", label = "examples/12-ui-components/lib/ui.lua" },
}

local pass, fail = 0, 0
for _, copy in ipairs(copies) do
    local ui = load_ui(copy.path)
    local copy_pass, copy_fail = Tests.run(ui, Fake, copy.label)
    pass, fail = pass + copy_pass, fail + copy_fail
end

if read(copies[1].path) ~= read(copies[2].path) then
    fail = fail + 1
    print("  [FAIL] library copy sync: example copy differs from map/lib/ui.lua")
else
    pass = pass + 1
    print("  [PASS] library copy sync")
end

print(string.format(
    "OFFLINE MOCK SUITE: %d passed, %d failed across 2 library copies; "
        .. "no War3 process, native SDK, rendering, or real input was exercised",
    pass, fail))
if fail > 0 then os.exit(1) end

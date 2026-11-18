-- tools/object-data/build.lua
-- CLI entry point for the build-only object declaration compiler.
--
-- Usage:
--   w3x2lni-lua.exe -E tools/object-data/build.lua <objects.lua> <work-dir> <data-root>
--
-- <work-dir> is the unpacked map work directory (pack.ps1 writes there).
-- <data-root> is the w3x2lni data version directory, for example
--   tools/w3x2lni/data/enUS-1.27.1
--
-- Exit codes: 0 success, 1 validation/IO failure, 2 usage error.

local here = assert(arg[0]:match('^(.*)[/\\]'))
local compiler = assert(loadfile(here .. '/compiler.lua'))()

local declarations = arg[1]
local work_dir = arg[2]
local data_root = arg[3]

if not declarations or not work_dir or not data_root then
    io.stderr:write([[
usage: build.lua <objects.lua> <unpacked-map-work-dir> <w3x2lni-data-version-dir>

Example:
  w3x2lni-lua.exe -E tools/object-data/build.lua map/objects.lua build/work tools/w3x2lni/data/enUS-1.27.1
]])
    os.exit(2)
end

local ok, result = pcall(compiler.compile, declarations, work_dir, data_root)
if not ok then
    io.stderr:write('Object data: ' .. tostring(result) .. '\n')
    os.exit(1)
end

local paths = {}
for path in pairs(result) do
    paths[#paths + 1] = path
end
table.sort(paths)

if #paths == 0 then
    print('Object data: no unit or ability declarations; object files left unchanged')
    os.exit(0)
end

for _, path in ipairs(paths) do
    print(('Object data: wrote %s (%d bytes)'):format(path, #result[path]))
end
print('Object data: declarations compiled')
os.exit(0)

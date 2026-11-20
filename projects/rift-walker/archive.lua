-- Archive authored map members only, using the converter's normal MPQ library.
local vendor, input, output = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = vendor .. '/script/?.lua;' .. package.path
package.cpath = vendor .. '/bin/?.dll;' .. package.cpath
local fs = require 'bee.filesystem'
local stormlib = require 'ffi.stormlib'
local members = {}
for i = 4, #arg do
    local name = arg[i]
    assert(name:match('^war3map%.[%w]+$') or name == 'war3mapUnits.doo' or name == 'war3mapMap.blp',
        'invalid map member: ' .. name)
    local file = assert(io.open(input .. '/' .. name, 'rb'))
    members[name] = assert(file:read('a'))
    assert(file:close())
end
local header = assert(io.open(output, 'wb'))
assert(header:write(string.pack('<c4I4zI4I4', 'HM3W', 0, 'Rift Walker', 0x42, 1)))
assert(header:close())
local path = fs.path(output)
local archive = assert(stormlib.create(path, #arg + 3, false), 'create MPQ')
for i = 4, #arg do
    local name = arg[i]
    assert(archive:save_file(name, members[name], 0), 'write ' .. name)
end
archive:close()
archive = assert(stormlib.open(path, true), 'reopen MPQ')
for i = 4, #arg do
    local name = arg[i]
    assert(archive:load_file(name) == members[name], 'round trip ' .. name)
end
archive:close()
print('Standard MPQ member round trip: ' .. tostring(#arg - 3) .. '/' .. tostring(#arg - 3))

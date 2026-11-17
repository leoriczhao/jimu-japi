-- 语法校验：w3x2lni-lua check-syntax.lua <file>
local target = ...
if target == nil then
    print("usage: check-syntax.lua <file>")
    os.exit(2)
end
local chunk, err = loadfile(target)
if chunk == nil then
    print("SYNTAX ERROR: " .. tostring(err))
    os.exit(1)
end
print("SYNTAX OK: " .. target)

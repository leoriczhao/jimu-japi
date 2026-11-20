-- Run from the repository root with the Lua interpreter bundled with w3x2lni.
local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = assert(file:read("a"))
    file:close()
    return content
end

local original = read("reference/builtin-japi/war3map.j")
local registration = read("src/src/extensions/ex_natives/Initialize.cpp")
local dispatch = read("src/src/lua_engine/lua_engine/bridge_dispatch.cpp")

-- The extra R in the old effect wrapper is harmless only while dispatch uses
-- the registered signature. The other two wrappers discard the return value.
assert(dispatch:find("parse_spec(h.spec.c_str())", 1, true),
    "expected dispatch to use the registered signature")

local cases = {
    { name = "EXSetAbilityState", wrapper = "YDWESetUnitAbilityState", spec = "(IIR)B" },
    { name = "EXSetItemDataString", wrapper = "YDWESetItemDataString", spec = "(IIS)B" },
    { name = "EXSetEffectZ", wrapper = "EXSetEffectZ", spec = "(IR)V" },
}
local slot_types = { Integer = "I", Real = "R", Str = "S" }

for _, case in ipairs(cases) do
    local pattern = 'register_cpp_handler%(%s*"' .. case.name .. '"%s*,%s*"([^"]+)"'
    local spec = assert(registration:match(pattern), case.name .. " is not registered")
    assert(spec == case.spec, case.name .. " changed its public signature")

    local wrapper = assert(original:match("function%s+" .. case.wrapper
        .. "%s+takes(.-)endfunction"), "missing wrapper: " .. case.wrapper)
    assert(wrapper:match("returns%s+nothing"), case.wrapper .. " must discard the return value")
    assert(wrapper:find('UnitId(("' .. case.name .. '"))', 1, true),
        case.wrapper .. " calls a different API")

    local slots = {}
    for kind, slot in wrapper:gmatch("Save(%a+)%(%s*japi_ht%s*,%s*japi__key%s*,%s*(%d+)") do
        local index = tonumber(slot)
        if index > 0 then
            slots[index] = assert(slot_types[kind], "unexpected argument type: " .. kind)
        end
    end
    local params = assert(spec:match("^%((%u+)%)"))
    for index = 1, #params do
        assert(slots[index] == params:sub(index, index),
            case.wrapper .. " stores a mismatched argument in slot " .. index)
    end
    assert(slots[#params + 1] == nil, case.wrapper .. " stores an extra argument")
    print("[PASS] " .. case.name .. " legacy wrapper")
end

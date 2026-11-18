-- ============================================================
-- Example 11: code-defined unit and three-level ability.
-- Copy this directory, including its build-only objects.lua.
-- ============================================================
-- ============ Paste into your war3map.lua ============
local jass = require "jass.common"
local slk = require "jass.slk"
-- ============ Example self-check harness ============
local passed, failed = 0, 0
local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('[PASS] ' .. name)
    else failed = failed + 1; print('[FAIL] ' .. name .. ': ' .. tostring(err)) end
end
local function fourcc(s)
    local a,b,c,d = s:byte(1,4)
    return ((a*256+b)*256+c)*256+d
end
local timer = jass.CreateTimer()
jass.TimerStart(timer, 1.0, false, function()
    jass.DestroyTimer(timer)
    local unit
    check("CreateUnit custom id and inherited model", function()
        unit = jass.CreateUnit(jass.Player(0), fourcc('uO11'), 0, 0, 270)
        assert(unit and jass.GetUnitTypeId(unit) == fourcc('uO11'))
        assert(jass.GetUnitName(unit) == 'Code Footman')
        assert(math.abs(jass.GetUnitState(unit, jass.UNIT_STATE_MAX_LIFE) - 725) < 0.1)
    end)
    check("UnitAddAbility and all three levels", function()
        assert(unit and jass.UnitAddAbility(unit, fourcc('AO11')))
        for level = 1, 3 do
            jass.SetUnitAbilityLevel(unit, fourcc('AO11'), level)
            assert(jass.GetUnitAbilityLevel(unit, fourcc('AO11')) == level)
        end
    end)
    check("SLK custom unit roundtrip", function()
        local row = assert(slk.unit['uO11'], 'custom unit missing')
        assert(row.name == 'Code Footman', tostring(row.name))
        assert(tonumber(row.hp) == 725, tostring(row.hp))
        assert(row.race == 'human', tostring(row.race))
    end)
    check("SLK custom ability roundtrip", function()
        local row = assert(slk.ability['AO11'], 'custom ability missing')
        assert(row.code == 'AHbz', tostring(row.code))
        assert(tonumber(row.levels) == 3, tostring(row.levels))
        assert(tonumber(row.cool1) == 9 and tonumber(row.cool3) == 5,
            tostring(row.cool1) .. '/' .. tostring(row.cool3))
    end)
    if unit then jass.RemoveUnit(unit) end
    print(string.format(" Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
end)

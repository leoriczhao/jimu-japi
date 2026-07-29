-- ============================================================
-- EX* natives fixture-based tests (E1)
-- Creates real game objects (unit/item/effect) at the player start,
-- then exercises the EX* bridge natives against them.
-- ============================================================
local jass    = require "jass.common"
local globals = require "jass.globals"

local pass, fail = 0, 0
local SKIP = {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print(string.format("  [PASS] %s", name))
    elseif err == SKIP then
        print(string.format("  [SKIP] %s", name))
    else
        fail = fail + 1
        print(string.format("  [FAIL] %s : %s", name, tostring(err)))
    end
end

-- ── 4CC helper ───────────────────────────────────────────────
local function fourcc(s)
    local a, b, c, d = s:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

-- ── hashtable RPC harness ────────────────────────────────────
local HT, KEY
local function rpc_ready()
    if HT then return true end
    HT  = globals.japi_ht
    KEY = globals.japi__key
    return HT ~= nil and KEY ~= nil
end

local function save_slot(slot, v)
    local t = type(v)
    if t == "number" then
        if math.type(v) == "integer" then
            jass.SaveInteger(HT, KEY, slot, v)
        else
            jass.SaveReal(HT, KEY, slot, v)
        end
    elseif t == "string" then
        jass.SaveStr(HT, KEY, slot, v)
    elseif t == "boolean" then
        jass.SaveBoolean(HT, KEY, slot, v)
    else
        error("unsupported arg type " .. t)
    end
end

local function excall(name, spec, ...)
    assert(rpc_ready(), "japi hashtable globals not available")
    local args = {...}
    for i, v in ipairs(args) do
        save_slot(i, v)
    end
    jass.SaveStr(HT, KEY, 0, spec)
    jass.UnitId(name)
    local r = spec:match("%)(%a)")
    if r == "I" or r == "H" then
        return jass.LoadInteger(HT, KEY, 0)
    elseif r == "R" then
        return jass.LoadReal(HT, KEY, 0)
    elseif r == "S" then
        return jass.LoadStr(HT, KEY, 0)
    elseif r == "B" then
        return jass.LoadBoolean(HT, KEY, 0)
    end
end

-- ── fixtures ─────────────────────────────────────────────────
local fx = {}
local function fx_setup()
    local p0 = jass.Player(0)
    fx.x = jass.GetPlayerStartLocationX(p0) + 400
    fx.y = jass.GetPlayerStartLocationY(p0) + 400
    fx.u = jass.CreateUnit(p0, fourcc("hfoo"), fx.x, fx.y, 270)
    assert(fx.u ~= nil, "CreateUnit(hfoo) failed")
    jass.SetUnitInvulnerable(fx.u, true)
    jass.UnitAddAbility(fx.u, fourcc("AHbz"))
    fx.uid = jass.GetHandleId(fx.u)
    fx.item = jass.CreateItem(fourcc("rat3"), fx.x + 100, fx.y + 100)
end
local function fx_teardown()
    if fx.eff then jass.DestroyEffect(fx.eff) fx.eff = nil end
    if fx.item then jass.RemoveItem(fx.item) fx.item = nil end
    if fx.u then jass.RemoveUnit(fx.u) fx.u = nil end
end

-- ── unit data section ────────────────────────────────────────
local function test_unit_data()
    print("\n-- EX unit data --")
    local code = fourcc("hfoo")

    test("EXGetUnitReal/EXSetUnitReal (round-trip)", function()
        -- The UNIT_STATE enum belongs to a different subsystem; field indices
        -- here are unit-type data slots. Discover the first sane real field,
        -- then round-trip on it (restored afterwards).
        local field, orig
        for t = 0, 60 do
            local v = excall("EXGetUnitReal", "(II)R", code, t)
            if v and v == v and v > 0.5 and v < 100000 then field, orig = t, v break end
        end
        if not field then error(SKIP) end
        excall("EXSetUnitReal", "(IIR)B", code, field, orig + 100)
        local now = excall("EXGetUnitReal", "(II)R", code, field)
        excall("EXSetUnitReal", "(IIR)B", code, field, orig)
        assert(math.abs(now - (orig + 100)) < 0.01,
            string.format("expected %.1f, got %.1f (field %d)", orig + 100, now, field))
    end)

    test("EXGetUnitInteger/EXSetUnitInteger (ATK1_BASE=0x12)", function()
        local orig = excall("EXGetUnitInteger", "(II)I", code, 0x12)
        assert(orig ~= nil, "orig is nil")
        excall("EXSetUnitInteger", "(III)B", code, 0x12, orig + 5)
        local now = excall("EXGetUnitInteger", "(II)I", code, 0x12)
        excall("EXSetUnitInteger", "(III)B", code, 0x12, orig)
        assert(now == orig + 5, string.format("expected %d, got %d", orig + 5, now))
    end)

    test("EXGetUnitString/EXSetUnitString round-trip", function()
        local field
        for t = 0, 7 do
            local v = excall("EXGetUnitString", "(II)S", code, t)
            if v and v ~= "" and v ~= "Default string" then field = t break end
        end
        if not field then error(SKIP) end
        local orig = excall("EXGetUnitString", "(II)S", code, field)
        local ok = excall("EXSetUnitString", "(IIS)B", code, field, "JapiTest")
        assert(ok == true, "EXSetUnitString returned false")
        local now = excall("EXGetUnitString", "(II)S", code, field)
        excall("EXSetUnitString", "(IIS)B", code, field, orig)
        assert(now == "JapiTest", "expected JapiTest, got " .. tostring(now))
    end)

    test("EXGetUnitArrayString/EXSetUnitArrayString", function()
        local field
        for t = 0, 7 do
            local v = excall("EXGetUnitArrayString", "(III)S", code, t, 0)
            if v and v ~= "" and v ~= "Default string" then field = t break end
        end
        if not field then error(SKIP) end
        local orig = excall("EXGetUnitArrayString", "(III)S", code, field, 0)
        excall("EXSetUnitArrayString", "(IIIS)B", code, field, 0, "JapiArr")
        local now = excall("EXGetUnitArrayString", "(III)S", code, field, 0)
        excall("EXSetUnitArrayString", "(IIIS)B", code, field, 0, orig)
        assert(now == "JapiArr", "expected JapiArr, got " .. tostring(now))
    end)

    test("EXPauseUnit call", function()
        excall("EXPauseUnit", "(IB)V", fx.uid, true)
        excall("EXPauseUnit", "(IB)V", fx.uid, false)
    end)

    test("EXSetUnitCollisionType call", function()
        excall("EXSetUnitCollisionType", "(BII)V", true, fx.uid, 0)
        excall("EXSetUnitCollisionType", "(BII)V", false, fx.uid, 0)
    end)

    test("EXSetUnitMoveType call", function()
        excall("EXSetUnitMoveType", "(II)V", fx.uid, 0)
    end)

    test("EXSetUnitFacing sets angle", function()
        excall("EXSetUnitFacing", "(IR)V", fx.uid, 90.0)
        local f = jass.GetUnitFacing(fx.u)
        assert(math.abs(f - 90) < 1.5, "facing " .. tostring(f) .. " != 90")
    end)
end

-- ── ability data section ─────────────────────────────────────
local function test_ability_data()
    print("\n-- EX ability data --")
    local abcode = fourcc("AHbz")

    test("EXGetUnitAbility returns handle", function()
        local h = excall("EXGetUnitAbility", "(II)I", fx.uid, abcode)
        assert(h and h ~= 0, "no AHbz on fixture unit")
        fx.abil = h
    end)

    test("EXGetUnitAbilityByIndex finds AHbz", function()
        -- compare by ability code (pool handles may differ per call)
        for i = 0, 10 do
            local h = excall("EXGetUnitAbilityByIndex", "(II)I", fx.uid, i)
            if h and h ~= 0 and excall("EXGetAbilityId", "(I)I", h) == abcode then return end
        end
        error("ability not found by index")
    end)

    test("EXGetAbilityId round-trips", function()
        assert(fx.abil)
        local code = excall("EXGetAbilityId", "(I)I", fx.abil)
        assert(code == abcode, string.format("expected %08X, got %08X", abcode, code))
    end)

    test("EXGetAbilityState cooldown is number", function()
        assert(fx.abil)
        local cd = excall("EXGetAbilityState", "(II)R", fx.abil, 1)
        assert(type(cd) == "number" and cd >= 0, "cooldown: " .. tostring(cd))
    end)

    test("EXSetAbilityState cooldown write+reset", function()
        assert(fx.abil)
        excall("EXSetAbilityState", "(IIR)B", fx.abil, 1, 5.0)
        local cd = excall("EXGetAbilityState", "(II)R", fx.abil, 1)
        excall("EXSetAbilityState", "(IIR)B", fx.abil, 1, 0.0)
        assert(math.abs(cd - 5.0) < 0.01, "cooldown after set: " .. tostring(cd))
    end)

    test("EXGetAbilityDataInteger mana cost (104)", function()
        assert(fx.abil)
        local cost = excall("EXGetAbilityDataInteger", "(III)I", fx.abil, 1, 104)
        assert(cost and cost > 0, "mana cost: " .. tostring(cost))
    end)

    test("EXSetAbilityDataInteger mana cost round-trip", function()
        assert(fx.abil)
        local orig = excall("EXGetAbilityDataInteger", "(III)I", fx.abil, 1, 104)
        excall("EXSetAbilityDataInteger", "(IIII)V", fx.abil, 1, 104, orig + 1)
        local now = excall("EXGetAbilityDataInteger", "(III)I", fx.abil, 1, 104)
        excall("EXSetAbilityDataInteger", "(IIII)V", fx.abil, 1, 104, orig)
        assert(now == orig + 1, string.format("expected %d, got %d", orig + 1, now))
    end)

    test("EXGetAbilityDataReal cooldown (105)", function()
        assert(fx.abil)
        local cd = excall("EXGetAbilityDataReal", "(III)R", fx.abil, 1, 105)
        assert(cd and cd > 0, "cooldown: " .. tostring(cd))
    end)

    test("EXSetAbilityDataReal cooldown round-trip", function()
        assert(fx.abil)
        local orig = excall("EXGetAbilityDataReal", "(III)R", fx.abil, 1, 105)
        excall("EXSetAbilityDataReal", "(IIIR)V", fx.abil, 1, 105, orig + 1.0)
        local now = excall("EXGetAbilityDataReal", "(III)R", fx.abil, 1, 105)
        excall("EXSetAbilityDataReal", "(IIIR)V", fx.abil, 1, 105, orig)
        assert(math.abs(now - (orig + 1.0)) < 0.01,
            string.format("expected %.1f, got %.1f", orig + 1.0, now))
    end)

    test("EXGetAbilityDataInteger targets mask (100)", function()
        assert(fx.abil)
        -- data[0] = targets-allowed bitmask (layout cross-validated by
        -- mana cost at data[4]=75); the mask's high bit makes it look negative.
        local targs = excall("EXGetAbilityDataInteger", "(III)I", fx.abil, 1, 100)
        assert(targs and targs ~= 0, "targets mask: " .. tostring(targs))
    end)

    test("EXGetAbilityDataString/EXSetAbilityDataString", function()
        assert(fx.abil)
        -- string types live at 203+ (NAME=203, ART=204, ..., TIP=215)
        local h, field = fx.abil, nil
        for t = 203, 220 do
            local v = excall("EXGetAbilityDataString", "(III)S", h, 1, t)
            if v and v ~= "" then field = t break end
        end
        if not field then
            -- learned abilities may lack UI strings; retry on a native carrier
            local mk = jass.CreateUnit(jass.Player(0), fourcc("Hmkg"), fx.x + 200, fx.y, 270)
            jass.SetUnitInvulnerable(mk, true)
            h = excall("EXGetUnitAbility", "(II)I", jass.GetHandleId(mk), abcode)
            for t = 203, 220 do
                local v = excall("EXGetAbilityDataString", "(III)S", h, 1, t)
                if v and v ~= "" then field = t break end
            end
            if not field then jass.RemoveUnit(mk) error(SKIP) end
            fx.mk = mk
        end
        local orig = excall("EXGetAbilityDataString", "(III)S", h, 1, field)
        excall("EXSetAbilityDataString", "(IIIS)V", h, 1, field, "JapiAbil")
        local now = excall("EXGetAbilityDataString", "(III)S", h, 1, field)
        excall("EXSetAbilityDataString", "(IIIS)V", h, 1, field, orig)
        if fx.mk then jass.RemoveUnit(fx.mk) fx.mk = nil end
        assert(now == "JapiAbil", "expected JapiAbil, got " .. tostring(now))
    end)

    test("EXSetAbilityAEmeDataA executes", function()
        assert(fx.abil)
        -- not a metamorphosis ability; just verify no crash (false acceptable)
        excall("EXSetAbilityAEmeDataA", "(II)B", fx.abil, 0)
    end)
end

-- ── buff data section ────────────────────────────────────────
local function test_buff_data()
    print("\n-- EX buff data --")
    local bcode = fourcc("Bpsd")

    test("EXGetBuffDataString/EXSetBuffDataString round-trip", function()
        local bcode, field
        for _, bc in ipairs({fourcc("Bpsd"), fourcc("Bhea"), fourcc("Bfro")}) do
            for t = 1, 3 do
                local v = excall("EXGetBuffDataString", "(II)S", bc, t)
                if v and v ~= "" then bcode, field = bc, t break end
            end
            if field then break end
        end
        if not field then error(SKIP) end
        local orig = excall("EXGetBuffDataString", "(II)S", bcode, field)
        excall("EXSetBuffDataString", "(IIS)B", bcode, field, "JapiBuff")
        local now = excall("EXGetBuffDataString", "(II)S", bcode, field)
        excall("EXSetBuffDataString", "(IIS)B", bcode, field, orig)
        assert(now == "JapiBuff", "expected JapiBuff, got " .. tostring(now))
    end)
end

-- ── item data section ────────────────────────────────────────
local function test_item_data()
    print("\n-- EX item data --")
    local icode = fourcc("rat3")

    test("EXGetItemDataString/EXSetItemDataString round-trip", function()
        local field
        for t = 0, 5 do
            local v = excall("EXGetItemDataString", "(II)S", icode, t)
            if v and v ~= "" then field = t break end
        end
        if not field then error(SKIP) end
        local orig = excall("EXGetItemDataString", "(II)S", icode, field)
        excall("EXSetItemDataString", "(IIS)B", icode, field, "JapiItem")
        local now = excall("EXGetItemDataString", "(II)S", icode, field)
        excall("EXSetItemDataString", "(IIS)B", icode, field, orig)
        assert(now == "JapiItem", "expected JapiItem, got " .. tostring(now))
    end)
end

-- ── effect section ───────────────────────────────────────────
local function test_effect()
    print("\n-- EX effect --")
    fx.eff = jass.AddSpecialEffect(
        "Abilities\\Spells\\Human\\HolyBolt\\HolyBoltSpecialArt.mdl", fx.x, fx.y)
    local eid = jass.GetHandleId(fx.eff)

    test("EXSetEffectXY + EXGetEffectX/Y", function()
        excall("EXSetEffectXY", "(IRR)V", eid, fx.x + 500, fx.y + 500)
        local ex = excall("EXGetEffectX", "(I)R", eid)
        local ey = excall("EXGetEffectY", "(I)R", eid)
        assert(math.abs(ex - (fx.x + 500)) < 1 and math.abs(ey - (fx.y + 500)) < 1,
            string.format("pos (%.1f, %.1f)", ex, ey))
    end)

    test("EXSetEffectZ + EXGetEffectZ", function()
        -- signature adjudicated: ours is (IR)V; builtin-japi's wrapper shows (IRR)V
        -- (05-map-side.md line 520) — verified compatible at (IR)V.
        excall("EXSetEffectZ", "(IR)V", eid, 200.0)
        local ez = excall("EXGetEffectZ", "(I)R", eid)
        assert(math.abs(ez - 200.0) < 1, "z: " .. tostring(ez))
    end)

    test("EXSetEffectSize + EXGetEffectSize", function()
        excall("EXSetEffectSize", "(IR)V", eid, 2.0)
        local s = excall("EXGetEffectSize", "(I)R", eid)
        assert(math.abs(s - 2.0) < 0.01, "size: " .. tostring(s))
    end)

    test("EXEffectMatRotateX/Y/Z call", function()
        excall("EXEffectMatRotateX", "(IR)V", eid, 45.0)
        excall("EXEffectMatRotateY", "(IR)V", eid, 45.0)
        excall("EXEffectMatRotateZ", "(IR)V", eid, 45.0)
    end)

    test("EXEffectMatScale call", function()
        excall("EXEffectMatScale", "(IRRR)V", eid, 2.0, 2.0, 2.0)
    end)

    test("EXEffectMatReset call", function()
        excall("EXEffectMatReset", "(I)V", eid)
    end)

    test("EXSetEffectSpeed call", function()
        excall("EXSetEffectSpeed", "(IR)V", eid, 2.0)
        excall("EXSetEffectSpeed", "(IR)V", eid, 1.0)
    end)
end

-- ── info/display section ─────────────────────────────────────
local function test_info()
    print("\n-- EX info/display --")

    test("GetMapName non-empty", function()
        local name = excall("GetMapName", "()S")
        assert(type(name) == "string" and #name > 0, "map name: " .. tostring(name))
    end)

    test("GetGameVersion > 0", function()
        local v = excall("GetGameVersion", "()I")
        assert(type(v) == "number" and v > 0, "version: " .. tostring(v))
    end)

    test("GetPluginVersion non-empty", function()
        local v = excall("GetPluginVersion", "()S")
        assert(type(v) == "string" and #v > 0, "plugin version: " .. tostring(v))
    end)

    test("EXDisplayChat executes", function()
        excall("EXDisplayChat", "(IIS)V", 0, 0, "[test] display chat")
    end)

    test("Hex formats", function()
        assert(excall("Hex", "(I)S", 255) == "000000FF", "Hex(255): " .. tostring(excall("Hex", "(I)S", 255)))
        assert(excall("Hex", "(I)S", 0xDEADBEEF) == "DEADBEEF",
            "Hex(0xDEADBEEF): " .. tostring(excall("Hex", "(I)S", 0xDEADBEEF)))
    end)

    test("EXExecuteScript evaluates", function()
        assert(excall("EXExecuteScript", "(S)S", "1+1") == "2",
            "EXExecuteScript('1+1'): " .. tostring(excall("EXExecuteScript", "(S)S", "1+1")))
        assert(excall("EXExecuteScript", "(S)S", "'abc'..'def'") == "abcdef")
    end)
end

-- ── run ──────────────────────────────────────────────────────
local function run()
    fx_setup()
    test_unit_data()
    test_ability_data()
    test_buff_data()
    test_item_data()
    test_effect()
    test_info()
    fx_teardown()
    return pass, fail
end

return { run = run }

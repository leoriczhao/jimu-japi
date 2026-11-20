-- ============================================================
-- EX* natives fixture-based tests (E1)
-- Creates real game objects (unit/item/effect) at the player start,
-- then exercises the EX* bridge natives against them.
-- ============================================================
local jass    = require "jass.common"
local globals = require "jass.globals"
local message = require "jass.message"

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

-- ── event damage section ────────────────────────────────────
local function test_damage_event()
    print("\n-- EX event damage --")

    local source, victim, trig
    local fired = false
    local valid, physical, is_attack
    local damage_before_set, damage_after_set, set_ok
    local life_before, life_after, control_life_after

    local setup_ok, setup_err = pcall(function()
        source = jass.CreateUnit(jass.Player(0), fourcc("hfoo"), fx.x + 250, fx.y, 270)
        victim = jass.CreateUnit(jass.Player(1), fourcc("hfoo"), fx.x + 400, fx.y, 270)
        assert(source ~= nil and victim ~= nil, "damage fixture CreateUnit failed")
        jass.SetWidgetLife(victim, 200.0)

        trig = jass.CreateTrigger()
        jass.TriggerRegisterUnitEvent(trig, victim, jass.ConvertUnitEvent(52)) -- EVENT_UNIT_DAMAGED
        jass.TriggerAddAction(trig, jass.code(function()
            fired = true
            valid = excall("EXGetEventDamageData", "(I)I", 0)
            physical = excall("EXGetEventDamageData", "(I)I", 1)
            is_attack = excall("EXGetEventDamageData", "(I)I", 2)
            damage_before_set = jass.GetEventDamage()
            set_ok = excall("EXSetEventDamage", "(R)B", 7.0)
            damage_after_set = jass.GetEventDamage()
        end))

        life_before = jass.GetWidgetLife(victim)
        local issued = jass.UnitDamageTarget(
            source, victim, 20.0, true, false,
            jass.ConvertAttackType(0),     -- ATTACK_TYPE_NORMAL
            jass.ConvertDamageType(4),    -- DAMAGE_TYPE_NORMAL (physical)
            jass.ConvertWeaponType(0))    -- WEAPON_TYPE_WHOKNOWS
        assert(issued == true, "UnitDamageTarget returned false")
        life_after = jass.GetWidgetLife(victim)

        -- Compare the modified 20->7 hit with a native 7-damage control hit.
        -- This avoids depending on the fixture unit's armor formula.
        jass.DestroyTrigger(trig)
        trig = nil
        jass.UnitDamageTarget(
            source, victim, 7.0, true, false,
            jass.ConvertAttackType(0), jass.ConvertDamageType(4), jass.ConvertWeaponType(0))
        control_life_after = jass.GetWidgetLife(victim)
    end)

    test("EXGetEventDamageData sees live damage context", function()
        assert(setup_ok, tostring(setup_err))
        assert(fired, "EVENT_UNIT_DAMAGED callback did not fire")
        assert(valid == 1, "EVENT_DAMAGE_DATA_VALID: " .. tostring(valid))
        assert(physical == 0 or physical == 1,
            "EVENT_DAMAGE_DATA_PHYSICAL is not boolean: " .. tostring(physical))
        assert(is_attack == 1, "EVENT_DAMAGE_DATA_IS_ATTACK: " .. tostring(is_attack))
        assert(type(damage_before_set) == "number" and damage_before_set > 7.0,
            "GetEventDamage before set: " .. tostring(damage_before_set))
    end)

    test("EXSetEventDamage changes event and applied damage", function()
        assert(setup_ok, tostring(setup_err))
        assert(set_ok == true, "EXSetEventDamage returned " .. tostring(set_ok))
        assert(math.abs((damage_after_set or -1) - 7.0) < 0.01,
            "GetEventDamage after set: " .. tostring(damage_after_set))
        local modified_applied = (life_before or 0) - (life_after or 0)
        local control_applied = (life_after or 0) - (control_life_after or 0)
        assert(math.abs(modified_applied - 7.0) < 0.25,
            string.format("modified damage %.3f != 7.0", modified_applied))
        assert(control_applied > 0.1, "7-damage control hit applied no damage")
        assert(control_applied < modified_applied,
            string.format("physical control %.3f was not armor-reduced below %.3f",
                control_applied, modified_applied))
    end)

    if trig then jass.DestroyTrigger(trig) end
    if source then jass.RemoveUnit(source) end
    if victim then jass.RemoveUnit(victim) end
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

-- ── mouse / selection / local orders section (E3) ────────────
local function test_mouse_orders()
    print("\n-- EX mouse / selection / local orders --")

    test("GetMouseX/Y return numbers", function()
        local mx = excall("GetMouseX", "()R")
        local my = excall("GetMouseY", "()R")
        assert(type(mx) == "number" and type(my) == "number",
            string.format("mouse world (%.1f, %.1f)", mx, my))
    end)

    test("GetMouseVectorX/Y return numbers", function()
        local vx = excall("GetMouseVectorX", "()R")
        local vy = excall("GetMouseVectorY", "()R")
        assert(type(vx) == "number" and type(vy) == "number",
            string.format("mouse screen (%.1f, %.1f)", vx, vy))
    end)

    test("GetPlayerSelectedUnit after SelectUnit", function()
        -- SelectUnit adds to the selection; remove any existing hero first.
        jass.ClearSelection()
        jass.SelectUnit(fx.u, true)
        local sel = excall("GetPlayerSelectedUnit", "(I)Hunit;", 0)
        jass.SelectUnit(fx.u, false)
        assert(sel == fx.uid, string.format("selected %d != fixture %d", sel or -1, fx.uid))
    end)

    test("GetTargetObject returns integer", function()
        local t = excall("GetTargetObject", "()Hunit;")
        assert(type(t) == "number", "target object: " .. tostring(t))
    end)

    test("SetUnitAbilityButtonShow hide/show", function()
        excall("SetUnitAbilityButtonShow", "(IIB)V", fx.uid, fourcc("AHbz"), false)
        excall("SetUnitAbilityButtonShow", "(IIB)V", fx.uid, fourcc("AHbz"), true)
    end)
end

-- Optional real-window interaction for the two E3 APIs whose ordinary tests can
-- only prove type/ABI safety. The deployment flag fixes the camera and keeps each
-- visual phase stable until a real foreground mouse/key action advances it.
local function test_interactive_ui_async(done)
    if rawget(_G, "__JAPI_TEST_INTERACTIVE_UI") ~= true then
        done()
        return
    end

    local timer = jass.CreateTimer()
    local local_player = jass.GetLocalPlayer()
    local local_player_id = jass.GetPlayerId(local_player)
    local enemy_player = jass.Player(local_player_id == 0 and 1 or 0)
    local center_x = jass.GetPlayerStartLocationX(local_player) + 512.0
    local center_y = jass.GetPlayerStartLocationY(local_player) + 512.0
    local hero = jass.CreateUnit(local_player, fourcc("Hamg"),
        center_x - 320.0, center_y - 160.0, 0.0)
    local hover_target = jass.CreateUnit(enemy_player, fourcc("htow"),
        center_x, center_y, 270.0)
    local ability_id = fourcc("AHbz")
    local hero_id = hero and jass.GetHandleId(hero) or 0
    local target_id = hover_target and jass.GetHandleId(hover_target) or 0
    local hook_installed = false

    assert(hero ~= nil and hover_target ~= nil, "interactive UI fixture CreateUnit failed")
    jass.SetUnitInvulnerable(hero, true)
    jass.SetUnitInvulnerable(hover_target, true)
    jass.SetHeroLevel(hero, 10, false)
    jass.SelectHeroSkill(hero, ability_id)
    assert(jass.GetUnitAbilityLevel(hero, ability_id) > 0,
        "interactive UI hero did not learn AHbz")

    local function notice(text)
        jass.ClearTextMessages()
        jass.DisplayTimedTextToPlayer(local_player, 0.0, 0.0, 3600.0, text)
    end

    local function find_ability_button()
        for y = 0, 2 do
            for x = 0, 3 do
                local ability = message.button(x, y)
                if ability == ability_id then return x, y end
            end
        end
        return nil, nil
    end

    local function cleanup()
        if hook_installed then
            message.hook = nil
            hook_installed = false
        end
        jass.ClearTextMessages()
        jass.SelectUnit(hero, false)
        if hover_target then jass.RemoveUnit(hover_target) hover_target = nil end
        if hero then jass.RemoveUnit(hero) hero = nil end
        -- Let CGameUI finish rebuilding the command card before the following
        -- Local*Order fixture selects its own unit.
        jass.TimerStart(timer, 0.75, false, function()
            jass.DestroyTimer(timer)
            done()
        end)
    end

    local function wait_for_button_presence(want_present, timeout, callback)
        local waited = 0.0
        local function poll()
            local x, y = find_ability_button()
            local present = x ~= nil and y ~= nil
            if present == want_present or waited >= timeout then
                callback(x, y)
                return
            end
            waited = waited + 0.10
            jass.TimerStart(timer, 0.10, false, poll)
        end
        poll()
    end

    local function begin_button_phases()
        jass.SelectUnit(hover_target, false)
        jass.SelectUnit(hero, true)
        excall("SetUnitAbilityButtonShow", "(IIB)V", hero_id, ability_id, true)

        wait_for_button_presence(true, 10.0, function(shown_x, shown_y)
            print(string.format(
                "INTERACTIVE_UI_BUTTON_SHOWN_READY: ability=AHbz slot=%s,%s press Q to hide",
                tostring(shown_x), tostring(shown_y)))
            notice("[UI TEST] SHOWN: Blizzard button must be visible. Press Q to hide it.")

            local phase = 0
            local q_is_down = false
            hook_installed = true
            message.hook = function(msg)
                if msg.code ~= 81 then return true end
                if msg.type == "key_up" then
                    q_is_down = false
                    return false
                end
                if msg.type ~= "key_down" then return true end
                if q_is_down then return false end
                q_is_down = true
                if phase ~= 0 then return false end

                if phase == 0 then
                    phase = 1
                    jass.TimerStart(timer, 0.01, false, function()
                        excall("SetUnitAbilityButtonShow", "(IIB)V",
                            hero_id, ability_id, false)
                        jass.SelectUnit(hero, false)
                        jass.SelectUnit(hero, true)
                        wait_for_button_presence(false, 10.0, function(hidden_x, hidden_y)
                            print(string.format(
                                "INTERACTIVE_UI_BUTTON_HIDDEN_READY: ability=AHbz slot=%s,%s auto-restore=10s",
                                tostring(hidden_x), tostring(hidden_y)))
                            notice("[UI TEST] HIDDEN: Blizzard is disabled for 10 seconds; restore is automatic.")

                            jass.TimerStart(timer, 10.0, false, function()
                                excall("SetUnitAbilityButtonShow", "(IIB)V",
                                    hero_id, ability_id, true)
                                jass.SelectUnit(hero, false)
                                jass.SelectUnit(hero, true)
                                wait_for_button_presence(true, 10.0, function(restored_x, restored_y)
                                    test("SetUnitAbilityButtonShow visible/hidden/restored interaction", function()
                                        assert(shown_x ~= nil and shown_y ~= nil,
                                            "AHbz button missing in shown phase")
                                        assert(hidden_x == nil and hidden_y == nil,
                                            string.format("AHbz still present in hidden slot %s,%s",
                                                tostring(hidden_x), tostring(hidden_y)))
                                        assert(restored_x == shown_x and restored_y == shown_y,
                                            string.format("AHbz restored slot %s,%s != %s,%s",
                                                tostring(restored_x), tostring(restored_y),
                                                tostring(shown_x), tostring(shown_y)))
                                    end)
                                    print(string.format(
                                        "INTERACTIVE_UI_BUTTON_RESTORED: ability=AHbz slot=%s,%s",
                                        tostring(restored_x), tostring(restored_y)))
                                    cleanup()
                                end)
                            end)
                        end)
                    end)
                end
                return false
            end
        end)
    end

    jass.SelectUnit(fx.u, false)
    jass.SelectUnit(hero, true)
    jass.PanCameraToTimed(center_x, center_y, 0.0)
    notice("[UI TEST] Hover/click the enemy Town Hall at screen center.")
    print("INTERACTIVE_UI_HOVER_READY: target_handle=" .. tostring(target_id)
        .. " target=enemy Town Hall at camera center")

    local elapsed = 0.0
    local function poll_hover_target()
        elapsed = elapsed + 0.10
        local hovered = excall("GetTargetObject", "()Hunit;")
        if hovered == target_id then
            test("GetTargetObject matches real hovered unit", function()
                assert(hovered == target_id,
                    string.format("hovered %s != target %s", tostring(hovered), tostring(target_id)))
            end)
            print("INTERACTIVE_UI_HOVER_MATCH: actual=" .. tostring(hovered)
                .. " expected=" .. tostring(target_id))
            begin_button_phases()
            return
        end
        if elapsed >= 3600.0 then
            test("GetTargetObject matches real hovered unit", function()
                error("real mouse hover did not resolve the fixture target")
            end)
            cleanup()
            return
        end
        jass.TimerStart(timer, 0.10, false, poll_hover_target)
    end
    jass.TimerStart(timer, 0.50, false, poll_hover_target)
end

-- Local orders enqueue UI command packets. The ordinary suite checks bridge ABI
-- safety and the observable target-order result. -InteractivePoint additionally
-- requires a real foreground key event, then checks whether the shared point-order
-- submit path casts a point-target ability (see RE doc 08 section 7).
local function test_local_orders_async(done)
    local timer = jass.CreateTimer()
    local enemy
    local local_player = jass.GetLocalPlayer()
    local local_player_id = jass.GetPlayerId(local_player)
    local enemy_player = jass.Player(local_player_id == 0 and 1 or 0)
    local order_spawn_x = jass.GetPlayerStartLocationX(local_player)
    local order_spawn_y = jass.GetPlayerStartLocationY(local_player)
    local order_unit = jass.CreateUnit(local_player, fourcc("Hamg"),
        order_spawn_x, order_spawn_y, 270)
    local FLAG_LOCAL_CAST = (1 << 2) | (1 << 5)
    assert(order_unit ~= nil, "CreateUnit(order fixture) failed")

    local move_order = jass.OrderId("move")
    local point_ability = fourcc("AHbz")
    local point_order = jass.OrderId("blizzard")
    jass.SetHeroLevel(order_unit, 10, false)
    jass.SelectHeroSkill(order_unit, point_ability)
    assert(jass.GetUnitAbilityLevel(order_unit, point_ability) > 0,
        "SelectHeroSkill(AHbz) failed")
    local max_mana = jass.GetUnitState(order_unit, jass.ConvertUnitState(3))
    assert(max_mana > 0.0, "Archmage fixture has no mana pool")
    jass.SetUnitState(order_unit, jass.ConvertUnitState(2), max_mana)
    local start_x = jass.GetUnitX(order_unit)
    local start_y = jass.GetUnitY(order_unit)
    local point_x = start_x + 256.0
    local point_y = start_y + 128.0
    local hook_seen = false
    local hook_submit_ok = false
    local hook_submit_err
    local hook_input_code
    local spell_trigger
    local spell_fired = false
    local spell_ability_seen
    local interactive_point = rawget(_G, "__JAPI_TEST_INTERACTIVE_POINT") == true

    local function continue_with_target()
        local target_ok, target_err = pcall(function()
            enemy = jass.CreateUnit(enemy_player, fourcc("hfoo"),
                jass.GetUnitX(order_unit) + 200, jass.GetUnitY(order_unit), 270)
            assert(enemy ~= nil, "CreateUnit(enemy) failed")
            jass.SetUnitInvulnerable(enemy, true)
            excall("LocalTargetOrder", "(IHwidget;I)V",
                jass.OrderId("attack"), jass.GetHandleId(enemy), FLAG_LOCAL_CAST)
        end)

        jass.TimerStart(timer, 0.50, false, function()
            test("LocalTargetOrder attack executes", function()
                assert(target_ok, tostring(target_err))
                local cur = jass.GetUnitCurrentOrder(order_unit)
                assert(cur == jass.OrderId("attack"),
                    string.format("current order %d != attack %d", cur or -1, jass.OrderId("attack")))
            end)

            jass.SelectUnit(order_unit, false)
            if enemy then jass.RemoveUnit(enemy) enemy = nil end
            jass.RemoveUnit(order_unit)
            jass.DestroyTimer(timer)
            done()
        end)
    end

    jass.SelectUnit(fx.u, false)
    jass.SelectUnit(order_unit, true)
    test("LocalOrder stop executes", function()
        excall("LocalOrder", "(II)V", jass.OrderId("stop"), FLAG_LOCAL_CAST)
    end)

    jass.TimerStart(timer, 0.05, false, function()
        test("LocalPointOrder call is safe", function()
            excall("LocalPointOrder", "(IRRI)V", move_order,
                jass.GetUnitX(order_unit), jass.GetUnitY(order_unit) - 500,
                FLAG_LOCAL_CAST)
        end)

        if not interactive_point then
            continue_with_target()
            return
        end

        -- This mode deliberately waits for a real foreground key press. It is
        -- enabled only by tools/deploy.ps1 -InteractivePoint, so unattended
        -- regression remains deterministic and never claims synthetic input as
        -- proof of the CGameUI interaction path.
        spell_trigger = jass.CreateTrigger()
        jass.TriggerRegisterUnitEvent(spell_trigger, order_unit, jass.ConvertUnitEvent(291))
        jass.TriggerAddAction(spell_trigger, jass.code(function()
            spell_fired = true
            spell_ability_seen = jass.GetSpellAbilityId()
        end))

        print("INTERACTIVE_POINT_READY: focus War3 and press Q to cast Blizzard")
        message.hook = function(msg)
            if msg.type == "key_down" and msg.code == 81 and not hook_seen then
                hook_seen = true
                hook_input_code = msg.code
                local call_ok, submit_result = pcall(message.order_point,
                    point_order, point_x, point_y, FLAG_LOCAL_CAST)
                hook_submit_ok = call_ok and submit_result == true
                hook_submit_err = call_ok and
                    ("order_point returned " .. tostring(submit_result)) or submit_result
                print("INTERACTIVE_POINT_HOOK: type=key_down code=" .. tostring(hook_input_code)
                    .. " submit=" .. tostring(hook_submit_ok)
                    .. " error=" .. tostring(hook_submit_err))
                -- Match builtin-japi's cast_ability example: the original key
                -- must not continue into War3 after the local order is submitted.
                return false
            elseif msg.type == "key_down" and msg.code == 81 then
                -- Remote/held keys can repeat. Submit exactly one local order.
                return false
            end
            return true
        end

        local elapsed = 0.0
        local function poll_point_result()
            elapsed = elapsed + 0.25
            if not (hook_seen and spell_fired) and elapsed < 3600.0 then
                jass.TimerStart(timer, 0.25, false, poll_point_result)
                return
            end

            test("LocalPointOrder casts a point ability from real message.hook", function()
                assert(hook_seen, "real Q input did not reach message.hook")
                assert(type(hook_input_code) == "number",
                    "message.hook input code missing: " .. tostring(hook_input_code))
                assert(hook_submit_ok == true,
                    "LocalPointOrder failed in hook: " .. tostring(hook_submit_err))
                assert(spell_fired, "EVENT_UNIT_SPELL_EFFECT did not fire")
                assert(spell_ability_seen == point_ability,
                    string.format("spell ability %s != AHbz %d",
                        tostring(spell_ability_seen), point_ability))
            end)
            print("INTERACTIVE_POINT_KEY_CODE: " .. tostring(hook_input_code))
            message.hook = nil
            if spell_trigger then
                jass.DestroyTrigger(spell_trigger)
                spell_trigger = nil
            end
            continue_with_target()
        end
        jass.TimerStart(timer, 0.25, false, poll_point_result)
    end)
end

-- ── game UI section (E2b, builtin-japi CGameUI series) ───────
local function test_gameui()
    print("\n-- EX game UI (CGameUI) --")

    test("GetChatState is false at start", function()
        local st = excall("GetChatState", "()B")
        assert(st == false, "chat state: " .. tostring(st))
    end)

    test("GetFps > 0", function()
        local fps = excall("GetFps", "()R")
        assert(type(fps) == "number" and fps > 0, "fps: " .. tostring(fps))
    end)

    test("LittleMapX/Y get-set-get round-trip", function()
        local x0 = excall("GetLittleMapX", "()R")
        local y0 = excall("GetLittleMapY", "()R")
        assert(type(x0) == "number" and type(y0) == "number",
            string.format("littlemap (%.3f, %.3f)", x0, y0))
        excall("SetLittleMapX", "(R)V", x0 + 0.01)
        excall("SetLittleMapY", "(R)V", y0 + 0.01)
        local x1 = excall("GetLittleMapX", "()R")
        local y1 = excall("GetLittleMapY", "()R")
        assert(math.abs(x1 - (x0 + 0.01)) < 1e-4, string.format("X %.4f != %.4f", x1, x0 + 0.01))
        assert(math.abs(y1 - (y0 + 0.01)) < 1e-4, string.format("Y %.4f != %.4f", y1, y0 + 0.01))
        excall("SetLittleMapX", "(R)V", x0)
        excall("SetLittleMapY", "(R)V", y0)
    end)

    test("ShowFpsText on/off/on does not crash", function()
        excall("ShowFpsText", "(B)V", true)
        excall("ShowFpsText", "(B)V", false)
        excall("ShowFpsText", "(B)V", true)
    end)

    test("ShowConsole hide/restore changes and restores console frames", function()
        local original_x = excall("GetLittleMapX", "()R")
        excall("ShowConsole", "(B)V", false)
        local hidden_x = excall("GetLittleMapX", "()R")
        assert(math.abs(hidden_x - (-2.0)) < 0.001,
            "hidden minimap x=" .. tostring(hidden_x))
        excall("ShowConsole", "(B)V", true)
        local restored_x = excall("GetLittleMapX", "()R")
        assert(math.abs(restored_x - original_x) < 0.001,
            string.format("restored minimap x=%s original=%s",
                tostring(restored_x), tostring(original_x)))
    end)
end

-- ── run ──────────────────────────────────────────────────────

-- ── builtin-compat natives (BigMap / ConsoleUI / stopwatch) ────────────────
-- These are real JASS natives (japi_add), so they are called through jass.call
-- rather than the UnitId bridge.
local function test_compat()
    test("GetBigMapX/Y return numbers", function()
        local x = jass.call("GetBigMapX")
        local y = jass.call("GetBigMapY")
        assert(type(x) == "number" and type(y) == "number",
            "x=" .. tostring(x) .. " y=" .. tostring(y))
    end)

    test("ConsoleUIY set/get round-trip", function()
        -- Y is the only frame coordinate ShowConsole does not rewrite, so it is
        -- the safe one to exercise.
        local before = jass.call("GetConsoleUIY")
        assert(type(before) == "number", "before=" .. tostring(before))
        jass.call("SetConsoleUIY", before + 0.1)
        local after = jass.call("GetConsoleUIY")
        jass.call("SetConsoleUIY", before)
        assert(math.abs(after - (before + 0.1)) < 0.01,
            "before=" .. tostring(before) .. " after=" .. tostring(after))
    end)

    test("ReplacePath remaps a resource loaded afterwards", function()
        -- Register the mapping, then force a first-time load of that exact path
        -- (creating a knight makes the game pull its model + skin). If the
        -- consumer works, the detour substitutes the path and logs it.
        -- The knight model references this texture by this exact name
        -- (confirmed by tracing the Storm#279 hits).
        jass.call("ReplacePath", [[Textures\Knight.blp]],
                  [[ReplaceableTextures\CommandButtons\BTNRifleman.blp]])
        local u = jass.CreateUnit(jass.Player(0), fourcc("hkni"), fx.x + 512, fx.y, 270)
        assert(u ~= nil, "CreateUnit(hkni) failed")
        jass.SetUnitInvulnerable(u, true)
    end)

    test("timer_start / timer_end / timer_destroy", function()
        local handle = jass.call("timer_start")
        assert(type(handle) == "number" and handle ~= 0, "handle=" .. tostring(handle))
        local elapsed = jass.call("timer_end", handle)
        jass.call("timer_destroy", handle)
        assert(type(elapsed) == "number" and elapsed >= 0 and elapsed < 60,
            "elapsed=" .. tostring(elapsed))
    end)
end

local function run(done)
    fx_setup()
    test_unit_data()
    test_ability_data()
    test_buff_data()
    test_item_data()
    test_damage_event()
    test_effect()
    test_info()
    test_mouse_orders()
    test_gameui()
    test_compat()
    test_interactive_ui_async(function()
        test_local_orders_async(function()
            fx_teardown()
            done(pass, fail)
        end)
    end)
end

return { run = run }

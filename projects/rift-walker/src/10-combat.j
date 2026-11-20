globals
    integer rwTick = 0
    integer rwRun = 0
    integer rwRoom = 1
    boolean rwFighting = false
    unit rwHero = null
    integer rwCount = 0
    unit array rwEnemy
    boolean array rwActive
    integer array rwKind
    real rwMinX = 0.0
    real rwMaxX = 0.0
    real rwMinY = 0.0
    real rwMaxY = 0.0
    string rwLastDamage = ""
    integer rwAppliedQ = 0
    integer rwAppliedW = 0
    integer rwAppliedE = 0
    integer rwNativeHits = 0

    integer rwQReady = 0
    integer rwWReady = 0
    integer rwEReady = 0
    integer array rwMark
    integer array rwMarkUntil
    integer rwECount = 0
    integer rwEMax = 0
    // Optional map setting. Use the base range until a live W probe warrants the fallback.
    boolean rwWShortRange = false

    constant integer RW_COMBAT_SLOTS = 40
    constant integer RW_GATE_SLOTS = 8
    constant integer RW_Q_ABILITY = 'ArwQ'
    constant integer RW_W_ABILITY = 'ArwW'
    constant integer RW_E_ABILITY = 'ArwE'
    constant integer RW_Q_DELAY = 5
    constant integer RW_Q_CD = 90
    constant real RW_Q_LENGTH = 650.0
    constant real RW_Q_WIDTH_SQ = 8100.0
    constant real RW_E_RANGE_SQ = 230400.0
    constant real RW_W_STEP = 32.0
    constant real RW_W_CLEARANCE = 24.0
    constant integer RW_COMBAT_EFFECT_SLOTS = 40
    constant string RW_Q_TRAIL = "Abilities\\Spells\\Items\\AIlb\\AIlbSpecialArt.mdl"
    constant string RW_W_DEPART = "Abilities\\Spells\\NightElf\\Blink\\BlinkCaster.mdl"
    constant string RW_W_ARRIVE = "Abilities\\Spells\\NightElf\\Blink\\BlinkTarget.mdl"
    constant string RW_E_CHARGE = "Abilities\\Spells\\Items\\AIma\\AImaTarget.mdl"
    constant string RW_E_WAVE = "Abilities\\Spells\\Human\\DispelMagic\\DispelMagicTarget.mdl"
    constant string RW_E_HIT = "Abilities\\Spells\\Human\\SpellSteal\\SpellStealTarget.mdl"

    effect array rwCombatEffect
    integer array rwCombatEffectUntil
    integer rwCombatEffectNext = 1
    integer rwCombatFeedbackUntil = 0

    trigger rwCombatDamageTrigger = null
    trigger rwCombatSpellTrigger = null
    unit rwRegisteredHero = null
    unit array rwRegisteredEnemy
    rect array rwWGateBounds
    boolean array rwWGateClosed
    integer rwScriptDamageDepth = 0
    // Active script damage cast ID for synchronous observers. Pair with rwRun.
    integer rwDamageCast = 0
    integer rwCastSerial = 0
    boolean rwCombatTickBusy = false

    integer rwPendingAbility = 0
    integer rwPendingUntil = 0
    integer rwPendingRun = 0
    integer rwPendingRoom = 0
    unit rwPendingHero = null

    integer rwStageOne = 0
    integer rwStageTwo = 0
    integer rwMarkCap = 3
    integer rwMarkLife = 120
    real rwQDamage = 95.0
    integer rwWCd = 100
    integer rwWRetry = 0
    real rwWMax = 360.0
    real rwWShortMax = 240.0
    integer rwEDelay = 7
    integer rwECd = 160
    real rwEPerLayer = 45.0
    real rwEchoRangeSq = 40000.0
    real rwEchoDamage = 55.0

    integer rwQDue = 0
    integer rwQRun = 0
    integer rwQRoom = 0
    integer rwQCast = 0
    unit rwQHero = null
    real rwQX = 0.0
    real rwQY = 0.0
    real rwQDX = 0.0
    real rwQDY = 0.0
    real rwQHitDamage = 0.0
    integer rwQMarkCap = 0
    integer rwQMarkLife = 0

    integer rwEDue = 0
    integer rwERun = 0
    integer rwERoom = 0
    integer rwECast = 0
    unit rwEHero = null
    real rwEHitPerLayer = 0.0
    real rwEHitEchoRangeSq = 0.0
    real rwEHitEchoDamage = 0.0

    unit array rwHitUnit
    real array rwHitX
    real array rwHitY
    integer array rwHitLayers
    boolean array rwHitEcho
endglobals

function RWAlive takes unit whichUnit returns boolean
    return whichUnit != null and GetUnitTypeId(whichUnit) != 0 and not IsUnitType(whichUnit, UNIT_TYPE_DEAD) and GetWidgetLife(whichUnit) > 0.405
endfunction

// Classic has no native invulnerability query. Use the standard 'Avul' ability
// for gameplay invulnerability so damage, mark expiry and E eligibility agree.
function RWCombatInvulnerable takes unit whichUnit returns boolean
    return GetUnitAbilityLevel(whichUnit, 'Avul') > 0
endfunction

function RWCombatPhase takes integer runId, integer roomId, unit hero returns boolean
    return runId == rwRun and roomId == rwRoom and hero == rwHero and rwFighting and RWAlive(hero)
endfunction

function RWCombatEnemyIndex takes unit whichUnit returns integer
    local integer i = 1
    if whichUnit == null then
        return 0
    endif
    loop
        exitwhen i > rwCount or i > RW_COMBAT_SLOTS
        if rwEnemy[i] == whichUnit and rwRegisteredEnemy[i] == whichUnit then
            return i
        endif
        set i = i + 1
    endloop
    return 0
endfunction

function RWCombatTarget takes integer i returns boolean
    return rwActive[i] and rwEnemy[i] == rwRegisteredEnemy[i] and RWAlive(rwEnemy[i]) and not RWCombatInvulnerable(rwEnemy[i]) and IsUnitEnemy(rwEnemy[i], GetOwningPlayer(rwHero))
endfunction

function RWCombatClearMark takes integer i returns nothing
    set rwMark[i] = 0
    set rwMarkUntil[i] = 0
endfunction

function RWCombatLayers takes integer i returns integer
    if rwMarkUntil[i] > rwTick and RWCombatTarget(i) then
        return rwMark[i]
    endif
    return 0
endfunction

function RWCombatAddMark takes integer i, integer amount, integer cap, integer lifetime returns nothing
    local integer layers = RWCombatLayers(i) + amount
    if layers > cap then
        set layers = cap
    endif
    set rwMark[i] = layers
    set rwMarkUntil[i] = rwTick + lifetime
endfunction

function RWCombatEnemyLabel takes integer i returns string
    if rwKind[i] == 1 then
        return "Squire attack"
    elseif rwKind[i] == 2 then
        return "Needler attack"
    elseif rwKind[i] == 3 then
        return "Warden attack"
    elseif rwKind[i] == 4 then
        return "Mender attack"
    elseif rwKind[i] == 5 then
        return "Boss attack"
    endif
    return "Enemy attack"
endfunction

function RWCombatOnDamage takes nothing returns nothing
    local unit target = GetTriggerUnit()
    local unit source = null
    local integer i = RWCombatEnemyIndex(target)
    local real amount
    if GetTriggerEventId() == EVENT_UNIT_DEATH then
        if i != 0 then
            call RWCombatClearMark(i)
        endif
    elseif rwScriptDamageDepth == 0 and rwFighting and RWAlive(rwHero) then
        set amount = GetEventDamage()
        if amount > 0.0 then
            set source = GetEventDamageSource()
            if source == rwHero and i != 0 and RWCombatTarget(i) then
                // With the specified object data, a positive unsuppressed hero hit is native.
                set rwNativeHits = rwNativeHits + 1
                if GetWidgetLife(target) - amount > 0.405 then
                    call RWCombatAddMark(i, 1, rwMarkCap, rwMarkLife)
                else
                    call RWCombatClearMark(i)
                endif
            elseif target == rwHero and not RWCombatInvulnerable(target) then
                set i = RWCombatEnemyIndex(source)
                if i != 0 and rwActive[i] and IsUnitEnemy(source, GetOwningPlayer(target)) then
                    set rwLastDamage = RWCombatEnemyLabel(i)
                endif
            endif
        endif
    endif
    set source = null
    set target = null
endfunction

// Reset owns the trigger. Call this after assigning a new hero if it is created
// after reset and must receive damage before the first combat tick.
function RWRegisterHero takes nothing returns nothing
    if rwCombatDamageTrigger != null and RWAlive(rwHero) and rwRegisteredHero != rwHero then
        set rwRegisteredHero = rwHero
        call TriggerRegisterUnitEvent(rwCombatDamageTrigger, rwHero, EVENT_UNIT_DAMAGED)
    endif
endfunction

function RWRegisterEnemy takes integer index returns nothing
    if rwCombatDamageTrigger == null or index < 1 or index > rwCount or index > RW_COMBAT_SLOTS or not RWAlive(rwEnemy[index]) then
        return
    endif
    // A unit and its stable slot each have exactly one registration per run.
    if rwRegisteredEnemy[index] != null or RWCombatEnemyIndex(rwEnemy[index]) != 0 then
        return
    endif
    set rwRegisteredEnemy[index] = rwEnemy[index]
    call TriggerRegisterUnitEvent(rwCombatDamageTrigger, rwEnemy[index], EVENT_UNIT_DAMAGED)
    call TriggerRegisterUnitEvent(rwCombatDamageTrigger, rwEnemy[index], EVENT_UNIT_DEATH)
    call RWRegisterHero()
endfunction

function RWCombatNextCast takes nothing returns integer
    set rwCastSerial = rwCastSerial + 1
    return rwCastSerial
endfunction

function RWCombatDamage takes integer runId, integer roomId, integer castId, unit source, unit target, real amount, string sourceLabel returns boolean
    local integer i
    local integer prevCast = rwDamageCast
    local string prevLabel = rwLastDamage
    local boolean applied
    if not RWCombatPhase(runId, roomId, rwHero) or not RWAlive(source) or not RWAlive(target) or not (amount > 0.0) or RWCombatInvulnerable(target) then
        return false
    endif
    if source == rwHero then
        set i = RWCombatEnemyIndex(target)
        if i == 0 or not RWCombatTarget(i) then
            return false
        endif
    else
        set i = RWCombatEnemyIndex(source)
        if target != rwHero or i == 0 or not rwActive[i] or not IsUnitEnemy(source, GetOwningPlayer(target)) then
            return false
        endif
        // Set before the native so a synchronous hero death observer has the label.
        set rwLastDamage = sourceLabel
    endif
    set rwDamageCast = castId
    set rwScriptDamageDepth = rwScriptDamageDepth + 1
    set applied = UnitDamageTarget(source, target, amount, false, false, ATTACK_TYPE_CHAOS, DAMAGE_TYPE_UNIVERSAL, WEAPON_TYPE_WHOKNOWS)
    set rwScriptDamageDepth = rwScriptDamageDepth - 1
    if rwRun == runId then
        set rwDamageCast = prevCast
        if not applied and target == rwHero and rwLastDamage == sourceLabel then
            set rwLastDamage = prevLabel
        endif
    endif
    return applied
endfunction

// One call per intended enemy special hit. The scheduler owns special-hit deduplication.
function RWDamage takes unit source, unit target, real amount, string sourceLabel returns nothing
    call RWCombatDamage(rwRun, rwRoom, RWCombatNextCast(), source, target, amount, sourceLabel)
endfunction

function RWCombatDistSq takes real ax, real ay, real bx, real by returns real
    local real dx = ax - bx
    local real dy = ay - by
    return dx*dx + dy*dy
endfunction

function RWCombatMeasureE takes nothing returns nothing
    local integer i = 1
    local integer layers
    local real x
    local real y
    set rwECount = 0
    set rwEMax = 0
    if not rwFighting or not RWAlive(rwHero) then
        return
    endif
    set x = GetUnitX(rwHero)
    set y = GetUnitY(rwHero)
    loop
        exitwhen i > rwCount or i > RW_COMBAT_SLOTS
        set layers = RWCombatLayers(i)
        if layers > 0 and RWCombatDistSq(x, y, GetUnitX(rwEnemy[i]), GetUnitY(rwEnemy[i])) <= RW_E_RANGE_SQ then
            set rwECount = rwECount + 1
            if layers > rwEMax then
                set rwEMax = layers
            endif
        endif
        set i = i + 1
    endloop
endfunction

function RWCombatClearHits takes integer count returns nothing
    local integer i = 1
    loop
        exitwhen i > count
        set rwHitUnit[i] = null
        set rwHitX[i] = 0.0
        set rwHitY[i] = 0.0
        set rwHitLayers[i] = 0
        set rwHitEcho[i] = false
        set i = i + 1
    endloop
endfunction

function RWCombatReleaseEffect takes integer slot returns nothing
    if rwCombatEffect[slot] != null then
        call DestroyEffect(rwCombatEffect[slot])
        set rwCombatEffect[slot] = null
    endif
endfunction

function RWCombatUpdateEffects takes boolean clear returns nothing
    local integer slot = 1
    loop
        exitwhen slot > RW_COMBAT_EFFECT_SLOTS
        if clear or rwCombatEffectUntil[slot] <= rwTick then
            call RWCombatReleaseEffect(slot)
        endif
        set slot = slot + 1
    endloop
endfunction

function RWCombatTrackEffect takes effect visual, integer duration returns nothing
    local integer slot = rwCombatEffectNext
    call RWCombatReleaseEffect(slot)
    set rwCombatEffect[slot] = visual
    set rwCombatEffectUntil[slot] = rwTick + duration
    set rwCombatEffectNext = ModuloInteger(slot, RW_COMBAT_EFFECT_SLOTS) + 1
endfunction

function RWCombatFeedback takes string text returns nothing
    if rwTick >= rwCombatFeedbackUntil then
        set rwCombatFeedbackUntil = rwTick + 10
        call DisplayTimedTextToPlayer(GetOwningPlayer(rwHero), 0.0, 0.0, 2.0, text)
    endif
endfunction

function RWCombatDrawSlash takes nothing returns nothing
    local real distance = 110.0
    loop
        call RWCombatTrackEffect(AddSpecialEffect(RW_Q_TRAIL, rwQX + distance * rwQDX, rwQY + distance * rwQDY), 12)
        exitwhen distance >= RW_Q_LENGTH
        set distance = RMinBJ(RW_Q_LENGTH, distance + 108.0)
    endloop
endfunction

function RWCombatResolveQ takes nothing returns nothing
    local integer runId = rwQRun
    local integer roomId = rwQRoom
    local integer castId = rwQCast
    local unit hero = rwQHero
    local unit target = null
    local integer count = IMinBJ(rwCount, RW_COMBAT_SLOTS)
    local integer cap = rwQMarkCap
    local integer lifetime = rwQMarkLife
    local real damage = rwQHitDamage
    local integer i = 1
    local real x
    local real y
    local real along
    local boolean applied = false
    set rwQDue = 0
    set rwQHero = null
    if RWCombatPhase(runId, roomId, hero) then
        call RWCombatDrawSlash()
        loop
            exitwhen i > count
            if RWCombatTarget(i) then
                set x = GetUnitX(rwEnemy[i]) - rwQX
                set y = GetUnitY(rwEnemy[i]) - rwQY
                set along = RMaxBJ(0.0, RMinBJ(RW_Q_LENGTH, x*rwQDX + y*rwQDY))
                if RWCombatDistSq(x, y, along*rwQDX, along*rwQDY) <= RW_Q_WIDTH_SQ then
                    set rwHitUnit[i] = rwEnemy[i]
                endif
            endif
            set i = i + 1
        endloop
        set i = 1
        loop
            exitwhen i > count or not RWCombatPhase(runId, roomId, hero)
            set target = rwHitUnit[i]
            if target != null and target == rwEnemy[i] and RWCombatDamage(runId, roomId, castId, hero, target, damage, "Q") then
                set applied = true
                if RWCombatPhase(runId, roomId, hero) and target == rwEnemy[i] and RWCombatTarget(i) then
                    call RWCombatAddMark(i, 2, cap, lifetime)
                endif
            endif
            set i = i + 1
        endloop
        if applied and rwRun == runId then
            set rwAppliedQ = rwAppliedQ + 1
        elseif rwRun == runId then
            call RWCombatFeedback("Rift Slash: no target hit.")
        endif
        call RWCombatClearHits(count)
    endif
    set target = null
    set hero = null
endfunction

function RWCombatResolveE takes nothing returns nothing
    local integer runId = rwERun
    local integer roomId = rwERoom
    local integer castId = rwECast
    local unit hero = rwEHero
    local unit target = null
    local integer count = IMinBJ(rwCount, RW_COMBAT_SLOTS)
    local real perLayer = rwEHitPerLayer
    local real echoRangeSq = rwEHitEchoRangeSq
    local real echoDamage = rwEHitEchoDamage
    local integer i = 1
    local integer j
    local real x
    local real y
    local boolean consumed = false
    set rwEDue = 0
    set rwEHero = null
    if RWCombatPhase(runId, roomId, hero) then
        set x = GetUnitX(hero)
        set y = GetUnitY(hero)
        // Freeze positions and identity for all eligible enemies, including echo-only targets.
        loop
            exitwhen i > count
            if RWCombatTarget(i) then
                set rwHitUnit[i] = rwEnemy[i]
                set rwHitX[i] = GetUnitX(rwEnemy[i])
                set rwHitY[i] = GetUnitY(rwEnemy[i])
                if RWCombatDistSq(x, y, rwHitX[i], rwHitY[i]) <= RW_E_RANGE_SQ then
                    set rwHitLayers[i] = RWCombatLayers(i)
                endif
            endif
            set i = i + 1
        endloop
        set i = 1
        loop
            exitwhen i > count
            if rwHitLayers[i] > 0 then
                call RWCombatClearMark(i)
                set consumed = true
                set j = 1
                loop
                    exitwhen j > count
                    if j != i and rwHitUnit[j] != null and RWCombatDistSq(rwHitX[i], rwHitY[i], rwHitX[j], rwHitY[j]) <= echoRangeSq then
                        set rwHitEcho[j] = true
                    endif
                    set j = j + 1
                endloop
            endif
            set i = i + 1
        endloop
        call RWCombatTrackEffect(AddSpecialEffect(RW_E_WAVE, x, y), 16)
        if consumed then
            set rwAppliedE = rwAppliedE + 1
        else
            call RWCombatFeedback("Convergence: no marked targets remained in range.")
        endif
        set i = 1
        loop
            exitwhen i > count or not RWCombatPhase(runId, roomId, hero)
            set target = rwHitUnit[i]
            if target != null and target == rwEnemy[i] then
                if rwHitLayers[i] > 0 or rwHitEcho[i] then
                    call RWCombatTrackEffect(AddSpecialEffect(RW_E_HIT, rwHitX[i], rwHitY[i]), 16)
                endif
                if rwHitLayers[i] > 0 then
                    call RWCombatDamage(runId, roomId, castId, hero, target, 90.0 + perLayer*I2R(rwHitLayers[i]), "E")
                endif
                if rwHitEcho[i] and target == rwEnemy[i] then
                    call RWCombatDamage(runId, roomId, castId, hero, target, echoDamage, "E echo")
                endif
            endif
            set i = i + 1
        endloop
        call RWCombatClearHits(count)
    endif
    set target = null
    set hero = null
endfunction

// Supply room-owned footprints for closed gates and other explicit blockers.
// Bounds are borrowed until reset, replacement, or RWSetWGate(slot, null, false).
function RWSetWGate takes integer slot, rect bounds, boolean closed returns nothing
    if slot >= 1 and slot <= RW_GATE_SLOTS then
        set rwWGateBounds[slot] = bounds
        set rwWGateClosed[slot] = closed and bounds != null
    endif
endfunction

function RWCombatPlayable takes real x, real y returns boolean
    return bj_mapInitialPlayableArea != null and x >= GetRectMinX(bj_mapInitialPlayableArea) and x <= GetRectMaxX(bj_mapInitialPlayableArea) and y >= GetRectMinY(bj_mapInitialPlayableArea) and y <= GetRectMaxY(bj_mapInitialPlayableArea)
endfunction

function RWCombatWalkSample takes real x, real y returns boolean
    return x >= rwMinX and x <= rwMaxX and y >= rwMinY and y <= rwMaxY and RWCombatPlayable(x, y) and not IsTerrainPathable(x, y, PATHING_TYPE_WALKABILITY)
endfunction

function RWCombatWClear takes group nearby, unit hero, real x, real y returns boolean
    local unit obstacle
    local boolean clear = true
    if not RWCombatWalkSample(x, y) or not RWCombatWalkSample(x + RW_W_CLEARANCE, y) or not RWCombatWalkSample(x - RW_W_CLEARANCE, y) or not RWCombatWalkSample(x, y + RW_W_CLEARANCE) or not RWCombatWalkSample(x, y - RW_W_CLEARANCE) then
        return false
    endif
    call GroupClear(nearby)
    call GroupEnumUnitsInRange(nearby, x, y, 256.0, null)
    loop
        set obstacle = FirstOfGroup(nearby)
        exitwhen obstacle == null or not clear
        call GroupRemoveUnit(nearby, obstacle)
        if obstacle != hero and RWAlive(obstacle) and not IsUnitHidden(obstacle) and not IsUnitType(obstacle, UNIT_TYPE_FLYING) then
            if RWCombatDistSq(x, y, GetUnitX(obstacle), GetUnitY(obstacle)) < 2304.0 or IsUnitInRangeXY(obstacle, x, y, RW_W_CLEARANCE) then
                set clear = false
            endif
        endif
    endloop
    set obstacle = null
    return clear
endfunction

function RWCombatWGateClear takes real ax, real ay, real bx, real by returns boolean
    local integer i = 1
    local rect bounds = null
    local real dx = bx - ax
    local real dy = by - ay
    local real halfX
    local real halfY
    local real offsetX
    local real offsetY
    local boolean clear = true
    loop
        exitwhen i > RW_GATE_SLOTS or not clear
        if rwWGateClosed[i] then
            set bounds = rwWGateBounds[i]
            set halfX = (GetRectMaxX(bounds) - GetRectMinX(bounds))*0.5 + RW_W_CLEARANCE
            set halfY = (GetRectMaxY(bounds) - GetRectMinY(bounds))*0.5 + RW_W_CLEARANCE
            set offsetX = (ax + bx)*0.5 - GetRectCenterX(bounds)
            set offsetY = (ay + by)*0.5 - GetRectCenterY(bounds)
            // Segment versus expanded gate rectangle, using the two axes and segment normal.
            if RAbsBJ(offsetX) <= halfX + RAbsBJ(dx)*0.5 and RAbsBJ(offsetY) <= halfY + RAbsBJ(dy)*0.5 and RAbsBJ(offsetX*dy - offsetY*dx) <= halfX*RAbsBJ(dy) + halfY*RAbsBJ(dx) then
                set clear = false
            endif
        endif
        set i = i + 1
    endloop
    set bounds = null
    return clear
endfunction

function RWCombatWRoute takes group nearby, unit hero, real ax, real ay, real bx, real by, real distance returns boolean
    local real step = RW_W_STEP
    local real dx = (bx - ax)/distance
    local real dy = (by - ay)/distance
    if not RWCombatWGateClear(ax, ay, bx, by) then
        return false
    endif
    loop
        exitwhen step >= distance
        if not RWCombatWClear(nearby, hero, ax + dx*step, ay + dy*step) then
            return false
        endif
        set step = step + RW_W_STEP
    endloop
    return RWCombatWClear(nearby, hero, bx, by)
endfunction

function RWCombatBlink takes unit hero, real dx, real dy, real distance returns boolean
    local integer runId = rwRun
    local integer roomId = rwRoom
    local real ax = GetUnitX(hero)
    local real ay = GetUnitY(hero)
    local real facing = GetUnitFacing(hero)
    local real minDistance = 128.0
    local real maxDistance = rwWMax
    local real wanted
    local real bx
    local real by
    local real actualX
    local real actualY
    local real actualSq
    local boolean found = false
    local boolean moved = false
    local group nearby = null
    if rwWShortRange then
        set minDistance = 96.0
        set maxDistance = rwWShortMax
    endif
    set wanted = RMinBJ(distance, maxDistance)
    // The hero's current point must belong to the same room as the entire route.
    if wanted < minDistance or not RWCombatWalkSample(ax, ay) then
        return false
    endif
    set nearby = CreateGroup()
    loop
        exitwhen wanted < minDistance or found
        set bx = ax + dx*wanted
        set by = ay + dy*wanted
        set found = RWCombatWRoute(nearby, hero, ax, ay, bx, by, wanted)
        set wanted = wanted - RW_W_STEP
    endloop
    if found and IssueImmediateOrder(hero, "stop") and RWCombatPhase(runId, roomId, hero) then
        call SetUnitPosition(hero, bx, by)
        if runId == rwRun and hero == rwHero and RWAlive(hero) then
            set actualX = GetUnitX(hero)
            set actualY = GetUnitY(hero)
            set actualSq = RWCombatDistSq(ax, ay, actualX, actualY)
            if RWCombatPhase(runId, roomId, hero) and actualSq >= minDistance*minDistance - 0.1 and actualSq <= maxDistance*maxDistance + 0.1 and RWCombatDistSq(bx, by, actualX, actualY) <= RW_W_STEP*RW_W_STEP then
                set moved = RWCombatWRoute(nearby, hero, ax, ay, actualX, actualY, SquareRoot(actualSq))
            endif
            if moved then
                call RWCombatTrackEffect(AddSpecialEffect(RW_W_DEPART, ax, ay), 14)
                call RWCombatTrackEffect(AddSpecialEffect(RW_W_ARRIVE, actualX, actualY), 14)
            else
                // Restore only the point this unit occupied before the attempted blink.
                call SetUnitX(hero, ax)
                call SetUnitY(hero, ay)
            endif
            call SetUnitFacing(hero, facing)
        endif
    endif
    call DestroyGroup(nearby)
    set nearby = null
    return moved
endfunction

function RWCombatClearPending takes nothing returns nothing
    set rwPendingAbility = 0
    set rwPendingUntil = 0
    set rwPendingHero = null
endfunction

function RWCombatReady takes integer abilityId returns boolean
    if abilityId == RW_Q_ABILITY then
        return rwQDue == 0 and rwTick >= rwQReady
    elseif abilityId == RW_W_ABILITY then
        return rwTick >= rwWReady and rwTick >= rwWRetry
    elseif abilityId == RW_E_ABILITY then
        return rwEDue == 0 and rwTick >= rwEReady
    endif
    return false
endfunction

// Channel object data: distinct base order IDs, Q/W point targets, E no target,
// zero native damage/mana/cooldown, and zero follow-through. Use Q/W then click.
function RWCombatOnSpell takes nothing returns nothing
    local unit caster = GetTriggerUnit()
    local eventid spellEvent = GetTriggerEventId()
    local integer abilityId = GetSpellAbilityId()
    local integer runId = rwRun
    local integer roomId = rwRoom
    local real x
    local real y
    local real dx
    local real dy
    local real distance = 0.0
    if rwPendingAbility != 0 and (rwTick >= rwPendingUntil or not RWCombatPhase(rwPendingRun, rwPendingRoom, rwPendingHero)) then
        call RWCombatClearPending()
    endif
    if caster == rwHero and caster != null and (abilityId == RW_Q_ABILITY or abilityId == RW_W_ABILITY or abilityId == RW_E_ABILITY) then
        if spellEvent == EVENT_PLAYER_UNIT_SPELL_CHANNEL then
            if rwPendingAbility == 0 and RWCombatPhase(runId, roomId, caster) and RWCombatReady(abilityId) and GetUnitAbilityLevel(caster, abilityId) > 0 then
                set rwPendingAbility = abilityId
                set rwPendingUntil = rwTick + 20
                set rwPendingRun = runId
                set rwPendingRoom = roomId
                set rwPendingHero = caster
            endif
        elseif spellEvent == EVENT_PLAYER_UNIT_SPELL_EFFECT and not RWCombatPhase(runId, roomId, caster) then
            call RWCombatFeedback("Skills unlock during an encounter.")
        elseif spellEvent == EVENT_PLAYER_UNIT_SPELL_EFFECT and not RWCombatReady(abilityId) then
            call RWCombatFeedback("Skill is on cooldown.")
        elseif rwPendingAbility == abilityId and rwPendingHero == caster then
            // Consume the request once, before callbacks or any gameplay result.
            call RWCombatClearPending()
            if spellEvent == EVENT_PLAYER_UNIT_SPELL_EFFECT and RWCombatPhase(runId, roomId, caster) and RWCombatReady(abilityId) and GetUnitAbilityLevel(caster, abilityId) > 0 then
                if abilityId == RW_E_ABILITY then
                    call RWCombatMeasureE()
                    if rwECount > 0 then
                        set rwECast = RWCombatNextCast()
                        set rwERun = runId
                        set rwERoom = roomId
                        set rwEHero = caster
                        set rwEHitPerLayer = rwEPerLayer
                        set rwEHitEchoRangeSq = rwEchoRangeSq
                        set rwEHitEchoDamage = rwEchoDamage
                        set rwEDue = rwTick + rwEDelay
                        set rwEReady = rwTick + rwECd
                        call RWCombatTrackEffect(AddSpecialEffectTarget(RW_E_CHARGE, caster, "origin"), rwEDelay)
                    else
                        call RWCombatFeedback("Convergence: mark an enemy within range first.")
                    endif
                else
                    set x = GetSpellTargetX()
                    set y = GetSpellTargetY()
                    set dx = x - GetUnitX(caster)
                    set dy = y - GetUnitY(caster)
                    if GetSpellTargetUnit() == null and GetSpellTargetItem() == null and GetSpellTargetDestructable() == null and RWCombatPlayable(x, y) then
                        set distance = SquareRoot(dx*dx + dy*dy)
                    endif
                    if abilityId == RW_Q_ABILITY then
                        if distance > 0.0 then
                            set rwQCast = RWCombatNextCast()
                            set rwQRun = runId
                            set rwQRoom = roomId
                            set rwQHero = caster
                            set rwQX = GetUnitX(caster)
                            set rwQY = GetUnitY(caster)
                            set rwQDX = dx/distance
                            set rwQDY = dy/distance
                            set rwQHitDamage = rwQDamage
                            set rwQMarkCap = rwMarkCap
                            set rwQMarkLife = rwMarkLife
                            set rwQDue = rwTick + RW_Q_DELAY
                            set rwQReady = rwTick + RW_Q_CD
                        else
                            call RWCombatFeedback("Rift Slash: select a point away from Eli.")
                        endif
                    else
                        call RWCombatNextCast()
                        // Gate reentrant order callbacks too. Success starts the cooldown.
                        set rwWRetry = rwTick + 5
                        if distance > 0.0 and RWCombatBlink(caster, dx/distance, dy/distance, distance) and RWCombatPhase(runId, roomId, caster) then
                            set rwWReady = rwTick + rwWCd
                            set rwAppliedW = rwAppliedW + 1
                        else
                            call RWCombatFeedback("Slipstep: no clear landing in that direction.")
                        endif
                    endif
                endif
            endif
        endif
    endif
    set caster = null
    set spellEvent = null
endfunction

function RWCombatReset takes nothing returns nothing
    local integer i = 1
    if rwCombatDamageTrigger != null then
        call DestroyTrigger(rwCombatDamageTrigger)
    endif
    set rwCombatDamageTrigger = CreateTrigger()
    call TriggerAddAction(rwCombatDamageTrigger, function RWCombatOnDamage)
    set rwRegisteredHero = null
    call RWCombatUpdateEffects(true)
    set rwCombatEffectNext = 1
    set rwCombatFeedbackUntil = 0
    call RWCombatClearPending()
    set rwQDue = 0
    set rwEDue = 0
    set rwQHero = null
    set rwEHero = null
    set rwCount = 0
    set rwLastDamage = ""
    set rwAppliedQ = 0
    set rwAppliedW = 0
    set rwAppliedE = 0
    set rwNativeHits = 0
    set rwECount = 0
    set rwEMax = 0
    set rwCastSerial = 0
    set rwDamageCast = 0
    set rwStageOne = 0
    set rwStageTwo = 0
    set rwQReady = 0
    set rwWReady = 0
    set rwEReady = 0
    set rwWRetry = 0
    set rwMarkCap = 3
    set rwMarkLife = 120
    set rwQDamage = 95.0
    set rwWCd = 100
    set rwWMax = 360.0
    set rwWShortMax = 240.0
    set rwEDelay = 7
    set rwECd = 160
    set rwEPerLayer = 45.0
    set rwEchoRangeSq = 40000.0
    set rwEchoDamage = 55.0
    loop
        exitwhen i > RW_COMBAT_SLOTS
        set rwEnemy[i] = null
        set rwRegisteredEnemy[i] = null
        set rwActive[i] = false
        set rwKind[i] = 0
        call RWCombatClearMark(i)
        set i = i + 1
    endloop
    call RWCombatClearHits(RW_COMBAT_SLOTS)
    set i = 1
    loop
        exitwhen i > RW_GATE_SLOTS
        call RWSetWGate(i, null, false)
        set i = i + 1
    endloop
endfunction

function RWCombatInit takes nothing returns nothing
    local integer i = 0
    if rwCombatSpellTrigger == null then
        set rwCombatSpellTrigger = CreateTrigger()
        loop
            exitwhen i >= bj_MAX_PLAYER_SLOTS
            call TriggerRegisterPlayerUnitEvent(rwCombatSpellTrigger, Player(i), EVENT_PLAYER_UNIT_SPELL_CHANNEL, null)
            call TriggerRegisterPlayerUnitEvent(rwCombatSpellTrigger, Player(i), EVENT_PLAYER_UNIT_SPELL_EFFECT, null)
            call TriggerRegisterPlayerUnitEvent(rwCombatSpellTrigger, Player(i), EVENT_PLAYER_UNIT_SPELL_ENDCAST, null)
            set i = i + 1
        endloop
        call TriggerAddAction(rwCombatSpellTrigger, function RWCombatOnSpell)
    endif
endfunction

// The run advances rwTick before calling. Resolve equal-tick effects in confirmation order.
function RWCombatTick takes nothing returns nothing
    local integer runId = rwRun
    local integer i = 1
    if rwCombatTickBusy then
        return
    endif
    set rwCombatTickBusy = true
    call RWCombatUpdateEffects(not RWAlive(rwHero))
    call RWRegisterHero()
    if rwPendingAbility != 0 and (rwTick >= rwPendingUntil or not RWCombatPhase(rwPendingRun, rwPendingRoom, rwPendingHero)) then
        call RWCombatClearPending()
    endif
    if rwQDue != 0 and not RWCombatPhase(rwQRun, rwQRoom, rwQHero) then
        set rwQDue = 0
        set rwQHero = null
    endif
    if rwEDue != 0 and not RWCombatPhase(rwERun, rwERoom, rwEHero) then
        set rwEDue = 0
        set rwEHero = null
    endif
    loop
        exitwhen i > rwCount or i > RW_COMBAT_SLOTS
        if rwMark[i] != 0 and (not rwFighting or not RWAlive(rwHero) or RWCombatLayers(i) == 0) then
            call RWCombatClearMark(i)
        endif
        set i = i + 1
    endloop
    if rwQDue != 0 and rwQDue <= rwTick and rwEDue != 0 and rwEDue <= rwTick and (rwEDue < rwQDue or (rwEDue == rwQDue and rwECast < rwQCast)) then
        call RWCombatResolveE()
    endif
    if rwRun == runId and rwQDue != 0 and rwQDue <= rwTick then
        call RWCombatResolveQ()
    endif
    if rwRun == runId and rwEDue != 0 and rwEDue <= rwTick then
        call RWCombatResolveE()
    endif
    call RWCombatMeasureE()
    set rwCombatTickBusy = false
endfunction

// Call from the appropriate safe choice phase. Room code owns the phase and heal.
function RWUpgrade takes integer stage, integer choice returns nothing
    if rwFighting or not RWAlive(rwHero) or (choice != 1 and choice != 2) then
        return
    endif
    if stage == 1 and rwStageOne == 0 then
        set rwStageOne = choice
        if choice == 1 then
            set rwMarkCap = 4
            set rwMarkLife = 90
        else
            set rwWMax = 420.0
            set rwWShortMax = 280.0
            set rwWCd = 80
            set rwQDamage = 75.0
        endif
    elseif stage == 2 and rwStageOne != 0 and rwStageTwo == 0 then
        set rwStageTwo = choice
        if choice == 1 then
            set rwEchoRangeSq = 67600.0
            set rwEchoDamage = 75.0
            set rwECd = 200
        else
            set rwECd = 120
            set rwEDelay = 4
            set rwEPerLayer = 30.0
        endif
    endif
endfunction

// Compatibility entry for 4 Hz presentation. Presentation owns visual tags.
function RWRefreshMarks takes nothing returns nothing
    call RWCombatMeasureE()
endfunction

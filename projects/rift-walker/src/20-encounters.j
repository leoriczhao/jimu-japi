globals
    integer rwChoiceStage = 0
    integer rwChoiceOne = 0
    integer rwChoiceTwo = 0
    integer rwBossPhase = 0
    unit rwBoss = null
    integer rwObjectiveRemaining = 0
    boolean rwWinner = false
    string rwThreat = ""

    constant integer RW_WORLD_BOSS_ID = 33
    constant integer RW_WORLD_FAN_SLOT = 34
    constant integer RW_WORLD_GATE_SLOT = 37
    constant integer RW_WORLD_TAG_STRIDE = 24
    constant real RW_WORLD_PI = 3.141592653589793
    constant real RW_WORLD_DEG = 57.29577951308232
    integer rwWorldRun = -1
    boolean rwWorldFrozen = true
    unit array rwWorldOwned
    boolean array rwWorldGroupStarted
    integer array rwWorldGroupAlive
    integer array rwWorldEnemyGroup
    real array rwWorldHomeX
    real array rwWorldHomeY
    boolean array rwWorldReturning
    integer array rwWorldRemoveAt
    integer array rwWorldReadyAt
    integer array rwWorldRepositionAt
    integer array rwWorldCastAt
    integer array rwWorldHealTarget
    real array rwWorldCastX
    real array rwWorldCastY
    texttag array rwWorldTag
    integer array rwWorldTagCount

    integer rwWorldBossStartAt = -1
    integer rwWorldBossCycle = 0
    integer rwWorldBossNext = 1
    integer rwWorldBossAttack = 0
    integer rwWorldBossImpactAt = 0
    integer rwWorldBossRecoverAt = 0
    boolean rwWorldBossPhasePending = false
    real rwWorldBossX = 0.0
    real rwWorldBossY = 0.0
    real rwWorldBossDX = 0.0
    real rwWorldBossDY = 0.0
    integer rwWorldStarsPlaced = 0
    integer rwWorldStarsLanded = 0
    integer rwWorldStarNextAt = 0
    integer array rwWorldStarHitAt
    real array rwWorldStarX
    real array rwWorldStarY

    // Recent actual starts for acceptance checks. Sequence numbers start at zero.
    integer rwWorldBossLogCount = 0
    integer array rwWorldBossLogPhase
    integer array rwWorldBossLogMove
    integer array rwWorldBossLogTick
endglobals

function RWWorldDistance2 takes real x, real y, real tx, real ty returns real
    local real dx = x - tx
    local real dy = y - ty
    return dx * dx + dy * dy
endfunction

function RWWorldCenter takes integer room returns real
    return I2R(room - 2) * 2200.0
endfunction

function RWWorldClearMarks takes integer slot returns nothing
    local integer count = rwWorldTagCount[slot]
    local integer index
    loop
        exitwhen count == 0
        set index = slot * RW_WORLD_TAG_STRIDE + count
        call DestroyTextTag(rwWorldTag[index])
        set rwWorldTag[index] = null
        set count = count - 1
    endloop
    set rwWorldTagCount[slot] = 0
endfunction

// Native world-space text tags trace the hit geometry with discrete marks.
function RWWorldMark takes integer slot, real x, real y, string label, integer r, integer g, integer b returns nothing
    local texttag mark = CreateTextTag()
    local integer count = rwWorldTagCount[slot] + 1
    set rwWorldTagCount[slot] = count
    set rwWorldTag[slot * RW_WORLD_TAG_STRIDE + count] = mark
    call SetTextTagText(mark, label, 0.021)
    call SetTextTagPos(mark, x, y, 12.0)
    call SetTextTagColor(mark, r, g, b, 255)
    call SetTextTagPermanent(mark, true)
    call SetTextTagVisibility(mark, true)
    set mark = null
endfunction

function RWWorldRing takes integer slot, real x, real y, real radius, integer points, integer r, integer g, integer b returns nothing
    local integer i = 0
    local real angle
    loop
        exitwhen i == points
        set angle = 2.0 * RW_WORLD_PI * I2R(i) / I2R(points)
        call RWWorldMark(slot, x + radius * Cos(angle), y + radius * Sin(angle), "o", r, g, b)
        set i = i + 1
    endloop
endfunction

function RWWorldShowGate takes nothing returns nothing
    local real x = RWWorldCenter(rwRoom) + 760.0
    call RWWorldClearMarks(RW_WORLD_GATE_SLOT)
    if rwRoom < 3 then
        call RWWorldMark(RW_WORLD_GATE_SLOT, x, -175.0, "|", 237, 196, 126)
        call RWWorldMark(RW_WORLD_GATE_SLOT, x, -88.0, "|", 237, 196, 126)
        call RWWorldMark(RW_WORLD_GATE_SLOT, x, 0.0, "SEALED", 237, 196, 126)
        call RWWorldMark(RW_WORLD_GATE_SLOT, x, 88.0, "|", 237, 196, 126)
        call RWWorldMark(RW_WORLD_GATE_SLOT, x, 175.0, "|", 237, 196, 126)
    endif
endfunction

function RWWorldSetRoom takes integer room returns nothing
    local real center = RWWorldCenter(room)
    set rwRoom = room
    set rwFighting = false
    set rwMinX = center - 900.0
    set rwMaxX = center + 900.0
    set rwMinY = -780.0
    set rwMaxY = 780.0
    if room == 1 then
        set rwObjectiveRemaining = 12
    elseif room == 2 then
        set rwObjectiveRemaining = 17
    else
        set rwObjectiveRemaining = 3
    endif
    if room < 3 then
        // The combat module must reject W past the sealed exit as well.
        set rwMaxX = center + 760.0
    endif
    call RWWorldShowGate()
endfunction

function RWWorldClosed takes nothing returns boolean
    return (rwRoom == 1 and rwChoiceOne == 0) or (rwRoom == 2 and rwChoiceTwo == 0)
endfunction

function RWWorldKeepHeroInBounds takes nothing returns nothing
    local real x = GetUnitX(rwHero)
    if RWWorldClosed() and x > rwMaxX then
        call SetUnitX(rwHero, rwMaxX - 24.0)
        call IssueImmediateOrder(rwHero, "stop")
    elseif (rwFighting or rwWorldBossStartAt >= 0) and x < rwMinX then
        call SetUnitX(rwHero, rwMinX + 24.0)
        call IssueImmediateOrder(rwHero, "stop")
    endif
endfunction

function RWWorldSpawn takes integer id, integer kind, integer groupId, real x, real y returns nothing
    local integer raw = 'urw1'
    local unit enemy
    if kind == 2 then
        set raw = 'urw2'
    elseif kind == 3 then
        set raw = 'urw3'
    elseif kind == 4 then
        set raw = 'urw4'
    elseif kind == 5 then
        set raw = 'urw5'
    endif
    set enemy = CreateUnit(Player(PLAYER_NEUTRAL_AGGRESSIVE), raw, RWWorldCenter(rwRoom) + x, y, 180.0)
    set rwWorldOwned[id] = enemy
    set rwEnemy[id] = enemy
    set rwKind[id] = kind
    set rwWorldEnemyGroup[id] = groupId
    set rwWorldGroupAlive[groupId] = rwWorldGroupAlive[groupId] + 1
    set rwWorldHomeX[id] = GetUnitX(enemy)
    set rwWorldHomeY[id] = GetUnitY(enemy)
    set rwWorldRepositionAt[id] = rwTick
    if kind == 3 then
        set rwWorldReadyAt[id] = rwTick + 140
    elseif kind == 4 then
        set rwWorldReadyAt[id] = rwTick + 80
    endif
    set rwActive[id] = true
    if id > rwCount then
        set rwCount = id
    endif
    call SetUnitCreepGuard(enemy, false)
    call RemoveGuardPosition(enemy)
    call SetUnitAcquireRange(enemy, 0.0)
    call RWRegisterEnemy(id)
    set enemy = null
endfunction

function RWWorldStartGroup takes integer groupId returns nothing
    set rwWorldGroupStarted[groupId] = true
    set rwFighting = true
    if groupId == 1 then
        call RWWorldSpawn(1, 1, groupId, -220.0, 0.0)
        call RWWorldSpawn(2, 1, groupId, -300.0, 155.0)
        call RWWorldSpawn(3, 1, groupId, -245.0, -155.0)
    elseif groupId == 2 then
        call RWWorldSpawn(4, 1, groupId, 220.0, 0.0)
        call RWWorldSpawn(5, 1, groupId, 155.0, 200.0)
        call RWWorldSpawn(6, 1, groupId, 170.0, -215.0)
        call RWWorldSpawn(7, 1, groupId, 280.0, -70.0)
        call RWWorldSpawn(8, 2, groupId, 370.0, 345.0)
        call RWWorldSpawn(9, 2, groupId, 460.0, -345.0)
    elseif groupId == 3 then
        call RWWorldSpawn(10, 1, groupId, 575.0, 255.0)
        call RWWorldSpawn(11, 1, groupId, 590.0, -135.0)
        call RWWorldSpawn(12, 3, groupId, 620.0, 65.0)
    elseif groupId == 4 then
        call RWWorldSpawn(13, 1, groupId, -420.0, 0.0)
        call RWWorldSpawn(14, 1, groupId, -435.0, 180.0)
        call RWWorldSpawn(15, 1, groupId, -435.0, -180.0)
        call RWWorldSpawn(16, 2, groupId, -300.0, 295.0)
        call RWWorldSpawn(17, 2, groupId, -300.0, -295.0)
    elseif groupId == 5 then
        call RWWorldSpawn(18, 1, groupId, -105.0, -395.0)
        call RWWorldSpawn(19, 1, groupId, 70.0, -585.0)
        call RWWorldSpawn(20, 3, groupId, 130.0, -400.0)
        call RWWorldSpawn(21, 4, groupId, 290.0, -540.0)
    elseif groupId == 6 then
        call RWWorldSpawn(22, 1, groupId, -105.0, 395.0)
        call RWWorldSpawn(23, 1, groupId, 70.0, 585.0)
        call RWWorldSpawn(24, 3, groupId, 130.0, 400.0)
        call RWWorldSpawn(25, 4, groupId, 290.0, 540.0)
    elseif groupId == 7 then
        call RWWorldSpawn(26, 3, groupId, 540.0, 200.0)
        call RWWorldSpawn(27, 3, groupId, 540.0, -200.0)
        call RWWorldSpawn(28, 2, groupId, 660.0, 310.0)
        call RWWorldSpawn(29, 4, groupId, 660.0, -310.0)
    elseif groupId == 8 then
        call RWWorldSpawn(30, 1, groupId, -230.0, 130.0)
        call RWWorldSpawn(31, 1, groupId, -230.0, -130.0)
        call RWWorldSpawn(32, 3, groupId, -90.0, 0.0)
    else
        call RWWorldSpawn(RW_WORLD_BOSS_ID, 5, groupId, 290.0, 260.0)
        set rwBoss = rwEnemy[RW_WORLD_BOSS_ID]
        call IssueTargetOrder(rwBoss, "attack", rwHero)
    endif
endfunction

function RWWorldGroupClear takes integer groupId returns boolean
    return rwWorldGroupStarted[groupId] and rwWorldGroupAlive[groupId] == 0
endfunction

function RWWorldHeal takes unit target, real amount returns nothing
    local real cap = GetUnitState(target, UNIT_STATE_MAX_LIFE)
    local real life = GetWidgetLife(target) + amount
    if life > cap then
        set life = cap
    endif
    call SetWidgetLife(target, life)
endfunction

function RWChoose takes integer choice returns nothing
    local integer stage = rwChoiceStage
    if (choice != 1 and choice != 2) or rwWorldFrozen or rwWorldRun != rwRun or rwFighting or not RWAlive(rwHero) then
        return
    endif
    if stage == 1 and rwRoom == 1 and rwChoiceOne == 0 then
        set rwChoiceOne = choice
    elseif stage == 2 and rwRoom == 2 and rwChoiceTwo == 0 then
        set rwChoiceTwo = choice
    else
        return
    endif
    set rwChoiceStage = 0
    call RWUpgrade(stage, choice)
    set rwMaxX = RWWorldCenter(rwRoom) + 900.0
    call RWWorldClearMarks(RW_WORLD_GATE_SLOT)
endfunction

function RWWorldAdvance takes nothing returns nothing
    local real x = GetUnitX(rwHero)
    local real y = GetUnitY(rwHero)
    if rwRoom < 3 and rwObjectiveRemaining == 0 then
        set rwFighting = false
        if RWWorldClosed() then
            if rwChoiceStage == 0 and x >= RWWorldCenter(rwRoom) + 620.0 and y >= -210.0 and y <= 210.0 then
                call IssueImmediateOrder(rwHero, "stop")
                call RWWorldHeal(rwHero, 180.0)
                set rwChoiceStage = rwRoom
            endif
        elseif x >= RWWorldCenter(rwRoom + 1) - 750.0 then
            call RWWorldSetRoom(rwRoom + 1)
        endif
    elseif rwRoom == 1 then
        if not rwWorldGroupStarted[1] and x >= -2720.0 then
            call RWWorldStartGroup(1)
        elseif not rwWorldGroupStarted[2] and RWWorldGroupClear(1) and x >= -2250.0 then
            call RWWorldStartGroup(2)
        elseif not rwWorldGroupStarted[3] and RWWorldGroupClear(2) and x >= -1790.0 then
            call RWWorldStartGroup(3)
        endif
    elseif rwRoom == 2 then
        if not rwWorldGroupStarted[4] and x >= -700.0 then
            call RWWorldStartGroup(4)
        elseif RWWorldGroupClear(4) then
            // Entering either passage, or approaching it from the east, can pull it.
            if not rwWorldGroupStarted[5] and x >= -335.0 and y <= -200.0 then
                call RWWorldStartGroup(5)
            endif
            if not rwWorldGroupStarted[6] and x >= -335.0 and y >= 200.0 then
                call RWWorldStartGroup(6)
            endif
            if not rwWorldGroupStarted[7] and x >= 360.0 then
                call RWWorldStartGroup(7)
            endif
        endif
    elseif not rwWorldGroupStarted[8] then
        if x >= 1675.0 then
            call RWWorldStartGroup(8)
        endif
    elseif RWWorldGroupClear(8) and not rwWorldGroupStarted[9] then
        set rwFighting = false
        if rwWorldBossStartAt < 0 then
            set rwWorldBossStartAt = rwTick + 160
        elseif rwTick >= rwWorldBossStartAt then
            set rwBossPhase = 1
            set rwWorldBossCycle = rwTick
            set rwObjectiveRemaining = 1
            call RWWorldStartGroup(9)
            call RWWorldKeepHeroInBounds()
        endif
    endif
endfunction

function RWWorldStopForCast takes unit enemy returns nothing
    call IssueImmediateOrder(enemy, "stop")
    call PauseUnit(enemy, true)
endfunction

function RWWorldCancelCast takes integer id returns nothing
    set rwWorldCastAt[id] = 0
    set rwWorldHealTarget[id] = 0
    call RWWorldClearMarks(id)
endfunction

function RWWorldSupportLink takes integer id, unit target returns nothing
    local real x = GetUnitX(rwEnemy[id])
    local real y = GetUnitY(rwEnemy[id])
    local real dx = GetUnitX(target) - x
    local real dy = GetUnitY(target) - y
    local integer index = id * RW_WORLD_TAG_STRIDE
    call SetTextTagPos(rwWorldTag[index + 1], x + 0.33 * dx, y + 0.33 * dy, 12.0)
    call SetTextTagPos(rwWorldTag[index + 2], x + 0.67 * dx, y + 0.67 * dy, 12.0)
endfunction

function RWWorldCastTick takes integer id returns nothing
    local integer targetId = rwWorldHealTarget[id]
    local unit enemy = rwEnemy[id]
    local unit target = rwEnemy[targetId]
    if targetId != 0 and (not rwActive[targetId] or not RWAlive(target)) then
        call RWWorldCancelCast(id)
        call PauseUnit(enemy, false)
    elseif rwTick < rwWorldCastAt[id] then
        if targetId != 0 then
            call RWWorldSupportLink(id, target)
        endif
    else
        call RWWorldCancelCast(id)
        call PauseUnit(enemy, false)
        if rwKind[id] == 3 then
            if RWAlive(rwHero) and RWWorldDistance2(rwWorldCastX[id], rwWorldCastY[id], GetUnitX(rwHero), GetUnitY(rwHero)) <= 32400.0 then
                call RWDamage(enemy, rwHero, 90.0, "Guard slam")
            endif
        elseif rwActive[targetId] and RWAlive(target) and RWWorldDistance2(GetUnitX(enemy), GetUnitY(enemy), GetUnitX(target), GetUnitY(target)) <= 122500.0 then
            call RWWorldHeal(target, 80.0)
        endif
    endif
    set enemy = null
    set target = null
endfunction

function RWWorldSupportTarget takes integer id, real x, real y returns integer
    local integer i = 1
    local integer best = 0
    local real life
    local real bestLife = 100000.0
    local unit ally
    loop
        exitwhen i == RW_WORLD_BOSS_ID
        if i != id and rwActive[i] and RWAlive(rwEnemy[i]) then
            set ally = rwEnemy[i]
            set life = GetWidgetLife(ally)
            if life < bestLife and life < GetUnitState(ally, UNIT_STATE_MAX_LIFE) and RWWorldDistance2(x, y, GetUnitX(ally), GetUnitY(ally)) <= 122500.0 then
                set bestLife = life
                set best = i
            endif
        endif
        set i = i + 1
    endloop
    set ally = null
    return best
endfunction

function RWWorldMoveAtRange takes integer id, real x, real y, real hx, real hy, real range returns boolean
    local real angle = Atan2(y - hy, x - hx)
    local real destX = hx + range * Cos(angle)
    local real destY = hy + range * Sin(angle)
    set rwWorldRepositionAt[id] = rwTick + 20
    if destX >= rwMinX + 32.0 and destX <= rwMaxX - 32.0 and destY >= rwMinY + 32.0 and destY <= rwMaxY - 32.0 and not IsTerrainPathable(destX, destY, PATHING_TYPE_WALKABILITY) then
        return IssuePointOrder(rwEnemy[id], "move", destX, destY)
    endif
    return false
endfunction

function RWWorldChase takes unit enemy returns nothing
    if GetUnitCurrentOrder(enemy) != OrderId("attack") then
        call IssueTargetOrder(enemy, "attack", rwHero)
    endif
endfunction

function RWWorldEnemyAI takes integer id, real hx, real hy returns nothing
    local unit enemy = rwEnemy[id]
    local integer kind = rwKind[id]
    local real x = GetUnitX(enemy)
    local real y = GetUnitY(enemy)
    local real distance2 = RWWorldDistance2(x, y, hx, hy)
    local integer targetId = 0
    local integer order = GetUnitCurrentOrder(enemy)
    local boolean moved = false
    local boolean wasReturning = rwWorldReturning[id]
    if x < rwMinX or x > rwMaxX or y < rwMinY or y > rwMaxY then
        set rwWorldReturning[id] = true
    elseif rwWorldReturning[id] and RWWorldDistance2(x, y, rwWorldHomeX[id], rwWorldHomeY[id]) <= 16384.0 then
        set rwWorldReturning[id] = false
    endif
    if rwWorldReturning[id] then
        if rwWorldCastAt[id] != 0 then
            call RWWorldCancelCast(id)
            call PauseUnit(enemy, false)
        endif
        if not wasReturning or order != OrderId("move") then
            call IssuePointOrder(enemy, "move", rwWorldHomeX[id], rwWorldHomeY[id])
        endif
    elseif rwWorldCastAt[id] == 0 then
        if kind == 4 then
            if rwTick >= rwWorldReadyAt[id] then
                set targetId = RWWorldSupportTarget(id, x, y)
            endif
            if targetId != 0 then
                call RWWorldStopForCast(enemy)
                set rwWorldHealTarget[id] = targetId
                set rwWorldCastAt[id] = rwTick + 24
                set rwWorldReadyAt[id] = rwTick + 160
                call RWWorldMark(id, x, y, "-", 210, 135, 255)
                call RWWorldMark(id, x, y, ">", 210, 135, 255)
                call RWWorldSupportLink(id, rwEnemy[targetId])
            elseif rwTick >= rwWorldRepositionAt[id] and (distance2 < 48400.0 or distance2 > 160000.0) then
                call RWWorldMoveAtRange(id, x, y, hx, hy, 310.0)
            endif
        elseif kind == 3 and rwTick >= rwWorldReadyAt[id] and distance2 <= 32400.0 then
            call RWWorldStopForCast(enemy)
            set rwWorldCastX[id] = x
            set rwWorldCastY[id] = y
            set rwWorldCastAt[id] = rwTick + 18
            set rwWorldReadyAt[id] = rwTick + 140
            call RWWorldRing(id, x, y, 180.0, 4, 255, 177, 70)
            call RWWorldMark(id, x, y, "SLAM", 255, 177, 70)
        elseif kind == 2 then
            // Keep native projectile and cooldown. Movement orders are at most 1 Hz.
            if rwTick >= rwWorldRepositionAt[id] and (distance2 < 115600.0 or distance2 > 250000.0) then
                set moved = RWWorldMoveAtRange(id, x, y, hx, hy, 420.0)
            endif
            if not moved and (order != OrderId("move") or rwTick >= rwWorldRepositionAt[id] or (distance2 >= 115600.0 and distance2 <= 250000.0)) then
                call RWWorldChase(enemy)
            endif
        else
            call RWWorldChase(enemy)
        endif
    endif
    set enemy = null
endfunction

function RWWorldBossOffset takes integer move returns integer
    if rwBossPhase == 1 then
        if move == 1 then
            return 60
        elseif move == 2 then
            return 160
        endif
        return 300
    endif
    if move == 1 then
        return 40
    elseif move == 2 then
        return 120
    endif
    return 240
endfunction

function RWWorldBossBegin takes integer move, integer due returns nothing
    local integer i = 0
    local integer logIndex = ModuloInteger(rwWorldBossLogCount, 64)
    local real angle
    local real edge
    set rwWorldBossLogPhase[logIndex] = rwBossPhase
    set rwWorldBossLogMove[logIndex] = move
    set rwWorldBossLogTick[logIndex] = rwTick
    set rwWorldBossLogCount = rwWorldBossLogCount + 1
    // Shift the remaining schedule when late so it cannot catch up by bunching moves.
    set rwWorldBossCycle = rwWorldBossCycle + rwTick - due
    set rwWorldBossNext = move + 1
    if move == 3 then
        set rwWorldBossNext = 1
        if rwBossPhase == 1 then
            set rwWorldBossCycle = rwWorldBossCycle + 400
        else
            set rwWorldBossCycle = rwWorldBossCycle + 320
        endif
    endif
    set rwWorldBossAttack = move
    set rwWorldBossX = GetUnitX(rwBoss)
    set rwWorldBossY = GetUnitY(rwBoss)
    if move == 1 then
        set angle = Atan2(GetUnitY(rwHero) - rwWorldBossY, GetUnitX(rwHero) - rwWorldBossX)
        set rwWorldBossDX = Cos(angle)
        set rwWorldBossDY = Sin(angle)
        call IssueImmediateOrder(rwBoss, "stop")
        call SetUnitFacing(rwBoss, angle * RW_WORLD_DEG)
        call PauseUnit(rwBoss, true)
        set rwWorldBossImpactAt = rwTick + 20
        if rwBossPhase == 2 then
            set rwWorldBossImpactAt = rwTick + 16
        endif
        loop
            exitwhen i > 6
            set edge = angle - RW_WORLD_PI / 4.0 + I2R(i) * RW_WORLD_PI / 12.0
            call RWWorldMark(RW_WORLD_FAN_SLOT, rwWorldBossX + 420.0 * Cos(edge), rwWorldBossY + 420.0 * Sin(edge), "x", 255, 86, 55)
            if i == 0 or i == 6 then
                call RWWorldMark(RW_WORLD_FAN_SLOT, rwWorldBossX + 210.0 * Cos(edge), rwWorldBossY + 210.0 * Sin(edge), "x", 255, 86, 55)
            endif
            set i = i + 1
        endloop
        call RWWorldMark(RW_WORLD_FAN_SLOT, rwWorldBossX + 235.0 * Cos(angle), rwWorldBossY + 235.0 * Sin(angle), "CLEAVE", 255, 86, 55)
    elseif move == 2 then
        call RWWorldStopForCast(rwBoss)
        set rwWorldStarsPlaced = 0
        set rwWorldStarsLanded = 0
        set rwWorldStarNextAt = rwTick
    else
        call RWWorldStopForCast(rwBoss)
        set rwWorldBossImpactAt = rwTick + 28
        if rwBossPhase == 2 then
            set rwWorldBossImpactAt = rwTick + 22
        endif
        call RWWorldRing(RW_WORLD_FAN_SLOT, rwWorldBossX, rwWorldBossY, 650.0, 12, 255, 122, 62)
        call RWWorldRing(RW_WORLD_FAN_SLOT, rwWorldBossX, rwWorldBossY, 220.0, 8, 255, 194, 85)
        call RWWorldMark(RW_WORLD_FAN_SLOT, rwWorldBossX, rwWorldBossY - 80.0, "INNER SAFE", 255, 216, 125)
    endif
endfunction

function RWWorldStarTick takes nothing returns nothing
    local integer i = 1
    local integer slot
    local integer interval = 12
    local integer delay = 20
    local real damage = 100.0
    if rwBossPhase == 2 then
        set interval = 10
        set delay = 17
        set damage = 110.0
    endif
    if rwWorldStarsPlaced < 3 and rwTick >= rwWorldStarNextAt then
        set rwWorldStarsPlaced = rwWorldStarsPlaced + 1
        set slot = rwWorldStarsPlaced
        set rwWorldStarX[slot] = GetUnitX(rwHero)
        set rwWorldStarY[slot] = GetUnitY(rwHero)
        set rwWorldStarHitAt[slot] = rwTick + delay
        set rwWorldStarNextAt = rwTick + interval
        call RWWorldRing(RW_WORLD_FAN_SLOT + slot - 1, rwWorldStarX[slot], rwWorldStarY[slot], 140.0, 4, 255, 157, 70)
        call RWWorldMark(RW_WORLD_FAN_SLOT + slot - 1, rwWorldStarX[slot], rwWorldStarY[slot], "STAR " + I2S(slot), 255, 157, 70)
    endif
    loop
        exitwhen i > rwWorldStarsPlaced
        if rwWorldStarHitAt[i] > 0 and rwTick >= rwWorldStarHitAt[i] then
            set rwWorldStarHitAt[i] = 0
            set rwWorldStarsLanded = rwWorldStarsLanded + 1
            call RWWorldClearMarks(RW_WORLD_FAN_SLOT + i - 1)
            if RWAlive(rwBoss) and RWAlive(rwHero) and RWWorldDistance2(rwWorldStarX[i], rwWorldStarY[i], GetUnitX(rwHero), GetUnitY(rwHero)) <= 19600.0 then
                call RWDamage(rwBoss, rwHero, damage, "Boss starfall")
            endif
        endif
        set i = i + 1
    endloop
    if rwWorldStarsLanded == 3 then
        set rwWorldBossAttack = 0
        set rwWorldBossRecoverAt = rwTick + 24
    endif
endfunction

function RWWorldBossImpact takes nothing returns nothing
    local real dx = GetUnitX(rwHero) - rwWorldBossX
    local real dy = GetUnitY(rwHero) - rwWorldBossY
    local real distance2 = dx * dx + dy * dy
    local real dot = dx * rwWorldBossDX + dy * rwWorldBossDY
    local real damage
    local integer move = rwWorldBossAttack
    call RWWorldClearMarks(RW_WORLD_FAN_SLOT)
    set rwWorldBossAttack = 0
    if move == 1 then
        set rwWorldBossRecoverAt = rwTick + 28
        if distance2 <= 176400.0 and dot >= 0.0 and 2.0 * dot * dot >= distance2 then
            set damage = 160.0
            if rwBossPhase == 2 then
                set damage = 180.0
            endif
            call RWDamage(rwBoss, rwHero, damage, "Boss cleave")
        endif
    else
        set rwWorldBossRecoverAt = rwTick + 40
        if distance2 > 48400.0 and distance2 <= 422500.0 then
            set damage = 190.0
            if rwBossPhase == 2 then
                set damage = 210.0
            endif
            call RWDamage(rwBoss, rwHero, damage, "Boss rift ring")
        endif
    endif
endfunction

function RWWorldBossTick takes boolean aiTick returns nothing
    local integer due
    if rwBossPhase == 1 and GetWidgetLife(rwBoss) <= 4320.0 then
        set rwWorldBossPhasePending = true
    endif
    if rwWorldBossRecoverAt > 0 and rwTick >= rwWorldBossRecoverAt then
        set rwWorldBossRecoverAt = 0
        call PauseUnit(rwBoss, false)
        call RWWorldChase(rwBoss)
    endif
    if rwWorldBossAttack == 0 and rwWorldBossRecoverAt == 0 then
        if rwWorldBossPhasePending then
            set rwWorldBossPhasePending = false
            set rwBossPhase = 2
            set rwWorldBossCycle = rwTick
            set rwWorldBossNext = 1
        endif
        set due = rwWorldBossCycle + RWWorldBossOffset(rwWorldBossNext)
        if rwTick >= due then
            call RWWorldBossBegin(rwWorldBossNext, due)
        elseif aiTick then
            call RWWorldChase(rwBoss)
        endif
    endif
    if rwWorldBossAttack == 2 then
        call RWWorldStarTick()
    elseif rwWorldBossAttack != 0 and rwTick >= rwWorldBossImpactAt then
        call RWWorldBossImpact()
    endif
endfunction

function RWWorldForgetCorpse takes integer id returns nothing
    call RemoveUnit(rwWorldOwned[id])
    set rwWorldOwned[id] = null
    set rwEnemy[id] = null
    set rwWorldRemoveAt[id] = 0
    if id == RW_WORLD_BOSS_ID then
        set rwBoss = null
    endif
endfunction

function RWWorldRecordDeaths takes nothing returns nothing
    local integer i = 1
    local integer groupId
    loop
        exitwhen i > RW_WORLD_BOSS_ID
        if rwActive[i] and rwWorldOwned[i] != null and not RWAlive(rwWorldOwned[i]) then
            set rwActive[i] = false
            set rwWorldRemoveAt[i] = rwTick + 60
            set groupId = rwWorldEnemyGroup[i]
            set rwWorldGroupAlive[groupId] = rwWorldGroupAlive[groupId] - 1
            set rwObjectiveRemaining = rwObjectiveRemaining - 1
            call RWWorldCancelCast(i)
            if i == RW_WORLD_BOSS_ID and rwRoom == 3 and rwBossPhase > 0 and RWAlive(rwHero) then
                set rwWinner = true
            endif
        elseif rwWorldRemoveAt[i] > 0 and rwTick >= rwWorldRemoveAt[i] then
            call RWWorldForgetCorpse(i)
        endif
        set i = i + 1
    endloop
endfunction

function RWWorldUpdateThreat takes nothing returns nothing
    local integer i = 1
    set rwThreat = ""
    if rwWorldBossAttack == 1 then
        set rwThreat = "Cleave: move to the side"
    elseif rwWorldBossAttack == 2 then
        set rwThreat = "Starfall: keep moving"
    elseif rwWorldBossAttack == 3 then
        set rwThreat = "Rift ring: inner circle safe"
    elseif rwWorldBossRecoverAt > 0 then
        set rwThreat = "Boss opening"
    elseif rwWorldBossStartAt > 0 and rwBossPhase == 0 then
        set rwThreat = "The Warden approaches"
    else
        loop
            exitwhen i >= RW_WORLD_BOSS_ID
            if rwWorldCastAt[i] > 0 then
                if rwKind[i] == 3 then
                    set rwThreat = "Guard slam: move out"
                    return
                endif
                set rwThreat = "Mender channeling"
            endif
            set i = i + 1
        endloop
    endif
endfunction

function RWWorldFreeze takes nothing returns nothing
    local integer i = 1
    if rwWorldFrozen then
        return
    endif
    set rwWorldFrozen = true
    set rwFighting = false
    set rwChoiceStage = 0
    set rwThreat = ""
    set rwWorldBossAttack = 0
    set rwWorldBossRecoverAt = 0
    set rwWorldBossStartAt = -1
    set rwWorldBossImpactAt = 0
    set rwWorldStarNextAt = 0
    set rwWorldBossPhasePending = false
    loop
        exitwhen i > RW_WORLD_GATE_SLOT
        call RWWorldClearMarks(i)
        if i <= RW_WORLD_BOSS_ID then
            set rwWorldCastAt[i] = 0
            set rwWorldHealTarget[i] = 0
            if RWAlive(rwWorldOwned[i]) then
                call RWWorldStopForCast(rwWorldOwned[i])
            elseif rwWorldOwned[i] != null then
                call RWWorldForgetCorpse(i)
            endif
            set rwActive[i] = false
        endif
        if i <= 3 then
            set rwWorldStarHitAt[i] = 0
        endif
        set i = i + 1
    endloop
endfunction

function RWWorldReset takes nothing returns nothing
    local integer i = 1
    call RWWorldFreeze()
    loop
        exitwhen i > RW_WORLD_BOSS_ID
        if rwWorldOwned[i] != null then
            call RWWorldForgetCorpse(i)
        endif
        set rwEnemy[i] = null
        set rwActive[i] = false
        set rwKind[i] = 0
        set rwWorldEnemyGroup[i] = 0
        set rwWorldReturning[i] = false
        set rwWorldRemoveAt[i] = 0
        set rwWorldReadyAt[i] = 0
        set rwWorldRepositionAt[i] = 0
        set rwWorldCastAt[i] = 0
        set rwWorldHealTarget[i] = 0
        if i <= 9 then
            set rwWorldGroupStarted[i] = false
            set rwWorldGroupAlive[i] = 0
        endif
        set i = i + 1
    endloop
    set rwWorldRun = rwRun
    set rwWorldFrozen = false
    set rwCount = 0
    set rwChoiceStage = 0
    set rwChoiceOne = 0
    set rwChoiceTwo = 0
    set rwBossPhase = 0
    set rwBoss = null
    set rwWorldBossStartAt = -1
    set rwWorldBossNext = 1
    set rwWorldBossLogCount = 0
    set rwWinner = false
    set rwThreat = ""
    call RWWorldSetRoom(1)
endfunction

function RWWorldTick takes nothing returns nothing
    local integer i = 1
    local boolean aiTick = ModuloInteger(rwTick, 4) == 0
    local real hx
    local real hy
    if rwWorldFrozen or rwWorldRun != rwRun then
        return
    endif
    if RWAlive(rwHero) then
        call RWWorldKeepHeroInBounds()
        if rwFighting then
            loop
                exitwhen i >= RW_WORLD_BOSS_ID or not RWAlive(rwHero)
                if rwActive[i] and rwWorldCastAt[i] != 0 and RWAlive(rwEnemy[i]) then
                    call RWWorldCastTick(i)
                endif
                set i = i + 1
            endloop
            if rwActive[RW_WORLD_BOSS_ID] and RWAlive(rwBoss) and RWAlive(rwHero) then
                call RWWorldBossTick(aiTick)
            endif
        endif
    endif
    call RWWorldRecordDeaths()
    if rwWinner or not RWAlive(rwHero) then
        call RWWorldFreeze()
        return
    endif
    call RWWorldAdvance()
    if aiTick and rwFighting then
        set i = 1
        set hx = GetUnitX(rwHero)
        set hy = GetUnitY(rwHero)
        loop
            exitwhen i >= RW_WORLD_BOSS_ID
            if rwActive[i] and RWAlive(rwEnemy[i]) then
                call RWWorldEnemyAI(i, hx, hy)
            endif
            set i = i + 1
        endloop
    endif
    call RWWorldUpdateThreat()
endfunction

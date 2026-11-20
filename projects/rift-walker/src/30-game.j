globals
    constant real RW_GAME_PERIOD = 0.05
    constant real RW_GAME_START_X = -2950.0
    constant real RW_GAME_START_Y = 0.0
    constant integer RW_GAME_MARK_TAGS = 16
    constant integer RW_GAME_DEFEAT = 1
    constant integer RW_GAME_VICTORY = 2

    player rwGamePlayer = null
    timer rwGameTimer = null
    trigger rwGameDialogTrigger = null
    trigger rwGameChatTrigger = null
    trigger rwGameEscapeTrigger = null
    dialog rwGameDialog = null
    button rwGameOption1 = null
    button rwGameOption2 = null
    integer rwGameDialogStage = 0
    integer rwGameResult = 0
    boolean rwGameMuted = false
    sound array rwGameWarning
    integer rwGameLastWarning = 0
    multiboard rwGameHud = null
    quest rwGameObjective = null
    questitem rwGameObjectiveItem = null
    texttag array rwGameMarkTag

    real rwGameLastX = 0.0
    real rwGameLastY = 0.0
    real rwGameWalked = 0.0
    integer rwGameSeenW = 0
    integer rwGameSeenE = 0
    boolean rwGameMoved = false
    boolean rwGameMarkTaught = false
    boolean rwGameMarked = false
    boolean rwGameComboTaught = false
    boolean rwGameDashed = false
    boolean rwGameDetonated = false
    boolean rwGameGuardTaught = false
    boolean rwGameRingTaught = false
endglobals

function RWGameSay takes real duration, string message returns nothing
    call DisplayTimedTextToPlayer(rwGamePlayer, 0.0, 0.0, duration, message)
endfunction

function RWGameRoomName takes nothing returns string
    if rwRoom == 1 then
        return "1 - Broken Court"
    elseif rwRoom == 2 then
        return "2 - Prism Hall"
    endif
    return "3 - Rift Court"
endfunction

function RWGameElapsed takes nothing returns string
    local integer minutes = rwTick / 1200
    local integer seconds = (rwTick / 20) - (minutes * 60)
    if seconds < 10 then
        return I2S(minutes) + ":0" + I2S(seconds)
    endif
    return I2S(minutes) + ":" + I2S(seconds)
endfunction

function RWGameCooldown takes integer ready returns string
    local integer tenths = (ready - rwTick + 1) / 2
    if ready <= rwTick then
        return "Ready"
    endif
    return I2S(tenths / 10) + "." + I2S(tenths - 10 * (tenths / 10)) + "s"
endfunction

function RWGameUpgradedWRange takes nothing returns string
    if rwWShortRange then
        return "280"
    endif
    return "420"
endfunction

function RWGameUpgrade takes integer stage, integer choice returns string
    if choice == 0 then
        return "Pending"
    endif
    if stage == 1 then
        if choice == 1 then
            return "Deep Cut: 4 marks, 4.5s life"
        endif
        return "Arc Step: W " + RWGameUpgradedWRange() + "/4s, Q 75 dmg"
    endif
    if choice == 1 then
        return "Overload: 260 range / 75 echo, 10s E"
    endif
    return "Quick Fuse: 6s E, 0.20s cast, +30/layer"
endfunction

function RWGameHelp takes nothing returns nothing
    call RWGameSay(12.0, "Right-click to move or attack. Hits and Q add marks. Q and W take a point. E detonates marks within 480 after a short charge.")
    call RWGameSay(12.0, "W crosses clear ground and grants no immunity. Keep moving through falling circles. The boss ring is safe inside its inner edge.")
    call RWGameSay(12.0, "Upgrades: click a button, press 1/2, or type -1/-2. Chat: -help, -mute, -status, -retry.")
endfunction

function RWGameStopWarnings takes nothing returns nothing
    local integer i = 1
    loop
        exitwhen i > 3
        call StopSound(rwGameWarning[i], false, false)
        set i = i + 1
    endloop
endfunction

function RWGameApplyAudio takes nothing returns nothing
    if rwGameMuted then
        call RWGameStopWarnings()
        call SetMusicVolume(0)
        call VolumeGroupSetVolume(SOUND_VOLUMEGROUP_UNITMOVEMENT, 0.0)
        call VolumeGroupSetVolume(SOUND_VOLUMEGROUP_UNITSOUNDS, 0.0)
        call VolumeGroupSetVolume(SOUND_VOLUMEGROUP_COMBAT, 0.0)
        call VolumeGroupSetVolume(SOUND_VOLUMEGROUP_SPELLS, 0.0)
        call VolumeGroupSetVolume(SOUND_VOLUMEGROUP_UI, 0.0)
        call VolumeGroupSetVolume(SOUND_VOLUMEGROUP_MUSIC, 0.0)
        call VolumeGroupSetVolume(SOUND_VOLUMEGROUP_AMBIENTSOUNDS, 0.0)
        call VolumeGroupSetVolume(SOUND_VOLUMEGROUP_FIRE, 0.0)
    else
        call VolumeGroupReset()
        call SetMusicVolume(20)
        call VolumeGroupSetVolume(SOUND_VOLUMEGROUP_AMBIENTSOUNDS, 0.30)
    endif
endfunction

function RWGameCamera takes boolean snap returns nothing
    local real blend = 0.15
    local real distance = 1650.0
    local real x = GetUnitX(rwHero)
    local real y = GetUnitY(rwHero)
    if snap then
        set blend = 0.0
    endif
    if rwRoom == 3 then
        set distance = 1850.0
    endif
    if snap or ModuloInteger(rwTick, 5) == 0 then
        call SetCameraField(CAMERA_FIELD_TARGET_DISTANCE, distance, blend)
        call SetCameraField(CAMERA_FIELD_ANGLE_OF_ATTACK, 295.0, blend)
        call SetCameraField(CAMERA_FIELD_ROTATION, 90.0, blend)
        call SetCameraField(CAMERA_FIELD_ROLL, 0.0, blend)
    endif
    // Keep the camera target inside the terrain, with room for the tilted view.
    set x = RMaxBJ(-2850.0, RMinBJ(2850.0, x))
    set y = RMaxBJ(-950.0, RMinBJ(950.0, y))
    call PanCameraToTimed(x, y, blend)
endfunction

function RWGameHudValue takes integer row, string value returns nothing
    local multiboarditem cell = MultiboardGetItem(rwGameHud, row, 0)
    call MultiboardSetItemValue(cell, value)
    call MultiboardReleaseItem(cell)
    set cell = null
endfunction

function RWGameHudIcon takes integer row, string icon returns nothing
    local multiboarditem cell = MultiboardGetItem(rwGameHud, row, 0)
    call MultiboardSetItemStyle(cell, true, true)
    call MultiboardSetItemIcon(cell, icon)
    call MultiboardReleaseItem(cell)
    set cell = null
endfunction

function RWGameMarksText takes integer count returns string
    local string marks = ""
    loop
        exitwhen count <= 0
        set marks = marks + "<>"
        set count = count - 1
    endloop
    return marks
endfunction

function RWGameDrawMark takes integer slot, integer index returns nothing
    local texttag tag = rwGameMarkTag[slot]
    local unit enemy = rwEnemy[index]
    local integer remaining = rwMarkUntil[index] - rwTick
    local string marks = RWGameMarksText(rwMark[index])
    if remaining <= 30 then
        set marks = marks + " " + RWGameCooldown(rwMarkUntil[index])
        if ModuloInteger(rwTick / 5, 2) == 0 then
            call SetTextTagColor(tag, 255, 210, 120, 255)
        else
            call SetTextTagColor(tag, 185, 155, 255, 200)
        endif
    else
        call SetTextTagColor(tag, 205, 175, 255, 255)
    endif
    call SetTextTagText(tag, marks, 0.023)
    call SetTextTagPos(tag, GetUnitX(enemy) - 5.0 * I2R(StringLength(marks)), GetUnitY(enemy), 105.0)
    call SetTextTagVisibility(tag, true)
    set tag = null
    set enemy = null
endfunction

function RWGameBossBar takes nothing returns string
    local real life = GetWidgetLife(rwBoss)
    local real maximum = GetUnitState(rwBoss, UNIT_STATE_MAX_LIFE)
    local integer bar = 0
    local integer filled = 0
    local string text = ""
    if maximum > 0.0 then
        set filled = R2I(10.0 * life / maximum + 0.999)
    endif
    loop
        exitwhen bar == 10
        if bar < filled then
            set text = text + "|cffff8066#|r"
        else
            set text = text + "-"
        endif
        set bar = bar + 1
    endloop
    return "Boss P" + I2S(rwBossPhase) + " [" + text + "] " + I2S(R2I(life)) + " HP"
endfunction

function RWGameHideMarks takes integer first returns nothing
    loop
        exitwhen first >= RW_GAME_MARK_TAGS
        call SetTextTagVisibility(rwGameMarkTag[first], false)
        set first = first + 1
    endloop
endfunction

function RWGameHudTick takes nothing returns nothing
    local integer i = 1
    local integer slot = 0
    local string objective = "Enemies left: " + I2S(rwObjectiveRemaining)
    local string boss = ""
    if rwGameResult == RW_GAME_DEFEAT then
        set objective = "Defeat - Esc or -retry"
    elseif rwGameResult == RW_GAME_VICTORY then
        set objective = "Victory - Esc or -retry"
    elseif rwChoiceStage > 0 then
        set objective = "Anchor sealed - choose 1 or 2"
    elseif rwBossPhase > 0 and RWAlive(rwBoss) then
        set objective = "Defeat the Rift Warden"
        set boss = RWGameBossBar()
    elseif rwRoom == 3 and rwObjectiveRemaining == 0 then
        set objective = "The Warden approaches"
    elseif rwObjectiveRemaining == 0 then
        set objective = "Follow the path east"
    endif

    call RWGameHudValue(0, RWGameRoomName() + "   " + RWGameElapsed())
    call RWGameHudValue(1, "HP " + I2S(R2I(RMaxBJ(0.0, GetWidgetLife(rwHero)))) + "/" + I2S(R2I(GetUnitState(rwHero, UNIT_STATE_MAX_LIFE))))
    call RWGameHudValue(2, objective)
    call RWGameHudValue(3, boss)
    call RWGameHudValue(4, rwThreat)
    call RWGameHudValue(5, "Q  Rift Slash   " + RWGameCooldown(rwQReady))
    call RWGameHudValue(6, "W  Slipstep   " + RWGameCooldown(rwWReady))
    call RWGameHudValue(7, "E  Convergence   " + RWGameCooldown(rwEReady))
    if rwGameResult == 0 then
        call RWGameHudValue(8, "E targets " + I2S(rwECount) + "  |  Top marks " + I2S(rwEMax))
        // Reserve the first slot for the boss when marked.
        loop
            exitwhen i > rwCount or slot > 0
            if rwEnemy[i] == rwBoss and rwMark[i] > 0 and RWAlive(rwBoss) then
                call RWGameDrawMark(slot, i)
                set slot = slot + 1
            endif
            set i = i + 1
        endloop
        set i = 1
        loop
            exitwhen i > rwCount or slot == RW_GAME_MARK_TAGS
            if rwActive[i] and rwEnemy[i] != rwBoss and rwMark[i] > 0 and RWAlive(rwEnemy[i]) then
                call RWGameDrawMark(slot, i)
                set slot = slot + 1
            endif
            set i = i + 1
        endloop
    else
        call RWGameHudValue(8, "")
    endif
    call RWGameHideMarks(slot)
    call RWGameHudValue(9, "I   " + RWGameUpgrade(1, rwChoiceOne))
    call RWGameHudValue(10, "II  " + RWGameUpgrade(2, rwChoiceTwo))
endfunction

function RWGameHideDialog takes nothing returns nothing
    call DialogDisplay(rwGamePlayer, rwGameDialog, false)
    call DialogClear(rwGameDialog)
    set rwGameOption1 = null
    set rwGameOption2 = null
    set rwGameDialogStage = 0
endfunction

function RWGameShowChoice takes integer stage returns nothing
    call RWGameHideDialog()
    set rwGameDialogStage = stage
    if stage == 1 then
        call DialogSetMessage(rwGameDialog, "Anchor I - Choose a combat style")
        set rwGameOption1 = DialogAddButton(rwGameDialog, "1  Deep Cut: 4 marks, 4.5s life", '1')
        set rwGameOption2 = DialogAddButton(rwGameDialog, "2  Arc Step: W " + RWGameUpgradedWRange() + "/4s, Q 75 dmg", '2')
        call RWGameSay(12.0, "Deep Cut: 4 marks per enemy, 270 damage at 4 stacks, marks last 4.5s. Arc Step: W reaches " + RWGameUpgradedWRange() + ", W CD 4s, Q damage 75.")
    else
        call DialogSetMessage(rwGameDialog, "Anchor II - Choose a detonation style")
        set rwGameOption1 = DialogAddButton(rwGameDialog, "1  Overload: 260 range / 75 echo, 10s E", '1')
        set rwGameOption2 = DialogAddButton(rwGameDialog, "2  Quick Fuse: 6s E, 0.20s cast, +30/layer", '2')
        call RWGameSay(12.0, "Overload: echo range 260, echo damage 75, E CD 10s. Quick Fuse: E CD 6s, charge 0.20s, main blast 90 + 30 per mark. W grants no immunity.")
    endif
    call DialogDisplay(rwGamePlayer, rwGameDialog, true)
endfunction

function RWGameResultText takes nothing returns string
    local string cause = rwLastDamage
    if rwGameResult == RW_GAME_VICTORY then
        return "Victory - " + RWGameElapsed() + "\n" + RWGameUpgrade(1, rwChoiceOne) + "\n" + RWGameUpgrade(2, rwChoiceTwo)
    endif
    if cause == null or cause == "" then
        set cause = "Unknown"
    endif
    return "Defeat - " + RWGameElapsed() + "\n" + RWGameRoomName() + "\nLast hit: " + cause
endfunction

function RWGameShowResult takes nothing returns nothing
    call RWGameHideDialog()
    call DialogSetMessage(rwGameDialog, RWGameResultText())
    set rwGameOption1 = DialogAddButton(rwGameDialog, "1  Retry from the start", '1')
    set rwGameOption2 = DialogAddButton(rwGameDialog, "2  Review results", '2')
    call DialogDisplay(rwGamePlayer, rwGameDialog, true)
endfunction

function RWGameFinish takes integer result returns nothing
    if rwGameResult != 0 then
        return
    endif
    set rwGameResult = result
    set rwFighting = false
    call RWWorldFreeze()
    call RWGameStopWarnings()
    call RWCombatTick()
    call RWCombatUpdateEffects(true)
    if RWAlive(rwHero) then
        call IssueImmediateOrder(rwHero, "stop")
        call PauseUnit(rwHero, true)
    endif
    call QuestSetCompleted(rwGameObjective, result == RW_GAME_VICTORY)
    call QuestItemSetCompleted(rwGameObjectiveItem, result == RW_GAME_VICTORY)
    call QuestSetFailed(rwGameObjective, result == RW_GAME_DEFEAT)
    call QuestItemSetDescription(rwGameObjectiveItem, RWGameResultText())
    call RWGameHudTick()
    call RWGameSay(30.0, RWGameResultText())
    call RWGameShowResult()
endfunction

function RWGameEnsureAbility takes integer rawcode returns nothing
    if GetUnitAbilityLevel(rwHero, rawcode) == 0 then
        call UnitAddAbility(rwHero, rawcode)
    endif
endfunction

function RWGameRestart takes nothing returns nothing
    call RWGameHideDialog()
    call RWGameHideMarks(0)
    call ClearTextMessages()
    set rwRun = rwRun + 1
    set rwTick = 0
    set rwFighting = false
    if rwHero != null then
        call RemoveUnit(rwHero)
    endif
    set rwHero = CreateUnit(rwGamePlayer, 'Hrw0', RW_GAME_START_X, RW_GAME_START_Y, 0.0)
    call RWGameEnsureAbility(RW_Q_ABILITY)
    call RWGameEnsureAbility(RW_W_ABILITY)
    call RWGameEnsureAbility(RW_E_ABILITY)
    // World retains its owned units while combat clears registrations.
    call RWCombatReset()
    call RWWorldReset()
    set rwGameResult = 0
    set rwGameLastWarning = 0
    set rwGameLastX = GetUnitX(rwHero)
    set rwGameLastY = GetUnitY(rwHero)
    set rwGameWalked = 0.0
    set rwGameSeenW = rwAppliedW
    set rwGameSeenE = rwAppliedE
    set rwGameMoved = false
    set rwGameMarkTaught = false
    set rwGameMarked = false
    set rwGameComboTaught = false
    set rwGameDashed = false
    set rwGameDetonated = false
    set rwGameGuardTaught = false
    set rwGameRingTaught = false
    call QuestSetCompleted(rwGameObjective, false)
    call QuestSetFailed(rwGameObjective, false)
    call QuestItemSetCompleted(rwGameObjectiveItem, false)
    call QuestItemSetDescription(rwGameObjectiveItem, "Seal both anchors, then defeat the Rift Warden.")
    call ClearSelection()
    call SelectUnit(rwHero, true)
    call RWGameCamera(true)
    call RWGameHudTick()
    call RWGameSay(10.0, "Right-click the ground to move. Right-click enemies to attack. Type -help for controls.")
endfunction

function RWGameChoose takes integer choice returns nothing
    local integer stage = rwChoiceStage
    if rwGameResult == 0 and RWAlive(rwHero) and (stage == 1 or stage == 2) and (choice == 1 or choice == 2) then
        call RWChoose(choice)
        if rwChoiceStage != stage then
            call RWGameHideDialog()
            call RWGameHudTick()
        endif
    endif
endfunction

function RWGameDialogClick takes nothing returns nothing
    local button clicked = GetClickedButton()
    // This dialog is only displayed to the sole human slot.
    if clicked != null then
        if rwGameResult != 0 then
            if clicked == rwGameOption1 then
                call RWGameRestart()
            elseif clicked == rwGameOption2 then
                call RWGameHideDialog()
                call RWGameSay(10.0, "Press Esc to see the result again, or type -retry.")
            endif
        elseif rwGameDialogStage == rwChoiceStage then
            if clicked == rwGameOption1 then
                call RWGameChoose(1)
            elseif clicked == rwGameOption2 then
                call RWGameChoose(2)
            endif
        endif
    endif
    set clicked = null
endfunction

function RWGameChat takes nothing returns nothing
    local string command = StringCase(GetEventPlayerChatString(), false)
    if command == "-help" then
        call RWGameHelp()
    elseif command == "-status" then
        call RWGameSay(15.0, "ROOM " + I2S(rwRoom) + "   HP " + I2S(R2I(GetWidgetLife(rwHero))) + "   LEFT " + I2S(rwObjectiveRemaining))
        call RWGameSay(15.0, "POS " + I2S(R2I(GetUnitX(rwHero))) + "/" + I2S(R2I(GetUnitY(rwHero))) + "   HIT " + I2S(rwNativeHits) + "   QWE " + I2S(rwAppliedQ) + "/" + I2S(rwAppliedW) + "/" + I2S(rwAppliedE))
    elseif command == "-mute" then
        set rwGameMuted = not rwGameMuted
        call RWGameApplyAudio()
        if rwGameMuted then
            call RWGameSay(5.0, "Sound muted. Type -mute again to restore it.")
        else
            call RWGameSay(5.0, "Sound on.")
        endif
    elseif command == "-retry" and rwGameResult != 0 then
        call RWGameRestart()
    elseif command == "-1" then
        call RWGameChoose(1)
    elseif command == "-2" then
        call RWGameChoose(2)
    endif
endfunction

function RWGameEscape takes nothing returns nothing
    if rwGameResult != 0 then
        call RWGameShowResult()
    elseif rwChoiceStage > 0 then
        call DialogDisplay(rwGamePlayer, rwGameDialog, true)
    endif
endfunction

function RWGameTutorial takes nothing returns nothing
    local real x = GetUnitX(rwHero)
    local real y = GetUnitY(rwHero)
    local real dx = x - rwGameLastX
    local real dy = y - rwGameLastY
    local real change = dx * dx + dy * dy
    local integer i = 1
    if not rwGameMoved and rwAppliedW == rwGameSeenW and change > 0.0 and change <= 4096.0 then
        set rwGameWalked = rwGameWalked + SquareRoot(change)
        if rwGameWalked >= 200.0 then
            set rwGameMoved = true
            call RWGameSay(5.0, "Movement complete. Approach the first enemies.")
        endif
    endif
    set rwGameLastX = x
    set rwGameLastY = y

    if rwRoom == 1 and rwFighting and not rwGameMarkTaught then
        set rwGameMarkTaught = true
        call RWGameSay(8.0, "Land a sword hit or use Q to add Rift Marks.")
    endif
    if rwGameMarkTaught and not rwGameMarked then
        loop
            exitwhen i > rwCount or rwGameMarked
            if rwActive[i] and rwMark[i] > 0 and RWAlive(rwEnemy[i]) then
                set rwGameMarked = true
                call RWGameSay(6.0, "Mark applied. New marks refresh the whole stack.")
            endif
            set i = i + 1
        endloop
    endif
    if rwWorldGroupStarted[2] and not rwGameComboTaught then
        set rwGameComboTaught = true
        call RWGameSay(9.0, "Use W to change position. Press E near marked enemies to detonate and chain. W grants no immunity.")
    endif
    if rwGameComboTaught then
        if not rwGameDashed and rwAppliedW > rwGameSeenW then
            set rwGameDashed = true
            call RWGameSay(5.0, "Blink complete.")
        endif
        if not rwGameDetonated and rwAppliedE > rwGameSeenE then
            set rwGameDetonated = true
            call RWGameSay(5.0, "Detonation complete. Echoes can also hit unmarked enemies.")
        endif
    endif
    set rwGameSeenW = rwAppliedW
    set rwGameSeenE = rwAppliedE
    if not rwGameGuardTaught and rwThreat == "Guard slam: move out" then
        set rwGameGuardTaught = true
        call RWGameSay(7.0, "Move outside the guard slam. W grants no immunity.")
    endif
    if not rwGameRingTaught and rwThreat == "Rift ring: inner circle safe" then
        set rwGameRingTaught = true
        call RWGameSay(7.0, "Stay inside the inner circle or move beyond the outer edge.")
    endif
endfunction

function RWGameDangerCue takes nothing returns nothing
    local integer warning = rwWorldBossAttack
    if warning > 0 and warning <= 3 and warning != rwGameLastWarning and RWAlive(rwBoss) then
        if not rwGameMuted then
            call StartSound(rwGameWarning[warning])
        endif
        if warning == 2 then
            call PingMinimapEx(GetUnitX(rwHero), GetUnitY(rwHero), 1.0, 255, 95, 70, false)
        else
            call PingMinimapEx(GetUnitX(rwBoss), GetUnitY(rwBoss), 1.0, 255, 95, 70, false)
        endif
    endif
    set rwGameLastWarning = warning
endfunction

function RWGameInitAudio takes nothing returns nothing
    set rwGameWarning[1] = CreateSoundFromLabel("Warning", false, false, false, 0, 0)
    set rwGameWarning[2] = CreateSoundFromLabel("Hint", false, false, false, 0, 0)
    set rwGameWarning[3] = CreateSoundFromLabel("QuestUpdate", false, false, false, 0, 0)
    call RWGameApplyAudio()
endfunction

function RWGameInitUi takes nothing returns nothing
    local integer i = 0
    set rwGameHud = CreateMultiboard()
    call MultiboardSetColumnCount(rwGameHud, 1)
    call MultiboardSetRowCount(rwGameHud, 11)
    call MultiboardSetTitleText(rwGameHud, "Rift Walker")
    call MultiboardSetItemsWidth(rwGameHud, 0.28)
    call MultiboardSetItemsStyle(rwGameHud, true, false)
    call RWGameHudIcon(5, "ReplaceableTextures\\CommandButtons\\BTNCarrionSwarm.blp")
    call RWGameHudIcon(6, "ReplaceableTextures\\CommandButtons\\BTNBlink.blp")
    call RWGameHudIcon(7, "ReplaceableTextures\\CommandButtons\\BTNThunderclap.blp")
    call MultiboardDisplay(rwGameHud, true)
    call MultiboardMinimize(rwGameHud, false)
    loop
        exitwhen i >= RW_GAME_MARK_TAGS
        set rwGameMarkTag[i] = CreateTextTag()
        call SetTextTagPermanent(rwGameMarkTag[i], true)
        set i = i + 1
    endloop
    set rwGameObjective = CreateQuest()
    call QuestSetTitle(rwGameObjective, "Seal the Rift")
    call QuestSetDescription(rwGameObjective, "Cross the broken sanctum and stop the Rift Warden.")
    call QuestSetRequired(rwGameObjective, true)
    call QuestSetDiscovered(rwGameObjective, true)
    set rwGameObjectiveItem = QuestCreateItem(rwGameObjective)
endfunction

function RWGameInitInput takes nothing returns nothing
    set rwGameDialog = DialogCreate()
    set rwGameDialogTrigger = CreateTrigger()
    call TriggerRegisterDialogEvent(rwGameDialogTrigger, rwGameDialog)
    call TriggerAddAction(rwGameDialogTrigger, function RWGameDialogClick)
    set rwGameChatTrigger = CreateTrigger()
    call TriggerRegisterPlayerChatEvent(rwGameChatTrigger, rwGamePlayer, "-", false)
    call TriggerAddAction(rwGameChatTrigger, function RWGameChat)
    set rwGameEscapeTrigger = CreateTrigger()
    call TriggerRegisterPlayerEvent(rwGameEscapeTrigger, rwGamePlayer, EVENT_PLAYER_END_CINEMATIC)
    call TriggerAddAction(rwGameEscapeTrigger, function RWGameEscape)
endfunction

function RWGameTick takes nothing returns nothing
    if rwGameHud == null then
        // Classic UI is ready after the first timer fires.
        call RWGameInitAudio()
        call RWGameInitUi()
        call RWGameInitInput()
        call RWCombatInit()
        call RWGameRestart()
        return
    endif
    if rwGameResult != 0 then
        return
    endif
    set rwTick = rwTick + 1
    call RWCombatTick()
    call RWWorldTick()
    if not RWAlive(rwHero) then
        call RWGameFinish(RW_GAME_DEFEAT)
        return
    elseif rwWinner then
        call RWGameFinish(RW_GAME_VICTORY)
        return
    endif
    if rwChoiceStage > 0 and rwGameDialogStage != rwChoiceStage then
        call RWGameShowChoice(rwChoiceStage)
    endif
    call RWGameTutorial()
    call RWGameDangerCue()
    call RWGameCamera(false)
    if ModuloInteger(rwTick, 5) == 0 then
        call RWGameHudTick()
    endif
endfunction

function main takes nothing returns nothing
    set rwGamePlayer = Player(0)
    call SetCameraBounds(-3900.0, -2000.0, -3900.0, 2000.0, 3900.0, 2000.0, 3900.0, -2000.0)
    set bj_mapInitialPlayableArea = Rect(-3900.0, -2000.0, 3900.0, 2000.0)
    call FogMaskEnable(false)
    call FogEnable(false)
    call SetDayNightModels("Environment\\DNC\\DNCLordaeron\\DNCLordaeronTerrain\\DNCLordaeronTerrain.mdl", "Environment\\DNC\\DNCLordaeron\\DNCLordaeronUnit\\DNCLordaeronUnit.mdl")
    call SetFloatGameState(GAME_STATE_TIME_OF_DAY, 12.0)
    call SuspendTimeOfDay(true)
    set rwGameTimer = CreateTimer()
    call TimerStart(rwGameTimer, RW_GAME_PERIOD, true, function RWGameTick)
endfunction

function config takes nothing returns nothing
    call SetMapName("Rift Walker")
    call SetMapDescription("A single-player action dungeon.")
    call SetPlayers(1)
    call SetTeams(1)
    call SetGamePlacement(MAP_PLACEMENT_USE_MAP_SETTINGS)
    call DefineStartLocation(0, RW_GAME_START_X, RW_GAME_START_Y)
    call SetPlayerStartLocation(Player(0), 0)
    call ForcePlayerStartLocation(Player(0), 0)
    call SetPlayerController(Player(0), MAP_CONTROL_USER)
    call SetPlayerRacePreference(Player(0), RACE_PREF_HUMAN)
    call SetPlayerRaceSelectable(Player(0), false)
    call SetPlayerTeam(Player(0), 0)
endfunction

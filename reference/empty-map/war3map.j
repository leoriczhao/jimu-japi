//===========================================================================
// JAPI Empty Rifleman
// Minimal test map: flat terrain, one user slot, no melee initialization.
// The sole rifleman is created by map/lib/scene.lua.
//===========================================================================

globals
    hashtable japi_ht = null
    integer japi__key = 0

    // Bridge/preflight regression probes (read by the Lua suite).
    integer udg_lua_bridge_result = 0
    integer udg_lua_error_result = 0
    integer udg_lua_handle_result = 0
    integer udg_lua_test_value = 0
    integer array udg_lua_test_array

    // Arrays the JASS code never touches: they only become writable at
    // index > 0 because tools/pack.ps1 force-allocates every declared array
    // before LoadScript (JapiForceAllocArrays).
    integer array udg_lua_test_array_untouched
    string array udg_lua_test_string_array
endglobals

function InitGlobals takes nothing returns nothing
    // Force allocation of the array used by the Lua globals regression.
    set udg_lua_test_array[0] = 0
endfunction
//===========================================================================
// JAPI bridge
//===========================================================================

function japiDoNothing takes nothing returns nothing
endfunction

function initializePlugin takes nothing returns integer
    set japi_ht = InitHashtable()
    set japi__key = StringHash("jass")
    call ExecuteFunc("japiDoNothing")
    call StartCampaignAI(Player(PLAYER_NEUTRAL_AGGRESSIVE), "callback")
    call UnitId(I2S(GetHandleId(japi_ht)))
    call ExecuteFunc("japiDoNothing")
    return 0
endfunction

function GetMouseX takes nothing returns real
    call SaveStr(japi_ht, japi__key, 0, "()R")
    call UnitId("GetMouseX")
    return LoadReal(japi_ht, japi__key, 0)
endfunction

function GetMouseY takes nothing returns real
    call SaveStr(japi_ht, japi__key, 0, "()R")
    call UnitId("GetMouseY")
    return LoadReal(japi_ht, japi__key, 0)
endfunction

function EXExecuteScript takes string str returns string
    call SaveStr(japi_ht, japi__key, 0, "(S)S")
    call SaveStr(japi_ht, japi__key, 1, str)
    call UnitId("EXExecuteScript")
    return LoadStr(japi_ht, japi__key, 0)
endfunction

function LuaCallback1 takes nothing returns nothing
    call UnitId("LuaCallbackBridge")
endfunction

function LuaCallback2 takes nothing returns nothing
    call UnitId("LuaCallback2")
endfunction

function LuaCallback3 takes nothing returns nothing
    call UnitId("LuaCallback3")
endfunction

function LuaCallback4 takes nothing returns nothing
    call UnitId("LuaCallback4")
endfunction

// Synchronous JASS -> Lua calls through the UnitId + hashtable bridge.
// The Lua handlers are registered by tests.bridge_preflight at LoadScript time.
function LuaBridgeProbeCall takes integer a, integer b returns integer
    call SaveStr(japi_ht, japi__key, 0, "(II)I")
    call SaveInteger(japi_ht, japi__key, 1, a)
    call SaveInteger(japi_ht, japi__key, 2, b)
    call UnitId("LuaBridgeProbe")
    return LoadInteger(japi_ht, japi__key, 0)
endfunction

function LuaErrorProbeCall takes nothing returns integer
    call SaveStr(japi_ht, japi__key, 0, "()I")
    call UnitId("LuaErrorProbe")
    return LoadInteger(japi_ht, japi__key, 0)
endfunction

// Handle ABI round-trip: the Lua handler receives the player handle as a
// userdata (handle_level=2) and returns the same handle.
function LuaHandleProbeCall takes nothing returns integer
    call SaveStr(japi_ht, japi__key, 0, "(Hplayer;)Hplayer;")
    call SaveInteger(japi_ht, japi__key, 1, GetHandleId(Player(0)))
    call UnitId("LuaHandleEcho")
    return LoadInteger(japi_ht, japi__key, 0)
endfunction


//===========================================================================
// Map initialization
//===========================================================================

function main takes nothing returns nothing
    call SetCameraBounds( -3328.0 + GetCameraMargin(CAMERA_MARGIN_LEFT), -3584.0 + GetCameraMargin(CAMERA_MARGIN_BOTTOM), 3328.0 - GetCameraMargin(CAMERA_MARGIN_RIGHT), 3072.0 - GetCameraMargin(CAMERA_MARGIN_TOP), -3328.0 + GetCameraMargin(CAMERA_MARGIN_LEFT), 3072.0 - GetCameraMargin(CAMERA_MARGIN_TOP), 3328.0 - GetCameraMargin(CAMERA_MARGIN_RIGHT), -3584.0 + GetCameraMargin(CAMERA_MARGIN_BOTTOM) )
    call SetDayNightModels( "Environment\\DNC\\DNCLordaeron\\DNCLordaeronTerrain\\DNCLordaeronTerrain.mdl", "Environment\\DNC\\DNCLordaeron\\DNCLordaeronUnit\\DNCLordaeronUnit.mdl" )
    call NewSoundEnvironment( "Default" )
    call SetAmbientDaySound( "LordaeronSummerDay" )
    call SetAmbientNightSound( "LordaeronSummerNight" )
    call SetMapMusic( "Music", true, 0 )
    call initializePlugin(  )
    call InitBlizzard(  )
    call InitGlobals(  )
endfunction

function config takes nothing returns nothing
    call SetMapName( "JAPI Empty Rifleman" )
    call SetMapDescription( "Minimal japi.dll validation map" )
    call SetPlayers( 1 )
    call SetTeams( 1 )
    call SetGamePlacement( MAP_PLACEMENT_USE_MAP_SETTINGS )
    call DefineStartLocation( 0, -715.4, 615.2 )
    call SetPlayerStartLocation( Player(0), 0 )
    call SetPlayerColor( Player(0), ConvertPlayerColor(0) )
    call SetPlayerRacePreference( Player(0), RACE_PREF_HUMAN )
    call SetPlayerRaceSelectable( Player(0), true )
    call SetPlayerController( Player(0), MAP_CONTROL_USER )
    call SetPlayerSlotAvailable( Player(0), MAP_CONTROL_USER )
    call InitGenericPlayerSlots(  )
endfunction

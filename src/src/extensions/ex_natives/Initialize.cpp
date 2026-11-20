// Initialize.cpp — Entry point for EX* native registration
// Uses bridge dispatch (UnitId hook) instead of JASS native table modification.
// This is the builtin-japi pattern — all functions go through UnitId hashtable RPC.

#include <windows.h>
#include <cstdint>
#include <warcraft3/jass.h>

// Forward declaration for bridge dispatch registration
namespace warcraft3::lua_engine::bridge {
	typedef uint32_t (*cpp_handler_fn)(const uint32_t* args, size_t nargs);
	void register_cpp_handler(const char* name, const char* spec, cpp_handler_fn fn);
}

// EXExecuteScript implementation lives in lua_loader.cpp
namespace warcraft3::lua_engine::lua_loader {
	jass::jstring_t __cdecl EXExecuteScript(jass::jstring_t script);
}

namespace warcraft3::japi {

	// Forward declarations for all EX* handler functions
	uint32_t EXGetUnitString_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitString_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetUnitReal_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitReal_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetUnitInteger_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitInteger_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetUnitArrayString_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitArrayString_handler(const uint32_t* args, size_t nargs);
	uint32_t EXPauseUnit_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitCollisionType_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitMoveType_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetUnitFacing_handler(const uint32_t* args, size_t nargs);
	uint32_t EXDclareButtonIcon_handler(const uint32_t* args, size_t nargs);
	uint32_t EXBlendButtonIcon_handler(const uint32_t* args, size_t nargs);

	uint32_t EXGetUnitAbility_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetUnitAbilityByIndex_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetAbilityId_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetAbilityState_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetAbilityState_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetAbilityDataReal_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetAbilityDataReal_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetAbilityDataInteger_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetAbilityDataInteger_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetAbilityDataString_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetAbilityDataString_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetAbilityAEmeDataA_handler(const uint32_t* args, size_t nargs);
uint32_t EXGetAbilityString_handler(const uint32_t* args, size_t nargs);
uint32_t EXSetAbilityString_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetBuffDataString_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetBuffDataString_handler(const uint32_t* args, size_t nargs);

	uint32_t EXGetItemDataString_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetItemDataString_handler(const uint32_t* args, size_t nargs);

	uint32_t EXSetEffectXY_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetEffectZ_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetEffectX_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetEffectY_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetEffectZ_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetEffectSize_handler(const uint32_t* args, size_t nargs);
	uint32_t EXGetEffectSize_handler(const uint32_t* args, size_t nargs);
	uint32_t EXEffectMatRotateX_handler(const uint32_t* args, size_t nargs);
	uint32_t EXEffectMatRotateY_handler(const uint32_t* args, size_t nargs);
	uint32_t EXEffectMatRotateZ_handler(const uint32_t* args, size_t nargs);
	uint32_t EXEffectMatScale_handler(const uint32_t* args, size_t nargs);
	uint32_t EXEffectMatReset_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetEffectSpeed_handler(const uint32_t* args, size_t nargs);

	uint32_t EXGetEventDamageData_handler(const uint32_t* args, size_t nargs);
	uint32_t EXSetEventDamage_handler(const uint32_t* args, size_t nargs);
	bool install_event_damage_hooks();

	uint32_t EXDisplayChat_handler(const uint32_t* args, size_t nargs);

	uint32_t GetMapName_handler(const uint32_t* args, size_t nargs);
	uint32_t GetGameVersion_handler(const uint32_t* args, size_t nargs);
	uint32_t GetPluginVersion_handler(const uint32_t* args, size_t nargs);
	uint32_t Hex_handler(const uint32_t* args, size_t nargs);

	uint32_t GetChatState_handler(const uint32_t* args, size_t nargs);
	uint32_t ShowConsole_handler(const uint32_t* args, size_t nargs);
	uint32_t GetFps_handler(const uint32_t* args, size_t nargs);
	uint32_t ShowFpsText_handler(const uint32_t* args, size_t nargs);
	uint32_t GetLittleMapX_handler(const uint32_t* args, size_t nargs);
	uint32_t SetLittleMapX_handler(const uint32_t* args, size_t nargs);
	uint32_t GetLittleMapY_handler(const uint32_t* args, size_t nargs);
	uint32_t SetLittleMapY_handler(const uint32_t* args, size_t nargs);

	// EXExecuteScript adapter
	static uint32_t EXExecuteScript_bridge(const uint32_t* a, size_t) {
		return warcraft3::lua_engine::lua_loader::EXExecuteScript((jass::jstring_t)a[0]);
	}

	using namespace warcraft3::lua_engine::bridge;

	// P3-E1: the EX* surface is exposed two ways on purpose.
	//
	//   * bridge handler (UnitId RPC + the jass.japi closure) — the path Lua uses.
	//     Its marshalling is the tested one (P1 conformance: string-result ABI,
	//     real/boolean types) and it survives the native table being rebuilt.
	//   * real JASS native (jass::japi_add) — the YDWE / builtin-japi contract:
	//     the name resolves through jass.debug.jass_func_address() and through a
	//     JASS native declaration compiled after this point (e.g. the reboot child
	//     map), which is what "EX* is a native" means for map authors.
	//
	// jass.japi prefers the bridge handler (libs_japi.cpp japi_index), so adding
	// the native cannot change what Lua sees.
	void InitializeUnitState();   // hooks the GetUnitState/SetUnitState native names
	void InitializeGameUiExtra(); // GetBigMapX/Y, SetBigMapX/Y, GetConsoleUIX/Y, SetConsoleUIX/Y
	void InitializeBuiltinCompat(); // timer_start/end/destroy, ReplacePath, gold/teleport aliases, save disable
	void InitializeAbilityState();
	void InitializeEffect();
	void InitializeItemState();
	void InitializeEventDamageData();
	void InitializeGameInfo();
	void InitializeDisplayChat();

	static void register_real_ex_natives()
	{
		InitializeAbilityState();     // 16 ability natives (EXGetUnitAbility …)
		InitializeEffect();           // 13 effect natives (EXSetEffectXY …)
		InitializeItemState();        //  2 item natives (EXGetItemDataString …)
		InitializeEventDamageData();  //  2 damage natives (EXGetEventDamageData, EXSetEventDamage)
		InitializeGameInfo();         //  4 game info natives (GetMapName/GetGameVersion/GetPluginVersion/Hex)
		InitializeDisplayChat();      //  1 display native (EXDisplayChat)
		// InitializeCodeRunLogs() stays empty: open_code_run_logs is a plugin
		// lifecycle entry point reached through the bridge, never a map-facing native.
	}

	void initialize_ex_natives()
	{
		install_event_damage_hooks();
		InitializeUnitState();
		InitializeGameUiExtra();
		InitializeBuiltinCompat();

		// Unit state
		register_cpp_handler("EXGetUnitString",        "(II)S",  EXGetUnitString_handler);
		register_cpp_handler("EXSetUnitString",        "(IIS)B", EXSetUnitString_handler);
		register_cpp_handler("EXGetUnitReal",          "(II)R",  EXGetUnitReal_handler);
		register_cpp_handler("EXSetUnitReal",          "(IIR)B", EXSetUnitReal_handler);
		register_cpp_handler("EXGetUnitInteger",       "(II)I",  EXGetUnitInteger_handler);
		register_cpp_handler("EXSetUnitInteger",       "(III)B", EXSetUnitInteger_handler);
		register_cpp_handler("EXGetUnitArrayString",   "(III)S", EXGetUnitArrayString_handler);
		register_cpp_handler("EXSetUnitArrayString",   "(IIIS)B", EXSetUnitArrayString_handler);
		register_cpp_handler("EXPauseUnit",            "(IB)V",  EXPauseUnit_handler);
		register_cpp_handler("EXSetUnitCollisionType", "(BII)V", EXSetUnitCollisionType_handler);
		register_cpp_handler("EXSetUnitMoveType",      "(II)V",  EXSetUnitMoveType_handler);
		register_cpp_handler("EXSetUnitFacing",        "(IR)V",  EXSetUnitFacing_handler);

		// Historical YDWE command-button icon API. The names (including the
		// "Dclare" typo) are part of the map contract. They perform real BLP
		// decode + disabled/blend + palette encode, write below
		// <map dir>\japi-button-icons\, and do NOT hook SFileLoadFile; see
		// ButtonIcon.cpp for the in-session limitation.
		register_cpp_handler("EXDclareButtonIcon",     "(S)V",   EXDclareButtonIcon_handler);
		register_cpp_handler("EXBlendButtonIcon",      "(SSS)B", EXBlendButtonIcon_handler);

		// Ability state
		register_cpp_handler("EXGetUnitAbility",       "(II)I",  EXGetUnitAbility_handler);
		register_cpp_handler("EXGetUnitAbilityByIndex","(II)I",  EXGetUnitAbilityByIndex_handler);
		register_cpp_handler("EXGetAbilityId",         "(I)I",   EXGetAbilityId_handler);
		register_cpp_handler("EXGetAbilityState",      "(II)R",  EXGetAbilityState_handler);
		register_cpp_handler("EXSetAbilityState",      "(IIR)B", EXSetAbilityState_handler);
		register_cpp_handler("EXGetAbilityDataReal",   "(III)R", EXGetAbilityDataReal_handler);
		register_cpp_handler("EXSetAbilityDataReal",   "(IIIR)V",EXSetAbilityDataReal_handler);
		register_cpp_handler("EXGetAbilityDataInteger","(III)I", EXGetAbilityDataInteger_handler);
		register_cpp_handler("EXSetAbilityDataInteger","(IIII)V",EXSetAbilityDataInteger_handler);
		register_cpp_handler("EXGetAbilityDataString", "(III)S", EXGetAbilityDataString_handler);
		register_cpp_handler("EXSetAbilityDataString", "(IIIS)V",EXSetAbilityDataString_handler);
		register_cpp_handler("EXSetAbilityAEmeDataA",  "(II)B",  EXSetAbilityAEmeDataA_handler);
	register_cpp_handler("EXGetAbilityString",     "(III)S", EXGetAbilityString_handler);
	register_cpp_handler("EXSetAbilityString",     "(IIIS)V",EXSetAbilityString_handler);
		register_cpp_handler("EXGetBuffDataString",    "(II)S",  EXGetBuffDataString_handler);
		register_cpp_handler("EXSetBuffDataString",    "(IIS)B", EXSetBuffDataString_handler);

		// Item state
		register_cpp_handler("EXGetItemDataString",    "(II)S",  EXGetItemDataString_handler);
		register_cpp_handler("EXSetItemDataString",    "(IIS)B", EXSetItemDataString_handler);

		// Effect
		register_cpp_handler("EXSetEffectXY",          "(IRR)V", EXSetEffectXY_handler);
		register_cpp_handler("EXSetEffectZ",           "(IR)V",  EXSetEffectZ_handler);
		register_cpp_handler("EXGetEffectX",           "(I)R",   EXGetEffectX_handler);
		register_cpp_handler("EXGetEffectY",           "(I)R",   EXGetEffectY_handler);
		register_cpp_handler("EXGetEffectZ",           "(I)R",   EXGetEffectZ_handler);
		register_cpp_handler("EXSetEffectSize",        "(IR)V",  EXSetEffectSize_handler);
		register_cpp_handler("EXGetEffectSize",        "(I)R",   EXGetEffectSize_handler);
		register_cpp_handler("EXEffectMatRotateX",     "(IR)V",  EXEffectMatRotateX_handler);
		register_cpp_handler("EXEffectMatRotateY",     "(IR)V",  EXEffectMatRotateY_handler);
		register_cpp_handler("EXEffectMatRotateZ",     "(IR)V",  EXEffectMatRotateZ_handler);
		register_cpp_handler("EXEffectMatScale",       "(IRRR)V",EXEffectMatScale_handler);
		register_cpp_handler("EXEffectMatReset",       "(I)V",   EXEffectMatReset_handler);
		register_cpp_handler("EXSetEffectSpeed",       "(IR)V",  EXSetEffectSpeed_handler);

		// Event damage
		register_cpp_handler("EXGetEventDamageData",   "(I)I",   EXGetEventDamageData_handler);
		register_cpp_handler("EXSetEventDamage",       "(R)B",   EXSetEventDamage_handler);

		// Display
		register_cpp_handler("EXDisplayChat",          "(IIS)V", EXDisplayChat_handler);

		// Game info
		register_cpp_handler("GetMapName",             "()S",    GetMapName_handler);
		register_cpp_handler("GetGameVersion",         "()I",    GetGameVersion_handler);
		register_cpp_handler("GetPluginVersion",       "()S",    GetPluginVersion_handler);
		register_cpp_handler("Hex",                    "(I)S",   Hex_handler);
		register_cpp_handler("EXExecuteScript",        "(S)S",   EXExecuteScript_bridge);

		// Game UI (builtin-japi CGameUI series)
		register_cpp_handler("GetChatState",           "()B",    GetChatState_handler);
		register_cpp_handler("ShowConsole",            "(B)V",   ShowConsole_handler);
		register_cpp_handler("GetFps",                 "()R",    GetFps_handler);
		register_cpp_handler("ShowFpsText",            "(B)V",   ShowFpsText_handler);
		register_cpp_handler("GetLittleMapX",          "()R",    GetLittleMapX_handler);
		register_cpp_handler("SetLittleMapX",          "(R)V",   SetLittleMapX_handler);
		register_cpp_handler("GetLittleMapY",          "()R",    GetLittleMapY_handler);
		register_cpp_handler("SetLittleMapY",          "(R)V",   SetLittleMapY_handler);

		// P3-E1: publish the same surface as real JASS natives. japi_add only
		// queues the entry; dllmain Step 3 flushes the queue into the current
		// JASS native table (a fresh table after every map boot).
		register_real_ex_natives();
	}
}

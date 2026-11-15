// FuncBind.h - code address -> label registry behind SaveFunc / func_bind_trigger_name
//
// builtin-japi's map side binds every trigger action's code address to a human
// readable label so its run/crash logs can name the function that was executing
// (docs/re-builtin-japi/05-map-side.md). Two UnitId RPC names carry it:
//
//   SaveFunc (I)V               one long-lived anchor address
//   func_bind_trigger_name (IS)V  code address + UTF-8 label
//
// Addresses travel as integers because the bridge ABI has no 'C' type and the
// real UnitId takes an integer. Three producers feed this table:
//   1. GetFuncAddr() on the JASS side, i.e. SetHeroLevels(code) +
//      LoadInteger(ht, key, 0). SetHeroLevels is a real engine native -- signature
//      "(C)V", registered by game.dll, absent from common.j -- that a map script
//      may declare as long as the name already exists in the engine's native
//      table and the declaration precedes the first function. Our japi_add of
//      "SetHeroLevels" rewrites that node's func_address, so the call lands in
//      SetHeroLevels_capture (libs_message.cpp) instead of the engine's AI stub.
//      tools/pack.ps1 -WithGetFuncAddr injects the declaration and GetFuncAddr().
//   2. jass.code() trampolines (a Lua function callable from JASS).
//   3. find_func_address() for native names.
// See docs/planning/JASS-NATIVE-DECLARATIONS.md for the rules and the evidence.
#pragma once

#include <cstddef>
#include <cstdint>

namespace warcraft3::japi {

	// Bridge handlers (register_cpp_handler in dllmain.cpp).
	uint32_t SaveFunc_handler(const uint32_t* args, size_t nargs);
	uint32_t func_bind_trigger_name_handler(const uint32_t* args, size_t nargs);

	// Lookup for log/crash output; returns nullptr when the address is unknown.
	const char* lookup_func_name(uint32_t func_address);

	// Resolve a native name to its code address (the VM's native table, plus the
	// jass.japi entries registered at runtime). Map script functions are not in
	// either table, so this returns 0 for script names by design: a script
	// function's address comes either from jass.code(fn) on the Lua side or from
	// GetFuncAddr(function f) on the JASS side (see this header's top comment).
	uint32_t find_func_address(const char* func_name);

	uint32_t save_func_addr();
	size_t   func_bind_count();

	// Code addresses are only meaningful for the script that produced them, so
	// the table is cleared whenever the map (and its JASS VM contents) is rebuilt.
	void clear_func_bind();

}

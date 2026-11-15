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
// real UnitId takes an integer. The builtin's map side obtains them from
// GetFuncAddr(), i.e. SetHeroLevels(code) + LoadInteger(ht, key, 0); that route
// is closed to us (see find_func_address below), so code addresses reach this
// table from jass.code() trampolines and from the resolver instead.
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
	// either table: the JASS side cannot produce their addresses on its own in
	// callback mode, because declaring a custom native (SetHeroLevels) in
	// war3map.j makes the game reject the script before main() ever runs --
	// natives registered at runtime are not in the map's native table at compile
	// time. So find_func_address() returns 0 for script names by design, and the
	// supported way to obtain a callable code address from Lua is jass.code(fn).
	uint32_t find_func_address(const char* func_name);

	uint32_t save_func_addr();
	size_t   func_bind_count();

	// Code addresses are only meaningful for the script that produced them, so
	// the table is cleared whenever the map (and its JASS VM contents) is rebuilt.
	void clear_func_bind();

}

// libs_selector.cpp - jass.selector module
//
// YDWE's jass.selector.hero() walked the engine's private CUnit array through
// hard-coded offsets. This port deliberately stays in the public map-author
// layer: the module body is Lua (libs_selector_lua.h) and calls only
// jass.common natives. The C++ side simply compiles and runs that chunk; it
// performs no memory access, hooking, native registration or bridge work.

#include <lua.hpp>
#include "libs_selector_lua.h"

namespace warcraft3::lua_engine::selector {

	int open(lua_State* L)
	{
		if (luaL_loadbuffer(L, selector_lua_source,
				sizeof(selector_lua_source) - 1,
				"=jass.selector") != LUA_OK) {
			return lua_error(L);
		}

		// The chunk returns the module table. pcall keeps a module-load error
		// from escaping as a panic; it is re-raised to require() as a normal
		// Lua error. hero()'s own pcall has already released its temporary
		// group/rect before any runtime error reaches this point.
		if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
			return lua_error(L);
		}
		return 1;
	}
}

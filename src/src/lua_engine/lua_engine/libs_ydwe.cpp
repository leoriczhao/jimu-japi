// libs_ydwe.cpp - jass.ydwe module (YDWE unit-state SDK compatibility layer).
//
// The module body is Lua (libs_ydwe_lua.h) and calls only jass.common natives
// plus the existing EXGetUnitState / EXSetUnitState bridge handlers through
// jass.japi. The C++ side performs no memory access, hooking, native-table
// registration or Storm work.

#include <lua.hpp>
#include "libs_ydwe_lua.h"

namespace warcraft3::lua_engine::ydwe {

	int open(lua_State* L)
	{
		if (luaL_loadbuffer(L, ydwe_lua_source,
				sizeof(ydwe_lua_source) - 1,
				"=jass.ydwe") != LUA_OK) {
			return lua_error(L);
		}

		// The chunk returns the module table. pcall keeps a module-load error
		// from escaping as a panic; require() still receives it as a normal
		// Lua error. unit_state.get/set validate their arguments themselves.
		if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
			return lua_error(L);
		}
		return 1;
	}
}

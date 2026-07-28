// fix_baselib.cpp — Callback mode adaptations of the Lua base library
//
// print: stock implementation writes to stdout (the debug console), which
// deploy.ps1 cannot see. Override it to push lines into DBG_LOG's ring
// buffer so test output lands in C:\ProgramData\japi_debug.txt.

#include "fix_baselib.h"
#include <lua.hpp>
#include "debug_log.h"

namespace warcraft3::lua_engine {

	lua_State* newstate()
	{
		return luaL_newstate();
	}

	static int print_to_log(lua_State* L)
	{
		int n = lua_gettop(L);
		luaL_Buffer b;
		luaL_buffinit(L, &b);
		for (int i = 1; i <= n; i++) {
			if (i > 1) luaL_addchar(&b, '\t');
			luaL_tolstring(L, i, NULL);  // respects __tostring, result on stack
			luaL_addvalue(&b);
		}
		luaL_pushresult(&b);
		DBG_LOG("%s", lua_tostring(L, -1));
		return 0;
	}

	int fix_baselib(lua_State* L)
	{
		lua_pushcfunction(L, print_to_log);
		lua_setglobal(L, "print");
		return 0;
	}
}

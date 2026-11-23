// libs_ai.cpp — jass.ai module (War3 common.ai native bindings)
// Ported from YDWE yd_lua_engine/lua_engine/libs_ai.cpp.

#include "common.h"
#include <warcraft3/hashtable.h>
#include <warcraft3/war3_searcher.h>
#include <warcraft3/jass/func_value.h>
#include <warcraft3/jass.h>
#include <base/lua/range.h>
#include <base/util/do_once.h>

namespace warcraft3::lua_engine::ai {

	static jass::func_mapping function;

	static jass::func_value const* get_function(const char* proc_name)
	{
		auto it = function.find(proc_name);
		if (it != function.end() && it->second.is_valid())
		{
			return &(it->second);
		}
		return nullptr;
	}

	static int get(lua_State* L)
	{
		jass::func_value const* nf = get_function(luaL_checkstring(L, 2));
		if (nf && nf->is_valid())
		{
			lua_pushinteger(L, (uint32_t)(uintptr_t)nf);
			lua_pushcclosure(L, jass_call_closure, 1);
			lua_pushvalue(L, 2);
			lua_pushvalue(L, -2);
			lua_rawset(L, 1);
			return 1;
		}
		lua_pushnil(L);
		return 1;
	}

	static int set(lua_State* /*L*/)
	{
		return 0;
	}

	static int pairs(lua_State* L)
	{
		return base::lua::make_range(L, function);
	}

	int open(lua_State* L)
	{
		DO_ONCE_NOTHREADSAFE()
		{
			function = jass::initialize_mapping("DebugS");
		}

		lua_newtable(L);
		{
			lua_newtable(L);
			{
				lua_pushstring(L, "__index");
				lua_pushcclosure(L, get, 0);
				lua_rawset(L, -3);

				lua_pushstring(L, "__newindex");
				lua_pushcclosure(L, set, 0);
				lua_rawset(L, -3);

				lua_pushstring(L, "__pairs");
				lua_pushcclosure(L, pairs, 0);
				lua_rawset(L, -3);
			}
			lua_setmetatable(L, -2);
		}
		return 1;
	}
}

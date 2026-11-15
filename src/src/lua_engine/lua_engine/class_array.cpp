#include "class_array.h"
#include "jassbind.h"
#include "common.h"
#include "debug_log.h"
#include <warcraft3/jass/global_variable.h>
#include <cstdio>

namespace warcraft3::lua_engine {
	namespace globals {
		void jass_get_global_variable(lua_State* L, jass::OPCODE_VARIABLE_TYPE opt, uint32_t value);
	}

#define LUA_JASS_ARRAY "jarray_t"

	jass::global_variable jarray_value(lua_State* L)
	{
		lua_pushvalue(L, 1);
		lua_pushstring(L, "__value");
		lua_rawget(L, -2);
		jass::global_variable gv((hashtable::variable_node*)lua_tointeger(L, -1));
		lua_pop(L, 2);
		return std::move(gv);
	}

	int jarray_index(lua_State* L)
	{
		jass::global_variable gv = jarray_value(L);
		int32_t index = (int32_t)luaL_checkinteger(L, 2);

		if (!gv.is_vaild() || !gv.is_array() || !gv.array_vaild(index))
		{
			lua_pushnil(L);
			return 1;
		}
	
		globals::jass_get_global_variable(L, jass::opcode_type_remove_array(gv.type()), gv[index]);
		return 1;
	}
	
	int jarray_newindex(lua_State* L)
	{
		jass::global_variable gv = jarray_value(L);
		int32_t index = (int32_t)luaL_checkinteger(L, 2);
	
		if (!gv.is_vaild() || !gv.is_array() || !gv.array_vaild(index))
		{
			// Dropping the write silently used to hide the lazy-allocation rule:
			// the JASS VM only materialises an array block on its first store, so
			// an array the map never touched is invisible here.
			// tools/pack.ps1 preallocates every declared array
			// (JapiForceAllocArrays); this log keeps whatever still slips
			// through visible instead of losing the value.
			static int warned_unallocated = 0;
			if (warned_unallocated < 16)
			{
				++warned_unallocated;
				const char* array_name = gv.is_vaild() ? gv.name() : "?";
				char msg[320];
				snprintf(msg, sizeof(msg),
					"[jass.globals] write ignored: %s[%d] - array not allocated "
					"(pack the map with tools/pack.ps1, or touch %s[0] from JASS first)",
					array_name, (int)index, array_name);
				japi_log::sync_write(msg);
			}
			return 0;
		}
	
		gv[index] = jass_read(L, jass::opcode_type_to_var_type(gv.type()), 3);
		return 0;
	}
	
	// __len receives the array table itself as argument 1 (the metatable is
	// shared by every array, so there is no per-array upvalue to read).
	// Reading the node from lua_upvalueindex(1) here used to yield 0 and turn
	// #arr into a null-pointer dereference.
	int jarray_len(lua_State* L)
	{
		jass::global_variable gv = jarray_value(L);
		lua_pushinteger(L, gv.is_vaild() ? (lua_Integer)gv.array_size() : 0);
		return 1;
	}

	int jarray_create(lua_State* L, uintptr_t value)
	{
		lua_newtable(L);
		luaL_getmetatable(L, LUA_JASS_ARRAY);
		lua_setmetatable(L, -2);
		lua_pushstring(L, "__value");
		lua_pushinteger(L, value);
		lua_rawset(L, -3);
		return 1;
	}

	void jarray_make_mt(lua_State* L)
	{
		luaL_Reg lib[] = {
			{ "__index",    jarray_index },
			{ "__newindex", jarray_newindex },
			{ "__len",      jarray_len },
			{ NULL, NULL },
		};
	
		luaL_newmetatable(L, LUA_JASS_ARRAY);
		luaL_setfuncs(L, lib, 0);
		lua_pop(L, 1);
	}
}

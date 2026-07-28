// libs_sleep.cpp — jass.sleep module
//
// Registers a global sleep(seconds) function that yields the Lua coroutine
// via TriggerSleepAction. Requires runtime.sleep = true to function.

#include <lua.hpp>
#include <warcraft3/jass.h>
#include <warcraft3/jass/func_value.h>
#include <warcraft3/hashtable.h>
#include <warcraft3/jass/trampoline_function.h>
#include "common.h"
#include <cstdio>

namespace warcraft3::lua_engine::sleep {

	// sleep(seconds) — yields the current Lua coroutine for the given duration.
	// Goes through jass_call_native_function + jass_maybe_yield so the standard
	// has_sleep/opcode-rewind machinery handles the coroutine hand-off.
	// Outside a coroutine this is a hard error (calling TriggerSleepAction
	// directly on a non-yieldable thread would hang the game).
	static int sleep_func(lua_State* L)
	{
		float seconds = (float)luaL_checknumber(L, 1);
		if (seconds <= 0) seconds = 0.001f;

		if (!lua_isyieldable(L)) {
			return luaL_error(L, "sleep() must be called from a coroutine");
		}

		jass::func_value const* nf = jass::jass_func("TriggerSleepAction");
		if (!nf || !nf->is_valid()) {
			return luaL_error(L, "TriggerSleepAction is not available");
		}

		lua_pushnumber(L, seconds);
		int result = jass_call_native_function(L, nf, 0);
		return jass_maybe_yield(L, result);
	}

	int open(lua_State* L)
	{
		lua_newtable(L);

		lua_pushstring(L, "sleep");
		lua_pushcclosure(L, sleep_func, 0);
		lua_rawset(L, -3);

		// Also register global "sleep" function
		lua_pushglobaltable(L);
		lua_pushstring(L, "sleep");
		lua_pushcclosure(L, sleep_func, 0);
		lua_rawset(L, -3);
		lua_pop(L, 1);

		return 1;
	}
}

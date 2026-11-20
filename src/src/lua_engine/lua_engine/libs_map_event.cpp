// libs_map_event.cpp — jass.map_event: the map-side event bus.
//
// builtin-japi exposes `jass::get_map_event()`, a std::map<string, vector<uint>>
// that its own handlers consult by event name ("endGame", "brokenNetwork").
// This is the Lua-facing equivalent: maps subscribe Lua functions by name and
// the engine (or the map itself) dispatches them.
//
//   local ev = require "jass.map_event"
//   ev.on("endGame", function() ... end)
//   ev.emit("endGame")         -- dispatch now
//   ev.count("endGame")        -- subscriber count
//   ev.clear("endGame")        -- drop one event's subscriptions
//
// Dispatch is protected: a callback that raises is logged and does not stop the
// remaining subscribers (same intent as builtin's `call eax` loop, minus the
// crash-on-throw behaviour).

#include <lua.hpp>
#include <string>
#include <vector>
#include <map>

#include "debug_log.h"

namespace warcraft3::lua_engine::mapevent {

	typedef std::vector<int> refs_t;            // luaL_ref values in the registry
	static std::map<std::string, refs_t> g_subs;
	static lua_State* g_state = nullptr;

	// Called by engine code (e.g. the EndGame hook) with the current Lua state.
	void set_state(lua_State* L)
	{
		g_state = L;
	}

	static lua_State* state()
	{
		return g_state;
	}

	// Dispatch one event to every subscriber. Returns how many were called.
	size_t emit(const char* name)
	{
		lua_State* L = state();
		if (!L || !name) return 0;

		auto it = g_subs.find(name);
		if (it == g_subs.end()) return 0;

		size_t called = 0;
		for (int ref : it->second) {
			lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
			if (!lua_isfunction(L, -1)) {
				lua_pop(L, 1);
				continue;
			}
			if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
				DBG_LOG("[map_event] %s handler error: %s", name, lua_tostring(L, -1));
				lua_pop(L, 1);
				continue;
			}
			++called;
		}
		return called;
	}

	// ── Lua API ────────────────────────────────────────────────────────────

	static int l_on(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 1);
		luaL_checktype(L, 2, LUA_TFUNCTION);
		lua_pushvalue(L, 2);
		int ref = luaL_ref(L, LUA_REGISTRYINDEX);
		g_subs[name].push_back(ref);
		set_state(L);
		lua_pushinteger(L, (lua_Integer)g_subs[name].size());
		return 1;
	}

	static int l_emit(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 1);
		set_state(L);
		lua_pushinteger(L, (lua_Integer)emit(name));
		return 1;
	}

	static int l_count(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 1);
		auto it = g_subs.find(name);
		lua_pushinteger(L, (lua_Integer)(it == g_subs.end() ? 0 : it->second.size()));
		return 1;
	}

	static int l_clear(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 1);
		auto it = g_subs.find(name);
		size_t dropped = 0;
		if (it != g_subs.end()) {
			dropped = it->second.size();
			for (int ref : it->second) luaL_unref(L, LUA_REGISTRYINDEX, ref);
			g_subs.erase(it);
		}
		lua_pushinteger(L, (lua_Integer)dropped);
		return 1;
	}

	// The VM is about to be closed (map boot): drop every subscription so the
	// registry refs do not dangle.
	void reset()
	{
		lua_State* L = state();
		if (L) {
			for (auto& kv : g_subs) {
				for (int ref : kv.second) luaL_unref(L, LUA_REGISTRYINDEX, ref);
			}
		}
		g_subs.clear();
		g_state = nullptr;
	}

	static const luaL_Reg lib[] = {
		{ "on",    l_on },
		{ "emit",  l_emit },
		{ "count", l_count },
		{ "clear", l_clear },
		{ nullptr, nullptr },
	};

	int open(lua_State* L)
	{
		set_state(L);
		luaL_newlib(L, lib);
		return 1;
	}
}

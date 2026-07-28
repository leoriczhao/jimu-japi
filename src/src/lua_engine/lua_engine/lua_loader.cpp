// lua_loader.cpp — Callback Mode Adaptation
//
// Original YDWE: hooks war3map.j loading via virtual_mpq::force_watch,
// then loads war3map.lua when a new map is detected.
// In callback mode, the map is already loaded, so we directly create
// the Lua state and load war3map.lua from the MPQ.

#include "callback.h"
#include "fix_baselib.h"
#include "lua_loader.h"
#include "storm.h"
#include "open_lua_engine.h"
#include "libs_runtime.h"
#include <lua.hpp>
#include <warcraft3/jass.h>
#include <warcraft3/jass/func_value.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/hashtable.h>
#include <base/util/singleton.h>
#include <base/hook/fp_call.h>
#include <string_view>
#include <base/util/string_algorithm.h>
#include <cstdio>
#include "debug_log.h"

namespace warcraft3::lua_engine {
	namespace message { void install(); }
}

namespace warcraft3::lua_engine::lua_loader {

	static lua_State* mainL = 0;

	lua_State* getMainL()
	{
		if (!mainL) {
			lua_State* L = newstate();
			if (L) {
				luaL_openlibs(L);
				open_lua_engine(L);
				fix_baselib(L);
				runtime::initialize();
				// Install the input-message filter early (builtin-japi style:
				// the engine installs its message filter at init, not on first use).
				// Safe here: getMainL() first runs in-game (ExecuteFunc/LoadScript).
				message::install();
			}
			mainL = L;
		}
		return mainL;
	}

	uintptr_t RealCheat = 0;
	void __cdecl FakeCheat(jass::jstring_t cheat_str)
	{
		const char* cheat = jass::from_string(cheat_str);

		if (!cheat)
		{
			base::c_call<uint32_t>(RealCheat, cheat_str);
			return;
		}

		std::string_view cheat_s = cheat;

		if (cheat_s.substr(0, 9) == "exec-lua:")
		{
			cheat_s = cheat_s.substr(9);
			base::algorithm::trim(cheat_s);
			if (cheat_s.size() >= 2 && cheat_s[0] == '"' && cheat_s[cheat_s.size() - 1] == '"')
			{
				cheat_s = cheat_s.substr(1, cheat_s.size() - 2);
			}
			lua_State* L = getMainL();
			lua_getglobal(L, "require");
			lua_pushlstring(L, cheat_s.data(), cheat_s.size());
			safe_call(L, 1, 1, true);
		}

		base::c_call<uint32_t>(RealCheat, cheat_str);
	}

	jass::jstring_t __cdecl EXExecuteScript(jass::jstring_t script)
	{
		lua_State* L = getMainL();

		const char* raw = jass::from_trigstring(jass::from_string(script));
		char buf[4096];
		snprintf(buf, sizeof(buf), "return (%s)", raw ? raw : "");
		size_t len = strlen(buf);

		if (luaL_loadbuffer(L, buf, len, buf) != LUA_OK)
		{
			printf("%s\n", lua_tostring(L, -1));
			lua_pop(L, 1);
			return 0;
		}

		if (LUA_OK != safe_call(L, 0, 1, true))
		{
			return 0;
		}

		jass::jstring_t result = 0;
		if (lua_isstring(L, -1))
		{
			result = jass::create_string(lua_tostring(L, -1));
		}
		lua_pop(L, 1);
		return result;
	}

	// Load war3map.lua from MPQ and execute it.
	void load_script()
	{
		static bool loaded = false;
		if (loaded) return;
		loaded = true;

		lua_State* L = getMainL();
		if (!L) return;

		const char* buf = 0;
		size_t      len = 0;
		if (storm_s::instance().load_file("script\\war3map.lua", (const void**)&buf, &len))
		{
			if (luaL_loadbuffer(L, buf, len, "@script\\war3map.lua") != LUA_OK) {
				DBG_LOG("[japi-lua] load error: %s", lua_tostring(L, -1));
				lua_pop(L, 1);
				storm_s::instance().unload_file(buf);
			}
			else
			{
				safe_call(L, 0, 0, true);
				storm_s::instance().unload_file(buf);
				DBG_LOG("[japi-lua] war3map.lua loaded");
			}
		}
		else
		{
			DBG_LOG("[japi-lua] war3map.lua not found in MPQ");
		}
	}

	// Callback mode: create Lua state only.
	// UnitId hook and war3map.lua loading are deferred (done by HookUnitId in JASS).
	void initialize()
	{
		lua_State* L = getMainL();
		if (!L) {
			DBG_LOG("getMainL() returned NULL");
			return;
		}
		DBG_LOG("getMainL() OK, L=%p", L);
	}

	// ── Lazy initialization (builtin-japi style) ─────────────────
	// builtin-japi's init_lua_engine does NOT create the Lua state up front;
	// it table_hooks ExecuteFunc and creates the state on the first call.
	// We do the same: the DLL's Initialize() only installs hooks, and the VM
	// (+ war3map.lua) comes up on the first ExecuteFunc.

	static uintptr_t RealExecuteFunc = 0;

	static void __cdecl FakeExecuteFunc(jass::jstring_t name)
	{
		getMainL();      // lazy-create the Lua VM
		load_script();   // and make sure war3map.lua is loaded (idempotent)
		base::c_call<uint32_t>(RealExecuteFunc, name);
	}

	void install_lazy_hook()
	{
		auto* node = warcraft3::get_native_function_hashtable()->find("ExecuteFunc");
		if (!node) {
			DBG_LOG("install_lazy_hook: ExecuteFunc not found");
			return;
		}
		RealExecuteFunc = node->func_address_;
		node->func_address_ = (uint32_t)FakeExecuteFunc;
		DBG_LOG("install_lazy_hook: ExecuteFunc hooked");
	}

	// Bridge handler for LoadScript — called from JASS via UnitId("LoadScript")
	uint32_t LoadScript_bridge(const uint32_t*, size_t) {
		load_script();
		return 0;
	}
}

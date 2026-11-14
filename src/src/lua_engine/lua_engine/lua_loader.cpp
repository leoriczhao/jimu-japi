// lua_loader.cpp — Callback Mode Adaptation
//
// Original YDWE: hooks war3map.j loading via virtual_mpq::force_watch,
// then loads war3map.lua when a new map is detected.
// In callback mode, the map is already loaded, so we directly create
// the Lua state and load war3map.lua from the MPQ.
//
// VM lifetime: builtin-japi registers a game-reset event and does
//     lua_close(mainL); mainL = 0;
// every time the game engine re-initialises (i.e. on every map boot).
// Callback mode gets the same signal for free: the map's JASS bootstrap
// calls Initialize() again on every map, so on_map_boot() runs the reset.

#include "callback.h"
#include "bridge_dispatch.h"
#include "fix_baselib.h"
#include "libs_d3d.h"
#include "libs_message.h"
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
#include <string>
#include <base/util/string_algorithm.h>
#include <cstdio>
#include "debug_log.h"

namespace warcraft3::lua_engine {
	namespace message { void install(); }
}

namespace warcraft3::lua_engine::lua_loader {

	static lua_State* mainL = 0;
	static int  s_boot_count = 0;
	static bool s_loaded = false;
	static bool s_closing = false;

	lua_State* getMainL()
	{
		// A VM that is being closed must never be handed out again (the
		// close runs user finalizers, which may re-enter the engine).
		if (s_closing) return 0;
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

	// Load one Lua chunk from MPQ and execute it.
	void load_script_file(const char* mpq_path)
	{
		lua_State* L = getMainL();
		if (!L) return;

		const char* buf = 0;
		size_t      len = 0;
		if (!storm_s::instance().load_file(mpq_path, (const void**)&buf, &len))
		{
			DBG_LOG("[japi-lua] %s not found in MPQ", mpq_path);
			return;
		}

		// Write a disk copy and name the chunk with its absolute path, so the
		// DAP debugger can map breakpoints to this source (worker matches by
		// path and can read the file for content verification).
		std::string chunkname = std::string("@") + mpq_path;
		char exe[MAX_PATH] = {0};
		if (GetModuleFileNameA(NULL, exe, MAX_PATH)) {
			std::string dir = exe;
			size_t slash = dir.find_last_of('\\');
			if (slash != std::string::npos) {
				dir.resize(slash + 1);
				std::string name = mpq_path;
				size_t back = name.find_last_of('\\');
				if (back != std::string::npos) name = name.substr(back + 1);
				std::string disk = dir + "japi-debugger\\script\\" + name;
				for (size_t i = 0; i < disk.size(); i++) {
					if (disk[i] == '\\') CreateDirectoryA(disk.substr(0, i).c_str(), NULL);
				}
				HANDLE h = CreateFileA(disk.c_str(), GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
				if (h != INVALID_HANDLE_VALUE) {
					DWORD bw;
					WriteFile(h, buf, (DWORD)len, &bw, NULL);
					CloseHandle(h);
					chunkname = "@" + disk;
				}
			}
		}

		if (luaL_loadbuffer(L, buf, len, chunkname.c_str()) != LUA_OK) {
			DBG_LOG("[japi-lua] load error (%s): %s", mpq_path, lua_tostring(L, -1));
			lua_pop(L, 1);
		}
		else
		{
			safe_call(L, 0, 0, true);
			DBG_LOG("[japi-lua] %s loaded", mpq_path);
		}
		storm_s::instance().unload_file(buf);
	}

	// Load war3map.lua from MPQ and execute it (once per VM).
	void load_script()
	{
		if (s_loaded) return;
		s_loaded = true;
		load_script_file("script\\war3map.lua");
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
		// The native table is rebuilt by the game on every map boot, so this
		// normally runs again; only capture the original address once per table.
		if (node->func_address_ != (uint32_t)FakeExecuteFunc) {
			RealExecuteFunc = node->func_address_;
			node->func_address_ = (uint32_t)FakeExecuteFunc;
			DBG_LOG("install_lazy_hook: ExecuteFunc hooked");
		}
		else {
			DBG_LOG("install_lazy_hook: ExecuteFunc already hooked");
		}
	}

	// Bridge handler for LoadScript — called from JASS via UnitId("LoadScript")
	uint32_t LoadScript_bridge(const uint32_t*, size_t) {
		load_script();
		return 0;
	}

	// ── Map / VM lifecycle ───────────────────────────────────────
	int map_boot_count()
	{
		return s_boot_count;
	}

	void close_vm(const char* reason)
	{
		lua_State* L = mainL;
		mainL = 0;
		s_loaded = false;
		if (!L) return;

		// lua_close() runs every finalizer: jass.d3d's context __gc cancels all
		// subscriptions and ends the native session there, so the D3D session
		// lifetime follows the VM (and therefore the map).
		s_closing = true;
		lua_close(L);
		s_closing = false;
		DBG_LOG("[japi-lua] Lua VM closed (%s)", reason ? reason : "reset");
	}

	// Map boot: tear down the previous VM (and everything that referenced it)
	// exactly like builtin-japi's game-reset callback, so the new map starts
	// from a clean Lua state and a fresh D3D session.
	void on_map_boot(bool jass_engine_alive)
	{
		++s_boot_count;
		DBG_LOG("[japi-lua] map boot #%d: resetting Lua VM (jass_alive=%d)",
			s_boot_count, jass_engine_alive ? 1 : 0);

		// Order matters: drop everything that stores a lua_State* or a Lua
		// registry reference before the state dies (C++ handlers survive),
		// stop the JASS timer that would re-enter the dead VM, then close.
		bridge::reset_lua_state(jass_engine_alive);
		message::reset_vm_state();
		d3d::prepare_vm_reset(jass_engine_alive);
		close_vm(jass_engine_alive ? "simulated map boot" : "map boot");
		d3d::reset_vm_state();
	}
}

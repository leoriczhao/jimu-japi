// libs_debugger.cpp — jass.debugger module
//
// Aligns with builtin-japi: (require "jass.debugger").listen("127.0.0.1", 4278)
// The DAP core is actboy168/lua-debug's luadebug.dll (MIT, vendored at
// tools/debugger/, see docs/planning/LUA-DEBUGGER-DESIGN.md appendix A).
//
// listen() flow:
//   1. Extract debugger resources from the MPQ (debugger\*) to
//      <war3 dir>/japi-debugger/ (wenhao_plugin resource-extraction pattern)
//   2. Point LUA_DEBUG_CORE at luadebug.dll and let debugger.lua's
//      package.loadlib(..., "init") auto-resolve our exported Lua API
//   3. Run script/debugger.lua and dbg:start("host:port") (DAP listen mode)

#include <lua.hpp>
#include "storm.h"
#include "callback.h"
#include "debug_log.h"
#include <windows.h>
#include <string>
#include <vector>
#include <cstring>

namespace warcraft3::lua_engine::debugger {

	static int         g_dbg_ref = LUA_NOREF;
	static bool        g_extracted = false;
	static std::string g_root;  // <war3 dir>\japi-debugger\ (backslashes)

	static bool write_file(const std::string& path, const void* data, size_t len)
	{
		for (size_t i = 0; i < path.size(); i++) {
			if (path[i] == '\\' || path[i] == '/') {
				CreateDirectoryA(path.substr(0, i).c_str(), NULL);
			}
		}
		HANDLE h = CreateFileA(path.c_str(), GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
		if (h == INVALID_HANDLE_VALUE) return false;
		DWORD bw = 0;
		WriteFile(h, data, (DWORD)len, &bw, NULL);
		CloseHandle(h);
		return bw == len;
	}

	static bool extract_one(const std::string& rel)
	{
		std::string mpq_path = "debugger\\" + rel;
		const void* buf = nullptr;
		size_t len = 0;
		if (!storm_s::instance().load_file(mpq_path.c_str(), &buf, &len)) {
			return false;
		}
		bool ok = write_file(g_root + rel, buf, len);
		storm_s::instance().unload_file(buf);
		return ok;
	}

	static bool ensure_extracted()
	{
		if (g_extracted) return true;

		char exe[MAX_PATH] = {0};
		GetModuleFileNameA(NULL, exe, MAX_PATH);
		std::string dir = exe;
		size_t slash = dir.find_last_of('\\');
		if (slash == std::string::npos) return false;
		dir.resize(slash + 1);
		g_root = dir + "japi-debugger\\";

		const void* buf = nullptr;
		size_t len = 0;
		if (!storm_s::instance().load_file("debugger\\manifest.txt", &buf, &len)) {
			DBG_LOG("[debugger] debugger\\manifest.txt not in MPQ (pack with -WithDebugger)");
			return false;
		}
		std::string manifest((const char*)buf, len);
		storm_s::instance().unload_file(buf);

		int ok_count = 0, total = 0;
		size_t pos = 0;
		while (pos < manifest.size()) {
			size_t eol = manifest.find('\n', pos);
			std::string line = manifest.substr(pos, eol == std::string::npos ? std::string::npos : eol - pos);
			if (eol == std::string::npos) pos = manifest.size(); else pos = eol + 1;
			while (!line.empty() && (line.back() == '\r' || line.back() == ' ' || line.back() == '\t')) line.pop_back();
			if (line.empty()) continue;
			total++;
			if (extract_one(line)) ok_count++;
			else DBG_LOG("[debugger] extract failed: %s", line.c_str());
		}
		DBG_LOG("[debugger] extracted %d/%d files to %s", ok_count, total, g_root.c_str());
		g_extracted = (total > 0 && ok_count == total);
		return g_extracted;
	}

	static std::string to_lua_path(std::string s)
	{
		for (auto& c : s) if (c == '\\') c = '/';
		return s;
	}

	// listen(host, port) — start DAP listen mode (builtin-japi call shape)
	static int l_listen(lua_State* L)
	{
		const char* host = luaL_optstring(L, 1, "127.0.0.1");
		int port = (int)luaL_optinteger(L, 2, 4278);

		if (strcmp(host, "127.0.0.1") != 0 && strcmp(host, "localhost") != 0) {
			return luaL_error(L, "jass.debugger: only 127.0.0.1 is allowed");
		}
		if (!ensure_extracted()) {
			return luaL_error(L, "jass.debugger: resource extraction failed");
		}

		std::string root  = to_lua_path(g_root);
		std::string core  = root + "luadebug.dll";
		std::string entry = root + "script/debugger.lua";
		// debugger.lua reads os.getenv("LUA_DEBUG_CORE") via the CRT environment,
		// which SetEnvironmentVariableA does NOT update — must use _putenv.
		_putenv_s("LUA_DEBUG_CORE", core.c_str());

		// local dbg = (loadfile(entry))(entry)   -- entry passed as selfsource
		if (luaL_loadfile(L, entry.c_str()) != LUA_OK) {
			return luaL_error(L, "jass.debugger: cannot load debugger.lua: %s", lua_tostring(L, -1));
		}
		lua_pushstring(L, entry.c_str());
		if (safe_call(L, 1, 1, true) != LUA_OK) {
			return luaL_error(L, "jass.debugger: debugger.lua failed to run");
		}

		// dbg:start("host:port")  (string cfg => listen mode)
		lua_getfield(L, -1, "start");
		lua_pushvalue(L, -2);
		lua_pushfstring(L, "%s:%d", host, port);
		if (safe_call(L, 2, 1, true) != LUA_OK) {
			return luaL_error(L, "jass.debugger: dbg:start failed");
		}
		lua_pop(L, 1);  // start() result

		if (g_dbg_ref != LUA_NOREF) {
			luaL_unref(L, LUA_REGISTRYINDEX, g_dbg_ref);
		}
		g_dbg_ref = luaL_ref(L, LUA_REGISTRYINDEX);  // keeps dbg (and the master) alive

		DBG_LOG("[debugger] DAP listening on %s:%d", host, port);
		lua_pushboolean(L, 1);
		return 1;
	}

	// close() — stop the debug master
	static int l_close(lua_State* L)
	{
		if (g_dbg_ref == LUA_NOREF) return 0;
		lua_rawgeti(L, LUA_REGISTRYINDEX, g_dbg_ref);
		lua_getfield(L, -1, "stop");
		if (lua_isfunction(L, -1)) {
			lua_pushvalue(L, -2);
			safe_call(L, 1, 1, true);
		} else {
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
		luaL_unref(L, LUA_REGISTRYINDEX, g_dbg_ref);
		g_dbg_ref = LUA_NOREF;
		return 0;
	}

	// connected() — whether the registry holds an active debugger
	static int l_connected(lua_State* L)
	{
		lua_pushboolean(L, g_dbg_ref != LUA_NOREF);
		return 1;
	}

	int open(lua_State* L)
	{
		luaL_Reg reg[] = {
			{ "listen",    l_listen },
			{ "close",     l_close },
			{ "connected", l_connected },
			{ NULL, NULL },
		};
		luaL_newlib(L, reg);
		return 1;
	}
}

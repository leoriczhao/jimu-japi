// libs_console.cpp - jass.console module
//
// builtin-japi exposes a "console" module that map scripts use to print text to
// the plugin console window (external YDWE maps do "console.enable = true"
// and then console.write(...)).
//
// Real implementation: writes through the same console the debug log owns
// (debug_log.h AllocConsole) and mirrors to OutputDebugString so the text is
// still visible when no console exists (e.g. release builds or a detached run).
//
//   local console = require "jass.console"
//   console.enable = true
//   console.write("hello", 1)      --> "hello\t1"
//   console.clear()

#include <lua.hpp>
#include <windows.h>
#include <cstdio>
#include <string>

namespace warcraft3::lua_engine::console {

	// Mirrors builtin-japi: enabled by default, scripts may switch it off.
	static bool g_enabled = true;

	static int console_write(lua_State* L)
	{
		int n = lua_gettop(L);
		std::string out;
		for (int i = 1; i <= n; ++i) {
			size_t len = 0;
			const char* s = luaL_tolstring(L, i, &len);   // pushes the converted value
			if (s) {
				if (!out.empty()) out += '\t';
				out.append(s, len);
			}
			lua_pop(L, 1);
		}

		if (!out.empty()) {
			if (g_enabled) {
				fputs(out.c_str(), stdout);
				fputc('\n', stdout);
				fflush(stdout);
			}
			OutputDebugStringA(out.c_str());
			OutputDebugStringA("\r\n");
		}
		return 0;
	}

	// Clear the console screen buffer (no-op when there is no console).
	static int console_clear(lua_State* /*L*/)
	{
		HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
		CONSOLE_SCREEN_BUFFER_INFO info;
		if (hOut == INVALID_HANDLE_VALUE || !GetConsoleScreenBufferInfo(hOut, &info)) return 0;

		DWORD cell_count = (DWORD)info.dwSize.X * (DWORD)info.dwSize.Y;
		DWORD written = 0;
		COORD origin = { 0, 0 };
		FillConsoleOutputCharacterA(hOut, ' ', cell_count, origin, &written);
		FillConsoleOutputAttribute(hOut, info.wAttributes, cell_count, origin, &written);
		SetConsoleCursorPosition(hOut, origin);
		return 0;
	}

	static int console_flush(lua_State* /*L*/)
	{
		fflush(stdout);
		return 0;
	}

	static int console_index(lua_State* L)
	{
		size_t len = 0;
		const char* key = luaL_checklstring(L, 2, &len);
		if (_stricmp(key, "enable") == 0 || _stricmp(key, "enabled") == 0) {
			lua_pushboolean(L, g_enabled ? 1 : 0);
			return 1;
		}
		if (_stricmp(key, "write") == 0) { lua_pushcfunction(L, console_write); return 1; }
		if (_stricmp(key, "clear") == 0) { lua_pushcfunction(L, console_clear); return 1; }
		if (_stricmp(key, "flush") == 0) { lua_pushcfunction(L, console_flush); return 1; }
		lua_pushnil(L);
		return 1;
	}

	static int console_newindex(lua_State* L)
	{
		size_t len = 0;
		const char* key = luaL_checklstring(L, 2, &len);
		if (_stricmp(key, "enable") == 0 || _stricmp(key, "enabled") == 0) {
			g_enabled = lua_toboolean(L, 3) != 0;
			return 0;
		}
		// Unknown assignments are accepted silently (builtin-japi behaves the same:
		// the module is a plain table on its side).
		return 0;
	}

	int open(lua_State* L)
	{
		lua_newtable(L);

		lua_newtable(L);                       // metatable
		lua_pushcfunction(L, console_index);
		lua_setfield(L, -2, "__index");
		lua_pushcfunction(L, console_newindex);
		lua_setfield(L, -2, "__newindex");
		lua_setmetatable(L, -2);

		return 1;
	}

}  // namespace warcraft3::lua_engine::console

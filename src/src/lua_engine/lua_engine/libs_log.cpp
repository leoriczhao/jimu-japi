// libs_log.cpp - jass.log module
//
// builtin-japi ships a file logger used by map scripts:
//
//   log = require "jass.log"
//   log.path = "MyMap\\logs\\"             -- relative to the game directory
//   log.info("hello %s", x)                  -- printf-ish, arguments concatenated
//
// Real implementation on our side: an UTF-8 file appended under
// <game dir>\\<path>log-YYYYMMDD.log, one line per call:
//
//   [HH:MM:SS] [INFO] message
//
// Path handling is done in UTF-16 (MultiByteToWideChar) because the game is a
// 1.27a ANSI process while Lua script strings are UTF-8.

#include <lua.hpp>
#include <windows.h>
#include <cstdio>
#include <cstdarg>
#include <string>

namespace warcraft3::lua_engine::maplog {

	// Builtin-japi default; map scripts usually override it.
	static std::string g_path = "logs\\map\\";

	static std::wstring utf8_to_wide(const char* s)
	{
		if (!s || !*s) return std::wstring();
		int need = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
		if (need <= 1) return std::wstring();
		std::wstring out((size_t)need - 1, L'\0');
		MultiByteToWideChar(CP_UTF8, 0, s, -1, &out[0], need);
		return out;
	}

	static std::wstring game_dir()
	{
		wchar_t exe[MAX_PATH] = { 0 };
		GetModuleFileNameW(NULL, exe, MAX_PATH);
		wchar_t* slash = wcsrchr(exe, L'\\');
		if (slash) *slash = L'\0';
		return std::wstring(exe);
	}

	static void make_dirs(const std::wstring& dir)
	{
		std::wstring cur;
		cur.reserve(dir.size());
		for (size_t i = 0; i < dir.size(); ++i) {
			cur += dir[i];
			if ((dir[i] == L'\\' || dir[i] == L'/') && cur.size() > 3) {
				CreateDirectoryW(cur.c_str(), NULL);
			}
		}
		CreateDirectoryW(dir.c_str(), NULL);
	}

	// Concatenate all arguments the way builtin-japi does: the first one is the
	// format-ish text, the rest are appended with a space separator.
	static std::string join_args(lua_State* L)
	{
		int n = lua_gettop(L);
		std::string out;
		for (int i = 1; i <= n; ++i) {
			size_t len = 0;
			const char* s = luaL_tolstring(L, i, &len);   // pushes the converted value
			if (s) {
				if (!out.empty()) out += ' ';
				out.append(s, len);
			}
			lua_pop(L, 1);
		}
		return out;
	}

	static void write_line(const char* level, const std::string& text)
	{
		SYSTEMTIME st;
		GetLocalTime(&st);

		std::wstring dir = game_dir();
		dir += L'\\';
		dir += utf8_to_wide(g_path.c_str());
		make_dirs(dir);

		wchar_t file[MAX_PATH * 2];
		_snwprintf(file, MAX_PATH * 2 - 1, L"%s\\log-%04d%02d%02d.log",
			dir.c_str(), (int)st.wYear, (int)st.wMonth, (int)st.wDay);
		file[MAX_PATH * 2 - 1] = L'\0';

		HANDLE h = CreateFileW(file, FILE_APPEND_DATA,
			FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
			OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
		if (h == INVALID_HANDLE_VALUE) return;

		char line[4096];
		int n = _snprintf(line, sizeof(line) - 3, "[%02d:%02d:%02d] [%s] %s",
			(int)st.wHour, (int)st.wMinute, (int)st.wSecond, level, text.c_str());
		if (n < 0) n = (int)sizeof(line) - 3;
		line[n] = '\r';
		line[n + 1] = '\n';
		line[n + 2] = '\0';

		DWORD written = 0;
		WriteFile(h, line, (DWORD)(n + 2), &written, NULL);
		CloseHandle(h);
	}

	static int log_emit(lua_State* L, const char* level)
	{
		std::string text = join_args(L);
		if (!text.empty()) write_line(level, text);
		return 0;
	}

	static int log_debug(lua_State* L) { return log_emit(L, "DEBUG"); }
	static int log_info(lua_State* L) { return log_emit(L, "INFO"); }
	static int log_warn(lua_State* L) { return log_emit(L, "WARN"); }
	static int log_error(lua_State* L) { return log_emit(L, "ERROR"); }

	static int log_index(lua_State* L)
	{
		size_t len = 0;
		const char* key = luaL_checklstring(L, 2, &len);
		if (_stricmp(key, "path") == 0) {
			lua_pushlstring(L, g_path.c_str(), g_path.size());
			return 1;
		}
		if (_stricmp(key, "debug") == 0) { lua_pushcfunction(L, log_debug); return 1; }
		if (_stricmp(key, "info") == 0) { lua_pushcfunction(L, log_info); return 1; }
		// builtin-japi really does ship both spellings.
		if (_stricmp(key, "warn") == 0 || _stricmp(key, "warnning") == 0) {
			lua_pushcfunction(L, log_warn);
			return 1;
		}
		if (_stricmp(key, "error") == 0) { lua_pushcfunction(L, log_error); return 1; }
		lua_pushnil(L);
		return 1;
	}

	static int log_newindex(lua_State* L)
	{
		size_t len = 0;
		const char* key = luaL_checklstring(L, 2, &len);
		if (_stricmp(key, "path") == 0) {
			size_t vlen = 0;
			const char* value = lua_tolstring(L, 3, &vlen);
			g_path.assign(value ? value : "", value ? vlen : 0);
			// Normalise to backslashes with a trailing separator.
			for (size_t i = 0; i < g_path.size(); ++i) {
				if (g_path[i] == '/') g_path[i] = '\\';
			}
			if (!g_path.empty() && g_path[g_path.size() - 1] != '\\') g_path += '\\';
			return 0;
		}
		return 0;
	}

	int open(lua_State* L)
	{
		lua_newtable(L);

		lua_newtable(L);                       // metatable
		lua_pushcfunction(L, log_index);
		lua_setfield(L, -2, "__index");
		lua_pushcfunction(L, log_newindex);
		lua_setfield(L, -2, "__newindex");
		lua_setmetatable(L, -2);

		return 1;
	}

}  // namespace warcraft3::lua_engine::maplog

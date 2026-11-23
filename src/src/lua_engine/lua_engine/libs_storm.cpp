// libs_storm.cpp - jass.storm module
//
// storm.load(filename) / storm.has(filename) read the game's MPQ archives.
// storm.save(filename, content) persists bytes for the map script.
//
// Read side is the real Storm API (storm.dll ordinals, see storm.cpp).
//
// Write side deliberately does NOT write into the map MPQ: the game opens the
// map archive read-only, and our loader (tools/pack.ps1) treats it as an
// immutable artifact. Instead storm.save writes a real file next to the map
// (the map directory, i.e. the directory of the archive returned by
// SFileGetArchiveName) and storm.load falls back to that same directory, so a
// save followed by a load round-trips inside the engine. The divergence from
// builtin-japi (which patches the archive) is deliberate: the map archive
// stays an immutable input.

#include <lua.hpp>
#include <windows.h>
#include <string>
#include <vector>
#include "storm.h"
#include "debug_log.h"

namespace warcraft3::japi {
	void set_replace_path_cstr(const char* from, const char* to);
	void clear_builtin_compat_map_state();
}

namespace warcraft3::lua_engine::storm {

	namespace {

		std::wstring utf8_to_wide(const char* s)
		{
			if (!s || !*s) return std::wstring();
			int need = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
			if (need <= 1) return std::wstring();
			std::wstring out((size_t)need - 1, L'\0');
			MultiByteToWideChar(CP_UTF8, 0, s, -1, &out[0], need);
			return out;
		}

		// Directory that storm.save/load-fallback work in: the map archive's own
		// directory, falling back to the game directory when the archive name is
		// not resolvable (e.g. a map started from the editor).
		std::wstring game_dir()
		{
			wchar_t exe[MAX_PATH] = { 0 };
			GetModuleFileNameW(NULL, exe, MAX_PATH);
			wchar_t* slash = wcsrchr(exe, L'\\');
			if (slash) *slash = L'\0';
			return std::wstring(exe);
		}

		std::wstring base_dir()
		{
			char mpq[MAX_PATH * 2] = { 0 };
			if (storm_s::instance().get_mpq_name(mpq, sizeof(mpq))) {
				std::wstring wide = utf8_to_wide(mpq);
				size_t slash = wide.find_last_of(L"\\/");
				std::wstring dir = (slash == std::wstring::npos) ? std::wstring() : wide.substr(0, slash);
				// The archive name is usually relative to the game directory
				// ("Maps\\Test\\x.w3x"), sometimes already absolute.
				bool absolute = dir.size() > 1 && dir[1] == L':';
				if (!dir.empty()) {
					return absolute ? dir : (game_dir() + L'\\' + dir);
				}
			}
			return game_dir();
		}

		std::wstring resolve(const char* relative)
		{
			std::wstring wide = utf8_to_wide(relative ? relative : "");
			for (size_t i = 0; i < wide.size(); ++i) {
				if (wide[i] == L'/') wide[i] = L'\\';
				if (wide[i] == L':' || wide[i] == L'*' || wide[i] == L'?' ||
					wide[i] == L'"' || wide[i] == L'<' || wide[i] == L'>' || wide[i] == L'|') {
					wide[i] = L'_';
				}
			}
			while (!wide.empty() && (wide[0] == L'\\' || wide[0] == L'/')) wide.erase(wide.begin());
			std::wstring path = base_dir();
			// Create intermediate directories (CreateDirectoryW is a no-op on hits).
			std::wstring cur = path + L'\\';
			for (size_t i = 0; i < wide.size(); ++i) {
				if (wide[i] == L'\\') {
					if (!CreateDirectoryW(cur.c_str(), NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
						DBG_LOG("[storm] storm.save: cannot create directory (%lu)", (unsigned long)GetLastError());
					}
				}
				cur += wide[i];
			}
			if (!wide.empty() && wide[wide.size() - 1] == L'\\') {
				CreateDirectoryW(cur.c_str(), NULL);
			}
			return path + L'\\' + wide;
		}

		bool write_file(const std::wstring& path, const void* data, size_t size)
		{
			HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE,
				FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
				CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
			if (h == INVALID_HANDLE_VALUE) return false;
			DWORD written = 0;
			bool ok = size == 0 || (WriteFile(h, data, (DWORD)size, &written, NULL) && written == size);
			CloseHandle(h);
			return ok;
		}

		bool read_file(const std::wstring& path, std::string& out)
		{
			HANDLE h = CreateFileW(path.c_str(), GENERIC_READ,
				FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
				OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
			if (h == INVALID_HANDLE_VALUE) return false;
			LARGE_INTEGER size;
			if (!GetFileSizeEx(h, &size) || size.QuadPart > (LONGLONG)64 * 1024 * 1024) {
				CloseHandle(h);
				return false;
			}
			out.assign((size_t)size.QuadPart, '\0');
			DWORD read = 0;
			bool ok = size.QuadPart == 0 || (ReadFile(h, &out[0], (DWORD)out.size(), &read, NULL) && read == out.size());
			CloseHandle(h);
			if (!ok) out.clear();
			return ok;
		}

	}  // namespace

	// storm.load(filename) -> string | nil
	static int storm_load(lua_State* L)
	{
		const char* filename = luaL_checkstring(L, 1);

		const void* buf = nullptr;
		size_t len = 0;
		if (storm_s::instance().load_file(filename, &buf, &len)) {
			lua_pushlstring(L, (const char*)buf, len);
			storm_s::instance().unload_file(buf);
			return 1;
		}

		// Not in any archive: this is where storm.save puts files.
		std::string disk;
		if (read_file(resolve(filename), disk)) {
			lua_pushlstring(L, disk.data(), disk.size());
			return 1;
		}

		lua_pushnil(L);
		return 1;
	}

	// storm.has(filename) -> boolean
	static int storm_has(lua_State* L)
	{
		const char* filename = luaL_checkstring(L, 1);
		if (storm_s::instance().has_file(filename)) {
			lua_pushboolean(L, 1);
			return 1;
		}
		HANDLE h = CreateFileW(resolve(filename).c_str(), GENERIC_READ,
			FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
		if (h != INVALID_HANDLE_VALUE) {
			CloseHandle(h);
			lua_pushboolean(L, 1);
			return 1;
		}
		lua_pushboolean(L, 0);
		return 1;
	}

	// storm.save(filename, content) -> boolean
	static int storm_save(lua_State* L)
	{
		const char* filename = luaL_checkstring(L, 1);
		size_t len = 0;
		const char* content = luaL_checklstring(L, 2, &len);
		std::wstring path = resolve(filename);
		bool ok = write_file(path, content ? content : "", len);
		DBG_LOG("[storm] save '%s' -> %s (%d bytes)", filename, ok ? "ok" : "FAILED", (int)len);
		lua_pushboolean(L, ok ? 1 : 0);
		return 1;
	}

	// storm.replace_path(from, to) -> boolean (routes through Storm#279 virtual MPQ detour)
	static int storm_replace_path(lua_State* L)
	{
		const char* from = luaL_checkstring(L, 1);
		const char* to   = luaL_checkstring(L, 2);
		warcraft3::japi::set_replace_path_cstr(from, to);
		lua_pushboolean(L, 1);
		return 1;
	}

	// storm.clear_replace_paths()
	static int storm_clear_replace_paths(lua_State* /*L*/)
	{
		warcraft3::japi::clear_builtin_compat_map_state();
		return 0;
	}

	int open(lua_State* L)
	{
		lua_newtable(L);

		lua_pushstring(L, "load");
		lua_pushcfunction(L, storm_load);
		lua_rawset(L, -3);

		lua_pushstring(L, "has");
		lua_pushcfunction(L, storm_has);
		lua_rawset(L, -3);

		lua_pushstring(L, "save");
		lua_pushcfunction(L, storm_save);
		lua_rawset(L, -3);

		lua_pushstring(L, "replace_path");
		lua_pushcfunction(L, storm_replace_path);
		lua_rawset(L, -3);

		lua_pushstring(L, "clear_replace_paths");
		lua_pushcfunction(L, storm_clear_replace_paths);
		lua_rawset(L, -3);

		return 1;
	}
}
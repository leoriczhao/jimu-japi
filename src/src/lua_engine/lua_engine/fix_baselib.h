#pragma once

#include <cstddef>
#include <string_view>

struct lua_State;

namespace warcraft3::lua_engine {
	lua_State* newstate();
	int fix_baselib(lua_State* L);

	// Virtualized MPQ file reader used by the package.searchers MPQ loader.
	// Production uses Storm; offline unit tests supply an in-memory map.
	struct MpqFileReader {
		void* ctx;
		bool (*valid)(void* ctx);
		bool (*has_file)(void* ctx, const char* path);
		bool (*load_file)(void* ctx, const char* path, const void** buf, size_t* size);
		void (*unload_file)(void* ctx, const void* buf);
	};

	void install_mpq_searcher(lua_State* L, const MpqFileReader& reader);

	// Parse a Cheat("exec-lua:<module>") argument into the trimmed, unquoted
	// module name; returns empty string_view when the cheat is not exec-lua.
	std::string_view parse_exec_lua_cheat(std::string_view cheat);
}

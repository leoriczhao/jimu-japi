// fix_baselib.cpp — Callback mode adaptations of the Lua base library
//
// 1. print: stock implementation writes to stdout (the debug console), which
//    deploy cannot see. Override it to push lines into DBG_LOG's ring buffer
//    so test output lands in C:\ProgramData\japi_debug.txt.
// 2. package.searchers: insert a Storm MPQ Lua searcher after package.preload
//    and the stock local-disk searcher so loose multi-file .lua scripts packed
//    into the map MPQ (YDWE / KKWE / Solar layout) can be required directly.

#include "fix_baselib.h"
#ifndef JAPI_MPQ_SEARCHER_STANDALONE
#include "storm.h"
#include "debug_log.h"
#include <warcraft3/jass.h>
#include <warcraft3/hashtable.h>
#include <warcraft3/war3_searcher.h>
#include <windows.h>
#endif
#include <lua.hpp>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

namespace warcraft3::lua_engine {

	std::string_view parse_exec_lua_cheat(std::string_view cheat)
	{
		if (cheat.size() < 9 || cheat.substr(0, 9) != "exec-lua:") {
			return {};
		}
		std::string_view mod = cheat.substr(9);
		while (!mod.empty() && std::isspace(static_cast<unsigned char>(mod.front()))) {
			mod.remove_prefix(1);
		}
		while (!mod.empty() && std::isspace(static_cast<unsigned char>(mod.back()))) {
			mod.remove_suffix(1);
		}
		if (mod.size() >= 2 &&
			((mod.front() == '"' && mod.back() == '"') ||
			 (mod.front() == '\'' && mod.back() == '\''))) {
			mod.remove_prefix(1);
			mod.remove_suffix(1);
		}
		return mod;
	}

#ifndef JAPI_MPQ_SEARCHER_STANDALONE
	// Read War3's synchronized RNG seed via SetRandomSeed (same chain as YDWE
	// & builtin-japi: search_string("SetRandomSeed") -> impl -> next_opcode(0x8B, 6)
	// -> *(uintptr_t*)(ptr+2) -> *(uint32_t*)(*(uintptr_t*)global + 4)).
	// Binding Lua's hash seed to the game's synchronized RNG seed prevents
	// multiplayer desyncs caused by divergent pairs() iteration order.
	static unsigned int read_war3_random_seed()
	{
		__try {
			war3_searcher& s = get_war3_searcher();
			uintptr_t ptr = s.search_string("SetRandomSeed");
			if (!ptr) return 0u;
			ptr = *reinterpret_cast<uintptr_t*>(ptr + 0x05);
			if (!ptr) return 0u;
			ptr = next_opcode(ptr, 0x8B, 6);
			if (!ptr) return 0u;
			uintptr_t global_ptr = *reinterpret_cast<uintptr_t*>(ptr + 2);
			if (!global_ptr) return 0u;
			uintptr_t state = *reinterpret_cast<uintptr_t*>(global_ptr);
			if (!state) return 0u;
			return *reinterpret_cast<uint32_t*>(state + 4);
		} __except (EXCEPTION_EXECUTE_HANDLER) {
			return 0u;
		}
	}

	static int sync_math_random(lua_State* L)
	{
		lua_Integer low = 0, up = 1;
		double r = 0.0;
		if (get_jass_vm() != nullptr) {
			jass::jreal_t a = jass::to_real(0.0f);
			jass::jreal_t b = jass::to_real(1.0f);
			r = static_cast<double>(jass::from_real(
				static_cast<jass::jreal_t>(jass::call("GetRandomReal", &a, &b))));
		} else {
			r = static_cast<double>(rand()) * (1.0 / (static_cast<double>(RAND_MAX) + 1.0));
		}

		switch (lua_gettop(L)) {
		case 0:
			lua_pushnumber(L, static_cast<lua_Number>(r));
			return 1;
		case 1:
			up = luaL_checkinteger(L, 1);
			if (up == 0) {
				// Lua 5.4 math.random(0) returns a random full-width integer
				lua_pushinteger(L, static_cast<lua_Integer>(r * 2147483647.0));
				return 1;
			}
			low = 1;
			break;
		case 2:
			low = luaL_checkinteger(L, 1);
			up  = luaL_checkinteger(L, 2);
			break;
		default:
			return luaL_error(L, "wrong number of arguments");
		}
		luaL_argcheck(L, low <= up, 1, "interval is empty");
		double span = static_cast<double>(up - low) + 1.0;
		lua_Integer res = static_cast<lua_Integer>(r * span) + low;
		if (res > up) res = up;
		lua_pushinteger(L, res);
		return 1;
	}

	static int sync_math_randomseed(lua_State* L)
	{
		unsigned int seed = static_cast<unsigned int>(luaL_optinteger(L, 1, 0));
		if (get_jass_vm() != nullptr) {
			jass::call("SetRandomSeed", seed);
		} else {
			srand(seed);
			(void)rand();
		}
		return 0;
	}
#endif

	lua_State* newstate()
	{
#ifndef JAPI_MPQ_SEARCHER_STANDALONE
		unsigned int seed = read_war3_random_seed();
		DBG_LOG("[japi-lua] luaL_newstate2(seed=0x%08X)", seed);
		return luaL_newstate2(seed);
#else
		return luaL_newstate();
#endif
	}

#ifndef JAPI_MPQ_SEARCHER_STANDALONE
	static int print_to_log(lua_State* L)
	{
		int n = lua_gettop(L);
		luaL_Buffer b;
		luaL_buffinit(L, &b);
		for (int i = 1; i <= n; i++) {
			if (i > 1) luaL_addchar(&b, '\t');
			luaL_tolstring(L, i, NULL);  // respects __tostring, result on stack
			luaL_addvalue(&b);
		}
		luaL_pushresult(&b);
		DBG_LOG("%s", lua_tostring(L, -1));
		return 0;
	}
#endif

	static bool normalize_mpq_candidate(std::string_view raw, std::string& out)
	{
		out.clear();
		if (raw.empty()) return false;
		// Skip absolute / drive / UNC / root-anchored disk paths.
		if (raw.find(':') != std::string_view::npos) return false;
		if (raw[0] == '\\' || raw[0] == '/') return false;

		std::string s;
		s.reserve(raw.size());
		bool prev_slash = false;
		for (char c : raw) {
			if (c == '/') c = '\\';
			if (c == '\\') {
				if (prev_slash) continue;
				prev_slash = true;
			} else {
				prev_slash = false;
			}
			s.push_back(c);
		}

		// Strip leading ".\" segments produced by stock package.path (e.g. ".\?.lua").
		size_t start = 0;
		while (start + 2 <= s.size() && s[start] == '.' && s[start + 1] == '\\') {
			start += 2;
		}
		if (start > 0) s.erase(0, start);
		if (s.empty()) return false;

		// Reject parent traversal segments (".."), which MPQ paths do not support.
		size_t pos = 0;
		while (pos <= s.size()) {
			size_t next = s.find('\\', pos);
			size_t len = (next == std::string::npos) ? (s.size() - pos) : (next - pos);
			if (len == 2 && s[pos] == '.' && s[pos + 1] == '.') return false;
			if (next == std::string::npos) break;
			pos = next + 1;
		}

		out = std::move(s);
		return true;
	}

	static void add_mpq_candidate(
		std::string_view raw,
		std::vector<std::string>& out,
		std::unordered_set<std::string>& seen)
	{
		std::string norm;
		if (!normalize_mpq_candidate(raw, norm)) return;
		std::string key = norm;
		std::transform(key.begin(), key.end(), key.begin(), [](unsigned char ch) {
			return static_cast<char>(std::tolower(ch));
		});
		if (seen.insert(key).second) {
			out.push_back(std::move(norm));
		}
	}

	static std::string expand_template(std::string_view tpl, std::string_view mod_rel)
	{
		std::string res;
		res.reserve(tpl.size() + mod_rel.size());
		for (char c : tpl) {
			if (c == '?') {
				res.append(mod_rel.data(), mod_rel.size());
			} else {
				res.push_back(c);
			}
		}
		return res;
	}

	// Upvalue 1: the `package` table.
	// Upvalue 2: full userdata holding a copy of MpqFileReader.
	static int searcher_mpq_lua(lua_State* L)
	{
		size_t name_len = 0;
		const char* name = luaL_checklstring(L, 1, &name_len);

		const auto* reader = static_cast<const MpqFileReader*>(
			lua_touserdata(L, lua_upvalueindex(2)));
		if (!reader || !reader->valid || !reader->valid(reader->ctx)) {
			lua_pushliteral(L, "\n\tmpq storm unavailable");
			return 1;
		}

		std::string mod_rel(name, name_len);
		for (char& c : mod_rel) {
			if (c == '.' || c == '/') c = '\\';
		}

		std::vector<std::string> candidates;
		std::unordered_set<std::string> seen;

		// 1. Respect package.path first (e.g. maps prepending "script\\?.lua;").
		lua_getfield(L, lua_upvalueindex(1), "path");
		if (lua_isstring(L, -1)) {
			size_t path_len = 0;
			const char* path_str = lua_tolstring(L, -1, &path_len);
			std::string_view path_sv(path_str, path_len);
			size_t pos = 0;
			while (pos <= path_sv.size()) {
				size_t sep = path_sv.find(';', pos);
				std::string_view tpl = (sep == std::string_view::npos)
					? path_sv.substr(pos)
					: path_sv.substr(pos, sep - pos);
				if (!tpl.empty()) {
					add_mpq_candidate(expand_template(tpl, mod_rel), candidates, seen);
				}
				if (sep == std::string_view::npos) break;
				pos = sep + 1;
			}
		}
		lua_pop(L, 1);

		// 2. Fallback to standard War3 MPQ layouts (root and script\).
		add_mpq_candidate(mod_rel + ".lua", candidates, seen);
		add_mpq_candidate(mod_rel + "\\init.lua", candidates, seen);
		add_mpq_candidate("script\\" + mod_rel + ".lua", candidates, seen);
		add_mpq_candidate("script\\" + mod_rel + "\\init.lua", candidates, seen);

		std::string err_msg;
		for (const std::string& cand : candidates) {
			if (!reader->has_file(reader->ctx, cand.c_str())) {
				err_msg.append("\n\tno mpq file '");
				err_msg.append(cand);
				err_msg.push_back('\'');
				continue;
			}

			const void* raw_buf = nullptr;
			size_t raw_len = 0;
			if (!reader->load_file(reader->ctx, cand.c_str(), &raw_buf, &raw_len) || !raw_buf) {
				err_msg.append("\n\tno mpq file '");
				err_msg.append(cand);
				err_msg.push_back('\'');
				continue;
			}

			const char* code = static_cast<const char*>(raw_buf);
			size_t code_len = raw_len;
			// Strip UTF-8 BOM: luaL_loadbuffer does not skip it automatically.
			if (code_len >= 3 &&
				static_cast<unsigned char>(code[0]) == 0xEF &&
				static_cast<unsigned char>(code[1]) == 0xBB &&
				static_cast<unsigned char>(code[2]) == 0xBF) {
				code += 3;
				code_len -= 3;
			}

			std::string chunkname = "@" + cand;
			int status = luaL_loadbuffer(L, code, code_len, chunkname.c_str());
			reader->unload_file(reader->ctx, raw_buf);

			if (status != LUA_OK) {
				return luaL_error(
					L,
					"error loading module '%s' from mpq file '%s':\n\t%s",
					name,
					cand.c_str(),
					lua_tostring(L, -1));
			}

			lua_pushlstring(L, cand.data(), cand.size());
			return 2;
		}

		lua_pushlstring(L, err_msg.data(), err_msg.size());
		return 1;
	}

	void install_mpq_searcher(lua_State* L, const MpqFileReader& reader)
	{
		if (lua_getglobal(L, "package") != LUA_TTABLE) {
			lua_pop(L, 1);
			return;
		}
		if (lua_getfield(L, -1, "searchers") != LUA_TTABLE) {
			lua_pop(L, 2);
			return;
		}

		// Insert at index 3 (after preload [1] and local-disk lua [2], before C loaders).
		lua_Integer len = luaL_len(L, -1);
		lua_Integer insert_at = (len >= 2) ? 3 : (len + 1);
		for (lua_Integer i = len; i >= insert_at; --i) {
			lua_rawgeti(L, -1, i);
			lua_rawseti(L, -2, i + 1);
		}
		lua_pushvalue(L, -2); // upvalue 1: package table
		auto* ud = static_cast<MpqFileReader*>(lua_newuserdatauv(L, sizeof(MpqFileReader), 0));
		*ud = reader;         // upvalue 2: reader callbacks
		lua_pushcclosure(L, searcher_mpq_lua, 2);
		lua_rawseti(L, -2, insert_at);

		lua_pop(L, 2); // pop searchers, package
	}

#ifndef JAPI_MPQ_SEARCHER_STANDALONE
	static bool storm_valid(void*) { return storm_s::instance().valid(); }
	static bool storm_has_file(void*, const char* path) { return storm_s::instance().has_file(path); }
	static bool storm_load_file(void*, const char* path, const void** buf, size_t* size) {
		return storm_s::instance().load_file(path, buf, size);
	}
	static void storm_unload_file(void*, const void* buf) {
		storm_s::instance().unload_file(buf);
	}

	int fix_baselib(lua_State* L)
	{
		lua_pushcfunction(L, print_to_log);
		lua_setglobal(L, "print");

		// Synchronize math.random / math.randomseed with War3's lockstep RNG
		if (lua_getglobal(L, "math") == LUA_TTABLE) {
			lua_pushcfunction(L, sync_math_random);
			lua_setfield(L, -2, "random");
			lua_pushcfunction(L, sync_math_randomseed);
			lua_setfield(L, -2, "randomseed");
		}
		lua_pop(L, 1);

		MpqFileReader reader {
			nullptr,
			&storm_valid,
			&storm_has_file,
			&storm_load_file,
			&storm_unload_file,
		};
		install_mpq_searcher(L, reader);
		return 0;
	}
#endif
}

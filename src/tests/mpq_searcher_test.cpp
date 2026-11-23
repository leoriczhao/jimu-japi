// mpq_searcher_test.cpp — Offline contract tests for MPQ require() searcher
// and Cheat("exec-lua:<module>") parser.

#include "lua_engine/lua_engine/fix_baselib.h"
#include <lua.hpp>
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>

using warcraft3::lua_engine::MpqFileReader;
using warcraft3::lua_engine::install_mpq_searcher;
using warcraft3::lua_engine::parse_exec_lua_cheat;

struct FakeMpq {
	bool available = true;
	std::unordered_map<std::string, std::string> files;
	int loads = 0;
	int unloads = 0;

	static std::string lower(const char* p) {
		std::string s(p ? p : "");
		std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
			return static_cast<char>(std::tolower(c));
		});
		return s;
	}

	void put(const char* path, std::string content) {
		files[lower(path)] = std::move(content);
	}
};

static bool fake_valid(void* ctx) { return static_cast<FakeMpq*>(ctx)->available; }
static bool fake_has(void* ctx, const char* path) {
	auto* m = static_cast<FakeMpq*>(ctx);
	return m->files.find(FakeMpq::lower(path)) != m->files.end();
}
static bool fake_load(void* ctx, const char* path, const void** buf, size_t* size) {
	auto* m = static_cast<FakeMpq*>(ctx);
	auto it = m->files.find(FakeMpq::lower(path));
	if (it == m->files.end()) return false;
	auto* copy = new std::string(it->second);
	*buf = copy->data();
	*size = copy->size();
	m->loads++;
	return true;
}
static void fake_unload(void* ctx, const void* buf) {
	auto* m = static_cast<FakeMpq*>(ctx);
	if (buf) m->unloads++;
	// Leak-free isn't needed for the tiny test strings, but keep count exact.
}

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg) do { \
	if (cond) { g_pass++; } \
	else { g_fail++; std::fprintf(stderr, "FAIL: %s (line %d)\n", (msg), __LINE__); } \
} while (0)

static bool run_lua(lua_State* L, const char* code, std::string* err_out = nullptr) {
	if (luaL_dostring(L, code) != LUA_OK) {
		if (err_out) *err_out = lua_tostring(L, -1) ? lua_tostring(L, -1) : "";
		lua_pop(L, 1);
		return false;
	}
	return true;
}

int main() {
	// 1. parse_exec_lua_cheat cases
	CHECK(parse_exec_lua_cheat("exec-lua:main") == "main", "plain exec-lua");
	CHECK(parse_exec_lua_cheat("exec-lua:  \"script.main\"  ") == "script.main", "double-quoted exec-lua");
	CHECK(parse_exec_lua_cheat("exec-lua:'app.entry'") == "app.entry", "single-quoted exec-lua");
	CHECK(parse_exec_lua_cheat("exec-lua:   ").empty(), "blank exec-lua ignored");
	CHECK(parse_exec_lua_cheat("whosyourdaddy").empty(), "non exec-lua ignored");
	CHECK(parse_exec_lua_cheat("exec-lua:").empty(), "empty exec-lua ignored");

	// 2. MPQ searcher tests
	FakeMpq mpq;
	mpq.put("foo\\bar.lua", "return { src = 'root-foo-bar', v = 42 }");
	mpq.put("pkg\\init.lua", "return { src = 'root-pkg-init' }");
	mpq.put("script\\solar\\app.lua", "local sub = require('foo.bar'); return { src = 'script-solar-app', v = sub.v + 1 }");
	mpq.put("script\\subpkg\\init.lua", "return { src = 'script-subpkg-init' }");
	mpq.put("custom\\override.lua", "return { src = 'custom-path' }");
	mpq.put("override.lua", "return { src = 'root-path' }");
	mpq.put("bom_mod.lua", std::string("\xEF\xBB\xBF") + "return { ok = true }");
	mpq.put("bad_syntax.lua", "return ??? invalid");
	mpq.put("shadowed.lua", "return { src = 'mpq' }");

	lua_State* L = luaL_newstate();
	luaL_openlibs(L);

	int top_before = lua_gettop(L);
	MpqFileReader reader { &mpq, &fake_valid, &fake_has, &fake_load, &fake_unload };
	install_mpq_searcher(L, reader);
	CHECK(lua_gettop(L) == top_before, "install_mpq_searcher preserves stack");

	// Verify searcher slot order (preload [1], disk [2], mpq [3])
	CHECK(run_lua(L, "assert(#package.searchers >= 5)"), "searchers length shifted cleanly");

	// Preload beats MPQ
	CHECK(run_lua(L,
		"package.preload['shadowed'] = function() return { src = 'preload' } end\n"
		"local m = require('shadowed')\n"
		"assert(m.src == 'preload')"), "package.preload takes priority over MPQ");

	// Root .lua and \init.lua
	CHECK(run_lua(L,
		"local m, path = require('foo.bar')\n"
		"assert(m.src == 'root-foo-bar' and m.v == 42)\n"
		"assert(path == 'foo\\\\bar.lua')"), "loads root foo\\bar.lua");

	CHECK(run_lua(L,
		"local m = require('pkg')\n"
		"assert(m.src == 'root-pkg-init')"), "loads root pkg\\init.lua");

	// script\ fallback and transitive require
	CHECK(run_lua(L,
		"local m, path = require('solar.app')\n"
		"assert(m.src == 'script-solar-app' and m.v == 43)\n"
		"assert(path == 'script\\\\solar\\\\app.lua')"), "loads script\\solar\\app.lua + transitive require");

	CHECK(run_lua(L,
		"local m = require('subpkg')\n"
		"assert(m.src == 'script-subpkg-init')"), "loads script\\subpkg\\init.lua");

	// package.path customization takes priority over default fallback
	CHECK(run_lua(L,
		"package.path = 'custom/?.lua;' .. package.path\n"
		"local m, path = require('override')\n"
		"assert(m.src == 'custom-path' and path == 'custom\\\\override.lua')"),
		"custom package.path beats default fallback");

	// UTF-8 BOM stripped
	CHECK(run_lua(L,
		"local m = require('bom_mod')\n"
		"assert(m.ok == true)"), "strips UTF-8 BOM from MPQ lua");

	// Syntax error reports error and still calls unload_file
	std::string err;
	int unloads_before = mpq.unloads;
	CHECK(!run_lua(L, "require('bad_syntax')", &err), "syntax error fails require");
	CHECK(err.find("bad_syntax.lua") != std::string::npos, "syntax error names MPQ file");
	CHECK(mpq.unloads == unloads_before + 1, "syntax error still unloads Storm buffer");

	// Missing module error mentions mpq search paths
	err.clear();
	CHECK(!run_lua(L, "require('does.not.exist')", &err), "missing module fails require");
	CHECK(err.find("no mpq file 'script\\does\\not\\exist.lua'") != std::string::npos,
		"missing module error lists mpq candidates");

	// Caching via package.loaded (no extra load on second require)
	int loads_before = mpq.loads;
	CHECK(run_lua(L, "assert(require('foo.bar').v == 42)"), "second require hits package.loaded");
	CHECK(mpq.loads == loads_before, "cached module does not re-read Storm");

	// Every load was paired with an unload
	CHECK(mpq.loads == mpq.unloads, "all Storm buffers unloaded");

	lua_close(L);

	std::printf("mpq_searcher_test: %d passed, %d failed\n", g_pass, g_fail);
	return g_fail == 0 ? 0 : 1;
}

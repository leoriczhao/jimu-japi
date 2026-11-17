// libs_slk.cpp — jass.slk module (SlkLib version)
//
// Provides lazy-loaded access to game data tables (ability, unit, item, etc.)
// by reading SLK/TXT files from the game's MPQ archives via SlkLib + Storm API.
//
// Usage:
//   local slk = require "jass.slk"
//   print(slk.ability["AHbz"].code)  --> "AHbz"
//   print(slk.unit["hfoo"].race)     --> "human"

#include <lua.hpp>
#include <slk/ObjectManager.hpp>
#include <slk/storm_adapter.hpp>
#include <slk/table/SlkTable.hpp>
#include <cstdint>
#include <string>
#include <memory>
#include <cstdio>
#include "debug_log.h"

namespace warcraft3::lua_engine::slk {

// ── Singleton ObjectManager ────────────────────────────────────

static ::slk::StormAdapter& get_storm_adapter()
{
	static ::slk::StormAdapter adapter;
	return adapter;
}

static ::slk::ObjectManager& get_object_manager()
{
	static ::slk::ObjectManager mgr(get_storm_adapter());
	return mgr;
}

// ── Type mapping ───────────────────────────────────────────────

enum slk_type_index {
	SLK_ABILITY = 0,
	SLK_BUFF,
	SLK_UNIT,
	SLK_ITEM,
	SLK_UPGRADE,
	SLK_DOODAD,
	SLK_DESTRUCTABLE,
	SLK_MISC,
	SLK_TYPE_COUNT
};

static const char* slk_type_names[SLK_TYPE_COUNT] = {
	"ability", "buff", "unit", "item", "upgrade", "doodad", "destructable", "misc"
};

// ── Cached SlkTable per type ───────────────────────────────────

static const char* SLK_CACHE_KEY = "_SLK_OBJECT_CACHE";

static ::slk::SlkTable* get_or_load_table(lua_State* L, int type_idx)
{
	// Check registry cache
	lua_getfield(L, LUA_REGISTRYINDEX, SLK_CACHE_KEY);
	if (!lua_istable(L, -1)) {
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushvalue(L, -1);
		lua_setfield(L, LUA_REGISTRYINDEX, SLK_CACHE_KEY);
	}
	lua_rawgeti(L, -1, type_idx + 1);
	if (!lua_isnil(L, -1)) {
		::slk::SlkTable* ptr = (::slk::SlkTable*)lua_touserdata(L, -1);
		lua_pop(L, 2);  // pop userdata and cache table
		return ptr;
	}
	lua_pop(L, 2);  // pop nil and cache table

	// Load from ObjectManager
	auto& mgr = get_object_manager();
	std::unique_ptr<::slk::SlkTable> table(new ::slk::SlkTable);

	// Prefer the object-aware load: base game data merged with the map's own
	// war3map.w3* object data (ObjectManagerLoadObjectTable falls back to the
	// base tables alone when the map ships no object files, e.g. foreign maps).
	bool loaded = true;
	switch (type_idx) {
	case SLK_ABILITY:
		loaded = mgr.load(::slk::ROBJECT_TYPE::ABILITY, *table);
		break;
	case SLK_BUFF:
		loaded = mgr.load(::slk::ROBJECT_TYPE::BUFF, *table);
		break;
	case SLK_UNIT:
		loaded = mgr.load(::slk::ROBJECT_TYPE::UNIT, *table);
		break;
	case SLK_ITEM:
		loaded = mgr.load(::slk::ROBJECT_TYPE::ITEM, *table);
		break;
	case SLK_UPGRADE:
		loaded = mgr.load(::slk::ROBJECT_TYPE::UPGRADE, *table);
		break;
	case SLK_DOODAD:
		loaded = mgr.load(::slk::ROBJECT_TYPE::DOODAD, *table);
		break;
	case SLK_DESTRUCTABLE:
		loaded = mgr.load(::slk::ROBJECT_TYPE::DESTRUCTABLE, *table);
		break;
	case SLK_MISC:
		// MiscData.txt + MiscData_Units.txt + MiscGameData.txt + the map's own
		// war3mapmisc.txt merged on top: slk.misc.Misc.DefenseArmor etc.
		loaded = mgr.load(::slk::ROBJECT_TYPE::MISC, *table);
		break;
	default:
		return nullptr;
	}

	if (!loaded) {
		// Object data path failed: retry with the plain base-table loaders.
		table.reset(new ::slk::SlkTable);
		switch (type_idx) {
		case SLK_ABILITY:
			mgr.load_ability(*table);
			break;
		case SLK_BUFF:
			mgr.load_buff(*table);
			break;
		case SLK_UNIT:
			mgr.load_unit(*table);
			break;
		case SLK_ITEM:
			mgr.load_item(*table);
			break;
		case SLK_UPGRADE:
			mgr.load_upgrde(*table);
			break;
		case SLK_DOODAD:
			mgr.load_doodad(*table);
			break;
		case SLK_DESTRUCTABLE:
			mgr.load_destructable(*table);
			break;
		case SLK_MISC:
			mgr.load_misc(*table);
			break;
		}
	}

	::slk::SlkTable* raw = table.release();

	// Store in registry cache as light userdata
	lua_getfield(L, LUA_REGISTRYINDEX, SLK_CACHE_KEY);
	lua_pushlightuserdata(L, raw);
	lua_rawseti(L, -2, type_idx + 1);
	lua_pop(L, 1);

	return raw;
}

// ── Lua metamethods ────────────────────────────────────────────

// row.__index(row_table, field_name) -> value
// SlkSingle pointer is carried as the closure's upvalue so the row proxy
// itself can be a plain Lua table (tests and builtin-japi both expect tables).
// Field lookup is case-insensitive (builtin-japi main.lua uses data.Hotkey).
static int row_index(lua_State* L)
{
	::slk::SlkSingle* single = (::slk::SlkSingle*)lua_touserdata(L, lua_upvalueindex(1));
	if (!single) { lua_pushnil(L); return 1; }

	const char* field = luaL_checkstring(L, 2);
	for (auto i = single->begin(); i != single->end(); ++i) {
		if (_stricmp(i->first.c_str(), field) == 0) {
			lua_pushstring(L, i->second.to_string().c_str());
			return 1;
		}
	}
	lua_pushnil(L);
	return 1;
}

// type.__index(self, object_id) -> row proxy (table with __index closure)
static void push_row_proxy(lua_State* L, ::slk::SlkSingle* single_ptr);

static int type_index(lua_State* L)
{
	int type_idx = -1;

	// Get type_idx from metatable
	lua_getmetatable(L, 1);
	lua_getfield(L, -1, "_type_idx");
	type_idx = (int)lua_tointeger(L, -1);
	lua_pop(L, 2);

	if (type_idx < 0 || type_idx >= SLK_TYPE_COUNT) {
		lua_pushnil(L);
		return 1;
	}

	// Object keys may be passed either as a 4-char id string ('hfoo') or as the
	// integer rawcode returned by natives such as GetDestructableTypeId /
	// GetUnitTypeId. Accept both, matching the YDWE slk library behaviour.
	char id_buf[8] = { 0 };
	const char* obj_id = nullptr;
	if (lua_type(L, 2) == LUA_TNUMBER) {
		uint32_t raw = (uint32_t)lua_tointeger(L, 2);
		// Rawcodes are big-endian in their integer form: 'YTfb' == 0x59546662.
		id_buf[0] = (char)((raw >> 24) & 0xFF);
		id_buf[1] = (char)((raw >> 16) & 0xFF);
		id_buf[2] = (char)((raw >> 8) & 0xFF);
		id_buf[3] = (char)((raw) & 0xFF);
		id_buf[4] = '\0';
		obj_id = id_buf;
	}
	else {
		obj_id = luaL_checkstring(L, 2);
	}

	::slk::SlkTable* table = get_or_load_table(L, type_idx);
	if (!table) {
		lua_pushnil(L);
		return 1;
	}

	// Search by string key (iterate for compatibility with SlkTable hash)
	auto it = table->end();
	for (auto i = table->begin(); i != table->end(); ++i) {
		if (i->first.to_string() == obj_id) {
			it = i;
			break;
		}
	}
	if (it == table->end()) {
		// Diagnostics: dump size + first keys when a lookup misses
		static int dump_count = 0;
		if (dump_count < 6) {
			dump_count++;
			std::string keys;
			int n = 0;
			for (auto i = table->begin(); i != table->end() && n < 4; ++i, ++n) {
				keys += "[";
				keys += i->first.to_string();
				keys += "] ";
			}
			DBG_LOG("[slk] MISS '%s' type=%d size=%d first: %s",
				obj_id, type_idx, (int)table->size(), keys.c_str());
		}
		lua_pushnil(L);
		return 1;
	}

	::slk::SlkSingle* single_ptr = &it->second;
	push_row_proxy(L, single_ptr);
	return 1;
}

// ── pairs() iteration over a type table ────────────────────────

struct pairs_state {
	::slk::SlkTable* table;
	::slk::SlkTable::iterator it;
};

static void push_row_proxy(lua_State* L, ::slk::SlkSingle* single_ptr)
{
	lua_newtable(L);              // row proxy: a real Lua table
	lua_newtable(L);              // its metatable
	lua_pushlightuserdata(L, single_ptr);
	lua_pushcclosure(L, row_index, 1);
	lua_setfield(L, -2, "__index");
	lua_setmetatable(L, -2);
}

static int slk_pairs_iter(lua_State* L)
{
	pairs_state* st = (pairs_state*)lua_touserdata(L, 1);
	if (!st || !st->table) return 0;
	if (st->it == st->table->end()) return 0;

	std::string key = st->it->first.to_string();
	::slk::SlkSingle* single_ptr = &st->it->second;
	++st->it;

	lua_pushlstring(L, key.data(), key.size());
	push_row_proxy(L, single_ptr);
	return 2;
}

static int type_pairs(lua_State* L)
{
	lua_getmetatable(L, 1);
	lua_getfield(L, -1, "_type_idx");
	int type_idx = (int)lua_tointeger(L, -1);
	lua_pop(L, 2);

	if (type_idx < 0 || type_idx >= SLK_TYPE_COUNT) return 0;

	::slk::SlkTable* table = get_or_load_table(L, type_idx);
	if (!table) return 0;

	pairs_state* st = (pairs_state*)lua_newuserdata(L, sizeof(pairs_state));
	st->table = table;
	new (&st->it) ::slk::SlkTable::iterator(table->begin());

	lua_pushcfunction(L, slk_pairs_iter);
	lua_pushvalue(L, -2);  // state userdata
	lua_pushnil(L);
	return 3;
}

// ── Module entry ───────────────────────────────────────────────

int open(lua_State* L)
{
	lua_newtable(L);  // slk table

	for (int i = 0; i < SLK_TYPE_COUNT; i++) {
		lua_newtable(L);  // type proxy

		lua_newtable(L);  // metatable
		lua_pushinteger(L, i);
		lua_setfield(L, -2, "_type_idx");
		lua_pushcfunction(L, type_index);
		lua_setfield(L, -2, "__index");
		lua_pushcfunction(L, type_pairs);
		lua_setfield(L, -2, "__pairs");
		lua_setmetatable(L, -2);

		lua_setfield(L, -2, slk_type_names[i]);
	}

	return 1;
}

}  // namespace warcraft3::lua_engine::slk

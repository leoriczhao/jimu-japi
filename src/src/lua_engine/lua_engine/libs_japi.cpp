#include "jassbind.h"
#include "common.h"
#include <warcraft3/jass/func_value.h>
#include <base/lua/range.h>
#include <map>
#include <string>
#include <warcraft3/jass/hook.h>
#include "lua_to_nativefunction.h"
#include "bridge_dispatch.h"

namespace base::lua {
	template <>
	inline int convert_to_lua(lua_State* L, const warcraft3::jass::func_value& v)
	{
		lua_pushinteger(L, (uint32_t)(uintptr_t)&v);
		lua_pushcclosure(L, warcraft3::lua_engine::jass_call_closure, 1);
		return 1;
	}
}


namespace warcraft3::lua_engine::japi {

	int empty_function(lua_State*, void*)
	{
		return 0;
	}

	struct japi
	{
		typedef lua_to_nativefunction<empty_function> mybase;

		jass::func_value funcdef;
		japi(lua_State*L, int luaobj, const char* name, const char* def)
			: funcdef(def, 0)
			, base_(new mybase(L, luaobj, &funcdef, 0))
		{
			jass::japi_table_add((uintptr_t)base_->funcentry, name, def);
		}

		~japi() { delete base_; }
		static const char* name() { return "japi_t"; }

		mybase* base_;
	};

	int japi_index(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 2);
		// Bridge handlers win over natives for the same name. P3-E1 registers the
		// EX*/game-info surface as real natives too (so JASS and jass.debug see
		// them), but the native call path converts a *string* return through
		// string_table the compiled-JASS way, while our EX getters hand back a
		// fresh jstring_t. The bridge marshalling is the tested one (P1), so keep
		// Lua on it. Maps written for YDWE call these as
		// `jass.japi.EXSetAbilityDataReal(...)`.
		if (bridge::push_cpp_handler(L, name)) {
			return 1;
		}
		jass::func_value const* nf = jass::japi_func(name);
		if (nf) {
			lua_pushinteger(L, (uint32_t)(uintptr_t)nf);
			lua_pushcclosure(L, jass_call_closure, 1);
			return 1;
		}
		lua_pushnil(L);
		return 1;
	}

	int japi_newindex(lua_State* /*L*/)
	{
		return 0;
	}

	int japi_call(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 2);
		const char* def = luaL_checkstring(L, 3);
		luaL_checktype(L, 4, LUA_TFUNCTION);
		if (strcmp(name, "info") == 0 || strcmp(name, "counts") == 0) {
			return luaL_error(L, "japi: '%s' is reserved for diagnostics", name);
		}
		if (jass::japi_func(name)) {
			return luaL_error(L, "japi: '%s' is already registered", name);
		}

		runtime::get_global_table(L, "_JASS_JAPI_TABLE", false);
		lua_pushstring(L, name);
		lua_rawget(L, -2);
		japi* self = (japi*)luaL_testudata(L, -1, japi::name());
		if (self) {
			return luaL_error(L, "japi: '%s' is already registered", name);
		}
		lua_pop(L, 1);

		// The same name is also reachable as UnitId("Name") + hashtable RPC,
		// the builtin-japi pattern used by precompiled war3map.j wrappers.
		// Do not let a Lua handler silently shadow a built-in C++ handler.
		if (bridge::has_handler(name)) {
			return luaL_error(L, "japi: '%s' conflicts with an existing bridge handler", name);
		}

		lua_pushstring(L, name);
		self = (japi*)lua_newuserdata(L, sizeof(japi));
		int luaobj = runtime::callback_push(L, 4);
		new (self)japi(L, luaobj, name, def);
		luaL_setmetatable(L, japi::name());
		lua_rawset(L, -3);

		// The native table entry above serves Lua-side japi.Name() calls; this
		// one serves precompiled JASS wrappers that call UnitId("Name").
		bridge::register_handler(L, name, def, 4);
		return 0;
	}

	int japi_pairs(lua_State* L)
	{
		return base::lua::make_range(L, jass::japi_function);
	}

	// jass.japi.info(name) — report which of the three registries owns a name
	// and which Lua/JASS routes can reach it. This is a snapshot of the live
	// maps, not a promise about map-side wrappers or compiled JASS symbols.
	int japi_info(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 1);

		// Reading jass_function initializes the lazy Game.dll native scan.
		jass::func_value const* engine = jass::jass_func(name);
		jass::func_value const* native = jass::japi_func(name);
		std::string bridge_spec;
		bool bridge_is_lua = false;
		const bool has_bridge =
			bridge::handler_describe(name, &bridge_spec, &bridge_is_lua);

		if (!engine && !native && !has_bridge) {
			lua_pushnil(L);
			return 1;
		}

		lua_newtable(L);
		lua_pushstring(L, name);
		lua_setfield(L, -2, "name");

		auto push_spec = [L](const char* field, const jass::func_value* nf) {
			if (!nf) return;
			lua_newtable(L);
			lua_pushstring(L, nf->get_spec());
			lua_setfield(L, -2, "spec");
			lua_setfield(L, -2, field);
		};
		push_spec("engine_native", engine);
		push_spec("japi_native", native);

		if (has_bridge) {
			lua_newtable(L);
			lua_pushstring(L, bridge_is_lua ? "lua" : "cpp");
			lua_setfield(L, -2, "kind");
			lua_pushstring(L, bridge_spec.c_str());
			lua_setfield(L, -2, "spec");
			lua_setfield(L, -2, "bridge");
		}

		lua_newtable(L);
		const auto set_bool = [L](const char* field, bool value) {
			lua_pushboolean(L, value);
			lua_setfield(L, -2, field);
		};
		// A route means "resolvable in this path", not "the map declared it".
		set_bool("lua_common", engine != nullptr);
		set_bool("lua_call", engine != nullptr || native != nullptr);
		set_bool("lua_japi",
			(has_bridge && !bridge_is_lua) || native != nullptr);
		set_bool("jass_native", engine != nullptr);
		set_bool("jass_unitid", has_bridge);
		lua_setfield(L, -2, "routes");

		lua_newtable(L);
		const auto set_effective = [L](const char* field, const char* spec) {
			if (spec) lua_pushstring(L, spec);
			else lua_pushnil(L);
			lua_setfield(L, -2, field);
		};
		const jass::func_value* call_effective = engine ? engine : native;
		const char* japi_effective = nullptr;
		if (has_bridge && !bridge_is_lua) japi_effective = bridge_spec.c_str();
		else if (native) japi_effective = native->get_spec();
		set_effective("lua_common", engine ? engine->get_spec() : nullptr);
		set_effective("lua_call", call_effective ? call_effective->get_spec() : nullptr);
		set_effective("lua_japi", japi_effective);
		lua_setfield(L, -2, "effective");
		return 1;
	}

	// jass.japi.counts() — live registry cardinalities and bridge readiness.
	int japi_counts(lua_State* L)
	{
		// Force the lazy engine-native scan before counting, even when no
		// name has been looked up yet.
		jass::jass_func("Deg2Rad");

		size_t engine_natives = 0;
		for (const auto& [key, value] : jass::jass_function) {
			(void)key;
			if (value.is_valid()) ++engine_natives;
		}
		size_t japi_natives = 0;
		for (const auto& [key, value] : jass::japi_function) {
			(void)key;
			if (value.is_valid()) ++japi_natives;
		}

		lua_newtable(L);
		const auto set_int = [L](const char* field, size_t value) {
			lua_pushinteger(L, static_cast<lua_Integer>(value));
			lua_setfield(L, -2, field);
		};
		set_int("engine_natives", engine_natives);
		set_int("japi_natives", japi_natives);
		set_int("bridge_handlers", bridge::handler_count());
		set_int("bridge_cpp", bridge::cpp_handler_count());
		set_int("bridge_lua", bridge::lua_handler_count());
		lua_pushboolean(L, bridge::handshake_ready());
		lua_setfield(L, -2, "handshake");
		lua_pushboolean(L, bridge::unitid_hooked());
		lua_setfield(L, -2, "unitid_hook");
		return 1;
	}

	static int mt_gc(lua_State *L)
	{
		japi* self = (japi*)luaL_testudata(L, 1, japi::name());
		if (self) {
			self->~japi();
		}
		return 0;
	}

	int open(lua_State* L)
	{
		luaL_Reg mt1[] = {
			{ "__gc", mt_gc },
			{ NULL, NULL },
		};

		luaL_newmetatable(L, japi::name());
		luaL_setfuncs(L, mt1, 0);
		lua_pop(L, 1);

		lua_newtable(L);
		{
			// Raw fields are checked before __index. They intentionally shadow
			// bridge handlers named "info"/"counts"; none exist today.
			lua_pushstring(L, "info");
			lua_pushcclosure(L, japi_info, 0);
			lua_rawset(L, -3);

			lua_pushstring(L, "counts");
			lua_pushcclosure(L, japi_counts, 0);
			lua_rawset(L, -3);

			lua_newtable(L);
			{
				lua_pushstring(L, "__index");
				lua_pushcclosure(L, japi_index, 0);
				lua_rawset(L, -3);

				lua_pushstring(L, "__newindex");
				lua_pushcclosure(L, japi_newindex, 0);
				lua_rawset(L, -3);

				lua_pushstring(L, "__call");
				lua_pushcclosure(L, japi_call, 0);
				lua_rawset(L, -3);

				lua_pushstring(L, "__pairs");
				lua_pushcclosure(L, japi_pairs, 0);
				lua_rawset(L, -3);
			}
			lua_setmetatable(L, -2);
		}
		return 1;
	}
}

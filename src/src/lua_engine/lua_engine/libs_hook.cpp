#include <map>
#include <string>
#include <memory>
#include <base/hook/assembler/writer.h>
#include <base/util/noncopyable.h>
#include <base/util/horrible_cast.h>
#include <warcraft3/jass.h>
#include <warcraft3/jass/func_value.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/war3_searcher.h>
#include "jassbind.h"
#include "callback.h"
#include "libs_runtime.h"
#include "common.h"
#include "lua_to_nativefunction.h"

namespace warcraft3::lua_engine::hook {

	class jhook_t
	{
	public:
		jhook_t()
			: base_(nullptr)
			, name_()
			, real_func_(0)
			, lua_(nullptr)
			, luaobj_(0)
		{ }

		~jhook_t()
		{
			uninstall();
		}

		bool install(lua_State* L, const jass::func_value* funcdef, const char* name, int luaobj)
		{
			if (base_)
			{
				if (!uninstall()) {
					return false;
				}
			}
			name_ = name;
			base_ = new nfunction(L, luaobj, funcdef, this);
			if (!jass::table_hook(name_.c_str(), &real_func_, (uintptr_t)base_->funcentry)) {
				delete base_;
				base_ = nullptr;
				runtime::callback_release(L, luaobj);
				return false;
			}
			// Also redirect Lua-side dispatch: the func_value maps cache native
			// addresses, and table_hook only touches the game's native hashtable.
			// Overwrite the cached entry with a copy pointing at the hook, so
			// jass.call()/metatable calls hit the hook too (restored in uninstall).
			auto jf = jass::jass_function.find(name_);
			if (jf != jass::jass_function.end()) {
				jf->second = jass::func_value(jf->second, (uintptr_t)base_->funcentry);
			}
			auto jp = jass::japi_function.find(name_);
			if (jp != jass::japi_function.end()) {
				jp->second = jass::func_value(jp->second, (uintptr_t)base_->funcentry);
			}
			// Release through the main thread, not the (possibly coroutine) state
			// that installed the hook: the coroutine may be collected long before
			// the hook is uninstalled, and the registry is shared anyway.
			lua_ = get_mainthread(L);
			if (!lua_) lua_ = L;
			luaobj_ = luaobj;
			return true;
		}

		bool uninstall()
		{
			if (!base_)
			{
				release_luaobj();
				return true;
			}
			if (base_->active_calls != 0) return false;
			jass::table_unhook(name_.c_str(), &real_func_, 0);
			// Restore the cached addresses (see install).
			auto jf = jass::jass_function.find(name_);
			if (jf != jass::jass_function.end()) {
				jf->second = jass::func_value(jf->second, real_func_);
			}
			auto jp = jass::japi_function.find(name_);
			if (jp != jass::japi_function.end()) {
				jp->second = jass::func_value(jp->second, real_func_);
			}
			delete base_;
			base_ = nullptr;
			release_luaobj();
			return true;
		}

		int push_luaobj(lua_State* L) const
		{
			if (base_)
			{
				runtime::callback_read(L, base_->luaobj);
			}
			else
			{
				lua_pushnil(L);
			}
			return 1;
		}

		bool installed() const
		{
			return base_ != nullptr;
		}

		static int call_real_function(lua_State* L)
		{
			jhook_t* self = static_cast<jhook_t*>(lua_touserdata(L, lua_upvalueindex(1)));
			if (!self || !self->installed()) {
				return luaL_error(L, "hook: original function is no longer installed");
			}
			return jass_call_native_function(L, self->base_->funcdef, self->real_func_);
		}

		static int push_real_function(lua_State* L, void* userdata)
		{
			// Pin the userdata, not a raw pointer: an escaped orig closure must
			// fail safely after unhook, even after the registry entry is removed.
			auto* self = static_cast<jhook_t*>(userdata);
			runtime::get_global_table(L, "_JASS_HOOK_TABLE", false);
			lua_getfield(L, -1, self->name_.c_str());
			lua_remove(L, -2);
			lua_pushcclosure(L, call_real_function, 1);
			return 1;
		}

		typedef lua_to_nativefunction<jhook_t::push_real_function> nfunction;

	private:
		void release_luaobj()
		{
			if (lua_ && luaobj_ != 0)
			{
				runtime::callback_release(lua_, luaobj_);
			}
			luaobj_ = 0;
		}

		nfunction*  base_;
		std::string name_;
		uintptr_t   real_func_;
		lua_State*  lua_;
		int         luaobj_;
	};

#define LUA_JASS_HOOK "jhook_t"

	static jhook_t* get_jhook(lua_State* L, const char* name)
	{
		runtime::get_global_table(L, "_JASS_HOOK_TABLE", false);
		lua_pushstring(L, name);
		lua_rawget(L, -2);
		return (jhook_t*)luaL_testudata(L, -1, LUA_JASS_HOOK);
	}

	// Drop the registration entry. Kept separate because get_jhook() leaves the
	// registry table and the hook object on the stack: using those positions for
	// a rawset would target the userdata instead of the table.
	static void remove_hook_entry(lua_State* L, const char* name)
	{
		runtime::get_global_table(L, "_JASS_HOOK_TABLE", false);
		lua_pushstring(L, name);
		lua_pushnil(L);
		lua_rawset(L, -3);
		lua_pop(L, 1);
	}

	static int mt_newindex(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 2);
		const jass::func_value* funcdef = jass::jass_func(name);
		if (!funcdef || !funcdef->is_valid()) {
			return 0;
		}

		jhook_t* self = get_jhook(L, name);
		if (self && !self->uninstall()) {
			return luaL_error(L, "hook: '%s' is executing; defer replacement/removal until it returns", name);
		}

		if (lua_isfunction(L, 3)) {
			if (!self) {
				runtime::get_global_table(L, "_JASS_HOOK_TABLE", false);
				lua_pushstring(L, name);
				self = (jhook_t*)lua_newuserdata(L, sizeof(jhook_t));
				new (self)jhook_t;
				luaL_setmetatable(L, LUA_JASS_HOOK);
				lua_rawset(L, -3);
			}

			int luaobj = runtime::callback_push(L, 3);
			if (!self->install(L, funcdef, name, luaobj)) {
				// install() already released luaobj. Drop the dead entry so a
				// later hook(name, fn) is not rejected as "already hooked".
				remove_hook_entry(L, name);
			}
		} else if (self) {
			// Assigning nil (or any non-function) unhooks: uninstall() ran above,
			// and the entry is dropped so a later hook.hook(name, fn) is not
			// rejected as "already hooked".
			remove_hook_entry(L, name);
		}
		return 0;
	}

	static int mt_index(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 2);
		jhook_t* self = get_jhook(L, name);
		if (self) {
			return self->push_luaobj(L);
		}
		lua_pushnil(L);
		return 1;
	}

	static int mt_gc(lua_State *L)
	{
		jhook_t* self = (jhook_t*)luaL_testudata(L, 1, LUA_JASS_HOOK);
		if (self) {
			self->~jhook_t();
		}
		return 0;
	}

	// hook.hook(name, fn) - function-style API (mirrors the builtin-japi usage).
	// Errors on unknown natives and on double-hooking.
	static int fn_hook(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 1);
		luaL_checktype(L, 2, LUA_TFUNCTION);

		const jass::func_value* funcdef = jass::jass_func(name);
		if (!funcdef) funcdef = jass::japi_func(name);
		if (!funcdef || !funcdef->is_valid()) {
			return luaL_error(L, "hook: unknown native '%s'", name);
		}

		if (get_jhook(L, name)) {
			return luaL_error(L, "hook: '%s' is already hooked", name);
		}
		lua_settop(L, 2);  // drop table + result left by get_jhook

		runtime::get_global_table(L, "_JASS_HOOK_TABLE", false);
		lua_pushstring(L, name);
		jhook_t* self = (jhook_t*)lua_newuserdata(L, sizeof(jhook_t));
		new (self)jhook_t;
		luaL_setmetatable(L, LUA_JASS_HOOK);
		lua_rawset(L, -3);

		int luaobj = runtime::callback_push(L, 2);
		if (!self->install(L, funcdef, name, luaobj)) {
			// Remove the dead entry (table is at stack top)
			lua_pushstring(L, name);
			lua_pushnil(L);
			lua_rawset(L, -3);
			return luaL_error(L, "hook: failed to install on '%s'", name);
		}
		return 0;
	}

	// hook.unhook(name) - remove a previously installed hook.
	// Returns true once (the hook was live), false for repeats/unknown names.
	static int fn_unhook(lua_State* L)
	{
		const char* name = luaL_checkstring(L, 1);
		jhook_t* self = get_jhook(L, name);
		bool removed = false;
		if (self) {
			removed = self->installed();
			if (!self->uninstall()) {
				return luaL_error(L, "hook: '%s' is executing; defer removal until it returns", name);
			}
			// Remove the table entry so re-hooking is allowed.
			remove_hook_entry(L, name);
		}
		lua_pushboolean(L, removed);
		return 1;
	}

	int open(lua_State* L)
	{
		luaL_Reg mt1[] = {
			{ "__gc", mt_gc },
			{ NULL, NULL },
		};

		luaL_newmetatable(L, LUA_JASS_HOOK);
		luaL_setfuncs(L, mt1, 0);
		lua_pop(L, 1);

		lua_newtable(L);
		{
			lua_pushstring(L, "hook");
			lua_pushcclosure(L, fn_hook, 0);
			lua_rawset(L, -3);

			lua_pushstring(L, "unhook");
			lua_pushcclosure(L, fn_unhook, 0);
			lua_rawset(L, -3);
		}
		luaL_Reg mt2[] = {
			{ "__index", mt_index },
			{ "__newindex", mt_newindex },
			{ NULL, NULL },
		};
		luaL_newlib(L, mt2);
		lua_setmetatable(L, -2);
		return 1;
	}
}

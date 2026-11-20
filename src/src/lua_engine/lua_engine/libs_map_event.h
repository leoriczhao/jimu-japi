#pragma once
#include <lua.hpp>
#include <cstddef>

namespace warcraft3::lua_engine::mapevent {
	int  open(lua_State* L);
	size_t emit(const char* name);   // dispatch to every subscriber
	void reset();                    // drop subscriptions (VM is going away)
}

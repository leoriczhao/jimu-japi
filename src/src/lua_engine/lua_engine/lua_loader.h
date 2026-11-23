#pragma once

#include <cstdint>
#include <warcraft3/jass.h>

struct lua_State;

namespace warcraft3::lua_engine::lua_loader {
	void initialize();
	lua_State* getMainL();
	void load_script();
	void install_lazy_hook();
	void install_cheat_hook();
	void install_abilityid_hook();
	uint32_t LoadScript_bridge(const uint32_t* args, size_t nargs);

	// VM / map lifecycle (builtin-japi's register_game_reset_event).
	// Every map boot destroys the previous Lua state, exactly like
	// builtin-japi does with lua_close(mainL); mainL = 0. jass_engine_alive
	// tells whether the JASS VM survived (true only for the in-process
	// "simulate map boot" bridge used by the regression suite; a real map
	// reboot invalidates every JASS handle and the JASS VM is fresh).
	void on_map_boot(bool jass_engine_alive);
	void load_script_file(const char* mpq_path);
	void close_vm(const char* reason);
	int  map_boot_count();
}

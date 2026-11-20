#pragma once

namespace warcraft3::japi {

	// True when another JAPI loader is already inside the process (builtin-japi's
	// jass.dll / lua_engine.dll, or YDWE's yd_jass_api.dll / yd_lua_engine.dll).
	// Set once by Initialize(); every invasive hook consults it and stands down,
	// the way builtin-japi skips its whole D3D block when QB_inject.dll is
	// present (jass.dll 0x1003F201).
	bool coexistence_mode();
	void set_coexistence_mode(bool on);

}

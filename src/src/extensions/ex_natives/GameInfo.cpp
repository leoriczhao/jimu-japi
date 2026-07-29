// GameInfo.cpp — Game info natives (GetMapName, GetGameVersion, GetPluginVersion)
// Ported from builtin-japi war3map.j API surface.

#include <warcraft3/jass.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/war3_searcher.h>
#include <warcraft3/hashtable.h>
#include <cstdio>

namespace warcraft3::japi {

	static char g_map_name_buf[512];

	// GetMapName() -> string
	// Returns the current map name. Reads from war3map.w3i or uses GetObjectName.
	static jass::jstring_t __cdecl GetMapName()
	{
		// Native string returns are string IDs — resolve to a handle before
		// from_string(), or the ID gets dereferenced as a pointer and crashes.
		uint32_t id = jass::call("GetObjectName");
		const char* name = nullptr;
		if (id) {
			name = jass::from_string((jass::jstring_t)get_jass_vm()->string_table->get(id));
		}
		if (name && name[0]) {
			return jass::create_string(name);
		}
		return jass::create_string("Unknown Map");
	}

	// GetGameVersion() -> integer
	// Returns the War3 version number (e.g. 6374 for 1.27a, 6401 for 1.27b)
	static int32_t __cdecl GetGameVersion()
	{
		return (int32_t)warcraft3::get_war3_searcher().get_version();
	}

	// GetPluginVersion() -> string
	// Returns the plugin version string.
	static jass::jstring_t __cdecl GetPluginVersion()
	{
		return jass::create_string("1.0.0");
	}

	// Hex(value) -> string
	// Formats an integer as an 8-digit uppercase hex string (builtin-japi parity).
	static jass::jstring_t __cdecl Hex(int32_t v)
	{
		char buf[16];
		snprintf(buf, sizeof(buf), "%08X", (uint32_t)v);
		return jass::create_string(buf);
	}

	void InitializeGameInfo()
	{
		jass::japi_add((uintptr_t)GetMapName, "GetMapName", "()S");
		jass::japi_add((uintptr_t)GetGameVersion, "GetGameVersion", "()I");
		jass::japi_add((uintptr_t)GetPluginVersion, "GetPluginVersion", "()S");
		jass::japi_add((uintptr_t)Hex, "Hex", "(I)S");
	}

	// Bridge dispatch handlers
	uint32_t GetMapName_handler(const uint32_t*, size_t) {
		return GetMapName();
	}
	uint32_t GetGameVersion_handler(const uint32_t*, size_t) {
		return (uint32_t)GetGameVersion();
	}
	uint32_t GetPluginVersion_handler(const uint32_t*, size_t) {
		return GetPluginVersion();
	}
	uint32_t Hex_handler(const uint32_t* a, size_t) {
		return Hex((int32_t)a[0]);
	}
}

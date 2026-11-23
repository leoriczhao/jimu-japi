// BuiltinCompat.cpp — natives builtin-japi's jass.dll has and we were missing.
//
// Sources (see docs/re-builtin-japi/09 + 10, and the address annotations below):
//   timer_start / timer_end / timer_destroy   jass.dll 0x10032A68 / 0x10032A7E / 0x10032AE9
//   ReplacePath                               jass.dll 0x1004CAFE
//   GetUnitGoldCost / TeleportCaptain         jass.dll 0x100339B6 / 0x100339C9 (table_hook)
//   SaveGame disabled by patch               jass.dll InitSaveGameHook 0x1003693A
//
// These are the last pieces of the builtin surface we did not have. Everything
// here is opt-in by name, nothing changes for maps that never call them.

#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>

#include <base/hook/fp_call.h>
#include <base/hook/iat.h>
#include <base/hook/patch.h>
#include <warcraft3/jass.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/jass/func_value.h>
#include <warcraft3/hashtable.h>
#include <warcraft3/version.h>
#include <warcraft3/war3_searcher.h>

#include "debug_log.h"
#include "../compat_mode.h"

namespace warcraft3::japi {

	// Implemented in EventDamageData.cpp; the two legacy aliases below forward to
	// them exactly like builtin-japi does.
	uint32_t __cdecl EXGetEventDamageData(uint32_t type);
	bool     __cdecl EXSetEventDamage(uint32_t value_bits_ptr);

	// Implemented in ButtonIcon.cpp; share the Storm.dll#279 (SFileLoadFile)
	// IAT detour cleanly with ReplacePath.
	void set_button_icon_storm_hook_active(bool active);
	bool button_icon_try_load_virtual(const char* filepath,
	                                  const void** buffer_ptr, uint32_t* size_ptr,
	                                  uint32_t reserve_size, OVERLAPPED* overlapped_ptr);
	bool button_icon_try_generate_disabled(const char* filepath,
	                                       const void** buffer_ptr, uint32_t* size_ptr,
	                                       uint32_t reserve_size, OVERLAPPED* overlapped_ptr);
	void button_icon_note_loaded_path(const char* filepath);

	// ── GetTriggeringTrigger gate ───────────────────────────────────────────
	// builtin-japi only hijacks GetUnitGoldCost / TeleportCaptain inside a
	// trigger (its own war3map.j uses them as damage accessors there). Outside a
	// trigger the original native still runs, so ordinary AI/script use is
	// unchanged.
	static uint32_t triggering_trigger()
	{
		static uintptr_t fn = 0;
		if (!fn) {
			jass::func_value const* nf = jass::jass_func("GetTriggeringTrigger");
			if (nf && nf->is_valid()) fn = nf->get_address();
		}
		if (!fn) return 0;
		return base::c_call<uint32_t>(fn);
	}

	// ── Legendary aliases (jass.dll 0x10032EE0 / 0x10032E3D) ─────────────────
	static uintptr_t RealGetUnitGoldCost = 0;
	static uint32_t __cdecl FakeGetUnitGoldCost(uint32_t type)
	{
		if (triggering_trigger()) return EXGetEventDamageData(type);
		return base::c_call<uint32_t>(RealGetUnitGoldCost, type);
	}

	static uintptr_t RealTeleportCaptain = 0;
	// (real x, real y): both arrive as pointers to the 4-byte value.
	static void __cdecl FakeTeleportCaptain(uint32_t x_bits_ptr, uint32_t y_bits_ptr)
	{
		if (triggering_trigger()) {
			EXSetEventDamage(x_bits_ptr);   // EXSetEventDamage dereferences the pointer
			return;
		}
		base::c_call<void>(RealTeleportCaptain, x_bits_ptr, y_bits_ptr);
	}

	// ── Stopwatch (jass.dll 0x10032A68 / 0x10032A7E / 0x10032AE9) ────────────
	// timer_start allocates an 8-byte QPC stamp and hands its pointer back as an
	// integer; timer_end is the elapsed seconds since then; timer_destroy frees
	// it. Not related to the game's CTimer at all.
	uint32_t __cdecl timer_start()
	{
		int64_t* stamp = new int64_t;
		QueryPerformanceCounter(reinterpret_cast<LARGE_INTEGER*>(stamp));
		return (uint32_t)(uintptr_t)stamp;
	}

	uint32_t __cdecl timer_end(uint32_t handle)
	{
		if (!handle) {
			japi_log::sync_write("timer_end: null handle");
			return jass::to_real(0.0f);
		}

		LARGE_INTEGER now, freq;
		QueryPerformanceCounter(&now);
		QueryPerformanceFrequency(&freq);

		int64_t start = *(const int64_t*)(uintptr_t)handle;
		double seconds = (double)(now.QuadPart - start) / (double)freq.QuadPart;
		return jass::to_real((float)seconds);
	}

	void __cdecl timer_destroy(uint32_t handle)
	{
		if (handle) delete reinterpret_cast<int64_t*>((uintptr_t)handle);
	}

	// ── ReplacePath (jass.dll 0x1004CAFE) ───────────────────────────────────
	// Exact-match table for resource path redirection.
	//
	// builtin-japi installs its consumer as a detour on Storm.dll ordinal 279
	// (jass.dll 0x1004C449: five __stdcall arguments, `ret 0x14`, filename in
	// arg 1). Two attempts to copy that (2026-11-20) crashed War3 during map
	// init with an access violation at Game.dll+0x516F0, even though the detour
	// was a pure pass-through with an empty table - so the slot we found is not
	// the contract the builtin relies on. Until Storm#279 is identified at
	// runtime, the table is recorded only.
	static std::map<std::string, std::string> g_replace_path;

	static const char* resolve_replace_path(const char* requested);

	typedef int(__stdcall* storm_open_fn)(const char* name, const void** buffer_ptr,
	                                      uint32_t* size_ptr, uint32_t reserve_size,
	                                      OVERLAPPED* overlapped_ptr);
	static storm_open_fn g_real_storm_open = nullptr;
	static uint32_t g_storm_hits = 0;
	static uint32_t g_remap_logs = 0;

	void clear_builtin_compat_map_state()
	{
		g_replace_path.clear();
		g_remap_logs = 0;
	}

	static int __stdcall storm_open_detour(const char* name, const void** buffer_ptr,
	                                       uint32_t* size_ptr, uint32_t reserve_size,
	                                       OVERLAPPED* overlapped_ptr)
	{
		if (!g_real_storm_open) return 0;
		static thread_local bool in_detour = false;
		if (in_detour || !name) {
			return g_real_storm_open(name, buffer_ptr, size_ptr, reserve_size, overlapped_ptr);
		}
		in_detour = true;
		struct DetourGuard {
			~DetourGuard() { in_detour = false; }
		} guard;

		const char* mapped = (!g_replace_path.empty())
		                         ? resolve_replace_path(name)
		                         : name;
		if (mapped != name && g_remap_logs < 20) {
			++g_remap_logs;
			char buf[320];
			snprintf(buf, sizeof(buf), "ReplacePath: \"%s\" -> \"%s\"", name, mapped);
			japi_log::sync_write(buf);
		}
		++g_storm_hits;

		if (buffer_ptr && button_icon_try_load_virtual(
				mapped, buffer_ptr, size_ptr, reserve_size, overlapped_ptr)) {
			button_icon_note_loaded_path(mapped);
			return 1;
		}

		int suc = g_real_storm_open(mapped, buffer_ptr, size_ptr, reserve_size, overlapped_ptr);
		if (suc) {
			button_icon_note_loaded_path(mapped);
			return suc;
		}

		if (buffer_ptr && button_icon_try_generate_disabled(
				mapped, buffer_ptr, size_ptr, reserve_size, overlapped_ptr)) {
			button_icon_note_loaded_path(mapped);
			return 1;
		}

		button_icon_note_loaded_path(mapped);
		return suc;
	}

	// Same install as builtin-japi: base::hook::iat(Game.dll, "Storm.dll",
	// ordinal 279, wrapper). Idempotent across map reboots so a second boot
	// never overwrites g_real_storm_open with &storm_open_detour.
	static void install_storm_detour()
	{
		if (g_real_storm_open) {
			set_button_icon_storm_hook_active(true);
			return;
		}
		uintptr_t real = base::hook::iat(::GetModuleHandleA("game.dll"), "Storm.dll",
		                                 (const char*)279, (uintptr_t)&storm_open_detour);
		if (real && real != (uintptr_t)&storm_open_detour) {
			g_real_storm_open = (storm_open_fn)real;
			set_button_icon_storm_hook_active(true);
		}

		char buf[160];
		snprintf(buf, sizeof(buf), "storm279: installed, real=0x%08X", (uint32_t)real);
		japi_log::sync_write(buf);
	}

	void set_replace_path_cstr(const char* from, const char* to)
	{
		if (!from || !*from) return;
		if (!to || !*to) {
			g_replace_path.erase(from);
			return;
		}
		g_replace_path[from] = to;

		char buf[320];
		snprintf(buf, sizeof(buf), "ReplacePath: \"%s\" -> \"%s\" (%u entries)", from, to,
		         (unsigned)g_replace_path.size());
		japi_log::sync_write(buf);
	}

	void __cdecl ReplacePath(uint32_t from, uint32_t to)
	{
		const char* k = jass::from_string((jass::jstring_t)from);
		const char* v = jass::from_string((jass::jstring_t)to);
		if (!k || !v) return;
		set_replace_path_cstr(k, v);
	}

	const char* resolve_replace_path(const char* requested)
	{
		if (!requested) return requested;
		auto it = g_replace_path.find(requested);
		return (it == g_replace_path.end()) ? requested : it->second.c_str();
	}

	// ── Install ────────────────────────────────────────────────────────────

	// jass.dll InitSaveGameHook (0x1003693A): find the call at SaveGame+0x90
	// (build 7000..7085, i.e. 1.27a/1.27b) or +0x91, resolve its target and
	// overwrite it with `ret; int3 x3`. The outer SaveGame keeps its argument
	// checks — only the inner routine is disabled.
	//
	// Unlike the builtin we verify the instruction first (it reads through a null
	// pointer when the name is missing) and use patch_guard, so a second map boot
	// cannot re-patch an already patched site.
	static void disable_save_game()
	{
		static base::hook::patch_guard guard;
		static bool done = false;
		if (done) return;
		done = true;

		jass::func_value const* nf = jass::jass_func("SaveGame");
		if (!nf || !nf->is_valid()) {
			japi_log::sync_write("SaveGame: native not found, saving stays enabled");
			return;
		}

		uintptr_t fn = nf->get_address();
		uint32_t build = get_war3_searcher().get_version();
		uintptr_t site = fn + ((build >= version_127a && build <= version_127b) ? 0x90 : 0x91);

		uint8_t opcode = 0;
		__try {
			opcode = *(const uint8_t*)site;
		} __except (EXCEPTION_EXECUTE_HANDLER) {
			opcode = 0;
		}
		if (opcode != 0xE8) {
			char buf[128];
			snprintf(buf, sizeof(buf),
			         "SaveGame: no call at +0x%02X (opcode=0x%02X), saving stays enabled",
			         (unsigned)(site - fn), (unsigned)opcode);
			japi_log::sync_write(buf);
			return;
		}

		int32_t rel = 0;
		__try {
			rel = *(const int32_t*)(site + 1);
		} __except (EXCEPTION_EXECUTE_HANDLER) {
			rel = 0;
		}
		uintptr_t target = site + 5 + rel;

		// Somebody already disabled it (another JAPI, a previous run's leftover):
		// leave their patch alone instead of backing it up as "the original".
		uint8_t first = 0;
		__try {
			first = *(const uint8_t*)target;
		} __except (EXCEPTION_EXECUTE_HANDLER) {
			first = 0;
		}
		if (first == 0xC3) {
			japi_log::sync_write("SaveGame: inner routine is already disabled; kept as is");
			return;
		}

		static const char kNoSave[4] = { (char)0xC3, (char)0xCC, (char)0xCC, (char)0xCC };
		if (guard.apply(target, kNoSave, sizeof(kNoSave))) {
			char buf[128];
			snprintf(buf, sizeof(buf), "SaveGame: inner routine disabled at 0x%08X", (uint32_t)target);
			japi_log::sync_write(buf);
		} else {
			japi_log::sync_write("SaveGame: cannot patch the inner routine; saving stays enabled");
		}
	}

	// Patch Storm.dll ordinal 279 in every module that imports it (war3.exe and
	// game.dll both do). The IAT slot is a plain 4-byte function pointer, so
	// patch_guard gives us the original for free.
	// Diagnostic (JAPI_STORM_IMPORTS=1): list every Storm.dll import slot in a
	// module together with the address it currently holds, resolved against the
	// loaded Storm.dll base. Needed before ReplacePath's consumer can be hooked:
	// the builtin detours ordinal 279, but copying that slot verbatim crashed
	// War3 (AV at Game.dll+0x516F0) even as a pass-through.
	static void log_storm_imports(HMODULE module, const char* label)
	{
		if (!module) return;

		auto base = (uintptr_t)module;
		auto dos = (PIMAGE_DOS_HEADER)base;
		if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
		auto nt = (PIMAGE_NT_HEADERS)(base + dos->e_lfanew);
		if (nt->Signature != IMAGE_NT_SIGNATURE) return;

		auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
		if (!dir.VirtualAddress) return;

		uintptr_t storm = (uintptr_t)GetModuleHandleA("storm.dll");
		char buf[192];

		auto desc = (PIMAGE_IMPORT_DESCRIPTOR)(base + dir.VirtualAddress);
		for (; desc->Name; ++desc) {
			const char* dll = (const char*)(base + desc->Name);
			if (_stricmp(dll, "storm.dll") != 0) continue;

			snprintf(buf, sizeof(buf), "stormentry: %s imports storm.dll base=0x%08X",
			         label, (uint32_t)storm);
			japi_log::sync_write(buf);

			auto int_thunk = (const uint32_t*)(base + desc->OriginalFirstThunk);
			auto iat = (uint32_t*)(base + desc->FirstThunk);
			for (size_t i = 0; int_thunk && int_thunk[i] && i < 512; ++i) {
				uint32_t thunk = int_thunk[i];
				uint32_t target = iat[i];
				const char* rel = "";
				if (storm && target >= storm && target < storm + 0x200000) rel = " (storm+rva)";
				if (thunk & IMAGE_ORDINAL_FLAG32) {
					snprintf(buf, sizeof(buf),
					         "stormentry: %s ord=%u slot=0x%08X target=0x%08X%s",
					         label, thunk & 0xFFFF, (uint32_t)(uintptr_t)&iat[i], target, rel);
				} else {
					const char* nm = (const char*)(base + thunk + 2);
					snprintf(buf, sizeof(buf),
					         "stormentry: %s name=%s slot=0x%08X target=0x%08X%s",
					         label, nm, (uint32_t)(uintptr_t)&iat[i], target, rel);
				}
				japi_log::sync_write(buf);
			}
			return;
		}
		japi_log::sync_write("stormentry: no storm.dll import found");
	}

	void InitializeBuiltinCompat()
	{
		// Additive natives are always safe; the takeovers (aliases, SaveGame,
		// Storm#279) are not, so they follow the same gate as the inline hooks.
		const bool coexist = coexistence_mode();

		jass::japi_add((uintptr_t)timer_start,   "timer_start",   "()I");
		jass::japi_add((uintptr_t)timer_end,     "timer_end",     "(I)R");
		jass::japi_add((uintptr_t)timer_destroy, "timer_destroy", "(I)V");
		jass::japi_add((uintptr_t)ReplacePath,   "ReplacePath",   "(SS)V");

		// The two aliases replace existing natives (table hook, same as
		// jass.dll 0x100339B6 / 0x100339C9). Skipped when the native table does
		// not have them yet; the next map boot retries.
		if (coexist) {
			japi_log::sync_write("Compat: coexistence mode, aliases/SaveGame/ReplacePath consumer skipped");
			return;
		}
		if (!RealGetUnitGoldCost) {
			if (jass::table_hook("GetUnitGoldCost", &RealGetUnitGoldCost, (uintptr_t)FakeGetUnitGoldCost)) {
				japi_log::sync_write("Compat: GetUnitGoldCost -> EXGetEventDamageData (trigger only)");
			}
		}
		if (!RealTeleportCaptain) {
			if (jass::table_hook("TeleportCaptain", &RealTeleportCaptain, (uintptr_t)FakeTeleportCaptain)) {
				japi_log::sync_write("Compat: TeleportCaptain -> EXSetEventDamage (trigger only)");
			}
		}

		disable_save_game();
		install_storm_detour();

		char flag[4] = {0};
		if (GetEnvironmentVariableA("JAPI_STORM_IMPORTS", flag, sizeof(flag)) > 0 && flag[0] == '1') {
			log_storm_imports(GetModuleHandleA(nullptr), "war3.exe");
			log_storm_imports(GetModuleHandleA("game.dll"), "game.dll");
		}
	}

}  // namespace warcraft3::japi

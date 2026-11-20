// GameUI.cpp — CGameUI natives
// (GetChatState, ShowConsole, GetFps, ShowFpsText,
//  GetLittleMapX/Y, SetLittleMapX/Y)
// Ported from builtin-japi jass.dll — see docs/re-builtin-japi/06-cgameui-offsets.md.
// All game.dll addresses are resolved at runtime using the same
// "byte-pattern + rel32-follow + build-constant" method builtin-japi uses;
// no absolute game.dll address is hardcoded.

#include <warcraft3/jass.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/war3_searcher.h>
#include <warcraft3/version.h>
#include <base/hook/fp_call.h>
#include <windows.h>
#include <cstring>

namespace warcraft3::japi {

namespace {

	// builtin-japi 0x10055B8F equivalent: linear scan of game.dll .text
	// for a byte pattern. Returns the match address or 0.
	uintptr_t search_text_pattern(const uint8_t* pat, size_t len)
	{
		basic_searcher& s = get_war3_searcher();
		uintptr_t end = s.text().second;
		uint32_t head;
		memcpy(&head, pat, sizeof head);
		uintptr_t p = s.search_int_in_text(head);
		while (p) {
			if (p + len <= end && 0 == memcmp((const void*)p, pat, len)) {
				return p;
			}
			p = s.search_int_in_text(head, p + 1);
		}
		return 0;
	}

	// 1.27a takes the build >= 7000 branch everywhere (version_127a == 7000,
	// clamped from the real 52240 inside war3_searcher::search_version).
	bool is_build_7000()
	{
		return get_war3_searcher().get_version() >= version_127a;
	}

	// ---- GetChatState -------------------------------------------------------
	// Resolves a game.dll global dword flag; nonzero = chat edit box open.
	uintptr_t resolve_chat_flag()
	{
		// push 0; push 0x5B5; push ...
		static const uint8_t pat[] = { 0x6A, 0x00, 0x68, 0xB5, 0x05, 0x00, 0x00, 0x68 };
		uintptr_t p = search_text_pattern(pat, sizeof pat);
		if (!p) return 0;
		int32_t rel = *(int32_t*)(p - 0x15);
		return *(uint32_t*)(p + rel - 0xA);
	}

	// ---- GetFps -------------------------------------------------------------
	// Resolves a game.dll global holding a pointer to the fps float.
	uintptr_t resolve_fps_ptr()
	{
		// je +0x12; push 0; push 0xD6...
		static const uint8_t pat[] = { 0x74, 0x12, 0x6A, 0x00, 0x68, 0xD6, 0x00, 0x00 };
		uintptr_t p = search_text_pattern(pat, sizeof pat);
		if (!p) return 0;
		uintptr_t ecx = p - (is_build_7000() ? 0x81 : 0x8C);
		ecx += *(int32_t*)(ecx + 1);
		ecx += is_build_7000() ? 0x11 : 0x12;
		uintptr_t eax = ecx + *(int32_t*)(ecx + 1);
		eax += is_build_7000() ? 0x283 : 0x211;
		return *(uint32_t*)eax;
	}

	// ---- ShowFpsText --------------------------------------------------------
	// Visibility flag byte: *(*(*(obj+0x00)+0x3CC)+0x144), obj = *(game.dll global).
	// Toggling simulates the "/fps" chat command via game.dll's command handler.
	uintptr_t g_fn_chat_cmd = 0;  // game.dll chat-command function
	uintptr_t g_pp_obj = 0;       // address of the game.dll global holding the object

	bool resolve_fps_text()
	{
		// Chat-command function head = "Unknown map name!" code reference - 0x9F (1.27a).
		uintptr_t ref = get_war3_searcher().search_string("Unknown map name!");
		if (!ref) return false;
		g_fn_chat_cmd = ref - (is_build_7000() ? 0x9F : 0x98);

		// push 0; push 0x379; push ...
		static const uint8_t pat[] = { 0x6A, 0x00, 0x68, 0x79, 0x03, 0x00, 0x00, 0x68 };
		uintptr_t p = search_text_pattern(pat, sizeof pat);
		if (!p) return false;
		int32_t rel = *(int32_t*)(p - 0x131);
		g_pp_obj = *(uint32_t*)(p + rel - 0x12B);
		return g_pp_obj != 0;
	}

	uint8_t fps_text_visible()
	{
		// Chain verified at runtime on 1.27a: sub = *(CGameUI+0x3CC),
		// flag byte at sub+0x144 toggles 0/1 with the /fps command.
		// (The 06 doc's chain had one dereference too many.)
		uintptr_t obj = *(uint32_t*)g_pp_obj;
		if (IsBadReadPtr((void*)obj, 4)) return 0xFF;
		uintptr_t sub = *(uint32_t*)(obj + 0x3CC);
		if (IsBadReadPtr((void*)sub, 0x145)) return 0xFF;
		return *(uint8_t*)(sub + 0x144);
	}

	// ---- ShowConsole / LittleMap --------------------------------------------
	// Frame layout: position floats at frame+0xF8 (X) / +0xFC (Y).
	struct console_frames {
		float* big_map;         // D + 0xF8
		float* little_map;      // *(D+0x1A0) + 0xF8
		float* console_ui;      // *(*(B+0x374)+0x68) + 0xF8
		float* extra;           // *(B+0x3F4) + 0xF8, rewritten by the game every frame
		float  saved_big_x;
		float  saved_lm_x;
		float  saved_lm_y;
		float  saved_cui_x;
		float  saved_extra;
		float  watchdog_scale;  // 2.0f on 1.27a, 0.5f on older builds
		bool   visible;
		bool   resolved;
	};
	console_frames g_console = {};

	// builtin-japi 0x10036BE5: resolve the UI root object A.
	uintptr_t resolve_ui_root()
	{
		// push 0; push 0x26E; push ...
		static const uint8_t pat[] = { 0x6A, 0x00, 0x68, 0x6E, 0x02, 0x00, 0x00, 0x68 };
		uintptr_t p = search_text_pattern(pat, sizeof pat);
		if (!p) return 0;
		uintptr_t eax = p - 0x20;
		eax += *(int32_t*)(eax + 1);
		eax += is_build_7000() ? 0x112 : 0x102;
		return *(uint32_t*)eax;
	}

	// While the console is hidden the game rewrites the Extra frame position
	// every frame, so builtin-japi keeps forcing it back from a watchdog thread.
	DWORD WINAPI console_watchdog(LPVOID)
	{
		for (;;) {
			if (g_console.resolved && !g_console.visible) {
				*g_console.extra = g_console.watchdog_scale;
			}
			Sleep(1);
		}
		return 0;
	}

	// builtin-japi 0x1004EE85: walk A -> frames, save originals, start watchdog.
	bool resolve_console_frames()
	{
		uintptr_t a = resolve_ui_root();
		if (!a) return false;
		uintptr_t b = *(uintptr_t*)(a + 0x00);
		uintptr_t d = *(uintptr_t*)(*(uintptr_t*)(b + 0x1C) + 0x0C);

		g_console.big_map    = (float*)(d + 0xF8);
		g_console.little_map = (float*)(*(uintptr_t*)(d + 0x1A0) + 0xF8);
		g_console.console_ui = (float*)(*(uintptr_t*)(*(uintptr_t*)(b + 0x374) + 0x68) + 0xF8);
		g_console.extra      = (float*)(*(uintptr_t*)(b + 0x3F4) + 0xF8);

		g_console.saved_big_x = g_console.big_map[0];
		g_console.saved_lm_x  = g_console.little_map[0];
		g_console.saved_lm_y  = g_console.little_map[1];
		g_console.saved_cui_x = g_console.console_ui[0];
		g_console.saved_extra = *g_console.extra;

		g_console.watchdog_scale = is_build_7000() ? 2.0f : 0.5f;
		g_console.visible = true;
		g_console.resolved = true;

		CreateThread(nullptr, 0, console_watchdog, nullptr, 0, nullptr);
		return true;
	}

	bool ensure_console_frames()
	{
		if (g_console.resolved) return true;
		return resolve_console_frames();
	}

} // anonymous namespace

// GetChatState() -> boolean
uint32_t GetChatState_handler(const uint32_t*, size_t)
{
	static uintptr_t chat_flag = resolve_chat_flag();
	if (!chat_flag) return 0;
	return *(uint32_t*)chat_flag ? 1 : 0;
}

// GetFps() -> real
uint32_t GetFps_handler(const uint32_t*, size_t)
{
	static uintptr_t fps_ptr = resolve_fps_ptr();
	if (!fps_ptr) return jass::to_real(0.0f);
	return jass::to_real(*(float*)fps_ptr);
}

// ShowFpsText(boolean show)
uint32_t ShowFpsText_handler(const uint32_t* a, size_t)
{
	static bool resolved = resolve_fps_text();
	if (!resolved) return 0;
	uint32_t want = a[0] ? 1 : 0;
	uint8_t cur = fps_text_visible();
	if (cur != 0xFF && cur != want) {
		base::this_call<void>(g_fn_chat_cmd, g_pp_obj, "/fps");
	}
	return 0;
}

// ShowConsole(boolean show)
uint32_t ShowConsole_handler(const uint32_t* a, size_t)
{
	if (!ensure_console_frames()) return 0;
	if (a[0]) {
		g_console.visible = true;
		g_console.big_map[0]    = g_console.saved_big_x;
		g_console.little_map[0] = g_console.saved_lm_x;
		g_console.little_map[1] = g_console.saved_lm_y;
		g_console.console_ui[0] = g_console.saved_cui_x;
		*g_console.extra        = g_console.saved_extra;
	}
	else {
		g_console.visible = false;
		g_console.big_map[0]    = 0.0f;
		g_console.little_map[0] = -2.0f;
		g_console.little_map[1] = 2.0f;
		g_console.console_ui[0] = 2.0f;
		// Extra frame is forced to watchdog_scale by the watchdog thread.
	}
	return 0;
}

// GetLittleMapX() -> real
uint32_t GetLittleMapX_handler(const uint32_t*, size_t)
{
	if (!ensure_console_frames()) return jass::to_real(0.0f);
	return jass::to_real(g_console.little_map[0]);
}

// SetLittleMapX(real x)
uint32_t SetLittleMapX_handler(const uint32_t* a, size_t)
{
	if (!ensure_console_frames()) return 0;
	g_console.little_map[0] = jass::from_real((jass::jreal_t)a[0]);
	return 0;
}

// GetLittleMapY() -> real
uint32_t GetLittleMapY_handler(const uint32_t*, size_t)
{
	if (!ensure_console_frames()) return jass::to_real(0.0f);
	return jass::to_real(g_console.little_map[1]);
}

// SetLittleMapY(real y)
uint32_t SetLittleMapY_handler(const uint32_t* a, size_t)
{
	if (!ensure_console_frames()) return 0;
	g_console.little_map[1] = jass::from_real((jass::jreal_t)a[0]);
	return 0;
}

// Big map / ConsoleUI frames — builtin-japi jass.dll 0x1004EF5D..0x1004F0B6.
// Same two floats per frame (frame+0xF8 = x, frame+0xFC = y), same layout-space
// units as the little map: 0.0 is the frame's home position, +/-2.0 pushes it
// off screen. Get with an unresolved frame returns 0.0, Set is a silent no-op
// (that is what the builtin does, it does not report failures).

// GetBigMapX() -> real
uint32_t GetBigMapX_handler(const uint32_t*, size_t)
{
	if (!ensure_console_frames()) return jass::to_real(0.0f);
	return jass::to_real(g_console.big_map[0]);
}

// SetBigMapX(real x)
uint32_t SetBigMapX_handler(const uint32_t* a, size_t)
{
	if (!ensure_console_frames()) return 0;
	g_console.big_map[0] = jass::from_real((jass::jreal_t)a[0]);
	return 0;
}

// GetBigMapY() -> real
uint32_t GetBigMapY_handler(const uint32_t*, size_t)
{
	if (!ensure_console_frames()) return jass::to_real(0.0f);
	return jass::to_real(g_console.big_map[1]);
}

// SetBigMapY(real y)
uint32_t SetBigMapY_handler(const uint32_t* a, size_t)
{
	if (!ensure_console_frames()) return 0;
	g_console.big_map[1] = jass::from_real((jass::jreal_t)a[0]);
	return 0;
}

// GetConsoleUIX() -> real
uint32_t GetConsoleUIX_handler(const uint32_t*, size_t)
{
	if (!ensure_console_frames()) return jass::to_real(0.0f);
	return jass::to_real(g_console.console_ui[0]);
}

// SetConsoleUIX(real x)
uint32_t SetConsoleUIX_handler(const uint32_t* a, size_t)
{
	if (!ensure_console_frames()) return 0;
	g_console.console_ui[0] = jass::from_real((jass::jreal_t)a[0]);
	return 0;
}

// GetConsoleUIY() -> real
uint32_t GetConsoleUIY_handler(const uint32_t*, size_t)
{
	if (!ensure_console_frames()) return jass::to_real(0.0f);
	return jass::to_real(g_console.console_ui[1]);
}

// SetConsoleUIY(real y)
uint32_t SetConsoleUIY_handler(const uint32_t* a, size_t)
{
	if (!ensure_console_frames()) return 0;
	g_console.console_ui[1] = jass::from_real((jass::jreal_t)a[0]);
	return 0;
}

// ── JASS-facing natives (builtin registers these 8 with japi_add) ───────────
// Get* return the real's bits in eax; Set* receive a pointer to the 4-byte real
// (that is how War3 1.27 passes `real` arguments to natives).
uint32_t __cdecl GetBigMapX_native()                  { return GetBigMapX_handler(nullptr, 0); }
void     __cdecl SetBigMapX_native(const float* x)    { SetBigMapX_handler((const uint32_t*)x, 0); }
uint32_t __cdecl GetBigMapY_native()                  { return GetBigMapY_handler(nullptr, 0); }
void     __cdecl SetBigMapY_native(const float* y)    { SetBigMapY_handler((const uint32_t*)y, 0); }
uint32_t __cdecl GetConsoleUIX_native()               { return GetConsoleUIX_handler(nullptr, 0); }
void     __cdecl SetConsoleUIX_native(const float* x) { SetConsoleUIX_handler((const uint32_t*)x, 0); }
uint32_t __cdecl GetConsoleUIY_native()               { return GetConsoleUIY_handler(nullptr, 0); }
void     __cdecl SetConsoleUIY_native(const float* y) { SetConsoleUIY_handler((const uint32_t*)y, 0); }

void InitializeGameUiExtra()
{
	jass::japi_add((uintptr_t)GetBigMapX_native,    "GetBigMapX",    "()R");
	jass::japi_add((uintptr_t)SetBigMapX_native,    "SetBigMapX",    "(R)V");
	jass::japi_add((uintptr_t)GetBigMapY_native,    "GetBigMapY",    "()R");
	jass::japi_add((uintptr_t)SetBigMapY_native,    "SetBigMapY",    "(R)V");
	jass::japi_add((uintptr_t)GetConsoleUIX_native, "GetConsoleUIX", "()R");
	jass::japi_add((uintptr_t)SetConsoleUIX_native, "SetConsoleUIX", "(R)V");
	jass::japi_add((uintptr_t)GetConsoleUIY_native, "GetConsoleUIY", "()R");
	jass::japi_add((uintptr_t)SetConsoleUIY_native, "SetConsoleUIY", "(R)V");
}

}

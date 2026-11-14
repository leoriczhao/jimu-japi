#include <lua.hpp>
#include <warcraft3/war3_searcher.h>
#include <warcraft3/version.h>
#include <warcraft3/keyboard_code.h>
#include <warcraft3/wark_to_vk.h>
#include <warcraft3/player.h>
#include <warcraft3/message_dispatch.h>
#include <warcraft3/jass/func_value.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/jass/inline_hook.h>
#include <warcraft3/jass/trampoline_function.h>
#include <base/hook/fp_call.h>
#include "common.h"
#include "callback.h"
#include "libs_runtime.h"
#include "lua_loader.h"
#include "jassbind.h"
#include "bridge_dispatch.h"
#include "debug_log.h"
#include "libs_d3d.h"
#include "libs_message.h"
#include <vector>
#include <map>
#include <cstring>

namespace warcraft3::lua_engine::message {
	// ============================================================
	// Texture event system
	// ============================================================
	struct texture_entry {
		int      id;
		float    x, y, w, h;     // screen-space bounds (normalized 0..1 or pixel)
		bool     visible;
		bool     trigger_enabled;
	};

	struct texture_event_entry {
		int      event_id;
		int      texture_id;
		int      keycode;          // keyboard key (WARK_*), or -1 for mouse
		uint32_t press_lua_ref;    // Lua registry ref for press callback
		uint32_t release_lua_ref;  // Lua registry ref for release callback
	};

	static int g_next_texture_id = 1;
	static int g_next_event_id   = 1;
	static std::map<int, texture_entry>       g_textures;
	static std::map<int, texture_event_entry> g_texture_events;

	// D3D bridge events use real newD3d9 texture handles and JASS code values.
	// Separate JASS timers are retained for press/release so rapid input cannot
	// overwrite a pending callback. The press timer id is the public event id;
	// the currently expired timer id is the builtin-compatible context parent.
	struct d3d_texture_event_entry {
		uint32_t event_id;
		uint32_t press_timer;
		uint32_t release_timer;
		uint32_t texture_id;
		int      keycode;
		uint32_t press_code;
		uint32_t release_code;
	};

	static std::map<uint32_t, d3d_texture_event_entry> g_d3d_texture_events;
	static bool g_lua_message_hook_registered = false;

	void install();

	static HWND FindWar3Window()
	{
		DWORD current_pid = GetCurrentProcessId();
		HWND hwnd = NULL;
		while (NULL != (hwnd = FindWindowExW(NULL, hwnd, L"Warcraft III", L"Warcraft III")))
		{
			DWORD pid = 0;
			GetWindowThreadProcessId(hwnd, &pid);
			if (pid == current_pid)
			{
				return hwnd;
			}
		}
		return NULL;
	}

	static HWND get_window()
	{
		static HWND war3_window =  FindWar3Window();
		return war3_window;
	}

	bool get_client_cursor(float* out_x, float* out_y)
	{
		if (!out_x || !out_y) return false;
		HWND window = get_window();
		if (!window) return false;
		POINT point = { 0 };
		if (!GetCursorPos(&point) || !ScreenToClient(window, &point)) return false;
		*out_x = static_cast<float>(point.x);
		*out_y = static_cast<float>(point.y);
		return true;
	}

	struct AbilityData
	{
		uintptr_t  vft_ptr;
		uintptr_t  ability_id;
		uintptr_t  order_id;
		uintptr_t  unk;
		uintptr_t  target_type;
	};

	struct CCommandButton
	{
		uintptr_t    vft_ptr;
		uintptr_t    unk[0x63];
		AbilityData* ability;   // offset 0x190
	};

	struct message_t
	{
		uint32_t vfptr;
		uint32_t unk01;
		uint32_t msgid;
	};

	struct keyboard_message_t
		: public message_t
	{
		uint32_t unk03;
		uint32_t keycode;
		uint8_t  keystate;
	};

	struct mouse_message_t
		: public message_t
	{
		uint32_t unk03;
		uint32_t unk04;
		float rx;
		float ry;
		float wx;
		float wy;
		uint32_t unk0A;
		uint32_t code;
	};

	struct ability_mouse_message_t
		: public message_t
	{
		uint32_t unk03;
		uint32_t unk04;
		uint32_t unk05;
		uint32_t unk06;
		uint32_t unk07;
		uint32_t unk08;
		uint32_t code;
		uint32_t unk0A;
		uint32_t unk0B;
		CCommandButton* button;
	};

	static uintptr_t search_convert_xy()
	{
		war3_searcher& s = get_war3_searcher();
		uintptr_t ptr = 0;
		if (s.get_version() <= version_120e)
		{
			ptr = s.search_string("E:\\Drive1\\temp\\buildwar3x\\War3\\Source\\UI\\CWorldFrameWar3.cpp");
			ptr += 4;
			ptr = next_opcode(ptr, 0xC7, 6);
			ptr += 6;
			ptr = next_opcode(ptr, 0xC7, 6);
			ptr += 6;
			ptr = next_opcode(ptr, 0xC7, 6);
			ptr += 2;
			ptr = *(uintptr_t*)ptr;
		}
		else
		{
			ptr = get_vfn_ptr(".?AVCWorldFrameWar3@@");
		}
		ptr += 0x38;
		ptr = *(uintptr_t*)ptr;
		do
		{
			ptr = next_opcode(ptr, 0x68, 5);
			ptr += 5;
		} while (*(uintptr_t*)(ptr - 4) != 0x1A0068);
		ptr = next_opcode(ptr, 0xE8, 5);
		ptr += 5;
		ptr = next_opcode(ptr, 0xE8, 5);
		if (s.get_version() >= version_127a)
		{
			ptr += 5;
			ptr = next_opcode(ptr, 0xE8, 5);
			ptr += 5;
			ptr = next_opcode(ptr, 0xE8, 5);
		}
		ptr = convert_function(ptr);
		return ptr;
	}

	static int convert_xy(float rx, float ry, float& wx, float& wy)
	{
		static uintptr_t s_convert_xy = search_convert_xy();
		war3_searcher& s = get_war3_searcher();
		uint32_t cgameui = s.get_gameui(0, 0);
		float buf[0x10] = { 0 };
		uintptr_t cworldframe = (s.get_version() <= version_120e) ? *(uintptr_t*)(cgameui + 0x3B0) : *(uintptr_t*)(cgameui + 0x3BC);
		int result = base::this_call<int>(s_convert_xy, cworldframe, rx, ry, buf, 1, 1);
		wx = buf[4];
		wy = buf[5];
		return result;
	}

	static int lmouse(lua_State* L)
	{
		HWND war3_window = get_window();
		POINT pt = { 0 };
		::GetCursorPos(&pt);
		ScreenToClient(war3_window, &pt);
		RECT rt;
		::GetClientRect(war3_window, &rt);
		float fx = 0.8f *((float)(pt.x - rt.left) / (rt.right - rt.left));
		float fy = 0.6f *(1.0f - (float)(pt.y - rt.top) / (rt.bottom - rt.top));
		float wx = 0.f, wy = 0.f;
		convert_xy(fx, fy, wx, wy);
		lua_pushnumber(L, wx);
		lua_pushnumber(L, wy);
		return 2;
	}

	static int lbutton(lua_State* L)
	{
		int x = (int)lua_tointeger(L, 1);
		int y = (int)lua_tointeger(L, 2);
		if (x < 0 || x >= 4 || y < 0 || y >= 3)
		{
			return 0;
		}

		war3_searcher& s = get_war3_searcher();
		uint32_t cgameui = s.get_gameui(0, 0);
		uintptr_t button_bar = (s.get_version() <= version_120e) ? *(uintptr_t*)(cgameui + 0x3BC) : *(uintptr_t*)(cgameui + 0x3C8);
		uintptr_t button_array = *(uintptr_t*)(button_bar + 0x154);
		CCommandButton* button = ((CCommandButton*)*(uintptr_t*)(*(uintptr_t*)(button_array + 0x10 * (y)+0x08) + 0x04 * (x)));
		AbilityData* ability = button->ability;
		if (!ability)
		{
			return 0;
		}
		lua_pushinteger(L, ability->ability_id);
		lua_pushinteger(L, ability->order_id);
		lua_pushinteger(L, ability->target_type & 0x3FF);
		return 3;
	}
	
	static uintptr_t get_select_unit()
	{
		player::selection_t* slt = player::selection(player::local());
		if (!slt || !slt->unit)
		{
			return 0;
		}
		return slt->unit;
	}

	static int lselection(lua_State* L)
	{
		uintptr_t unit = get_select_unit();
		if (!unit)
		{
			jassbind::push_handle(L, 0);
			return 1;
		}
		uintptr_t handle = object_to_handle(unit);
		jassbind::push_handle(L, handle);
		return 1;
	}

	namespace order {
		bool b_hook = false;
		bool b_search = false;
		bool b_debug_enabled = false;

		namespace real {
			uintptr_t immediate_order = 0;
			uintptr_t point_order = 0;
			uintptr_t target_order = 0;
		}

		namespace fake {
			int __fastcall immediate_order(uint32_t order, uint32_t unk, uint32_t flags)
			{
				if (b_debug_enabled) {
					if (order >= 'A000')
					{
						printf("immediate_order, %c%c%c%c, %X, %X\n", ((char*)&order)[3], ((char*)&order)[2], ((char*)&order)[1], ((char*)&order)[0], unk, flags);
					}
					else
					{
						printf("immediate_order, %X, %X, %X\n", order, unk, flags);
					}
				}
				return base::fast_call<int>(real::immediate_order, order, unk, flags);
			}

			int __fastcall point_order(uint32_t order, uint32_t unk, float* x, float* y, uint32_t flags)
			{
				if (b_debug_enabled) {
					if (order >= 'A000')
					{
						printf("point_order, %c%c%c%c, %X, %f, %f, %X\n", ((char*)&order)[3], ((char*)&order)[2], ((char*)&order)[1], ((char*)&order)[0], unk, *x, *y, flags);
					}
					else
					{
						printf("point_order, %X, %X, %f, %f, %X\n", order, unk, *x, *y, flags);
					}
				}
				return base::fast_call<int>(real::point_order, order, unk, x, y, flags);
			}

			int __fastcall target_order(uint32_t order, uint32_t unk, float* x, float* y, uint32_t target, uint32_t flags)
			{
				if (b_debug_enabled) {
					if (order >= 'A000')
					{
						printf("target_order, %c%c%c%c, %X, %f, %f, %X, %X\n", ((char*)&order)[3], ((char*)&order)[2], ((char*)&order)[1], ((char*)&order)[0], unk, *x, *y, target, flags);
					}
					else
					{
						printf("target_order, %X, %X, %f, %f, %X, %X\n", order, unk, *x, *y, target, flags);
					}
				}
				return base::fast_call<int>(real::target_order, order, unk, x, y, target, flags);
			}
		}

		static void search()
		{
			if (b_search) {
				return;
			}
			b_search = true;

			war3_searcher& s = get_war3_searcher();
			uintptr_t ptr = 0;
			if (s.get_version() >= version_127a)
			{
				// builtin-japi resolver 0x10036DBA (docs/re-builtin-japi/07-local-order.md):
				// anchor "and edx,1; shl esi,5; or esi,eax" (83 E2 01 C1 E6 05 0B F0), -0x19.
				// game.dll+0x3AE4E0 is the outer stdcall flag-packing wrapper, not the
				// fastcall submit target required by the JAPI handlers.
				static const uint8_t pat[] = { 0x83, 0xE2, 0x01, 0xC1, 0xE6, 0x05, 0x0B, 0xF0 };
				uint32_t head;
				memcpy(&head, pat, sizeof head);
				ptr = s.search_int_in_text(head);
				while (ptr && 0 != memcmp((const void*)ptr, pat, sizeof pat))
				{
					ptr = s.search_int_in_text(head, ptr + 1);
				}
				if (!ptr) return;
				ptr -= 0x19;
			}
			else
			{
				ptr = s.search_string("SimpleDestructableNameValue");
				ptr += 4;
				do
				{
					ptr = next_opcode(ptr, 0xC1, 3);
					ptr += 3;
				} while (*(uint16_t*)(ptr - 2) != 0x05E2);
			}

			ptr = next_opcode(ptr, 0xE8, 5);
			real::immediate_order = convert_function(ptr);
			ptr += 5;
			ptr = next_opcode(ptr, 0xE8, 5);
			real::point_order = convert_function(ptr);
			ptr += 5;
			ptr = next_opcode(ptr, 0xE8, 5);
			ptr += 5;
			ptr = next_opcode(ptr, 0xE8, 5);
			real::target_order = convert_function(ptr);
		}

		static int limmediate(lua_State* L)
		{
			if (!get_select_unit()){
				lua_pushboolean(L, 0);
				return 1;
			}
			search();
			uint32_t order = lua_tointeger(L, 1);
			uint32_t flags = lua_tointeger(L, 2);
            base::fast_call<int>(real::immediate_order, order, 0, flags);
			lua_pushboolean(L, 1);
			return 1;
		}

		static bool submit_point(uint32_t order_id, float x, float y, uint32_t flags);

		static int lpoint(lua_State* L)
		{
			uint32_t order = lua_tointeger(L, 1);
			float x = (float)lua_tonumber(L, 2);
			float y = (float)lua_tonumber(L, 3);
			uint32_t flags = lua_tointeger(L, 4);
			bool submitted = submit_point(order, x, y, flags);
			lua_pushboolean(L, submitted ? 1 : 0);
			return 1;
		}

		// Shared by message.order_point (the API used from message.hook) and the
		// LocalPointOrder bridge handler. This lets the integration suite validate
		// the exact submit function in a real CGameUI message callback while the
		// bridge test separately covers hashtable argument decoding.
		static bool submit_point(uint32_t order_id, float x, float y, uint32_t flags)
		{
			if (!get_select_unit()) return false;
			search();
			if (!real::point_order) return false;
			base::fast_call<int>(real::point_order, order_id, 0, &x, &y, flags);
			return true;
		}

		static int ltarget(lua_State* L)
		{
			if (!get_select_unit()){
				lua_pushboolean(L, 0);
				return 1;
			}
			search();
			uint32_t order = lua_tointeger(L, 1);
			float x = (float)lua_tonumber(L, 2);
			float y = (float)lua_tonumber(L, 3);
			uint32_t target = jassbind::read_handle(L, 4);
			uint32_t flags = lua_tointeger(L, 5);
			if (target)
			{
				target = handle_to_object(target);
			}
            base::fast_call<int>(real::target_order, order, 0, &x, &y, target, flags);
			lua_pushboolean(L, 1);
			return 1;
		}

		static int lenable_debug(lua_State* L)
		{
			bool enabled = lua_toboolean(L, 1) != 0;
			if (enabled && !b_hook) {
				b_hook = true;
				search();

				// The minimal base::hook::install stub only overwrites the pointer and
				// provides no trampoline. Using it here made fake::* call itself forever.
				// Install real code detours once and retain their trampolines; subsequent
				// calls only toggle logging.
				uintptr_t immediate = warcraft3::jass::inline_hook_install(
					real::immediate_order, (uintptr_t)fake::immediate_order);
				uintptr_t point = warcraft3::jass::inline_hook_install(
					real::point_order, (uintptr_t)fake::point_order);
				uintptr_t target = warcraft3::jass::inline_hook_install(
					real::target_order, (uintptr_t)fake::target_order);
				if (immediate) real::immediate_order = immediate;
				if (point) real::point_order = point;
				if (target) real::target_order = target;
				if (!immediate || !point || !target) {
					japi_log::sync_write("[order] one or more debug inline hooks failed");
				}
			}
			b_debug_enabled = enabled;
			return 0;
		}
	}

	// ============================================================
	// Forward declaration: ML is the main Lua state, set in lset()
	// when the message hook is installed.
	// ============================================================
	static lua_State* ML = 0;

	// ============================================================
	// Texture event dispatch: check if an input event matches
	// any registered texture event's key and mouse-in-bounds
	// ============================================================
	static void dispatch_texture_events(lua_State* L, int wark_key, bool is_press)
	{
		// Mouse position in client coords, queried on demand
		// (same GetCursorPos/ScreenToClient approach as builtin-japi)
		HWND hw = get_window();
		if (!hw) return;
		POINT pt = { 0 };
		GetCursorPos(&pt);
		ScreenToClient(hw, &pt);
		RECT rt;
		GetClientRect(hw, &rt);
		float norm_x = (float)pt.x / (float)(rt.right - rt.left);
		float norm_y = (float)pt.y / (float)(rt.bottom - rt.top);

		for (auto& kv : g_texture_events)
		{
			if (!L) break;
			const texture_event_entry& ev = kv.second;
			// Match key: -1 means mouse event (button), otherwise keyboard
			if (ev.keycode != wark_key) continue;

			// Look up the texture
			auto it = g_textures.find(ev.texture_id);
			if (it == g_textures.end()) continue;
			const texture_entry& tex = it->second;
			if (!tex.visible || !tex.trigger_enabled) continue;

			// Check mouse bounds (tex coords are normalized 0..1 client coords)
			if (norm_x < tex.x || norm_x > tex.x + tex.w) continue;
			if (norm_y < tex.y || norm_y > tex.y + tex.h) continue;

			// Fire the callback via Lua registry ref
			uint32_t lua_ref = is_press ? ev.press_lua_ref : ev.release_lua_ref;
			if (lua_ref == 0) continue;
			safe_call_ref(L, lua_ref, 0, jass::TYPE_BOOLEAN);
		}

		// The bridge-facing D3D events use the real renderer hit-test registered
		// by newD3d9.dll, then schedule the supplied JASS code on the event's
		// retained timer. Timer handle ids and hashtable slots match builtin-japi.
		for (auto& kv : g_d3d_texture_events)
		{
			const d3d_texture_event_entry& ev = kv.second;
			if (ev.keycode != wark_key) continue;

			uint32_t texture_arg = ev.texture_id;
			uint32_t inside = 0;
			if (!bridge::invoke_cpp_handler(
					"GetMouseInTexture", &texture_arg, 1, &inside) || !inside) {
				continue;
			}

			uint32_t code = is_press ? ev.press_code : ev.release_code;
			if (!code) continue;

			uint32_t ht = bridge::get_ht_handle();
			if (!ht) continue;
			uint32_t timer = is_press ? ev.press_timer : ev.release_timer;
			uint32_t parent = (uint32_t)jass::call("GetHandleId", timer);
			if (!parent) continue;
			jass::call("SaveInteger", ht, parent, 0x0FF, ev.texture_id);
			jass::call("SaveInteger", ht, parent, 0x100, (uint32_t)wark_key);
			jass::call("SaveInteger", ht, parent, 0x101, is_press ? 1u : 0u);
			jass::call("SaveInteger", ht, parent, 0x0FE, ev.event_id);

			jass::func_value const* timer_start = jass::jass_func("TimerStart");
			if (!timer_start) continue;
			jass::call_param param(4);
			param.push<uintptr_t>(0, timer);
			param.push_real(1, jass::to_real(0.0f));
			param.push<bool>(2, false);
			param.push<uintptr_t>(3, code);
			timer_start->call(param);
		}
	}

	// ============================================================
	// In-game message filter (CGameUI message dispatch)
	// ============================================================
	static bool keyboard_event(lua_State* L, const char* type, keyboard_message_t* msg)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "_JASS_MESSAGE_HANDLE");
		if (!lua_isfunction(L, -1))
		{
			lua_pop(L, 1);
			return true;
		}
		lua_newtable(L);
		lua_pushstring(L, type);
		lua_setfield(L, -2, "type");
		if (msg)
		{
			lua_pushinteger(L, msg->keycode);
			lua_setfield(L, -2, "code");
			lua_pushinteger(L, msg->keystate);
			lua_setfield(L, -2, "state");
		}
		lua_insert(L, -2);
		lua_pushvalue(L, -2);
		if (safe_call_not_sleep(L, 1, 1, true) != LUA_OK)
		{
			lua_pop(L, 1);
			return true;
		}
		int ok = lua_toboolean(L, -1);
		lua_pop(L, 1);
		if (ok && msg)
		{
			lua_getfield(L, -1, "code");
			msg->keycode = lua_tointeger(L, -1);
			lua_getfield(L, -2, "state");
			msg->keystate = lua_tointeger(L, -1);
			lua_pop(L, 2);
		}
		lua_pop(L, 1);
		return !!ok;
	}

	static bool mouse_event(lua_State* L, const char* type, mouse_message_t* msg)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "_JASS_MESSAGE_HANDLE");
		if (!lua_isfunction(L, -1))
		{
			lua_pop(L, 1);
			return true;
		}
		lua_newtable(L);
		lua_pushstring(L, type);
		lua_setfield(L, -2, "type");
		if (msg)
		{
			lua_pushinteger(L, msg->code);
			lua_setfield(L, -2, "code");
			lua_pushnumber(L, msg->wx);
			lua_setfield(L, -2, "x");
			lua_pushnumber(L, msg->wy);
			lua_setfield(L, -2, "y");
		}
		lua_insert(L, -2);
		lua_pushvalue(L, -2);
		if (safe_call_not_sleep(L, 1, 1, true) != LUA_OK)
		{
			lua_pop(L, 1);
			return true;
		}
		int ok = lua_toboolean(L, -1);
		lua_pop(L, 1);
		lua_pop(L, 1);
		return !!ok;
	}

	static bool ability_mouse_event(lua_State* L, ability_mouse_message_t* msg)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "_JASS_MESSAGE_HANDLE");
		if (!lua_isfunction(L, -1))
		{
			lua_pop(L, 1);
			return true;
		}
		lua_newtable(L);
		lua_pushstring(L, "mouse_ability");
		lua_setfield(L, -2, "type");
		if (msg && msg->button&& msg->button->ability)
		{
			lua_pushinteger(L, msg->code);
			lua_setfield(L, -2, "code");
			lua_pushinteger(L, msg->button->ability->ability_id);
			lua_setfield(L, -2, "ability");
			lua_pushinteger(L, msg->button->ability->order_id);
			lua_setfield(L, -2, "order");
		}
		lua_insert(L, -2);
		lua_pushvalue(L, -2);
		if (safe_call_not_sleep(L, 1, 1, true) != LUA_OK)
		{
			lua_pop(L, 1);
			return true;
		}
		int ok = lua_toboolean(L, -1);
		lua_pop(L, 1);
		lua_pop(L, 1);
		return !!ok;
	}

	// ============================================================
	// Pressed mouse buttons, tracked so texture release events can
	// be fired on mouse_up (the mouse_up message carries no button code)
	// ============================================================
	static bool g_mouse_button_down[5] = { false, false, false, false, false };

	static void queue_d3d_input(d3d::InputKind kind, int32_t code)
	{
		float x = 0.0f;
		float y = 0.0f;
		if (get_client_cursor(&x, &y)) d3d::queue_input_event(kind, code, x, y);
	}

	static bool __fastcall filter(uintptr_t /*cgameui*/, uintptr_t /*edx*/, message_t* msg)
	{
		if (!ML)
		{
			// No Lua hook registered yet: pass everything through
			return true;
		}
		switch (msg->msgid)
		{
		case 0x30064:
			return ability_mouse_event(ML, (ability_mouse_message_t*)msg);
			break;
		case 0x40060064:
			queue_d3d_input(d3d::InputKind::KeyDown,
				static_cast<int32_t>(((keyboard_message_t*)msg)->keycode));
			dispatch_texture_events(ML, (int)((keyboard_message_t*)msg)->keycode, true);
			return keyboard_event(ML, "key_down", (keyboard_message_t*)msg);
		case 0x40060066:
			queue_d3d_input(d3d::InputKind::KeyUp,
				static_cast<int32_t>(((keyboard_message_t*)msg)->keycode));
			dispatch_texture_events(ML, (int)((keyboard_message_t*)msg)->keycode, false);
			return keyboard_event(ML, "key_up", (keyboard_message_t*)msg);
			break;
		case 0x40060067:
			break;
		case 0x1A0068:
		{
			mouse_message_t* m = (mouse_message_t*)msg;
			if (m->code < 5)
			{
				g_mouse_button_down[m->code] = true;
			}
			queue_d3d_input(d3d::InputKind::MouseDown,
				static_cast<int32_t>(m->code));
			dispatch_texture_events(ML, (int)m->code, true);
			return mouse_event(ML, "mouse_down", m);
		}
		case 0x400500C9:
			for (int i = 0; i < 5; ++i)
			{
				if (g_mouse_button_down[i])
				{
					g_mouse_button_down[i] = false;
					queue_d3d_input(d3d::InputKind::MouseUp, i);
					dispatch_texture_events(ML, i, false);
				}
			}
			return mouse_event(ML, "mouse_up", 0);
		default:
			break;
		}
		return true;
	}

	// ============================================================
	// Install the in-game message filter. Self-contained and
	// idempotent; safe to call before any Lua hook is registered
	// (the filter passes all messages through until ML is set).
	// ============================================================
	static bool g_filter_installed = false;

	void install()
	{
		if (g_filter_installed) return;
		message_dispatch::add_filter((uintptr_t)filter);
		g_filter_installed = true;
	}

	static void uninstall()
	{
		if (!g_filter_installed) return;
		message_dispatch::remove_filter((uintptr_t)filter);
		g_filter_installed = false;
	}

	void ensure_input_dispatch(lua_State* L)
	{
		ML = get_mainthread(L);
		install();
	}

	void release_input_dispatch()
	{
		if (!g_lua_message_hook_registered && g_texture_events.empty()
			&& g_d3d_texture_events.empty() && !d3d::has_active_subscriptions()) {
			uninstall();
		}
	}

	static int lget(lua_State* L)
	{
		const char* name = lua_tostring(L, 2);
		if (strcmp("hook", name) == 0)
		{
			lua_getfield(L, LUA_REGISTRYINDEX, "_JASS_MESSAGE_HANDLE");
			return 1;
		}
		return 0;
	}

	static int lset(lua_State* L)
	{
		const char* name = lua_tostring(L, 2);
		if (strcmp("hook", name) == 0)
		{
			if (lua_isfunction(L, 3))
			{
				lua_pushvalue(L, 3);
				lua_setfield(L, LUA_REGISTRYINDEX, "_JASS_MESSAGE_HANDLE");
				ML = get_mainthread(L);
				g_lua_message_hook_registered = true;
				install();
			}
			else if (lua_isnil(L, 3))
			{
				lua_pushnil(L);
				lua_setfield(L, LUA_REGISTRYINDEX, "_JASS_MESSAGE_HANDLE");
				g_lua_message_hook_registered = false;
				if (g_texture_events.empty() && g_d3d_texture_events.empty()
					&& !d3d::has_active_subscriptions()) {
					uninstall();
				}
			}
			return 0;
		}
		return 0;
	}

	static int init_keyboard(lua_State* L)
	{
		lua_newtable(L);
#define SET_KEYBOARD(name) \
		lua_pushinteger(L, WARK_ ## name);	\
		lua_setfield(L, -2, #name)
		SET_KEYBOARD_ALL();
#undef SET_KEYBOARD
		return 1;
	}

	// ============================================================
	// Screen-space mouse coordinates (GetMouseVectorX / GetMouseVectorY)
	// Returns mouse position relative to War3 window in normalized [0..1] range
	// matching builtin-japi's GetMouseVectorX/GetMouseVectorY semantics
	// ============================================================
	static int lmouse_screen(lua_State* L)
	{
		HWND hw = get_window();
		POINT pt = { 0 };
		GetCursorPos(&pt);
		if (hw) ScreenToClient(hw, &pt);
		RECT rt = { 0 };
		if (hw) GetClientRect(hw, &rt);
		int w = rt.right - rt.left;
		int h = rt.bottom - rt.top;
		if (w <= 0) w = 1;
		if (h <= 0) h = 1;
		// Return normalized coordinates (0..1), matching builtin-japi semantics
		lua_pushnumber(L, (double)pt.x / (double)w);
		lua_pushnumber(L, (double)pt.y / (double)h);
		return 2;
	}

	// ============================================================
	// Keyboard simulation
	// SetKeyboard(key, is_down): set a key's state (press or release)
	// Uses PostMessage to the War3 window so it arrives through the
	// normal message queue (respects War3's internal dispatch).
	// ============================================================
	static bool post_keyboard(int wark_key, bool is_down)
	{
		int vk = warcraft3::input::wark_to_vk(wark_key);
		if (vk == 0) return false;

		HWND hw = get_window();
		if (!hw) return false;

		UINT msg = is_down ? WM_KEYDOWN : WM_KEYUP;
		LPARAM lParam = 0x00000001;  // repeat count=1, scan code=0
		if (!is_down)
		{
			lParam |= (0xC0 << 24);  // previous key state + transition state
		}
		return PostMessageW(hw, msg, (WPARAM)vk, lParam) != FALSE;
	}

	static int lset_keyboard(lua_State* L)
	{
		int wark_key = (int)lua_tointeger(L, 1);
		bool is_down = lua_toboolean(L, 2) != 0;
		lua_pushboolean(L, post_keyboard(wark_key, is_down));
		return 1;
	}

	// ClickKeyboard(key): simulate a full press+release cycle
	static int lclick_keyboard(lua_State* L)
	{
		int wark_key = (int)lua_tointeger(L, 1);
		if (!post_keyboard(wark_key, true)) return 0;
		post_keyboard(wark_key, false);
		return 0;
	}

	static uint32_t SetKeyboard_handler(const uint32_t* args, size_t nargs)
	{
		if (nargs >= 2) {
			post_keyboard((int)args[0], args[1] != 0);
		}
		return 0;
	}

	// ============================================================
	// ShowConsole: show/hide the War3 console UI
	// builtin-japi sets a flag that hides the command card / console
	// We implement it by finding the game UI frame and hiding child
	// windows, or by calling the War3 internal function.
	// Simplified: toggle console window visibility.
	// ============================================================
	static int lshow_console(lua_State* L)
	{
		bool show = lua_toboolean(L, 1) != 0;
		// The War3 console is rendered by the game engine, not a Win32 window.
		// In builtin-japi, ShowConsole hides the bottom console UI (command card,
		// resource bar, etc.). We find the ConsoleFrame via CGameUI child lookup.
		// For now, use the simpler approach: find "ConsoleWindowClass" child.
		HWND hw = get_window();
		if (!hw)
		{
			lua_pushboolean(L, 0);
			return 1;
		}

		// Try to find the console child window. War3 may use different class names.
		// Also try generic approach: find all child windows and toggle visibility.
		// builtin-japi actually manipulates the Frame (CSimpleFontString / CLayoutFrame),
		// not a Win32 HWND. We approximate with ShowWindow on the main window.
		// A proper implementation would call CGameUI->SetConsoleVisible().

		// Search for child windows with common War3 console class names
		static const wchar_t* console_classes[] = {
			L"ConsoleWindowClass",
			L"Warcraft III",
		};

		bool found = false;
		for (auto cls : console_classes)
		{
			HWND child = FindWindowExW(hw, NULL, cls, NULL);
			if (child)
			{
				ShowWindow(child, show ? SW_SHOW : SW_HIDE);
				found = true;
			}
		}

		// If no specific console window found, we can still toggle the
		// entire game's console rendering via the CGameUI pointer.
		// For now, store the state for future use.
		lua_pushboolean(L, found ? 1 : 0);
		return 1;
	}

	// ============================================================
	// TextureAddEvent: bind an event to a screen-space texture region
	// Lua API:
	//   local event_id = message.texture_add_event(texture_id, keycode, press_func, release_func)
	//   message.texture_remove_event(texture_id, event_id)
	//
	// texture_id: from message.texture_create()
	// keycode: WARK_* value from message.keyboard, or -1 for mouse buttons
	// press_func / release_func: Lua functions or JASS code references
	//
	// When an input event from the message filter matches the keycode AND
	// the mouse is within the texture's screen bounds, the callback fires.
	// ============================================================
	static int ltexture_create(lua_State* L)
	{
		// Args: x, y, w, h (normalized 0..1 screen coords)
		float x = (float)lua_tonumber(L, 1);
		float y = (float)lua_tonumber(L, 2);
		float w = (float)lua_tonumber(L, 3);
		float h = (float)lua_tonumber(L, 4);

		int id = g_next_texture_id++;
		texture_entry tex;
		tex.id = id;
		tex.x = x;
		tex.y = y;
		tex.w = w;
		tex.h = h;
		tex.visible = true;
		tex.trigger_enabled = true;
		g_textures[id] = tex;

		lua_pushinteger(L, id);
		return 1;
	}

	static int ltexture_destroy(lua_State* L)
	{
		int tex_id = (int)lua_tointeger(L, 1);
		g_textures.erase(tex_id);
		// Remove all events for this texture
		std::vector<int> to_remove;
		for (auto& kv : g_texture_events)
		{
			if (kv.second.texture_id == tex_id)
				to_remove.push_back(kv.first);
		}
		for (int id : to_remove) g_texture_events.erase(id);
		return 0;
	}

	static int ltexture_set_visible(lua_State* L)
	{
		int tex_id = (int)lua_tointeger(L, 1);
		bool vis = lua_toboolean(L, 2) != 0;
		auto it = g_textures.find(tex_id);
		if (it != g_textures.end()) it->second.visible = vis;
		return 0;
	}

	static int ltexture_set_trigger(lua_State* L)
	{
		int tex_id = (int)lua_tointeger(L, 1);
		bool en = lua_toboolean(L, 2) != 0;
		auto it = g_textures.find(tex_id);
		if (it != g_textures.end()) it->second.trigger_enabled = en;
		return 0;
	}

	static int ltexture_set_rect(lua_State* L)
	{
		int tex_id = (int)lua_tointeger(L, 1);
		float x = (float)lua_tonumber(L, 2);
		float y = (float)lua_tonumber(L, 3);
		float w = (float)lua_tonumber(L, 4);
		float h = (float)lua_tonumber(L, 5);
		auto it = g_textures.find(tex_id);
		if (it != g_textures.end())
		{
			it->second.x = x;
			it->second.y = y;
			it->second.w = w;
			it->second.h = h;
		}
		return 0;
	}

	static int ltexture_add_event(lua_State* L)
	{
		// Args: texture_id, keycode, press_func, release_func
		int tex_id   = (int)lua_tointeger(L, 1);
		int keycode  = (int)lua_tointeger(L, 2);

		// Validate texture exists
		if (g_textures.find(tex_id) == g_textures.end())
		{
			lua_pushinteger(L, 0);
			return 1;
		}

		int ev_id = g_next_event_id++;
		texture_event_entry ev;
		ev.event_id         = ev_id;
		ev.texture_id       = tex_id;
		ev.keycode          = keycode;
		ev.press_lua_ref    = 0;
		ev.release_lua_ref  = 0;

		// Arg 3: press callback (Lua function)
		if (lua_isfunction(L, 3))
		{
			// Store Lua ref for direct callback from the message filter
			ev.press_lua_ref = runtime::callback_push(L, 3);
		}
		else if (lua_isnumber(L, 3))
		{
			// Already a Lua registry ref (integer)
			ev.press_lua_ref = (uint32_t)lua_tointeger(L, 3);
		}

		// Arg 4: release callback (Lua function)
		if (lua_isfunction(L, 4))
		{
			ev.release_lua_ref = runtime::callback_push(L, 4);
		}
		else if (lua_isnumber(L, 4))
		{
			ev.release_lua_ref = (uint32_t)lua_tointeger(L, 4);
		}

		g_texture_events[ev_id] = ev;
		ML = get_mainthread(L);
		install();
		lua_pushinteger(L, ev_id);
		return 1;
	}

	static int ltexture_remove_event(lua_State* L)
	{
		// Args: texture_id, event_id
		// (texture_id is kept for API compatibility with builtin-japi but not strictly needed)
		/*int tex_id =*/ (void)lua_tointeger(L, 1);
		int ev_id = (int)lua_tointeger(L, 2);
		g_texture_events.erase(ev_id);
		return 0;
	}

	// ============================================================
	// Bridge natives (builtin-japi parity): mouse / selection / local orders
	// These reuse the same internal helpers as the Lua API above and are
	// registered into the UnitId bridge dispatch via register_bridge_natives().
	// ============================================================
	static void mouse_world(float& wx, float& wy)
	{
		HWND war3_window = get_window();
		POINT pt = { 0 };
		::GetCursorPos(&pt);
		ScreenToClient(war3_window, &pt);
		RECT rt;
		::GetClientRect(war3_window, &rt);
		float fx = 0.8f * ((float)(pt.x - rt.left) / (rt.right - rt.left));
		float fy = 0.6f * (1.0f - (float)(pt.y - rt.top) / (rt.bottom - rt.top));
		convert_xy(fx, fy, wx, wy);
	}

	uint32_t GetMouseX_handler(const uint32_t*, size_t) {
		float wx, wy;
		mouse_world(wx, wy);
		return jass::to_real(wx);
	}
	uint32_t GetMouseY_handler(const uint32_t*, size_t) {
		float wx, wy;
		mouse_world(wx, wy);
		return jass::to_real(wy);
	}
	uint32_t GetMouseVectorX_handler(const uint32_t*, size_t) {
		// pixels relative to the War3 window client area
		HWND hw = get_window();
		POINT pt = { 0 };
		::GetCursorPos(&pt);
		if (hw) ScreenToClient(hw, &pt);
		return jass::to_real((float)pt.x);
	}
	uint32_t GetMouseVectorY_handler(const uint32_t*, size_t) {
		HWND hw = get_window();
		POINT pt = { 0 };
		::GetCursorPos(&pt);
		if (hw) ScreenToClient(hw, &pt);
		return jass::to_real((float)pt.y);
	}

	uint32_t GetPlayerSelectedUnit_handler(const uint32_t* a, size_t) {
		player::selection_t* slt = player::selection(player::from_id(a[0]));
		if (!slt || !slt->unit) return 0;
		return (uint32_t)object_to_handle(slt->unit);
	}

	// The order-submit chain readiness (docs/re-builtin-japi/08-gameui-verify.md §6):
	// [base+0xBE4238]+0x28 is a WORD slot index ("current orderer"), bound to the
	// local player id during session slot-sync at match start; fn#1 indexes a
	// 12-entry pointer array at g+0x58 with it and derefs elem+0x34 without NULL
	// checks. Guard all four layers — calling before the bind AVs (and an AV
	// aborts the whole jass call context).
	static bool order_submit_ready()
	{
		uintptr_t base = get_war3_searcher().base();
		uintptr_t g = *(uintptr_t*)(base + 0xBE4238);
		if (!g || IsBadReadPtr((void*)g, 0x88)) return false;
		uint32_t idx = *(uint16_t*)(g + 0x28);
		if (idx >= 12) return false;
		uintptr_t elem = *(uintptr_t*)(g + 0x58 + 4 * idx);
		if (!elem || IsBadReadPtr((void*)elem, 0x38)) return false;
		return *(uintptr_t*)(elem + 0x34) != 0;
	}

	uint32_t LocalOrder_handler(const uint32_t* a, size_t) {
		order::search();
		if (!order_submit_ready()) return 0;
		base::fast_call<int>(order::real::immediate_order, a[0], 0, a[1]);
		return 0;
	}
	uint32_t LocalPointOrder_handler(const uint32_t* a, size_t) {
		if (!order_submit_ready()) return 0;
		float x = jass::from_real(a[1]);
		float y = jass::from_real(a[2]);
		order::submit_point(a[0], x, y, a[3]);
		return 0;
	}
	uint32_t LocalTargetOrder_handler(const uint32_t* a, size_t) {
		order::search();
		if (!order_submit_ready()) return 0;
		// builtin-japi: coordinates come from GetWidgetX/Y on the target widget
		float x = jass::from_real((jass::jreal_t)jass::call("GetWidgetX", a[1]));
		float y = jass::from_real((jass::jreal_t)jass::call("GetWidgetY", a[1]));
		uint32_t target = a[1] ? handle_to_object(a[1]) : 0;
		base::fast_call<int>(order::real::target_order, a[0], 0, &x, &y, target, a[2]);
		return 0;
	}

	// GetTargetObject ()Hunit — current mouse-hover target (unit/item/destructable).
	// builtin-japi resolver 0x10032CFB (docs/re-builtin-japi/07-local-order.md §2).
	static uintptr_t search_target_object_global()
	{
		war3_searcher& s = get_war3_searcher();
		uintptr_t str = s.search_string_ptr("CPreselectUI.cpp", sizeof("CPreselectUI.cpp"));
		if (!str) return 0;
		uintptr_t path = str;
		for (; *(unsigned char*)path != ':'; --path) { }
		path--;
		uintptr_t ref;
		{   // builtin's pattern is "00 00 00 68 <pathVA>" — the 3-zero prefix
			// disambiguates the correct push site among several path references.
			uint8_t pat[8] = { 0x00, 0x00, 0x00, 0x68, 0, 0, 0, 0 };
			memcpy(pat + 4, &path, 4);
			uint32_t head;
			memcpy(&head, pat, 4);
			uintptr_t m = s.search_int_in_text(head);
			while (m && 0 != memcmp((const void*)m, pat, sizeof pat))
			{
				m = s.search_int_in_text(head, m + 1);
			}
			ref = m;
		}
		if (!ref) return 0;
		return *(uint32_t*)(ref + (s.get_version() >= version_127a ? 0xAA : 0xA6));
	}

	uint32_t GetTargetObject_handler(const uint32_t*, size_t) {
		static uintptr_t g = search_target_object_global();
		if (!g || IsBadReadPtr((void*)g, 4)) return 0;
		uint32_t obj = *(uint32_t*)g;
		if (!obj || IsBadReadPtr((void*)obj, 4)) return 0;
		return (uint32_t)object_to_handle(obj);
	}

	// SetUnitAbilityButtonShow (IIB)V — hide/show a unit ability button
	// (hidden == disabled). builtin-japi 0x10032C2A (07 doc §3).
	static uintptr_t search_get_ability_button_fn()
	{
		// anchor "push 1;push 1;push eax;push 1;call" (6A 01 6A 01 50 6A 01 E8);
		// target = call at p+0xF  ->  p + 0x14 + rel32. No version branch.
		war3_searcher& s = get_war3_searcher();
		static const uint8_t pat[] = { 0x6A, 0x01, 0x6A, 0x01, 0x50, 0x6A, 0x01, 0xE8 };
		uint32_t head;
		memcpy(&head, pat, sizeof head);
		uintptr_t p = s.search_int_in_text(head);
		while (p && 0 != memcmp((const void*)p, pat, sizeof pat))
		{
			p = s.search_int_in_text(head, p + 1);
		}
		if (!p) return 0;
		return p + 0x14 + *(int32_t*)(p + 0x10);
	}

	uint32_t SetUnitAbilityButtonShow_handler(const uint32_t* a, size_t) {
		static uintptr_t fn = search_get_ability_button_fn();
		if (!fn || !a[0] || !a[1]) return 0;
		uint32_t uobj = (uint32_t)handle_to_object(a[0]);
		if (!uobj) return 0;
		uintptr_t btn = base::fast_call<uintptr_t>(fn, uobj, 0, a[1], 0, 1, 1, 1);
		if (!btn || IsBadReadPtr((void*)btn, 4) || !*(uint32_t*)btn) return 0;
		// +0x40 stores the inverted flag: 1 = hidden/disabled, 0 = shown
		*(uint32_t*)(btn + 0x40) = a[2] ? 0 : 1;
		return 0;
	}

	// Custom native used by builtin-japi's GetFuncAddr(code) wrapper. The map
	// declares SetHeroLevels as (C)V, then reads the raw code value from slot 0.
	// Registering it as a real JASS native keeps the original wrapper usable.
	static void __cdecl SetHeroLevels_capture(jass::jcode_t code)
	{
		uint32_t ht = bridge::get_ht_handle();
		uint32_t key = bridge::get_ht_key();
		if (!ht || !key) return;
		__try {
			jass::call("SaveInteger", ht, key, 0, code);
		} __except(EXCEPTION_EXECUTE_HANDLER) {
			japi_log::sync_write("[D3D event] SetHeroLevels code capture failed");
		}
	}

	static uint32_t TextureAddEvent_handler(const uint32_t* a, size_t nargs)
	{
		if (nargs < 4 || !a[0] || (!a[2] && !a[3])) return 0;

		uint32_t status = 0;
		if (!bridge::invoke_cpp_handler("GetD3DStatus", nullptr, 0, &status) ||
			(status & 0x02u) == 0) {
			return 0;
		}

		uint32_t press_timer = 0;
		uint32_t release_timer = 0;
		uint32_t event_id = 0;
		press_timer = (uint32_t)jass::call("CreateTimer");
		release_timer = (uint32_t)jass::call("CreateTimer");
		if (press_timer) event_id = (uint32_t)jass::call("GetHandleId", press_timer);
		if (!press_timer || !release_timer || !event_id) {
			if (press_timer) jass::call("DestroyTimer", press_timer);
			if (release_timer) jass::call("DestroyTimer", release_timer);
			return 0;
		}

		jass::handle_ref(press_timer);
		jass::handle_ref(release_timer);
		d3d_texture_event_entry ev = {};
		ev.event_id = event_id;
		ev.press_timer = press_timer;
		ev.release_timer = release_timer;
		ev.texture_id = a[0];
		ev.keycode = (int)a[1];
		ev.press_code = a[2];
		ev.release_code = a[3];
		g_d3d_texture_events[event_id] = ev;

		ML = lua_loader::getMainL();
		install();
		return event_id;
	}

	static uint32_t TextureRemoveEvent_handler(const uint32_t* a, size_t nargs)
	{
		if (nargs < 2) return 0;
		auto it = g_d3d_texture_events.find(a[1]);
		if (it == g_d3d_texture_events.end() || it->second.texture_id != a[0]) {
			return 0;
		}

		uint32_t press_timer = it->second.press_timer;
		uint32_t release_timer = it->second.release_timer;
		g_d3d_texture_events.erase(it);
		jass::call("DestroyTimer", press_timer);
		jass::call("DestroyTimer", release_timer);
		jass::handle_unref(press_timer);
		jass::handle_unref(release_timer);
		if (!g_lua_message_hook_registered && g_texture_events.empty() &&
			g_d3d_texture_events.empty() && !d3d::has_active_subscriptions()) {
			uninstall();
		}
		return 0;
	}

	static uint32_t GetTextureEventCount_handler(const uint32_t*, size_t)
	{
		return (uint32_t)g_d3d_texture_events.size();
	}

	void register_bridge_natives()
	{
		static bool done = false;
		if (done) return;
		done = true;
		using bridge_fn = uint32_t (*)(const uint32_t*, size_t);
		auto reg = [](const char* name, const char* spec, bridge_fn fn) {
			warcraft3::lua_engine::bridge::register_cpp_handler(name, spec, fn);
		};
		reg("GetMouseX",           "()R",          GetMouseX_handler);
		reg("GetMouseY",           "()R",          GetMouseY_handler);
		reg("GetMouseVectorX",     "()R",          GetMouseVectorX_handler);
		reg("GetMouseVectorY",     "()R",          GetMouseVectorY_handler);
		reg("SetKeyboard",         "(IB)V",        SetKeyboard_handler);
		reg("GetPlayerSelectedUnit","(I)Hunit;",   GetPlayerSelectedUnit_handler);
		reg("LocalOrder",          "(II)V",        LocalOrder_handler);
		reg("LocalPointOrder",     "(IRRI)V",      LocalPointOrder_handler);
		reg("LocalTargetOrder",    "(IHwidget;I)V",LocalTargetOrder_handler);
		reg("GetTargetObject",     "()Hunit;",     GetTargetObject_handler);
		reg("SetUnitAbilityButtonShow", "(IIB)V",  SetUnitAbilityButtonShow_handler);
		reg("TextureAddEvent",     "(IIII)I",      TextureAddEvent_handler);
		reg("TextureRemoveEvent",  "(II)V",        TextureRemoveEvent_handler);
		reg("GetTextureEventCount", "()I",         GetTextureEventCount_handler);

		// Required by the original JASS GetFuncAddr wrapper used to obtain the
		// two code parameters passed to TextureAddEvent.
		jass::japi_add((uintptr_t)SetHeroLevels_capture, "SetHeroLevels", "(C)V");
	}

	int open(lua_State* L)
	{
		lua_newtable(L);
		{
			lua_pushstring(L, "keyboard");
			init_keyboard(L);
			lua_rawset(L, -3);

			{
				luaL_Reg func[] = {
					{ "mouse", lmouse },
					{ "button", lbutton },
					{ "selection", lselection },
					// Screen-space mouse (builtin-japi: GetMouseVectorX/GetMouseVectorY)
					{ "mouse_screen", lmouse_screen },
					// Keyboard simulation (builtin-japi: SetKeyboard/ClickKeyboard)
					{ "set_keyboard", lset_keyboard },
					{ "click_keyboard", lclick_keyboard },
					// Console control (builtin-japi: ShowConsole)
					{ "show_console", lshow_console },
					// Texture event system (builtin-japi: TextureAddEvent)
					{ "texture_create", ltexture_create },
					{ "texture_destroy", ltexture_destroy },
					{ "texture_set_visible", ltexture_set_visible },
					{ "texture_set_trigger", ltexture_set_trigger },
					{ "texture_set_rect", ltexture_set_rect },
					{ "texture_add_event", ltexture_add_event },
					{ "texture_remove_event", ltexture_remove_event },
					{ NULL, NULL },
				};
				luaL_setfuncs(L, func, 0);
			}

			if (get_war3_searcher().get_version() >= version_124e)
			{
				luaL_Reg func[] = {
					{ "order_immediate", order::limmediate },
					{ "order_point", order::lpoint },
					{ "order_target", order::ltarget },
					{ "order_enable_debug", order::lenable_debug },
					{ NULL, NULL },
				};
				luaL_setfuncs(L, func, 0);
			}

			lua_newtable(L);
			{
				lua_pushstring(L, "__index");
				lua_pushcclosure(L, lget, 0);
				lua_rawset(L, -3);

				lua_pushstring(L, "__newindex");
				lua_pushcclosure(L, lset, 0);
				lua_rawset(L, -3);
			}
			lua_setmetatable(L, -2);

		}
		return 1;
	}
}

// EventDamageData.cpp — EX* event damage natives
// Ported from YDWE yd_jass_api/EventDamageData.cpp
// Hooks the unit damage function to intercept damage events.
// Provides EXGetEventDamageData and EXSetEventDamage, plus GetEventDamage hook.

#include <warcraft3/war3_searcher.h>
#include <warcraft3/version.h>
#include <warcraft3/hashtable.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/jass/inline_hook.h>
#include <warcraft3/jass/func_value.h>
#include <warcraft3/jass.h>
#include <base/hook/replace_pointer.h>
#include <base/hook/fp_call.h>
#include <deque>
#include "debug_log.h"

namespace warcraft3::japi {

static uintptr_t g_external_get_event_damage_data = 0;
static uintptr_t g_external_set_event_damage = 0;

uintptr_t searchUnitDamageFunc()
{
	war3_searcher& s = get_war3_searcher();
	uintptr_t str = s.search_string_ptr("EtherealDamageBonusAlly", sizeof("EtherealDamageBonusAlly"));

	for (uintptr_t ptr = s.search_int_in_text(str); ptr; ptr = s.search_int_in_text(str, ptr + 1))
	{
		uintptr_t func = s.current_function(ptr);
		if (ptr - func > 1000)
		{
			return s.search_int_in_rdata(func);
		}
	}

	return 0;
}

uintptr_t getUnitDamageFunc()
{
	static uintptr_t s_result = searchUnitDamageFunc();
	return s_result;
}

struct war3_event_damage_data
{
	uint32_t source_unit;
	uint32_t weapon_type;
	uint32_t unk2;
	uint32_t flag;
	uint32_t amount;
	uint32_t damage_type;
	uint32_t unk6;
	uint32_t unk7;
	uint32_t attack_type;
};

struct event_damage_data
{
	bool                    physical;
	bool                    change;
	war3_event_damage_data* data;
	uint32_t                old_amount;
	uint32_t                new_amount;

	event_damage_data(uint32_t is_physical, war3_event_damage_data* ptr)
		: physical(!!is_physical)
		, change(false)
		, data(ptr)
		, old_amount(0)
		, new_amount(0)
	{ }

	bool is_same(uint32_t* damage1, uint32_t* damage2) const
	{
		if (!old_amount)
		{
			return true;
		}

		if ((*damage1 ^ *damage2) != 0x80000000)
		{
			return false;
		}

		return old_amount == *damage1;
	}

	uint32_t damage_type()
	{
		uint32_t v = data->damage_type;
		uint32_t n = 0;
		for (; v; v >>= 1)
		{
			++n;
		}

		return n - 1;
	}
};


std::deque<event_damage_data> g_edd;

uintptr_t RealGetEventDamage = 0;
uint32_t __cdecl FakeGetEventDamage()
{
	if (!g_edd.empty())
	{
		event_damage_data& edd = g_edd.back();
		if (edd.change)
		{
			return g_edd.back().new_amount;
		}
	}

	return base::fast_call<uint32_t>(RealGetEventDamage);
}

uintptr_t RealUnitDamageDoneFunc = 0;
uint32_t __fastcall FakeUnitDamageDoneFunc(uint32_t _this, uint32_t _edx, uint32_t* damage1, uint32_t* damage2)
{
	if (!g_edd.empty())
	{
		event_damage_data& edd = g_edd.back();
		if (edd.change)
		{
			edd.change = false;
			float d = jass::from_real(edd.new_amount);
			uint32_t new_damage1 = jass::to_real(d);
			uint32_t new_damage2 = jass::to_real(-d);
			return base::fast_call<uint32_t>(RealUnitDamageDoneFunc, _this, _edx, &new_damage1, &new_damage2);
		}
	}

	return base::fast_call<uint32_t>(RealUnitDamageDoneFunc, _this, _edx, damage1, damage2);
}

uintptr_t RealUnitDamageFunc = 0;
uint32_t __fastcall FakeUnitDamageFunc(uint32_t _this, uint32_t _edx, uint32_t a2, war3_event_damage_data* ptr, uint32_t is_physical, uint32_t source_unit)
{
	if ((uintptr_t)FakeUnitDamageDoneFunc != *(uintptr_t*)(*(uint32_t*)_this + 296))
	{
		RealUnitDamageDoneFunc = base::hook::replace_pointer(*(uint32_t*)_this + 296, (uintptr_t)FakeUnitDamageDoneFunc);
	}

	g_edd.push_back(event_damage_data(is_physical, ptr));
	uint32_t retval = base::fast_call<uint32_t>(RealUnitDamageFunc, _this, _edx, a2, ptr, is_physical, source_unit);
	g_edd.pop_back();
	return retval;
}


enum EVENT_DAMAGE_DATA_TYPE
{
	EVENT_DAMAGE_DATA_VAILD  = 0,
	EVENT_DAMAGE_DATA_PHYSICAL,
	EVENT_DAMAGE_DATA_IS_ATTACK,
	EVENT_DAMAGE_DATA_IS_RANGED,
	EVENT_DAMAGE_DATA_DAMAGE_TYPE,
	EVENT_DAMAGE_DATA_WEAPON_TYPE,
	EVENT_DAMAGE_DATA_ATTACK_TYPE,
};

uint32_t __cdecl EXGetEventDamageData(uint32_t type)
{
	if (g_external_get_event_damage_data)
	{
		return base::c_call<uint32_t>(g_external_get_event_damage_data, type);
	}
	if (g_edd.empty())
	{
		return 0;
	}

	war3_event_damage_data* ptr = g_edd.back().data;

	switch (type)
	{
	case EVENT_DAMAGE_DATA_VAILD:
		return 1;
	case EVENT_DAMAGE_DATA_PHYSICAL:
		return g_edd.back().physical;
	case EVENT_DAMAGE_DATA_IS_ATTACK:
		return !!(ptr->flag & 0x100);
	case EVENT_DAMAGE_DATA_IS_RANGED:
		return !!(ptr->flag & 0x001);
	case EVENT_DAMAGE_DATA_DAMAGE_TYPE:
		return g_edd.back().damage_type();
	case EVENT_DAMAGE_DATA_WEAPON_TYPE:
		return ptr->weapon_type;
	case EVENT_DAMAGE_DATA_ATTACK_TYPE:
		return ptr->attack_type;
	default:
		break;
	}

	return 0;
}

bool __cdecl EXSetEventDamage(uint32_t value)
{
	if (g_external_set_event_damage)
	{
		return base::c_call<bool>(g_external_set_event_damage, value);
	}
	if (g_edd.empty())
	{
		return false;
	}

	event_damage_data& edd = g_edd.back();
	edd.change = true;
	edd.old_amount = edd.data->amount;
	edd.new_amount = *(uint32_t*)value;

	return true;
}

void InitializeEventDamageData()
{
	uintptr_t get_fn = g_external_get_event_damage_data
		? g_external_get_event_damage_data
		: (uintptr_t)EXGetEventDamageData;
	uintptr_t set_fn = g_external_set_event_damage
		? g_external_set_event_damage
		: (uintptr_t)EXSetEventDamage;
	jass::japi_add(get_fn, "EXGetEventDamageData", "(I)I");
	jass::japi_add(set_fn, "EXSetEventDamage",     "(R)B");
}

// Callback mode loads after the JASS VM has already been created, so the
// original YDWE event_add/japi_hook registration path never runs.
//
// Builtin-japi coexistence rule (jass.dll 0x10033617..0x10033761):
//   If a host plugin (KKWE / YDWE / platform) has ALREADY registered
//   EXGetEventDamageData and EXSetEventDamage in the game's native table,
//   it already owns the UnitDamageFunc vtable hook and damage stack. Reuse
//   its function pointers instead of searching .rdata (which now holds the
//   host detour) or double-hooking GetEventDamage.
//   Only on a vanilla 1.27a process do we install our own hooks:
//   1. replace the unit-damage vtable slot discovered by searchUnitDamageFunc;
//   2. inline-hook GetEventDamage so a value changed by EXSetEventDamage is
//      visible immediately inside EVENT_UNIT_DAMAGED.
bool install_event_damage_hooks()
{
	static bool attempted = false;
	static bool installed = false;
	if (attempted) return installed;
	attempted = true;

	// Coexistence check: reuse host plugin's damage natives when present.
	if (auto* ht = get_native_function_hashtable()) {
		auto* ext_get = ht->find("EXGetEventDamageData");
		auto* ext_set = ht->find("EXSetEventDamage");
		if (ext_get && ext_get->func_address_ && ext_set && ext_set->func_address_ &&
			ext_get->func_address_ != (uint32_t)(uintptr_t)EXGetEventDamageData &&
			ext_set->func_address_ != (uint32_t)(uintptr_t)EXSetEventDamage)
		{
			g_external_get_event_damage_data = (uintptr_t)ext_get->func_address_;
			g_external_set_event_damage = (uintptr_t)ext_set->func_address_;
			DBG_LOG("[EventDamageData] reusing host EXGetEventDamageData=0x%08X EXSetEventDamage=0x%08X",
				(uint32_t)g_external_get_event_damage_data,
				(uint32_t)g_external_set_event_damage);
			// Mirror builtin-japi (0x10033682): sync jass.common's cached
			// GetEventDamage address to the live native table entry so Lua sees
			// the host plugin's hooked GetEventDamage after EXSetEventDamage.
			if (auto* ext_dmg = ht->find("GetEventDamage")) {
				if (ext_dmg->func_address_) {
					const jass::func_value* mapped = jass::jass_func("GetEventDamage");
					if (mapped && mapped->is_valid() &&
						mapped->get_address() != (uintptr_t)ext_dmg->func_address_)
					{
						auto it = jass::jass_function.find("GetEventDamage");
						if (it != jass::jass_function.end()) {
							it->second = jass::func_value(it->second, (uintptr_t)ext_dmg->func_address_);
							DBG_LOG("[EventDamageData] synced GetEventDamage -> host 0x%08X",
								(uint32_t)ext_dmg->func_address_);
						}
					}
				}
			}
			installed = true;
			return true;
		}
	}

	uintptr_t damage_slot = getUnitDamageFunc();
	if (!damage_slot || IsBadReadPtr((void*)damage_slot, sizeof(uintptr_t))) {
		return false;
	}
	uintptr_t current_damage = *(uintptr_t*)damage_slot;
	if (current_damage == (uintptr_t)FakeUnitDamageFunc) {
		if (!RealUnitDamageFunc) return false;
	} else {
		RealUnitDamageFunc = base::hook::replace_pointer(
			damage_slot, (uintptr_t)FakeUnitDamageFunc);
		if (!RealUnitDamageFunc) return false;
	}

	// Force the Lua-side native map to exist before patching. It caches the
	// registration-time address independently of the game's native hash table.
	const jass::func_value* mapped = jass::jass_func("GetEventDamage");
	if (!mapped || !mapped->is_valid()) return false;

	auto* node = get_native_function_hashtable()->find("GetEventDamage");
	if (!node || !node->func_address_) return false;
	uintptr_t current_get_damage = mapped->get_address();
	if (current_get_damage == (uintptr_t)FakeGetEventDamage) {
		if (!RealGetEventDamage) return false;
	} else {
		uintptr_t trampoline = jass::inline_hook_install(
			current_get_damage, (uintptr_t)FakeGetEventDamage);
		if (trampoline) {
			RealGetEventDamage = trampoline;
		} else {
			RealGetEventDamage = current_get_damage;
			// jass.common closures dispatch through jass_function, while compiled
			// JASS dispatches through the game's native table. Update both.
			auto it = jass::jass_function.find("GetEventDamage");
			if (it == jass::jass_function.end()) return false;
			it->second = jass::func_value(it->second, (uintptr_t)FakeGetEventDamage);
			node->func_address_ = (uint32_t)FakeGetEventDamage;
		}
	}

	installed = RealUnitDamageFunc != 0 && RealGetEventDamage != 0;
	return installed;
}

// Bridge dispatch handlers
uint32_t EXGetEventDamageData_handler(const uint32_t* a, size_t) {
	return (uint32_t)EXGetEventDamageData(a[0]);
}
uint32_t EXSetEventDamage_handler(const uint32_t* a, size_t) {
	// Bridge real arguments are IEEE-754 bits. The native ABI version receives
	// a pointer to those bits, so provide an address instead of treating the
	// float value itself as a pointer.
	uint32_t value = a[0];
	return EXSetEventDamage((uint32_t)(uintptr_t)&value) ? 1 : 0;
}

}

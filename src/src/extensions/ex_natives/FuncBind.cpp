// FuncBind.cpp — SaveFunc / func_bind_trigger_name bridge handlers
//
// Model: builtin-japi's map side calls SaveFunc(japiDoNothing's address) once at
// boot and func_bind_trigger_name(action_address, "label") for every trigger
// action it wants to see in run logs. We keep the same shape: a persistent
// anchor address plus an address -> UTF-8 label table that crash/run diagnostics
// can consult (common.cpp uses it to name a crashing code call).
//
// Evidence note: the builtin's DLL-side handler bodies are not in the reversed
// artifacts (docs/re-builtin-japi/02-jass-dll.md only shows the "SaveFunc"
// string and its xref), so the table layout here is our own; the on-the-wire
// contract (names, specs, slot order) follows the builtin map exactly.

#include <warcraft3/jass.h>
#include <warcraft3/jass/func_value.h>
#include <cstdio>
#include <map>
#include <string>
#include "../../debug_log.h"
#include "FuncBind.h"

namespace warcraft3::japi {

	namespace {
		std::map<uint32_t, std::string> g_func_bind;
		uint32_t g_save_func_addr = 0;
	}

	uint32_t SaveFunc_handler(const uint32_t* args, size_t nargs)
	{
		if (nargs < 1)
		{
			return 0;
		}
		g_save_func_addr = args[0];
		DBG_LOG("[FuncBind] SaveFunc anchor=0x%08X", args[0]);
		return 0;
	}

	uint32_t func_bind_trigger_name_handler(const uint32_t* args, size_t nargs)
	{
		if (nargs < 2)
		{
			return 0;
		}
		const char* label = jass::from_string((jass::jstring_t)args[1]);
		g_func_bind[args[0]] = (label ? label : "");
		DBG_LOG("[FuncBind] bind 0x%08X -> %s", args[0], (label ? label : ""));
		return 0;
	}

	const char* lookup_func_name(uint32_t func_address)
	{
		std::map<uint32_t, std::string>::const_iterator it = g_func_bind.find(func_address);
		if (it == g_func_bind.end())
		{
			return 0;
		}
		return it->second.c_str();
	}

	uint32_t find_func_address(const char* func_name)
	{
		if (!func_name || !*func_name)
		{
			return 0;
		}
		const jass::func_value* fv = jass::jass_func(func_name);
		if (!fv || !fv->is_valid())
		{
			fv = jass::japi_func(func_name);
		}
		if (!fv || !fv->is_valid())
		{
			return 0;
		}
		return (uint32_t)fv->get_address();
	}

	uint32_t save_func_addr()
	{
		return g_save_func_addr;
	}

	size_t func_bind_count()
	{
		return g_func_bind.size();
	}

	void clear_func_bind()
	{
		if (!g_func_bind.empty() || g_save_func_addr)
		{
			DBG_LOG("[FuncBind] clearing %u binding(s) on map boot", (unsigned)g_func_bind.size());
		}
		g_func_bind.clear();
		g_save_func_addr = 0;
	}

}

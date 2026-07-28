#pragma once

#include <cstdint>

namespace warcraft3::jass {

	// Installs a 5-byte near JMP at `target`, detouring execution to `detour`.
	// The stolen instructions are moved into a freshly allocated trampoline
	// that jumps back to target+stolen_len. Returns the trampoline address
	// (use it to call the original function), or 0 on failure.
	//
	// This mirrors how builtin-japi's jass.dll hooks UnitId (inline hook on the
	// native's code instead of editing the native linked list / hash table).
	// Only position-independent instructions may be stolen; if any stolen
	// instruction uses a relative operand (call/jmp/jcc), the install fails.
	uintptr_t inline_hook_install(uintptr_t target, uintptr_t detour);
}

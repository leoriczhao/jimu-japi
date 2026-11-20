#pragma once

#include <cstdint>
#include <cstddef>

namespace warcraft3::jass {

	// Everything needed to undo an installed inline hook. builtin-japi keeps the
	// same record per patch (target + original bytes + length), which is what
	// makes "hook on map entry, unhook on map exit" possible at all — see
	// docs/re-builtin-japi/10-tables-hooks-and-game-side.md.
	struct inline_hook_info
	{
		uintptr_t target     = 0;   // patched address
		uintptr_t detour     = 0;   // what the JMP points at
		size_t    stolen     = 0;   // bytes overwritten (>= 5, whole instructions)
		uintptr_t trampoline = 0;   // call this to reach the original code
		uint8_t   original[16] = {}; // the bytes that were there before

		bool valid() const { return target != 0 && stolen != 0; }
	};

	// Installs a 5-byte near JMP at `target`, detouring execution to `detour`.
	// The stolen instructions are moved into a freshly allocated trampoline
	// that jumps back to target+stolen_len. Returns the trampoline address
	// (use it to call the original function), or 0 on failure.
	//
	// Installs are tracked per target: calling this again for a target that is
	// already hooked with the same detour returns the existing trampoline
	// instead of patching twice (a second patch would make the trampoline jump
	// to itself). A different detour replaces the old hook.
	//
	// When `out` is given it is filled with the record inline_hook_uninstall()
	// needs; on failure `out` is cleared.
	//
	// This mirrors how builtin-japi's jass.dll hooks UnitId (inline hook on the
	// native's code instead of editing the native linked list / hash table).
	// Only position-independent instructions may be stolen; if any stolen
	// instruction uses a relative operand (call/jmp/jcc), the install fails.
	uintptr_t inline_hook_install(uintptr_t target, uintptr_t detour, inline_hook_info* out = nullptr);

	// Puts the original bytes back and frees the trampoline, then clears the
	// record and drops it from the tracked set. Idempotent; safe to call on a
	// never-installed or already-removed record. Returns false only when the
	// memory protection change fails.
	bool inline_hook_uninstall(inline_hook_info* info);

	// Map boot re-entry: the engine may have rewritten native code (it rebuilds
	// its own tables every map), so every tracked hook is checked and re-patched
	// from its saved record when the JMP is gone. Returns how many were restored.
	// `skipped_foreign` (optional) reports how many hooks were left alone
	// because the site holds somebody else's patch.
	size_t inline_hook_reassert_all(size_t* skipped_foreign = nullptr);

	// Restore every tracked hook and forget them (shutdown / test teardown).
	size_t inline_hook_reset_all();

	// Number of hooks currently tracked (installed).
	size_t inline_hook_count();
}

#include <warcraft3/jass/inline_hook.h>
extern "C" {
#include <warcraft3/udis86/udis86.h>
}
#include <Windows.h>
#include <cstring>
#include <vector>

namespace warcraft3::jass {

	// Instructions with PC-relative operands cannot be relocated verbatim.
	static bool has_relative_operand(const uint8_t* insn, size_t len)
	{
		uint8_t b0 = insn[0];
		if (b0 == 0xE8 || b0 == 0xE9 || b0 == 0xEB) return true;                 // call/jmp rel
		if (b0 >= 0x70 && b0 <= 0x7F) return true;                                // jcc short
		if (b0 == 0x0F && len >= 2 && insn[1] >= 0x80 && insn[1] <= 0x8F) return true; // jcc near
		return false;
	}

	// ── tracked hook set ────────────────────────────────────────────────────
	// A hook that patches game code must survive a map boot (the code stays
	// patched) but must never be applied twice (a second JMP would make the
	// trampoline jump to itself). The registry is what makes both true: install
	// is keyed by target, and the map-boot path can ask every hook to re-check
	// its bytes instead of blindly re-patching.
	namespace {

		std::vector<inline_hook_info>& hooks()
		{
			static std::vector<inline_hook_info> instance;
			return instance;
		}

		CRITICAL_SECTION& lock()
		{
			static CRITICAL_SECTION cs;
			static volatile LONG state = 0;   // 0 = fresh, 1 = initialising, 2 = ready
			if (InterlockedCompareExchange(&state, 1, 0) == 0) {
				InitializeCriticalSection(&cs);
				InterlockedExchange(&state, 2);
			} else {
				while (state != 2) Sleep(0);
			}
			return cs;
		}

		struct guard {
			guard() { EnterCriticalSection(&lock()); }
			~guard() { LeaveCriticalSection(&lock()); }
		};

		bool lookup(uintptr_t target, inline_hook_info* out)
		{
			guard g;
			for (auto& h : hooks()) {
				if (h.target == target) {
					if (out) *out = h;
					return true;
				}
			}
			return false;
		}

		void forget(uintptr_t target)
		{
			guard g;
			auto& v = hooks();
			for (auto it = v.begin(); it != v.end(); ++it) {
				if (it->target == target) { v.erase(it); break; }
			}
		}

		// Write the JMP (and NOP padding) described by `info` into its target.
		bool write_jump(const inline_hook_info& info)
		{
			DWORD old_prot = 0;
			if (!VirtualProtect((void*)info.target, info.stolen, PAGE_EXECUTE_READWRITE, &old_prot)) {
				return false;
			}
			*(uint8_t*)info.target = 0xE9;
			*(int32_t*)(info.target + 1) = (int32_t)(info.detour - (info.target + 5));
			for (size_t i = 5; i < info.stolen; i++) {
				*(uint8_t*)(info.target + i) = 0x90;
			}
			FlushInstructionCache(GetCurrentProcess(), (void*)info.target, info.stolen);
			VirtualProtect((void*)info.target, info.stolen, old_prot, &old_prot);
			return true;
		}

		// True when the target still starts with the exact JMP this record wrote.
		bool jump_intact(const inline_hook_info& info)
		{
			if (*(const uint8_t*)info.target != 0xE9) return false;
			int32_t rel = *(const int32_t*)(info.target + 1);
			return rel == (int32_t)(info.detour - (info.target + 5));
		}

		bool restore_bytes(const inline_hook_info& info)
		{
			DWORD old_prot = 0;
			if (!VirtualProtect((void*)info.target, info.stolen, PAGE_EXECUTE_READWRITE, &old_prot)) {
				return false;
			}
			memcpy((void*)info.target, info.original, info.stolen);
			FlushInstructionCache(GetCurrentProcess(), (void*)info.target, info.stolen);
			VirtualProtect((void*)info.target, info.stolen, old_prot, &old_prot);
			return true;
		}
	}

	uintptr_t inline_hook_install(uintptr_t target, uintptr_t detour, inline_hook_info* out)
	{
		if (out) *out = inline_hook_info();
		if (!target || !detour) return 0;

		// Already hooked with this detour: hand back the existing trampoline
		// instead of patching a second time.
		inline_hook_info existing;
		if (lookup(target, &existing)) {
			if (existing.detour == detour) {
				if (out) *out = existing;
				return existing.trampoline;
			}
			// Different detour for the same target: replace the old hook.
			inline_hook_uninstall(&existing);
		}

		// 1. Measure whole instructions covering >= 5 bytes (JMP rel32 size)
		size_t stolen = 0;
		while (stolen < 5) {
			ud_t ud;
			ud_init(&ud, 32);
			ud_set_input_buffer(&ud, (uint8_t*)(target + stolen), 32);
			size_t len = ud_decode(&ud);
			if (len == 0 || len > 16) return 0;
			if (has_relative_operand((const uint8_t*)(target + stolen), len)) return 0;
			stolen += len;
		}
		if (stolen > sizeof(inline_hook_info::original)) return 0;

		// 2. Trampoline: stolen bytes + JMP back to target+stolen
		uint8_t* tramp = (uint8_t*)VirtualAlloc(NULL, stolen + 5, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
		if (!tramp) return 0;
		memcpy(tramp, (const void*)target, stolen);
		tramp[stolen] = 0xE9;
		*(int32_t*)(tramp + stolen + 1) = (int32_t)((target + stolen) - ((uintptr_t)tramp + stolen + 5));

		inline_hook_info info;
		info.target = target;
		info.detour = detour;
		info.stolen = stolen;
		info.trampoline = (uintptr_t)tramp;
		// Snapshot before writing: this is the only copy of the original code
		// once the JMP is in place.
		memcpy(info.original, (const void*)target, stolen);

		// 3. Patch target: JMP detour, pad the rest with NOP
		if (!write_jump(info)) {
			VirtualFree(tramp, 0, MEM_RELEASE);
			return 0;
		}

		{
			guard g;
			hooks().push_back(info);
		}
		if (out) *out = info;
		return info.trampoline;
	}

	bool inline_hook_uninstall(inline_hook_info* info)
	{
		if (!info || !info->valid()) return true;

		// Restore first, then drop the trampoline: between the two the target
		// must already execute the original code, or a thread passing through
		// the trampoline would jump into freed memory.
		bool ok = restore_bytes(*info);
		if (ok && info->trampoline) {
			VirtualFree((void*)info->trampoline, 0, MEM_RELEASE);
		}
		forget(info->target);
		*info = inline_hook_info();
		return ok;
	}

	size_t inline_hook_reassert_all()
	{
		std::vector<inline_hook_info> snapshot;
		{
			guard g;
			snapshot = hooks();
		}

		size_t repatched = 0;
		for (auto& h : snapshot) {
			if (jump_intact(h)) continue;
			// The engine rewrote this code (it rebuilds native tables per map).
			// Re-apply from the saved record; the trampoline is still valid
			// because the original bytes are unchanged.
			if (write_jump(h)) ++repatched;
		}
		return repatched;
	}

	size_t inline_hook_reset_all()
	{
		std::vector<inline_hook_info> snapshot;
		{
			guard g;
			snapshot.swap(hooks());
		}

		size_t restored = 0;
		for (auto& h : snapshot) {
			bool ok = restore_bytes(h);
			if (ok && h.trampoline) VirtualFree((void*)h.trampoline, 0, MEM_RELEASE);
			if (ok) ++restored;
		}
		return restored;
	}

	size_t inline_hook_count()
	{
		guard g;
		return hooks().size();
	}
}

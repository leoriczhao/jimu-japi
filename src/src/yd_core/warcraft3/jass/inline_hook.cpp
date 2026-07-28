#include <warcraft3/jass/inline_hook.h>
extern "C" {
#include <warcraft3/udis86/udis86.h>
}
#include <Windows.h>
#include <cstring>

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

	uintptr_t inline_hook_install(uintptr_t target, uintptr_t detour)
	{
		if (!target || !detour) return 0;

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

		// 2. Trampoline: stolen bytes + JMP back to target+stolen
		uint8_t* tramp = (uint8_t*)VirtualAlloc(NULL, stolen + 5, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
		if (!tramp) return 0;
		memcpy(tramp, (const void*)target, stolen);
		tramp[stolen] = 0xE9;
		*(int32_t*)(tramp + stolen + 1) = (int32_t)((target + stolen) - ((uintptr_t)tramp + stolen + 5));

		// 3. Patch target: JMP detour, pad the rest with NOP
		DWORD old_prot = 0;
		if (!VirtualProtect((void*)target, stolen, PAGE_EXECUTE_READWRITE, &old_prot)) {
			VirtualFree(tramp, 0, MEM_RELEASE);
			return 0;
		}
		*(uint8_t*)target = 0xE9;
		*(int32_t*)(target + 1) = (int32_t)(detour - (target + 5));
		for (size_t i = 5; i < stolen; i++) {
			*(uint8_t*)(target + i) = 0x90;
		}
		VirtualProtect((void*)target, stolen, old_prot, &old_prot);
		FlushInstructionCache(GetCurrentProcess(), (void*)target, stolen);

		return (uintptr_t)tramp;
	}
}

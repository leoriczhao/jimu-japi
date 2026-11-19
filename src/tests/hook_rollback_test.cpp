// hook_rollback_test.cpp — inline_hook_install/uninstall and patch_guard.
//
// The map-level hook lifetime needs to be reversible: hook on map entry, unhook
// on map exit, re-hook on the next entry. builtin-japi keeps the original bytes
// for every patch; this test pins the same guarantee for our side:
//   * install -> detour runs, trampoline still reaches the original code
//   * uninstall -> original bytes are byte-identical again, trampoline freed
//   * both APIs are idempotent and refuse out-of-range requests
//
// Run: build\bin\Release\hook_rollback_test.exe  (exit code 0 = pass)

#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <base/hook/patch.h>
#include <warcraft3/jass/inline_hook.h>

static int g_failures = 0;

static void check(bool ok, const char* what)
{
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) ++g_failures;
}

// A tiny position-independent function: mov eax, 7 ; ret
static const uint8_t kOriginalCode[] = { 0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3 };
static const size_t  kOriginalLen = sizeof(kOriginalCode);

static int __cdecl detour()
{
    return 42;
}

static int __cdecl detour2()
{
    return 13;
}

static uint8_t* alloc_code(const uint8_t* bytes, size_t len)
{
    uint8_t* p = (uint8_t*)VirtualAlloc(nullptr, 0x1000, MEM_COMMIT | MEM_RESERVE,
                                        PAGE_EXECUTE_READWRITE);
    if (!p) return nullptr;
    memset(p, 0xCC, 0x1000);
    memcpy(p, bytes, len);
    return p;
}

static void test_inline_hook()
{
    printf("-- inline hook install / uninstall --\n");

    uint8_t* code = alloc_code(kOriginalCode, kOriginalLen);
    check(code != nullptr, "executable page allocated");
    if (!code) return;

    typedef int (__cdecl *fn_t)();
    fn_t original = (fn_t)code;
    check(original() == 7, "original code returns 7");

    warcraft3::jass::inline_hook_info info;
    uintptr_t tramp = warcraft3::jass::inline_hook_install(
        (uintptr_t)code, (uintptr_t)&detour, &info);

    check(tramp != 0, "inline_hook_install succeeded");
    check(info.valid() && info.target == (uintptr_t)code && info.stolen == 5,
          "record captured (target + stolen bytes)");
    check(info.trampoline == tramp, "record carries the trampoline");
    check(original() == 42, "detour runs after install");
    check(((fn_t)tramp)() == 7, "trampoline still reaches the original code");

    check(warcraft3::jass::inline_hook_uninstall(&info), "inline_hook_uninstall succeeded");
    check(original() == 7, "original code runs again after uninstall");
    check(memcmp(code, kOriginalCode, kOriginalLen) == 0, "original bytes restored byte-for-byte");
    check(!info.valid(), "record cleared after uninstall");
    check(warcraft3::jass::inline_hook_uninstall(&info), "uninstall is idempotent");

    // Re-hook, the way a second map entry would.
    uintptr_t tramp2 = warcraft3::jass::inline_hook_install(
        (uintptr_t)code, (uintptr_t)&detour, &info);
    check(tramp2 != 0 && original() == 42, "re-install after uninstall works");
    check(warcraft3::jass::inline_hook_uninstall(&info), "second uninstall succeeded");
    check(memcmp(code, kOriginalCode, kOriginalLen) == 0, "bytes restored after re-install cycle");

    VirtualFree(code, 0, MEM_RELEASE);
}

static void test_tracking_and_reassert()
{
    printf("-- tracked hooks: idempotent install / reassert / reset --\n");

    uint8_t* code = alloc_code(kOriginalCode, kOriginalLen);
    check(code != nullptr, "executable page allocated");
    if (!code) return;

    typedef int (__cdecl *fn_t)();
    fn_t original = (fn_t)code;

    const size_t before = warcraft3::jass::inline_hook_count();

    warcraft3::jass::inline_hook_info first;
    uintptr_t tramp1 = warcraft3::jass::inline_hook_install(
        (uintptr_t)code, (uintptr_t)&detour, &first);
    check(tramp1 != 0, "first install succeeded");
    check(warcraft3::jass::inline_hook_count() == before + 1, "hook is tracked");
    check(first.detour == (uintptr_t)&detour, "record stores the detour");

    // Installing the same target+detour again must NOT patch twice: a second
    // JMP would overwrite the first one and the trampoline would jump to itself.
    warcraft3::jass::inline_hook_info second;
    uintptr_t tramp2 = warcraft3::jass::inline_hook_install(
        (uintptr_t)code, (uintptr_t)&detour, &second);
    check(tramp2 == tramp1, "re-install returns the existing trampoline");
    check(warcraft3::jass::inline_hook_count() == before + 1, "tracked set did not grow");
    check(original() == 42, "detour still runs after the idempotent install");
    check(((fn_t)tramp1)() == 7, "trampoline still reaches the original code");

    // Map boot: the engine rewrote the code we patched. Reassert must put the
    // JMP back from the saved record without a new install.
    memcpy(code, kOriginalCode, kOriginalLen);
    check(original() == 7, "code rewritten behind our back (simulated map boot)");
    check(warcraft3::jass::inline_hook_reassert_all() == 1, "reassert re-patched exactly one hook");
    check(original() == 42, "detour runs again after reassert");
    check(((fn_t)tramp1)() == 7, "trampoline still valid after reassert");
    check(warcraft3::jass::inline_hook_reassert_all() == 0, "reassert is a no-op while the JMP is intact");

    // Replacing the detour on the same target swaps the hook.
    warcraft3::jass::inline_hook_info replaced;
    uintptr_t tramp3 = warcraft3::jass::inline_hook_install(
        (uintptr_t)code, (uintptr_t)&detour2, &replaced);
    check(tramp3 != 0 && original() == 13, "new detour takes effect");
    check(warcraft3::jass::inline_hook_count() == before + 1, "replace did not duplicate the entry");

    check(warcraft3::jass::inline_hook_reset_all() == 1, "reset_all restored one hook");
    check(warcraft3::jass::inline_hook_count() == before, "tracked set is empty again");
    check(original() == 7, "original code runs after reset_all");
    check(memcmp(code, kOriginalCode, kOriginalLen) == 0, "bytes restored by reset_all");
    check(warcraft3::jass::inline_hook_reset_all() == 0, "reset_all is idempotent");

    VirtualFree(code, 0, MEM_RELEASE);
}

static void test_patch_guard()
{
    printf("-- patch_guard --\n");

    uint8_t buffer[16];
    for (int i = 0; i < 16; ++i) buffer[i] = (uint8_t)(0xA0 + i);
    uint8_t snapshot[16];
    memcpy(snapshot, buffer, sizeof(buffer));

    const uint8_t patched[5] = { 0x90, 0x90, 0x90, 0x90, 0x90 };

    base::hook::patch_guard guard;
    check(!guard.active(), "fresh guard is inactive");

    check(guard.apply((uintptr_t)buffer, patched, sizeof(patched)), "apply succeeded");
    check(guard.active() && guard.address() == (uintptr_t)buffer && guard.size() == sizeof(patched),
          "guard records address and size");
    check(memcmp(buffer, patched, sizeof(patched)) == 0, "bytes were written");
    check(memcmp(guard.original(), snapshot, sizeof(patched)) == 0, "guard holds the original bytes");

    check(guard.restore(), "restore succeeded");
    check(memcmp(buffer, snapshot, sizeof(buffer)) == 0, "all bytes restored");
    check(!guard.active(), "guard inactive after restore");
    check(guard.restore(), "restore is idempotent");

    // Applying twice must not lose the real original bytes.
    check(guard.apply((uintptr_t)buffer, patched, sizeof(patched)), "apply #1");
    const uint8_t second[3] = { 0xCC, 0xCC, 0xCC };
    check(guard.apply((uintptr_t)buffer, second, sizeof(second)), "apply #2 (implicit restore first)");
    check(buffer[0] == 0xCC && buffer[5] == snapshot[5], "second patch replaced only its own range");
    check(guard.restore(), "restore after double apply");
    check(memcmp(buffer, snapshot, sizeof(buffer)) == 0, "double apply restored the true original");

    uint8_t too_big[base::hook::patch_guard::kMaxSize + 1] = {};
    check(!guard.apply((uintptr_t)buffer, too_big, sizeof(too_big)), "size > kMaxSize is rejected");
    check(!guard.apply(0, patched, sizeof(patched)), "null address is rejected");
    check(!guard.apply((uintptr_t)buffer, nullptr, 4), "null source is rejected");

    // Destructor restores.
    {
        base::hook::patch_guard scoped((uintptr_t)buffer, patched, sizeof(patched));
        check(memcmp(buffer, patched, sizeof(patched)) == 0, "scoped guard patched");
    }
    check(memcmp(buffer, snapshot, sizeof(buffer)) == 0, "destructor restored the bytes");
}

int main()
{
    printf("hook rollback contract\n");
    test_inline_hook();
    test_tracking_and_reassert();
    test_patch_guard();

    if (g_failures == 0) {
        printf("hook rollback PASS\n");
        return 0;
    }
    printf("hook rollback FAIL: %d check(s)\n", g_failures);
    return 1;
}

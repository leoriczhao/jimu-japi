// dllmain.cpp — Entry point for the YDWE-based JAPI DLL
//
// This DLL is loaded via callback exploit (ExportFileFromMpq + LoadLibrary).
// Initialization follows the builtin-japi model:
//   - UnitId is INLINE-hooked (like jass.dll), not via linked-list editing
//   - the Lua VM is created lazily on the first ExecuteFunc call
//   - stale <pid>.dll files from dead runs are swept at startup

#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <warcraft3/jass.h>
#include <warcraft3/jass/nf_register.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/jass/inline_hook.h>
#include <warcraft3/war3_searcher.h>
#include <warcraft3/hashtable.h>
#include "../lua_engine/lua_engine/lua_loader.h"
#include "../lua_engine/lua_engine/bridge_dispatch.h"
#include "debug_log.h"

// Forward declarations
namespace warcraft3::lua_engine::lua_loader {
    void initialize();
    void load_script();
    void install_lazy_hook();
}
namespace warcraft3::lua_engine::message {
    void register_bridge_natives();
}
namespace warcraft3::japi {
    void initialize();
    void initialize_ex_natives();
    uint32_t open_code_run_logs_handler(const uint32_t* args, size_t nargs);
}
namespace warcraft3::lua_engine::bridge {
    typedef uint32_t (*cpp_handler_fn)(const uint32_t* args, size_t nargs);
    void register_cpp_handler(const char* name, const char* spec, cpp_handler_fn fn);
    void initialize();
}

static bool g_initialized = false;

// HookUnitId — exported for completeness but not called from war3map.j anymore.
extern "C" __declspec(dllexport) uint32_t __cdecl HookUnitId()
{
    return 0;
}

// Synchronous debug log — unified into japi_log::sync_write (debug_log.h),
// which adds [time pid] prefixes and works regardless of JAPI_DEBUG.
#define SYNC_LOG(msg) japi_log::sync_write(msg)

// Helper: find a native in the linked list by matching its hash table func_address.
// Returns the address of the func_address field in the linked list node, or 0.
// Linked list node layout: [+0] = next, [+12] = func_address
// Linked list head: [[GameDLL + 0xBE3740] + 0x14] + 0x20
static uintptr_t find_linked_list_func_addr(const char* name)
{
    uintptr_t game_base = warcraft3::get_war3_searcher().base();
    uintptr_t jass_env = *(uintptr_t*)(game_base + 0xBE3740);
    if (!jass_env) return 0;

    uintptr_t ptr1 = *(uintptr_t*)(jass_env + 0x14);
    if (!ptr1) return 0;

    uintptr_t first_node = *(uintptr_t*)(ptr1 + 0x20);
    if (!first_node) return 0;

    auto* ht_node = warcraft3::get_native_function_hashtable()->find(name);
    if (!ht_node) return 0;

    uint32_t target = ht_node->func_address_;
    for (uintptr_t cur = first_node; cur && cur > 0x10000; cur = *(uintptr_t*)cur) {
        if (*(uint32_t*)(cur + 12) == target) {
            return cur + 12;  // address of func_address field
        }
        if (*(uintptr_t*)cur == first_node) break;
    }
    return 0;
}

// Sweep stale <pid>.dll files left in the game directory by dead runs.
// (The callback exports this DLL as "<pid>.dll"; a loaded DLL cannot be
// deleted on Windows, so each run cleans up after its predecessors —
// this is the practical equivalent of builtin-japi's watchdog thread,
// which deletes <pid>.dll once initialization is confirmed complete.)
static void sweep_stale_pid_dlls()
{
    char self_path[MAX_PATH] = {0};
    HMODULE hm = NULL;
    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCSTR)&sweep_stale_pid_dlls, &hm)) return;
    if (!GetModuleFileNameA(hm, self_path, MAX_PATH)) return;

    std::string dir = self_path;
    size_t slash = dir.find_last_of('\\');
    if (slash == std::string::npos) return;
    dir.resize(slash);

    std::string mask = dir + "\\*.dll";
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(mask.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;

    int removed = 0;
    do {
        const char* name = fd.cFileName;
        char* end = nullptr;
        long pid = strtol(name, &end, 10);
        if (!end || _stricmp(end, ".dll") != 0 || pid <= 0) continue;
        if ((DWORD)pid == GetCurrentProcessId()) continue;  // ourselves (still loaded)
        HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
        if (proc) { CloseHandle(proc); continue; }          // pid alive — not ours to delete
        if (DeleteFileA((dir + "\\" + name).c_str())) removed++;
    } while (FindNextFileA(h, &fd));
    FindClose(h);

    if (removed) {
        char buf[96];
        snprintf(buf, sizeof(buf), "sweep: removed %d stale pid dll(s)", removed);
        SYNC_LOG(buf);
    }
}

extern "C" __declspec(dllexport) void __cdecl Initialize()
{
    if (g_initialized) return;
    g_initialized = true;

    // Debug logging is initialized here, NOT in DllMain — AllocConsole/CreateThread/
    // CreateFile under the loader lock risk deadlocking the game during LoadLibrary.
    DBG_INIT();

    SYNC_LOG("Initialize() START");

    sweep_stale_pid_dlls();

    // Step 1: Install ExecuteFunc hook; the Lua VM is created lazily on the
    // first ExecuteFunc call (builtin-japi style — nothing heavy in callback context)
    warcraft3::lua_engine::lua_loader::install_lazy_hook();
    SYNC_LOG("Step 1: lazy ExecuteFunc hook DONE");

    // Step 2: Register EX* natives
    warcraft3::japi::initialize_ex_natives();
    warcraft3::lua_engine::message::register_bridge_natives();
    SYNC_LOG("Step 2: initialize_ex_natives + message bridge natives DONE");

    // Step 3: Register bridge handlers + flush natives
    warcraft3::lua_engine::bridge::register_cpp_handler(
        "open_code_run_logs", "(B)V",
        warcraft3::japi::open_code_run_logs_handler);
    warcraft3::jass::nf_register::flush_add_only();
    SYNC_LOG("Step 3: flush_add_only DONE");

    // Step 4: Hook UnitId with an inline hook (builtin-japi's jass.dll mechanism).
    // Fall back to linked-list editing (callback's CreateJassNativeHook) if the
    // inline install fails.
    {
        uintptr_t fake = warcraft3::lua_engine::bridge::get_fake_unitid();
        uintptr_t unitid = 0;
        auto* node = warcraft3::get_native_function_hashtable()->find("UnitId");
        if (node) unitid = node->func_address_;

        uintptr_t tramp = unitid ? warcraft3::jass::inline_hook_install(unitid, fake) : 0;
        if (tramp) {
            warcraft3::lua_engine::bridge::set_real_unitid(tramp);
            SYNC_LOG("Step 4: UnitId inline-hooked");
        } else {
            uintptr_t addr = find_linked_list_func_addr("UnitId");
            if (addr) {
                uint32_t orig = *(uint32_t*)addr;
                warcraft3::lua_engine::bridge::set_real_unitid(orig);
                *(uint32_t*)addr = (uint32_t)fake;
                char buf[128];
                snprintf(buf, sizeof(buf), "Step 4: UnitId hooked via linked list (fallback), orig=0x%08X", orig);
                SYNC_LOG(buf);
            } else {
                SYNC_LOG("Step 4: UnitId hook FAILED");
            }
        }
    }

    // Step 5: Register LoadScript bridge handler
    // war3map.j calls SaveStr(ht,key,0,"()V") then UnitId("LoadScript")
    warcraft3::lua_engine::bridge::register_cpp_handler(
        "LoadScript", "()V",
        [](const uint32_t*, size_t) -> uint32_t {
            SYNC_LOG("LoadScript: loading war3map.lua");
            warcraft3::lua_engine::lua_loader::load_script();
            SYNC_LOG("LoadScript: done");
            return 0;
        });
    SYNC_LOG("Step 5: LoadScript handler registered");

    SYNC_LOG("Initialize() DONE");
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved)
{
    switch (reason)
    {
    case DLL_PROCESS_ATTACH:
        // Keep DllMain minimal: wenhao_plugin does nothing here either.
        // Heavy work (console, threads, files) belongs in Initialize().
        DisableThreadLibraryCalls(hModule);
        break;
    case DLL_PROCESS_DETACH:
        DBG_SHUTDOWN();
        break;
    }
    return TRUE;
}

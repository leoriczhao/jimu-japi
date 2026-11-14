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

static bool __cdecl read_rect_bounds(uint32_t rect, float* min_x, float* min_y,
                                     float* max_x, float* max_y)
{
    if (!rect) return false;
    if (min_x) *min_x = warcraft3::jass::from_real(
        (warcraft3::jass::jreal_t)warcraft3::jass::call("GetRectMinX", rect));
    if (min_y) *min_y = warcraft3::jass::from_real(
        (warcraft3::jass::jreal_t)warcraft3::jass::call("GetRectMinY", rect));
    if (max_x) *max_x = warcraft3::jass::from_real(
        (warcraft3::jass::jreal_t)warcraft3::jass::call("GetRectMaxX", rect));
    if (max_y) *max_y = warcraft3::jass::from_real(
        (warcraft3::jass::jreal_t)warcraft3::jass::call("GetRectMaxY", rect));
    return true;
}

static uint32_t __cdecl create_rect_handle(float min_x, float min_y,
                                           float max_x, float max_y)
{
    uint32_t x0 = warcraft3::jass::to_real(min_x);
    uint32_t y0 = warcraft3::jass::to_real(min_y);
    uint32_t x1 = warcraft3::jass::to_real(max_x);
    uint32_t y1 = warcraft3::jass::to_real(max_y);
    return (uint32_t)warcraft3::jass::call(
        "Rect", (uintptr_t)&x0, (uintptr_t)&y0, (uintptr_t)&x1, (uintptr_t)&y1);
}

static bool initialize_d3d_api()
{
    HMODULE d3d = GetModuleHandleA("d3d9.dll");
    if (!d3d) {
        japi_log::sync_write("D3D: d3d9.dll is not loaded; D3D handlers unavailable");
        return false;
    }

    typedef void (__cdecl *initialize_d3d_fn)(
        void (*)(const char*, const char*, warcraft3::lua_engine::bridge::cpp_handler_fn),
        const char* (*)(uint32_t),
        uint32_t (*)(const char*),
        bool (*)(uint32_t, float*, float*, float*, float*),
        uint32_t (*)(float, float, float, float));

    auto init = reinterpret_cast<initialize_d3d_fn>(
        GetProcAddress(d3d, "InitializeD3DAPI"));
    if (!init) {
        japi_log::sync_write("D3D: loaded d3d9.dll is not the project proxy; D3D handlers unavailable");
        return false;
    }

    init(
        &warcraft3::lua_engine::bridge::register_cpp_handler,
        &warcraft3::jass::from_string,
        &warcraft3::jass::create_string,
        &read_rect_bounds,
        &create_rect_handle);

    char module_path[MAX_PATH] = {0};
    GetModuleFileNameA(d3d, module_path, MAX_PATH);
    char buf[MAX_PATH + 64];
    snprintf(buf, sizeof(buf), "D3D: InitializeD3DAPI DONE (%s)", module_path);
    japi_log::sync_write(buf);
    return true;
}

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
    // The map's JASS bootstrap calls Initialize() through the callback exploit on
    // EVERY map boot, so a second call means "the engine is re-initialising". Use
    // it exactly like builtin-japi's game-reset callback: close the old Lua VM
    // (which also ends the D3D session through its finalizer) and rebuild the
    // hooks that hang off the per-map JASS structures.
    const bool reboot = g_initialized;
    g_initialized = true;

    if (!reboot) {
        // Debug logging is initialized here, NOT in DllMain — AllocConsole/CreateThread/
        // CreateFile under the loader lock risk deadlocking the game during LoadLibrary.
        DBG_INIT();
        SYNC_LOG("Initialize() START");
        sweep_stale_pid_dlls();
    } else {
        SYNC_LOG("Initialize() again: map boot, resetting the Lua VM");
        warcraft3::lua_engine::lua_loader::on_map_boot(false);
    }

    // Step 1: Install ExecuteFunc hook; the Lua VM is created lazily on the
    // first ExecuteFunc call (builtin-japi style — nothing heavy in callback context).
    // The native table is rebuilt by the game on every map, so this runs again.
    warcraft3::lua_engine::lua_loader::install_lazy_hook();
    SYNC_LOG("Step 1: lazy ExecuteFunc hook DONE");

    // Step 2: Register EX* natives. jass::japi_add only appends to the add list,
    // so re-running is idempotent; the damage hook inside targets game code and
    // is guarded internally.
    warcraft3::japi::initialize_ex_natives();
    warcraft3::lua_engine::message::register_bridge_natives();
    SYNC_LOG("Step 2: initialize_ex_natives + message bridge natives DONE");

    // The proxy must already be loaded as d3d9.dll before the process creates
    // its render device. Registration is optional so non-D3D maps still work;
    // the proxy is a process-wide singleton, so register its API only once.
    static bool d3d_api_ready = false;
    if (!d3d_api_ready) d3d_api_ready = initialize_d3d_api();

    // Step 3: Register bridge handlers + flush natives. flush_add_only() writes
    // the EX* natives into the CURRENT JASS native table, which is a fresh table
    // after a map boot, so this must run every time.
    warcraft3::lua_engine::bridge::register_cpp_handler(
        "open_code_run_logs", "(B)V",
        warcraft3::japi::open_code_run_logs_handler);
    warcraft3::jass::nf_register::flush_add_only();
    SYNC_LOG("Step 3: flush_add_only DONE");

    // Step 4: Hook UnitId with an inline hook (builtin-japi's jass.dll mechanism).
    // Fall back to linked-list editing (callback's CreateJassNativeHook) if the
    // inline install fails. The inline hook patches game code, which survives a
    // map boot: patching it twice would make the trampoline call itself.
    {
        static uintptr_t unitid_inline_hooked = 0;  // original UnitId address
        uintptr_t fake = warcraft3::lua_engine::bridge::get_fake_unitid();
        uintptr_t unitid = 0;
        auto* node = warcraft3::get_native_function_hashtable()->find("UnitId");
        if (node) unitid = node->func_address_;

        if (unitid_inline_hooked) {
            SYNC_LOG("Step 4: UnitId inline hook already installed, keeping it");
        } else if (unitid && unitid != fake) {
            uintptr_t tramp = warcraft3::jass::inline_hook_install(unitid, fake);
            if (tramp) {
                warcraft3::lua_engine::bridge::set_real_unitid(tramp);
                unitid_inline_hooked = unitid;
                SYNC_LOG("Step 4: UnitId inline-hooked");
            }
        }

        if (!unitid_inline_hooked) {
            uintptr_t addr = find_linked_list_func_addr("UnitId");
            if (addr) {
                uint32_t orig = *(uint32_t*)addr;
                if (orig != (uint32_t)fake) {
                    warcraft3::lua_engine::bridge::set_real_unitid(orig);
                    *(uint32_t*)addr = (uint32_t)fake;
                }
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

    // Step 6: In-process map-boot hook for the reboot regression: a pure JASS
    // action (no Lua frame) may force the builtin-japi style VM reset without
    // restarting the game. The JASS VM survives, so the shared hashtable
    // handshake and every JASS handle stay valid.
    warcraft3::lua_engine::bridge::register_cpp_handler(
        "SimulateMapBoot", "()V",
        [](const uint32_t*, size_t) -> uint32_t {
            SYNC_LOG("SimulateMapBoot: resetting the Lua VM");
            warcraft3::lua_engine::lua_loader::on_map_boot(true);
            warcraft3::lua_engine::lua_loader::load_script_file("script\\reboot_child.lua");
            SYNC_LOG("SimulateMapBoot: done");
            return 0;
        });
    SYNC_LOG("Step 6: SimulateMapBoot handler registered");

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

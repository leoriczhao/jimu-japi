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
#include "ex_natives/FuncBind.h"
#include <warcraft3/jass/func_value.h>

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
    uint32_t SaveFunc_handler(const uint32_t* args, size_t nargs);
    uint32_t func_bind_trigger_name_handler(const uint32_t* args, size_t nargs);
    void clear_func_bind();
}
namespace warcraft3::lua_engine::bridge {
    typedef uint32_t (*cpp_handler_fn)(const uint32_t* args, size_t nargs);
    void register_cpp_handler(const char* name, const char* spec, cpp_handler_fn fn);
    void initialize();
}

static bool g_initialized = false;

// ── Crash diagnostics ────────────────────────────────────────────────────
// DBG_LOG goes through an async ring buffer that dies with the process, so a
// hard crash loses exactly the lines we need. Everything here writes through
// japi_log::sync_write() instead (one CreateFile per line, always flushed).
//
// japi_sync.log then holds: the module base of yd_japi.dll (so an absolute
// address from the Windows crash dialog can be turned into a DLL offset) plus,
// for every first-chance AV, the exception record and a raw stack walk.
static void japi_resolve_addr(const void* addr, char* out, size_t n)
{
    HMODULE mod = nullptr;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)addr, &mod)) {
        char path[MAX_PATH] = { 0 };
        GetModuleFileNameA(mod, path, MAX_PATH);
        const char* name = strrchr(path, '\\');
        name = name ? name + 1 : path;
        _snprintf_s(out, n, _TRUNCATE, "0x%08X[%s+0x%X]", (unsigned)(uintptr_t)addr,
                    name, (unsigned)((uintptr_t)addr - (uintptr_t)mod));
    } else {
        _snprintf_s(out, n, _TRUNCATE, "0x%08X[?]", (unsigned)(uintptr_t)addr);
    }
}

// Turn a recorded native address back into the name the map called. Linear on
// purpose: this runs at crash time, where allocation is not an option.
static const char* japi_name_of_native(uintptr_t addr)
{
    for (auto const& kv : warcraft3::jass::japi_function) {
        if (kv.second.get_address() == addr) return kv.first.c_str();
    }
    for (auto const& kv : warcraft3::jass::jass_function) {
        if (kv.second.get_address() == addr) return kv.first.c_str();
    }
    return nullptr;
}

static void japi_dump_native_ring()
{
    japi_log::RecEntry* ring = japi_log::rec_ring();
    LONG pos = *japi_log::rec_pos();
    char buf[400];
    for (int k = 0; k < japi_log::REC_RING; ++k) {
        int i = (int)((pos + 1 + k) % japi_log::REC_RING);
        const japi_log::RecEntry& e = ring[i];
        if (!e.address) continue;
        const char* name = japi_name_of_native(e.address);
        snprintf(buf, sizeof(buf),
                 "[veh]   rec %s(0x%08X) a=0x%08X,0x%08X,0x%08X,0x%08X",
                 name ? name : "?", (unsigned)e.address,
                 e.args[0], e.args[1], e.args[2], e.args[3]);
        japi_log::sync_write(buf);
    }
}

static LONG CALLBACK japi_crash_veh(EXCEPTION_POINTERS* info)
{
    EXCEPTION_RECORD* er = info->ExceptionRecord;
    if (er->ExceptionCode != EXCEPTION_ACCESS_VIOLATION &&
        er->ExceptionCode != EXCEPTION_ILLEGAL_INSTRUCTION &&
        er->ExceptionCode != EXCEPTION_PRIV_INSTRUCTION &&
        er->ExceptionCode != EXCEPTION_STACK_OVERFLOW) {
        return EXCEPTION_CONTINUE_SEARCH;
    }

    char buf[512], a[96], b[96];
    japi_resolve_addr(er->ExceptionAddress, a, sizeof(a));
    unsigned op = er->NumberParameters > 0 ? (unsigned)er->ExceptionInformation[0] : 0u;
    unsigned tgt = er->NumberParameters > 1 ? (unsigned)er->ExceptionInformation[1] : 0u;
    snprintf(buf, sizeof(buf), "[veh] code=0x%08X at %s op=%u target=0x%08X",
             (unsigned)er->ExceptionCode, a, op, tgt);
    japi_log::sync_write(buf);

    CONTEXT* c = info->ContextRecord;
    snprintf(buf, sizeof(buf),
             "[veh] eip=0x%08X esp=0x%08X ebp=0x%08X eax=0x%08X ebx=0x%08X "
             "ecx=0x%08X edx=0x%08X esi=0x%08X edi=0x%08X",
             (unsigned)c->Eip, (unsigned)c->Esp, (unsigned)c->Ebp, (unsigned)c->Eax,
             (unsigned)c->Ebx, (unsigned)c->Ecx, (unsigned)c->Edx,
             (unsigned)c->Esi, (unsigned)c->Edi);
    japi_log::sync_write(buf);

    void* frames[48];
    USHORT n = RtlCaptureStackBackTrace(0, 48, frames, nullptr);
    for (USHORT i = 0; i < n; ++i) {
        japi_resolve_addr(frames[i], b, sizeof(b));
        snprintf(buf, sizeof(buf), "[veh]   #%02u %s", (unsigned)i, b);
        japi_log::sync_write(buf);
        if (i >= 40) break;
    }

    // Raw EBP chain as a second opinion (RtlCaptureStackBackTrace can give up).
    unsigned* ebp = (unsigned*)c->Ebp;
    for (int i = 0; i < 16 && ebp; ++i) {
        if ((uintptr_t)ebp < 0x10000 || (uintptr_t)ebp >= 0x7FFFFFFF) break;
        unsigned ret = 0;
        __try { ret = ebp[1]; } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
        if (!ret) break;
        japi_resolve_addr((const void*)ret, b, sizeof(b));
        snprintf(buf, sizeof(buf), "[veh]   ebp#%02d %s", i, b);
        japi_log::sync_write(buf);
        unsigned* next = nullptr;
        __try { next = (unsigned*)ebp[0]; } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
        if (next <= ebp) break;
        ebp = next;
    }

    japi_dump_native_ring();
    return EXCEPTION_CONTINUE_SEARCH;
}

static void japi_install_crash_diagnostics()
{
    static bool installed = false;
    if (installed) return;
    installed = true;
    AddVectoredExceptionHandler(1, japi_crash_veh);

    char a[96];
    japi_resolve_addr((const void*)&japi_install_crash_diagnostics, a, sizeof(a));
    char buf[256];
    snprintf(buf, sizeof(buf), "[japi] yd_japi %s exe=0x%08X", a,
             (unsigned)(uintptr_t)GetModuleHandleA(nullptr));
    japi_log::sync_write(buf);
}

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
        // Crash diagnostics are opt-in (JAPI_CRASH_DIAG=1): the vectored
        // handler dumps a symbolised stack of the faulting thread to
        // C:\ProgramData\japi_sync.log. Off by default so a shipped DLL never
        // installs an extra exception handler.
        char diag_flag[8] = {0};
        DWORD diag_len = GetEnvironmentVariableA("JAPI_CRASH_DIAG", diag_flag, sizeof(diag_flag));
        if (diag_len > 0 && diag_flag[0] == '1')
            japi_install_crash_diagnostics();
        sweep_stale_pid_dlls();
    } else {
        SYNC_LOG("Initialize() again: map boot, resetting the Lua VM");
        warcraft3::lua_engine::lua_loader::on_map_boot(false);
        // Code addresses belong to the script that produced them.
        warcraft3::japi::clear_func_bind();
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
    // builtin-japi's code<->label channel: the map binds a code address to a name
    // once at boot (SaveFunc) and per trigger action (func_bind_trigger_name).
    // Addresses travel as integers because the bridge ABI has no 'C' type.
    warcraft3::lua_engine::bridge::register_cpp_handler(
        "SaveFunc", "(I)V",
        warcraft3::japi::SaveFunc_handler);
    warcraft3::lua_engine::bridge::register_cpp_handler(
        "func_bind_trigger_name", "(IS)V",
        warcraft3::japi::func_bind_trigger_name_handler);
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
            warcraft3::japi::clear_func_bind();
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

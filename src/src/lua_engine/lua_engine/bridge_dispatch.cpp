// bridge_dispatch.cpp — UnitId-based JASS→Lua bridge dispatch
//
// The built-in JAPI pattern: JASS calls UnitId("FuncName"), the DLL intercepts,
// reads args from a shared hashtable, dispatches to a handler, writes result back.
// This keeps war3map.j clean (only standard JASS natives).

#include "bridge_dispatch.h"
#include "lua_loader.h"
#include "callback.h"
#include "jassbind.h"
#include "libs_runtime.h"
#include <warcraft3/jass.h>
#include <warcraft3/jass/hook.h>
#include <warcraft3/jass/func_value.h>
#include <warcraft3/hashtable.h>
#include <warcraft3/war3_searcher.h>
#include <base/hook/fp_call.h>
#include <lua.hpp>
#include <map>
#include <string>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include "debug_log.h"

// Synchronous debug log — unified into japi_log::sync_write (debug_log.h)
#define SYNC_LOG(msg) japi_log::sync_write(msg)

namespace warcraft3::lua_engine::bridge {

    // Log to both debug log and in-game screen
    static void log_message(const char* msg) {
        DBG_LOG("%s", msg);
        jass::string_fake sf(msg);
        jass::call("DisplayTimedTextToPlayer",
            jass::call("GetLocalPlayer"), 0, 0, 10.0f, (jass::jstring_t)sf);
    }

    // ── State ──────────────────────────────────────────────────────

    static uintptr_t RealUnitId = 0;
    static uint32_t  g_ht_handle = 0;   // JASS hashtable handle
    static uint32_t  g_ht_key = 0;      // StringHash("jass")

    struct handler_entry {
        std::string    spec;       // e.g. "(II)I"
        int            lua_ref;    // Lua registry reference (0 for C++ handlers)
        cpp_handler_fn cpp_fn;    // C++ handler (nullptr for Lua handlers)
    };

    static std::map<std::string, handler_entry> g_handlers;

    // ── Spec parser ────────────────────────────────────────────────

    struct param_info {
        char type;  // 'I', 'R', 'S', 'B', 'H'
    };

    struct parsed_spec {
        std::vector<param_info> params;
        char                    ret;  // 'I', 'R', 'S', 'B', 'V'
    };

    static parsed_spec parse_spec(const char* spec) {
        parsed_spec result;
        result.ret = 'V';
        if (!spec || spec[0] != '(') return result;

        const char* p = spec + 1;
        while (*p && *p != ')') {
            if (*p == ';') { p++; continue; }  // skip semicolons
            param_info pi;
            pi.type = *p;
            result.params.push_back(pi);
            p++;
            // skip lowercase subtype tags (e.g. Hplayer;)
            while (*p && *p >= 'a' && *p <= 'z') p++;
        }
        if (*p == ')') p++;
        if (*p) result.ret = *p;
        return result;
    }

    // ── Hashtable access via JASS natives ──────────────────────────
    // We call the game's Save/Load natives directly through the JASS VM.

    static void ht_save_str(uint32_t ht, uint32_t key, int slot, const char* value) {
        jass::string_fake sv(value);
        jass::call("SaveStr", ht, key, slot, (jass::jstring_t)sv);
    }

    static void ht_save_int(uint32_t ht, uint32_t key, int slot, int32_t value) {
        jass::call("SaveInteger", ht, key, slot, value);
    }

    static void ht_save_real(uint32_t ht, uint32_t key, int slot, uint32_t value) {
        // Natives take real params BY POINTER (call_param::push_real stores a
        // pointer to the 4-byte float) — passing the raw bits here would make
        // SaveReal dereference them as an address and crash.
        jass::call("SaveReal", ht, key, slot, (uintptr_t)&value);
    }

    static void ht_save_bool(uint32_t ht, uint32_t key, int slot, uint32_t value) {
        jass::call("SaveBoolean", ht, key, slot, value);
    }

    static const char* ht_load_str(uint32_t ht, uint32_t key, int slot) {
        // LoadStr returns a string ID — resolve ID -> string-table element
        // before from_string(), or the ID gets dereferenced as a pointer.
        jass::jstring_t id = (jass::jstring_t)jass::call("LoadStr", ht, key, slot);
        if (!id) return nullptr;
        uint32_t handle = get_jass_vm()->string_table->get((uint32_t)id);
        return jass::from_string((jass::jstring_t)handle);
    }

    static int32_t ht_load_int(uint32_t ht, uint32_t key, int slot) {
        return (int32_t)jass::call("LoadInteger", ht, key, slot);
    }

    static uint32_t ht_load_real(uint32_t ht, uint32_t key, int slot) {
        return (uint32_t)jass::call("LoadReal", ht, key, slot);
    }

    static uint32_t ht_load_bool(uint32_t ht, uint32_t key, int slot) {
        return (uint32_t)jass::call("LoadBoolean", ht, key, slot);
    }

    // ── Handler dispatch ───────────────────────────────────────────

    static void dispatch_handler(const char* name, const handler_entry& h) {
        parsed_spec spec = parse_spec(h.spec.c_str());

        // C++ handler: read args from ht, call, write result back
        if (h.cpp_fn) {
            uint32_t args[16] = {0};
            for (size_t i = 0; i < spec.params.size() && i < 16; i++) {
                int slot = (int)i + 1;
                switch (spec.params[i].type) {
                    case 'I': case 'H':
                        args[i] = (uint32_t)ht_load_int(g_ht_handle, g_ht_key, slot);
                        break;
                    case 'R':
                        args[i] = ht_load_real(g_ht_handle, g_ht_key, slot);
                        break;
                    case 'B':
                        args[i] = ht_load_bool(g_ht_handle, g_ht_key, slot);
                        break;
                    case 'S':
                        // JASS stored the value with SaveStr (string bucket) — LoadInteger
                        // would silently return 0. LoadStr returns a string ID; resolve
                        // it to a string-table element so handlers get a jstring_t
                        // handle they can pass to jass::from_string().
                        args[i] = get_jass_vm()->string_table->get(
                            (uint32_t)jass::call("LoadStr", g_ht_handle, g_ht_key, slot));
                        break;
                    default:
                        args[i] = (uint32_t)ht_load_int(g_ht_handle, g_ht_key, slot);
                        break;
                }
            }
            uint32_t result = h.cpp_fn(args, spec.params.size());

            if (spec.ret != 'V') {
                switch (spec.ret) {
                    case 'I': case 'H':
                        ht_save_int(g_ht_handle, g_ht_key, 0, (int32_t)result);
                        break;
                    case 'R':
                        ht_save_real(g_ht_handle, g_ht_key, 0, result);
                        break;
                    case 'S': {
                        // Native-ABI string returns are string IDs (small ints),
                        // NOT jstring_t handles. Resolve ID -> string-table
                        // element -> char* (same as jass_call_native_function's
                        // TYPE_STRING handling) or from_string() will deref the
                        // ID as a pointer and crash.
                        if (!result) {
                            ht_save_str(g_ht_handle, g_ht_key, 0, "");
                            break;
                        }
                        uint32_t handle = get_jass_vm()->string_table->get(result);
                        ht_save_str(g_ht_handle, g_ht_key, 0,
                            jass::from_string((jass::jstring_t)handle));
                        break;
                    }
                    case 'B':
                        ht_save_bool(g_ht_handle, g_ht_key, 0, result ? 1 : 0);
                        break;
                }
            }
            return;
        }

        lua_State* L = lua_loader::getMainL();
        if (!L) return;

        // Push the Lua function from registry
        lua_rawgeti(L, LUA_REGISTRYINDEX, h.lua_ref);

        // Read args from hashtable and push to Lua stack
        for (size_t i = 0; i < spec.params.size(); i++) {
            int slot = (int)i + 1;
            switch (spec.params[i].type) {
                case 'I':
                case 'H':
                    lua_pushinteger(L, ht_load_int(g_ht_handle, g_ht_key, slot));
                    break;
                case 'R': {
                    uint32_t rv = ht_load_real(g_ht_handle, g_ht_key, slot);
                    jassbind::push_real(L, rv);
                    break;
                }
                case 'S': {
                    const char* s = ht_load_str(g_ht_handle, g_ht_key, slot);
                    lua_pushstring(L, s ? s : "");
                    break;
                }
                case 'B':
                    lua_pushboolean(L, ht_load_bool(g_ht_handle, g_ht_key, slot));
                    break;
                default:
                    lua_pushinteger(L, ht_load_int(g_ht_handle, g_ht_key, slot));
                    break;
            }
        }

        // Call the Lua function
        int error = safe_call(L, (int)spec.params.size(),
                              (spec.ret != 'V') ? 1 : 0, true);

        // Write result back to hashtable
        if (error == LUA_OK && spec.ret != 'V') {
            switch (spec.ret) {
                case 'I':
                case 'H': {
                    int32_t val = (int32_t)lua_tointeger(L, -1);
                    ht_save_int(g_ht_handle, g_ht_key, 0, val);
                    break;
                }
                case 'R': {
                    jass::jreal_t rv = jassbind::read_real(L, -1);
                    ht_save_real(g_ht_handle, g_ht_key, 0, rv);
                    break;
                }
                case 'S': {
                    const char* s = lua_tostring(L, -1);
                    ht_save_str(g_ht_handle, g_ht_key, 0, s ? s : "");
                    break;
                }
                case 'B': {
                    uint32_t bv = lua_toboolean(L, -1) ? 1 : 0;
                    ht_save_bool(g_ht_handle, g_ht_key, 0, bv);
                    break;
                }
            }
            lua_pop(L, 1);
        }
    }

    // ── UnitId hook ────────────────────────────────────────────────

    // Hook UnitId using the linked list at [[JassEnv+0x14]+0x20]
    // This is the same mechanism as the callback's CreateJassNativeHook.
    // Node layout: [+0] = next pointer, [+12] = func_address_
    // The hash table is for name-based lookup; the linked list is for dispatch.
    static bool list_hook_by_name(const char* proc_name, uintptr_t* old_proc_ptr, uintptr_t new_proc)
    {
        // First, find the function address using the hash table
        auto* node_ptr = warcraft3::get_native_function_hashtable()->find(proc_name);
        if (!node_ptr) {
            SYNC_LOG("list_hook_by_name: node not found in hash table");
            return false;
        }

        uint32_t old_address = node_ptr->func_address_;
        *old_proc_ptr = (uintptr_t)old_address;

        char buf[256];
        snprintf(buf, sizeof(buf), "list_hook_by_name: old_address=0x%08X, new_proc=0x%08X", old_address, (uint32_t)new_proc);
        SYNC_LOG(buf);

        // Now walk the linked list and find the node with this address
        SYNC_LOG("list_hook_by_name: getting war3_searcher...");
        uintptr_t env = 0;
        __try {
            env = warcraft3::get_war3_searcher().get_instance(5);
        } __except(EXCEPTION_EXECUTE_HANDLER) {
            SYNC_LOG("list_hook_by_name: EXCEPTION in get_war3_searcher");
            return false;
        }
        snprintf(buf, sizeof(buf), "list_hook_by_name: env=0x%08X", (uint32_t)env);
        SYNC_LOG(buf);
        if (!env) {
            SYNC_LOG("list_hook_by_name: env is null");
            return false;
        }

        SYNC_LOG("list_hook_by_name: reading table_ptr...");
        uintptr_t table_ptr = *(uintptr_t*)(env + 0x14);
        snprintf(buf, sizeof(buf), "list_hook_by_name: table_ptr=0x%08X", (uint32_t)table_ptr);
        SYNC_LOG(buf);
        if (!table_ptr) {
            SYNC_LOG("list_hook_by_name: table_ptr is null");
            return false;
        }

        SYNC_LOG("list_hook_by_name: reading first_node...");
        uintptr_t first_node = *(uintptr_t*)(table_ptr + 0x20);
        snprintf(buf, sizeof(buf), "list_hook_by_name: first_node=0x%08X", (uint32_t)first_node);
        SYNC_LOG(buf);
        if (!first_node) {
            SYNC_LOG("list_hook_by_name: first_node is null");
            return false;
        }

        uintptr_t current = first_node;
        for (int i = 0; i < 10000; i++) {
            uint32_t func_addr = *(uint32_t*)(current + 12);
            if (func_addr < 0x3000) {
                snprintf(buf, sizeof(buf), "list_hook_by_name: reached end of list at node %d, func_addr=0x%08X", i, func_addr);
                SYNC_LOG(buf);
                break;
            }

            if (func_addr == old_address) {
                *(uint32_t*)(current + 12) = (uint32_t)new_proc;
                snprintf(buf, sizeof(buf), "list_hook_by_name: FOUND and hooked at node %d, addr=0x%08X", i, (uint32_t)current);
                SYNC_LOG(buf);
                return true;
            }

            // Follow linked list: [+0] = next pointer
            uintptr_t next = *(uintptr_t*)(current);
            if (next == first_node || next == 0 || next < 0x10000) {
                snprintf(buf, sizeof(buf), "list_hook_by_name: list end at node %d, next=0x%08X", i, (uint32_t)next);
                SYNC_LOG(buf);
                break;
            }
            current = next;
        }

        SYNC_LOG("list_hook_by_name: NOT FOUND in linked list");
        return false;
    }

    // Safe wrapper for from_string that catches access violations
    static const char* safe_from_string(jass::jstring_t str) {
        __try {
            return jass::from_string(str);
        } __except(EXCEPTION_EXECUTE_HANDLER) {
            return nullptr;
        }
    }

    // StringHash via the game native. Safe at the bridge-init call site (main-thread
    // JASS after StartCampaignAI returned), but keep SEH + constant fallback anyway.
    static uint32_t call_string_hash(const char* s) {
        return (uint32_t)jass::call("StringHash", jass::string_fake(s));
    }

    static uint32_t safe_string_hash(const char* s) {
        __try {
            return call_string_hash(s);
        } __except(EXCEPTION_EXECUTE_HANDLER) {
            return 0;
        }
    }

    static jass::jstring_t __cdecl FakeUnitId(jass::jstring_t name_str) {
        const char* name = safe_from_string(name_str);
        if (!name) {
            return base::c_call<jass::jstring_t>(RealUnitId, name_str);
        }

        // Initialization: UnitId(I2S(GetHandleId(japi_ht)))
        if (name[0] >= '0' && name[0] <= '9') {
            g_ht_handle = (uint32_t)std::atoll(name);
            // StringHash("jass") — must match japi__key computed at runtime by war3map.j.
            // Verified constant of the game's hash algorithm: 229083199.
            g_ht_key = safe_string_hash("jass");
            if (!g_ht_key) g_ht_key = 229083199u;  // fallback: StringHash("jass")
            char buf[128];
            snprintf(buf, sizeof(buf), "[bridge] ht initialized: handle=%u key=%u", g_ht_handle, g_ht_key);
            SYNC_LOG(buf);
            return 0;
        }

        // Dispatch: UnitId("FuncName")
        auto it = g_handlers.find(name);
        if (it != g_handlers.end()) {
            dispatch_handler(name, it->second);
            return 0;
        }

        // Unknown — pass through to original UnitId
        return base::c_call<jass::jstring_t>(RealUnitId, name_str);
    }

    // ── Public API ─────────────────────────────────────────────────

    void register_handler(lua_State* L, const char* name, const char* spec, int func_index) {
        handler_entry entry;
        entry.spec = spec;
        entry.cpp_fn = nullptr;
        // Store a reference to the Lua function
        lua_pushvalue(L, func_index);
        entry.lua_ref = luaL_ref(L, LUA_REGISTRYINDEX);
        g_handlers[name] = entry;
        DBG_LOG("[bridge] registered handler: %s %s", name, spec);
    }

    void register_cpp_handler(const char* name, const char* spec, cpp_handler_fn fn) {
        handler_entry entry;
        entry.spec = spec;
        entry.lua_ref = 0;
        entry.cpp_fn = fn;
        g_handlers[name] = entry;
        DBG_LOG("[bridge] registered C++ handler: %s %s", name, spec);
    }

    static bool invoke_cpp_handler_safely(cpp_handler_fn fn,
                                           const uint32_t* args,
                                           size_t nargs,
                                           uint32_t* result) {
        __try {
            uint32_t value = fn(args, nargs);
            if (result) *result = value;
            return true;
        } __except(EXCEPTION_EXECUTE_HANDLER) {
            SYNC_LOG("invoke_cpp_handler: handler raised an exception");
            return false;
        }
    }

    bool invoke_cpp_handler(const char* name, const uint32_t* args,
                            size_t nargs, uint32_t* result) {
        if (!name) return false;
        auto it = g_handlers.find(name);
        if (it == g_handlers.end() || !it->second.cpp_fn) return false;

        return invoke_cpp_handler_safely(
            it->second.cpp_fn, args, nargs, result);
    }

    void initialize() {
        // Hook is now done in dllmain.cpp via linked list (same as callback's CreateJassNativeHook).
        // This function is kept for API compatibility but does nothing.
        SYNC_LOG("bridge::initialize() — no-op (hook done in dllmain.cpp)");
    }

    uint32_t get_ht_handle() { return g_ht_handle; }
    uint32_t get_ht_key() { return g_ht_key; }

    void set_real_unitid(uintptr_t addr) {
        RealUnitId = addr;
        char buf[256];
        snprintf(buf, sizeof(buf), "set_real_unitid: RealUnitId=0x%08X", (uint32_t)addr);
        SYNC_LOG(buf);
    }

    uintptr_t get_fake_unitid() {
        return (uintptr_t)FakeUnitId;
    }

}  // namespace warcraft3::lua_engine::bridge

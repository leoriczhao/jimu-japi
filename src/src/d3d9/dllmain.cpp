// dllmain.cpp — Entry point for the D3D9 proxy DLL (newD3d9.dll)
//
// This DLL acts as a D3D9 proxy for War3 1.27a:
//   1. War3 loads "d3d9.dll" → picks up our proxy instead
//   2. We export Direct3DCreate9() which loads the real d3d9.dll
//   3. We wrap IDirect3D9 and IDirect3DDevice9 with our proxy classes
//   4. EndScene hook renders custom text/texture objects
//   5. yd_japi.dll calls InitializeD3DAPI() to register the d3d.* handlers
//
// The DLL must be placed where War3 can find it (e.g. game directory or MPQ).
// It is typically renamed from newD3d9.dll to d3d9.dll or loaded via DLL proxy.

#include <windows.h>
#include "CDirect3D9.h"
#include "api.h"
#include "status.h"

// ── Real d3d9.dll loading ─────────────────────────────────────

static HMODULE g_hRealD3D9 = nullptr;
static IDirect3D9* (WINAPI *g_pfnDirect3DCreate9)(UINT) = nullptr;

static bool load_real_d3d9()
{
    if (g_hRealD3D9) return true;

    // Get the system directory to find the real d3d9.dll
    char sysDir[MAX_PATH];
    GetSystemDirectoryA(sysDir, MAX_PATH);
    strcat_s(sysDir, "\\d3d9.dll");

    g_hRealD3D9 = LoadLibraryA(sysDir);
    if (!g_hRealD3D9) return false;

    g_pfnDirect3DCreate9 = (IDirect3D9 * (WINAPI *)(UINT))
        GetProcAddress(g_hRealD3D9, "Direct3DCreate9");
    if (!g_pfnDirect3DCreate9) return false;
    d3d9_status::set(d3d9_status::REAL_D3D9_LOADED);
    return true;
}

// ── Exported functions ────────────────────────────────────────

// Direct3DCreate9 — called by War3 to create the D3D9 device
// Exported via /export linker directive (avoids d3d9.h __declspec(dllimport) conflict)
IDirect3D9* WINAPI Direct3DCreate9(UINT SDKVersion)
{
    if (!load_real_d3d9()) {
        MessageBoxA(nullptr, "Failed to load real d3d9.dll", "newD3d9.dll Error", MB_OK | MB_ICONERROR);
        return nullptr;
    }

    IDirect3D9* pD3D = g_pfnDirect3DCreate9(SDKVersion);
    if (!pD3D) return nullptr;

    // Wrap with our proxy
    CDirect3D9* pProxy = new CDirect3D9(pD3D);
    d3d9_status::set(d3d9_status::D3D9_WRAPPED);
    return pProxy;
}

// InitializeD3DAPI — called by yd_japi.dll to register d3d.* handlers
// Parameters:
//   reg_fn      — bridge::register_cpp_handler function pointer
//   from_string — jass::from_string function pointer (for string arg conversion)
extern "C" __declspec(dllexport) void __cdecl InitializeD3DAPI(
    d3d9_api::register_handler_fn reg_fn,
    d3d9_api::from_string_fn from_string,
    d3d9_api::create_string_fn create_string)
{
    // Set up the string conversion function
    d3d9_api::set_from_string_fn(from_string);
    d3d9_api::set_create_string_fn(create_string);

    // Register all d3d API handlers with the bridge dispatch
    d3d9_api::register_all_handlers(reg_fn);
    d3d9_status::set(d3d9_status::API_REGISTERED);
}

// ── DLL entry point ───────────────────────────────────────────

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved)
{
    switch (reason)
    {
    case DLL_PROCESS_ATTACH:
        DisableThreadLibraryCalls(hModule);
        d3d9_status::set(d3d9_status::PROXY_LOADED);
        break;
    case DLL_PROCESS_DETACH:
        if (g_hRealD3D9) {
            FreeLibrary(g_hRealD3D9);
            g_hRealD3D9 = nullptr;
        }
        break;
    }
    return TRUE;
}

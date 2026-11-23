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
#include <cstdint>
#include "CDirect3D9.h"
#include "api.h"
#include "renderer.h"
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
    d3d9_api::create_string_fn create_string,
    d3d9_api::get_rect_fn get_rect,
    d3d9_api::create_rect_fn create_rect)
{
    // Set up the string conversion function
    d3d9_api::set_from_string_fn(from_string);
    d3d9_api::set_create_string_fn(create_string);
    d3d9_api::set_rect_fns(get_rect, create_rect);

    // Register all d3d API handlers with the bridge dispatch
    d3d9_api::register_all_handlers(reg_fn);
    d3d9_status::set(d3d9_status::API_REGISTERED);
}

// ── Zero-restart in-process D3D9 attach ───────────────────────
// When War3 booted without our d3d9.dll proxy (fresh machine, or a foreign
// d3d9.dll wrapper already occupies the slot), yd_japi.dll extracts this DLL
// at runtime as japi_d3d9_<pid>.dll and calls AttachInProcessD3D9() with its
// inline hook installer. We create a 1x1 dummy device against the already-
// loaded d3d9.dll to resolve the exact IDirect3DDevice9 vtable slots for
// Reset [16] and EndScene [42], release the dummy device, and inline-hook both.

typedef uintptr_t (__cdecl *d3d_inline_hook_fn)(uintptr_t target, uintptr_t detour);
typedef HRESULT (STDMETHODCALLTYPE *end_scene_fn)(IDirect3DDevice9*);
typedef HRESULT (STDMETHODCALLTYPE *reset_fn)(IDirect3DDevice9*, D3DPRESENT_PARAMETERS*);

static end_scene_fn      g_inproc_real_end_scene = nullptr;
static reset_fn          g_inproc_real_reset     = nullptr;
static IDirect3DDevice9* g_inproc_live_device    = nullptr;
static bool              g_inproc_attached       = false;

static HRESULT STDMETHODCALLTYPE inproc_detour_end_scene(IDirect3DDevice9* pDevice)
{
    static bool s_in_overlay = false;
    if (pDevice && !s_in_overlay) {
        s_in_overlay = true;
        if (!g_inproc_live_device) {
            g_inproc_live_device = pDevice;
            d3d9_renderer::on_device_created(pDevice);
            d3d9_status::set(d3d9_status::DEVICE_WRAPPED);
        }
        if (pDevice == g_inproc_live_device) {
            d3d9_renderer::on_end_scene(pDevice);
        }
        s_in_overlay = false;
    }
    return g_inproc_real_end_scene ? g_inproc_real_end_scene(pDevice) : D3D_OK;
}

static HRESULT STDMETHODCALLTYPE inproc_detour_reset(
    IDirect3DDevice9* pDevice, D3DPRESENT_PARAMETERS* pPresentationParameters)
{
    const bool is_live = (pDevice && pDevice == g_inproc_live_device);
    if (is_live) {
        d3d9_renderer::on_device_lost();
    }
    HRESULT hr = g_inproc_real_reset
        ? g_inproc_real_reset(pDevice, pPresentationParameters)
        : D3DERR_INVALIDCALL;
    if (is_live && SUCCEEDED(hr)) {
        d3d9_renderer::on_device_reset();
    }
    return hr;
}

extern "C" __declspec(dllexport) bool __cdecl AttachInProcessD3D9(
    d3d_inline_hook_fn install_hook)
{
    if (g_inproc_attached) return true;
    if (!install_hook) return false;

    HMODULE active_d3d9 = GetModuleHandleA("d3d9.dll");
    if (!active_d3d9) return false;

    auto create9 = reinterpret_cast<IDirect3D9* (WINAPI *)(UINT)>(
        GetProcAddress(active_d3d9, "Direct3DCreate9"));
    if (!create9) return false;

    HWND dummy_hwnd = CreateWindowExA(
        0, "STATIC", "", WS_POPUP,
        0, 0, 1, 1, nullptr, nullptr, nullptr, nullptr);
    if (!dummy_hwnd) return false;

    IDirect3D9* d3d = create9(D3D_SDK_VERSION);
    if (!d3d) {
        DestroyWindow(dummy_hwnd);
        return false;
    }

    D3DPRESENT_PARAMETERS pp{};
    pp.Windowed         = TRUE;
    pp.SwapEffect       = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow    = dummy_hwnd;
    pp.BackBufferFormat = D3DFMT_UNKNOWN;
    pp.BackBufferWidth  = 1;
    pp.BackBufferHeight = 1;

    IDirect3DDevice9* dummy_dev = nullptr;
    HRESULT hr = d3d->CreateDevice(
        D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, dummy_hwnd,
        D3DCREATE_SOFTWARE_VERTEXPROCESSING | D3DCREATE_DISABLE_DRIVER_MANAGEMENT,
        &pp, &dummy_dev);
    if (FAILED(hr) || !dummy_dev) {
        hr = d3d->CreateDevice(
            D3DADAPTER_DEFAULT, D3DDEVTYPE_NULLREF, dummy_hwnd,
            D3DCREATE_SOFTWARE_VERTEXPROCESSING,
            &pp, &dummy_dev);
    }

    uintptr_t target_reset = 0;
    uintptr_t target_end_scene = 0;
    if (SUCCEEDED(hr) && dummy_dev) {
        void** vtbl = *reinterpret_cast<void***>(dummy_dev);
        if (vtbl) {
            target_reset     = reinterpret_cast<uintptr_t>(vtbl[16]);
            target_end_scene = reinterpret_cast<uintptr_t>(vtbl[42]);
        }
        dummy_dev->Release();
    }

    d3d->Release();
    DestroyWindow(dummy_hwnd);

    if (!target_end_scene) return false;

    uintptr_t tramp_end = install_hook(
        target_end_scene, reinterpret_cast<uintptr_t>(&inproc_detour_end_scene));
    if (!tramp_end) return false;
    g_inproc_real_end_scene = reinterpret_cast<end_scene_fn>(tramp_end);

    if (target_reset) {
        uintptr_t tramp_reset = install_hook(
            target_reset, reinterpret_cast<uintptr_t>(&inproc_detour_reset));
        if (tramp_reset) {
            g_inproc_real_reset = reinterpret_cast<reset_fn>(tramp_reset);
        }
    }

    g_inproc_attached = true;
    d3d9_status::set(d3d9_status::REAL_D3D9_LOADED | d3d9_status::D3D9_WRAPPED);
    return true;
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

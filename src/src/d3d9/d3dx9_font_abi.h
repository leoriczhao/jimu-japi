#pragma once

// Minimal C ABI declarations for the legacy D3DX9 font interface. The proxy
// resolves D3DXCreateFontA dynamically, so it must not take a build-time D3DX
// dependency. Keep this vtable in the exact ID3DXFont method order.

#include <windows.h>
#include <d3d9.h>

struct ID3DXFont;

struct ID3DXFontVtbl {
    HRESULT (STDMETHODCALLTYPE* QueryInterface)(ID3DXFont*, REFIID, void**);
    ULONG (STDMETHODCALLTYPE* AddRef)(ID3DXFont*);
    ULONG (STDMETHODCALLTYPE* Release)(ID3DXFont*);
    HRESULT (STDMETHODCALLTYPE* GetDevice)(ID3DXFont*, IDirect3DDevice9**);
    HRESULT (STDMETHODCALLTYPE* GetDescA)(ID3DXFont*, void*);
    HRESULT (STDMETHODCALLTYPE* GetDescW)(ID3DXFont*, void*);
    BOOL (STDMETHODCALLTYPE* GetTextMetricsA)(ID3DXFont*, TEXTMETRICA*);
    BOOL (STDMETHODCALLTYPE* GetTextMetricsW)(ID3DXFont*, TEXTMETRICW*);
    HDC (STDMETHODCALLTYPE* GetDC)(ID3DXFont*);
    HRESULT (STDMETHODCALLTYPE* GetGlyphData)(
        ID3DXFont*, UINT, IDirect3DTexture9**, RECT*, POINT*);
    HRESULT (STDMETHODCALLTYPE* PreloadCharacters)(ID3DXFont*, UINT, UINT);
    HRESULT (STDMETHODCALLTYPE* PreloadGlyphs)(ID3DXFont*, UINT, UINT);
    HRESULT (STDMETHODCALLTYPE* PreloadTextA)(ID3DXFont*, const char*, INT);
    HRESULT (STDMETHODCALLTYPE* PreloadTextW)(ID3DXFont*, const wchar_t*, INT);
    INT (STDMETHODCALLTYPE* DrawTextA)(
        ID3DXFont*, void*, const char*, INT, RECT*, DWORD, D3DCOLOR);
    INT (STDMETHODCALLTYPE* DrawTextW)(
        ID3DXFont*, void*, const wchar_t*, INT, RECT*, DWORD, D3DCOLOR);
    HRESULT (STDMETHODCALLTYPE* OnLostDevice)(ID3DXFont*);
    HRESULT (STDMETHODCALLTYPE* OnResetDevice)(ID3DXFont*);
};

struct ID3DXFont {
    ID3DXFontVtbl* lpVtbl;
};

using D3DXCreateFontA_fn = HRESULT (WINAPI *)(
    IDirect3DDevice9* device,
    INT height,
    UINT width,
    UINT weight,
    UINT mip_levels,
    BOOL italic,
    DWORD charset,
    DWORD output_precision,
    DWORD quality,
    DWORD pitch_and_family,
    const char* face_name,
    ID3DXFont** out_font);

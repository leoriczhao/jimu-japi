// renderer.cpp — Text and texture rendering implementation
//
// Text rendering: GDI DrawText on backbuffer surface DC
// Texture rendering: DrawPrimitiveUP with transformed textured vertices
//
// All rendering happens in on_end_scene(), called from the hooked EndScene().

#include "renderer.h"
#include "resource_manager.h"
#include "status.h"
#include <d3d9.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace d3d9_renderer {

// ── State ─────────────────────────────────────────────────────

static IDirect3DDevice9* g_device = nullptr;

static std::map<font_handle_t, FontObj>      g_fonts;
static std::map<text_handle_t, TextObj>      g_texts;
static std::map<texture_handle_t, TextureObj> g_textures;

static float g_last_dt = 0.0f;
static DWORD g_last_tick = 0;

// FPS tracking
static bool  g_show_fps = false;
static int   g_fps_frames = 0;
static float g_fps_time = 0.0f;
static float g_fps_value = 0.0f;

// ── Vertex format for textured sprites ────────────────────────

struct VertexTL {
    float x, y, z, rhw;
    uint32_t color;
    float tu, tv;
};

#define D3DFVF_TL (D3DFVF_XYZRHW | D3DFVF_DIFFUSE | D3DFVF_TEX1)

// ── FontObj implementation ────────────────────────────────────

HFONT FontObj::get_handle()
{
    if (!hFont) {
        hFont = CreateFontA(
            height, width, 0, 0,
            weight,
            italic ? TRUE : FALSE,
            FALSE, FALSE,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            DEFAULT_PITCH | FF_DONTCARE,
            faceName.c_str()
        );
    }
    return hFont;
}

void FontObj::invalidate()
{
    if (hFont) {
        DeleteObject(hFont);
        hFont = NULL;
    }
}

void FontObj::destroy()
{
    invalidate();
}

// ── Texture loading helper ────────────────────────────────────

// Load a texture from a file path (BMP/TGA/JPG/PNG).
// Uses D3DXCreateTextureFromFileA if d3dx9 is available,
// otherwise falls back to D3DXCreateTextureFromFileEx via LoadLibrary.
static IDirect3DTexture9* load_texture(IDirect3DDevice9* dev, const char* path)
{
    if (!path || !path[0]) return nullptr;

    // Try loading via D3DX9 if available
    static HMODULE hD3DX9 = nullptr;
    static HRESULT (WINAPI *pfnD3DXCreateTextureFromFileA)(
        IDirect3DDevice9*, const char*, IDirect3DTexture9**) = nullptr;

    if (!hD3DX9) {
        hD3DX9 = LoadLibraryA("d3dx9_42.dll");
        if (!hD3DX9) hD3DX9 = LoadLibraryA("d3dx9_43.dll");
        if (!hD3DX9) hD3DX9 = LoadLibraryA("d3dx9_33.dll");
        if (hD3DX9) {
            pfnD3DXCreateTextureFromFileA = (decltype(pfnD3DXCreateTextureFromFileA))
                GetProcAddress(hD3DX9, "D3DXCreateTextureFromFileA");
        }
    }

    if (pfnD3DXCreateTextureFromFileA) {
        IDirect3DTexture9* tex = nullptr;
        HRESULT hr = pfnD3DXCreateTextureFromFileA(dev, path, &tex);
        if (SUCCEEDED(hr) && tex) return tex;
    }

    return nullptr;
}

// Reload a texture object's D3D texture
static void reload_texture(TextureObj& obj)
{
    if (obj.texture) {
        obj.texture->Release();
        obj.texture = nullptr;
    }
    if (g_device && !obj.path.empty()) {
        obj.texture = load_texture(g_device, obj.path.c_str());
        if (obj.texture) {
            D3DSURFACE_DESC desc;
            if (SUCCEEDED(obj.texture->GetLevelDesc(0, &desc))) {
                obj.pixelWidth = (int)desc.Width;
                obj.pixelHeight = (int)desc.Height;
            }
            d3d9_status::set(d3d9_status::TEXTURE_LOADED);
        }
    }
}

// ── Lifecycle callbacks ───────────────────────────────────────

void on_device_created(IDirect3DDevice9* pDevice)
{
    g_device = pDevice;
    g_last_tick = GetTickCount();

    // Load all textures
    for (auto& [h, obj] : g_textures) {
        reload_texture(obj);
    }

    // Recreate all fonts
    for (auto& [h, font] : g_fonts) {
        font.invalidate();
    }
}

void on_device_lost()
{
    // Release D3D resources (textures)
    for (auto& [h, obj] : g_textures) {
        if (obj.texture) {
            obj.texture->Release();
            obj.texture = nullptr;
        }
    }

    // Invalidate fonts (they'll be recreated on next use)
    for (auto& [h, font] : g_fonts) {
        font.invalidate();
    }
}

void on_device_reset()
{
    // Reload textures
    for (auto& [h, obj] : g_textures) {
        reload_texture(obj);
    }
}

// ── Rendering ─────────────────────────────────────────────────

static void render_text_objects(IDirect3DDevice9* dev)
{
    // Get backbuffer surface for GDI drawing
    IDirect3DSurface9* backBuffer = nullptr;
    if (FAILED(dev->GetRenderTarget(0, &backBuffer))) return;

    HDC hdc = nullptr;
    if (FAILED(backBuffer->GetDC(&hdc))) {
        backBuffer->Release();
        return;
    }

    // Set up for transparent text drawing
    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, 0x000000);  // Will be overridden per-object

    for (auto& [h, obj] : g_texts) {
        if (!obj.visible) continue;
        if (obj.text.empty()) continue;

        // Find the font
        auto fit = g_fonts.find(obj.font);
        if (fit == g_fonts.end()) continue;

        HFONT hFont = fit->second.get_handle();
        if (!hFont) continue;

        HFONT oldFont = (HFONT)SelectObject(hdc, hFont);

        // Convert ARGB to GDI COLORREF (swap R and B)
        uint32_t argb = obj.color;
        uint8_t a = (argb >> 24) & 0xFF;
        uint8_t r = (argb >> 16) & 0xFF;
        uint8_t g_val = (argb >> 8) & 0xFF;
        uint8_t b = argb & 0xFF;

        // GDI doesn't support alpha in DrawText directly.
        // We'll use the color as-is (ignore alpha for GDI text).
        COLORREF cr = RGB(r, g_val, b);
        SetTextColor(hdc, cr);

        RECT rc;
        rc.left = (LONG)obj.x;
        rc.top = (LONG)obj.y;
        rc.right = rc.left + 2000;  // generous bound
        rc.bottom = rc.top + 2000;

        DrawTextA(hdc, obj.text.c_str(), (int)obj.text.length(), &rc, DT_LEFT | DT_TOP | DT_NOCLIP);

        SelectObject(hdc, oldFont);
    }

    backBuffer->ReleaseDC(hdc);
    backBuffer->Release();
}

static void render_texture_objects(IDirect3DDevice9* dev)
{
    // Collect visible textures and sort by level (z-order)
    struct RenderEntry {
        texture_handle_t handle;
        TextureObj* obj;
    };
    std::vector<RenderEntry> sorted;
    for (auto& [h, obj] : g_textures) {
        if (obj.visible && obj.texture) {
            sorted.push_back({ h, &obj });
        }
    }
    std::sort(sorted.begin(), sorted.end(), [](const RenderEntry& a, const RenderEntry& b) {
        return a.obj->level < b.obj->level;
    });

    // Set up render state for alpha-blended sprites
    dev->SetRenderState(D3DRS_ALPHABLENDENABLE, TRUE);
    dev->SetRenderState(D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
    dev->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
    dev->SetRenderState(D3DRS_LIGHTING, FALSE);
    dev->SetRenderState(D3DRS_ZENABLE, FALSE);
    dev->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
    dev->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_MODULATE);
    dev->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
    dev->SetTextureStageState(0, D3DTSS_COLORARG2, D3DTA_DIFFUSE);
    dev->SetTextureStageState(0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
    dev->SetTextureStageState(0, D3DTSS_ALPHAARG1, D3DTA_TEXTURE);
    dev->SetTextureStageState(0, D3DTSS_ALPHAARG2, D3DTA_DIFFUSE);

    for (auto& entry : sorted) {
        TextureObj& obj = *entry.obj;

        dev->SetTexture(0, obj.texture);
        dev->SetFVF(D3DFVF_TL);

        // Calculate source UVs
        float u0 = 0.0f, v0 = 0.0f, u1 = 1.0f, v1 = 1.0f;
        if (obj.srcRight > 0 && obj.srcBottom > 0 && obj.pixelWidth > 0 && obj.pixelHeight > 0) {
            u0 = obj.srcLeft / (float)obj.pixelWidth;
            v0 = obj.srcTop / (float)obj.pixelHeight;
            u1 = obj.srcRight / (float)obj.pixelWidth;
            v1 = obj.srcBottom / (float)obj.pixelHeight;
        }

        // Extract ARGB color
        uint32_t col = obj.color;
        float cx = obj.x + obj.width * 0.5f;
        float cy = obj.y + obj.height * 0.5f;

        // Build quad corners (before rotation)
        float hw = obj.width * 0.5f;
        float hh = obj.height * 0.5f;

        float cosR = 1.0f, sinR = 0.0f;
        if (obj.rotation != 0.0f) {
            float rad = obj.rotation * (float)M_PI / 180.0f;
            cosR = cosf(rad);
            sinR = sinf(rad);
        }

        struct { float dx, dy, u, v; } corners[4] = {
            { -hw, -hh, u0, v0 },  // top-left
            {  hw, -hh, u1, v0 },  // top-right
            {  hw,  hh, u1, v1 },  // bottom-right
            { -hw,  hh, u0, v1 },  // bottom-left
        };

        VertexTL verts[6];  // 2 triangles
        // Triangle 1: 0,1,2
        // Triangle 2: 0,2,3
        int indices[6] = { 0, 1, 2, 0, 2, 3 };

        for (int i = 0; i < 6; i++) {
            int ci = indices[i];
            float dx = corners[ci].dx;
            float dy = corners[ci].dy;
            if (obj.rotation != 0.0f) {
                float rdx = dx * cosR - dy * sinR;
                float rdy = dx * sinR + dy * cosR;
                dx = rdx;
                dy = rdy;
            }
            verts[i].x = cx + dx;
            verts[i].y = cy + dy;
            verts[i].z = 0.0f;
            verts[i].rhw = 1.0f;
            verts[i].color = col;
            verts[i].tu = corners[ci].u;
            verts[i].tv = corners[ci].v;
        }

        dev->DrawPrimitiveUP(D3DPT_TRIANGLELIST, 2, verts, sizeof(VertexTL));
    }

    dev->SetTexture(0, nullptr);
}

static void render_fps(IDirect3DDevice9* dev)
{
    if (!g_show_fps) return;

    char buf[32];
    snprintf(buf, sizeof(buf), "FPS: %.1f", g_fps_value);

    IDirect3DSurface9* backBuffer = nullptr;
    if (FAILED(dev->GetRenderTarget(0, &backBuffer))) return;

    HDC hdc = nullptr;
    if (FAILED(backBuffer->GetDC(&hdc))) {
        backBuffer->Release();
        return;
    }

    SetBkMode(hdc, OPAQUE);
    SetBkColor(hdc, RGB(0, 0, 0));
    SetTextColor(hdc, RGB(0, 255, 0));

    RECT rc;
    rc.left = 4;
    rc.top = 4;
    rc.right = 200;
    rc.bottom = 30;
    DrawTextA(hdc, buf, -1, &rc, DT_LEFT | DT_TOP);

    backBuffer->ReleaseDC(hdc);
    backBuffer->Release();
}

void on_end_scene(IDirect3DDevice9* pDevice)
{
    d3d9_status::set(d3d9_status::FRAME_RENDERED);
    // Update delta time
    DWORD now = GetTickCount();
    if (g_last_tick == 0) g_last_tick = now;
    g_last_dt = (float)(now - g_last_tick) / 1000.0f;
    g_last_tick = now;

    // Update FPS
    g_fps_frames++;
    g_fps_time += g_last_dt;
    if (g_fps_time >= 1.0f) {
        g_fps_value = g_fps_frames / g_fps_time;
        g_fps_frames = 0;
        g_fps_time = 0.0f;
    }

    // Tick text lifetimes
    for (auto it = g_texts.begin(); it != g_texts.end(); ) {
        TextObj& obj = it->second;
        if (obj.remaining > 0.0f) {
            obj.remaining -= g_last_dt;
            if (obj.remaining <= 0.0f) {
                d3d9_resources::release(it->first, d3d9_resources::ResourceType::Text);
                it = g_texts.erase(it);
                continue;
            }
        }
        ++it;
    }

    // Overlay drawing can change blend, depth, lighting, texture-stage, FVF,
    // bindings, render targets and GDI/D3D interop state. Warcraft does not
    // necessarily re-establish every value before the next frame, so isolate
    // the complete overlay pass. If capture is unavailable, skip the whole
    // pass rather than risk corrupting Warcraft's renderer.
    IDirect3DStateBlock9* stateBlock = nullptr;
    if (SUCCEEDED(pDevice->CreateStateBlock(D3DSBT_ALL, &stateBlock)) && stateBlock) {
        if (SUCCEEDED(stateBlock->Capture())) {
            render_texture_objects(pDevice);
            render_text_objects(pDevice);
            render_fps(pDevice);
            stateBlock->Apply();
        }
        stateBlock->Release();
    }
}

void on_device_destroyed()
{
    on_device_lost();
    g_device = nullptr;
}

uint32_t begin_session()
{
    return d3d9_resources::begin_session();
}

bool end_session(uint32_t session)
{
    if (session == 0 || session != d3d9_resources::active_session()) return false;

    for (auto& [h, obj] : g_textures) {
        if (obj.texture) {
            obj.texture->Release();
            obj.texture = nullptr;
        }
    }
    for (auto& [h, font] : g_fonts) {
        font.destroy();
    }
    g_textures.clear();
    g_texts.clear();
    g_fonts.clear();

    g_last_dt = 0.0f;
    g_last_tick = GetTickCount();
    g_show_fps = false;
    g_fps_frames = 0;
    g_fps_time = 0.0f;
    g_fps_value = 0.0f;
    return d3d9_resources::invalidate_session(session);
}

bool is_device_ready()
{
    return g_device != nullptr;
}

d3d9_resources::ResourceCounts resource_counts()
{
    return d3d9_resources::counts();
}

// ── Font API ──────────────────────────────────────────────────

font_handle_t create_font()
{
    font_handle_t h = d3d9_resources::allocate(d3d9_resources::ResourceType::Font);
    if (!h) return 0;
    g_fonts[h] = FontObj();
    return h;
}

void destroy_font(font_handle_t h)
{
    if (font_in_use(h)) return;
    auto it = g_fonts.find(h);
    if (it != g_fonts.end()) {
        it->second.destroy();
        g_fonts.erase(it);
        d3d9_resources::release(h, d3d9_resources::ResourceType::Font);
    }
}

bool font_in_use(font_handle_t h)
{
    for (const auto& [text_handle, text] : g_texts) {
        if (text.font == h) return true;
    }
    return false;
}

int get_font_height(font_handle_t h)
{
    auto it = g_fonts.find(h);
    return it != g_fonts.end() ? it->second.height : 0;
}

void set_font_height(font_handle_t h, int value)
{
    auto it = g_fonts.find(h);
    if (it != g_fonts.end()) {
        it->second.height = value;
        it->second.invalidate();
    }
}

int get_font_width(font_handle_t h)
{
    auto it = g_fonts.find(h);
    return it != g_fonts.end() ? it->second.width : 0;
}

void set_font_width(font_handle_t h, int value)
{
    auto it = g_fonts.find(h);
    if (it != g_fonts.end()) {
        it->second.width = value;
        it->second.invalidate();
    }
}

int get_font_weight(font_handle_t h)
{
    auto it = g_fonts.find(h);
    return it != g_fonts.end() ? it->second.weight : 0;
}

void set_font_weight(font_handle_t h, int value)
{
    auto it = g_fonts.find(h);
    if (it != g_fonts.end()) {
        it->second.weight = value;
        it->second.invalidate();
    }
}

void set_font_italic(font_handle_t h, bool value)
{
    auto it = g_fonts.find(h);
    if (it != g_fonts.end()) {
        it->second.italic = value;
        it->second.invalidate();
    }
}

static char g_font_facename_buf[256];

const char* get_font_facename(font_handle_t h)
{
    auto it = g_fonts.find(h);
    if (it != g_fonts.end()) {
        strncpy(g_font_facename_buf, it->second.faceName.c_str(), 255);
        g_font_facename_buf[255] = '\0';
        return g_font_facename_buf;
    }
    return "";
}

void set_font_facename(font_handle_t h, const char* value)
{
    auto it = g_fonts.find(h);
    if (it != g_fonts.end()) {
        it->second.faceName = value ? value : "Arial";
        it->second.invalidate();
    }
}

// ── Text API ──────────────────────────────────────────────────

text_handle_t create_text(font_handle_t font, const char* str, float x, float y, float time, uint32_t color)
{
    if (!d3d9_resources::validate(font, d3d9_resources::ResourceType::Font)) return 0;
    text_handle_t h = d3d9_resources::allocate(d3d9_resources::ResourceType::Text);
    if (!h) return 0;
    TextObj& obj = g_texts[h];
    obj.text = str ? str : "";
    obj.x = x;
    obj.y = y;
    obj.remaining = time;
    obj.color = color;
    obj.font = font;
    obj.visible = true;
    return h;
}

void destroy_text(text_handle_t h)
{
    if (g_texts.erase(h) != 0) {
        d3d9_resources::release(h, d3d9_resources::ResourceType::Text);
    }
}

static char g_text_buf[4096];

const char* get_text_string(text_handle_t h)
{
    auto it = g_texts.find(h);
    if (it != g_texts.end()) {
        strncpy(g_text_buf, it->second.text.c_str(), 4095);
        g_text_buf[4095] = '\0';
        return g_text_buf;
    }
    return "";
}

void set_text_string(text_handle_t h, const char* str)
{
    auto it = g_texts.find(h);
    if (it != g_texts.end()) {
        it->second.text = str ? str : "";
    }
}

float get_text_x(text_handle_t h)
{
    auto it = g_texts.find(h);
    return it != g_texts.end() ? it->second.x : 0.0f;
}

void set_text_x(text_handle_t h, float value)
{
    auto it = g_texts.find(h);
    if (it != g_texts.end()) it->second.x = value;
}

float get_text_y(text_handle_t h)
{
    auto it = g_texts.find(h);
    return it != g_texts.end() ? it->second.y : 0.0f;
}

void set_text_y(text_handle_t h, float value)
{
    auto it = g_texts.find(h);
    if (it != g_texts.end()) it->second.y = value;
}

float get_text_time(text_handle_t h)
{
    auto it = g_texts.find(h);
    return it != g_texts.end() ? it->second.remaining : 0.0f;
}

void set_text_time(text_handle_t h, float value)
{
    auto it = g_texts.find(h);
    if (it != g_texts.end()) it->second.remaining = value;
}

uint32_t get_text_color(text_handle_t h)
{
    auto it = g_texts.find(h);
    return it != g_texts.end() ? it->second.color : 0;
}

void set_text_color(text_handle_t h, uint32_t value)
{
    auto it = g_texts.find(h);
    if (it != g_texts.end()) it->second.color = value;
}

// ── Texture API ───────────────────────────────────────────────

texture_handle_t create_texture(const char* path, float x, float y, float width, float height, uint32_t color, int level)
{
    texture_handle_t h = d3d9_resources::allocate(d3d9_resources::ResourceType::Texture);
    if (!h) return 0;
    TextureObj& obj = g_textures[h];
    obj.path = path ? path : "";
    obj.x = x;
    obj.y = y;
    obj.width = width;
    obj.height = height;
    obj.color = color;
    obj.level = level;
    obj.rotation = 0.0f;
    obj.visible = true;
    obj.triggerEnabled = true;

    if (g_device) {
        reload_texture(obj);
    }
    return h;
}

void destroy_texture(texture_handle_t h)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) {
        if (it->second.texture) {
            it->second.texture->Release();
        }
        g_textures.erase(it);
        d3d9_resources::release(h, d3d9_resources::ResourceType::Texture);
    }
}

float get_texture_x(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? it->second.x : 0.0f;
}

void set_texture_x(texture_handle_t h, float value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.x = value;
}

float get_texture_y(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? it->second.y : 0.0f;
}

void set_texture_y(texture_handle_t h, float value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.y = value;
}

float get_texture_width(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? it->second.width : 0.0f;
}

void set_texture_width(texture_handle_t h, float value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.width = value;
}

float get_texture_height(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? it->second.height : 0.0f;
}

void set_texture_height(texture_handle_t h, float value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.height = value;
}

uint32_t get_texture_color(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? it->second.color : 0;
}

void set_texture_color(texture_handle_t h, uint32_t value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.color = value;
}

int get_texture_level(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? it->second.level : 0;
}

void set_texture_level(texture_handle_t h, int value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.level = value;
}

float get_texture_rotation(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? it->second.rotation : 0.0f;
}

void set_texture_rotation(texture_handle_t h, float value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.rotation = value;
}

float get_texture_pixel_width(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? (float)it->second.pixelWidth : 0.0f;
}

float get_texture_pixel_height(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? (float)it->second.pixelHeight : 0.0f;
}

void set_texture(texture_handle_t h, const char* path)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) {
        it->second.path = path ? path : "";
        reload_texture(it->second);
    }
}

void set_texture_show(texture_handle_t h, bool value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.visible = value;
}

void set_texture_trigger(texture_handle_t h, bool value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.triggerEnabled = value;
}

bool get_mouse_in_texture(texture_handle_t h)
{
    auto it = g_textures.find(h);
    if (it == g_textures.end()) return false;

    const TextureObj& obj = it->second;
    if (!obj.visible || !obj.triggerEnabled || !obj.texture) return false;

    const float mx = get_mouse_vector_x();
    const float my = get_mouse_vector_y();
    return mx >= obj.x && mx < obj.x + obj.width &&
           my >= obj.y && my < obj.y + obj.height;
}

void get_texture_src_rect(texture_handle_t h, float* left, float* top, float* right, float* bottom)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) {
        if (left) *left = it->second.srcLeft;
        if (top) *top = it->second.srcTop;
        if (right) *right = it->second.srcRight > 0.0f
            ? it->second.srcRight : (float)it->second.pixelWidth;
        if (bottom) *bottom = it->second.srcBottom > 0.0f
            ? it->second.srcBottom : (float)it->second.pixelHeight;
    }
}

void set_texture_src_rect(texture_handle_t h, float left, float top, float right, float bottom)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) {
        it->second.srcLeft = left;
        it->second.srcTop = top;
        it->second.srcRight = right;
        it->second.srcBottom = bottom;
    }
}

// ── Window/mouse utilities ────────────────────────────────────

static HWND find_war3_window()
{
    // Find War3 window by class name
    HWND hwnd = FindWindowA("Warcraft III", nullptr);
    if (!hwnd) hwnd = FindWindowA(nullptr, "Warcraft III");
    if (!hwnd) hwnd = FindWindowA("OsWindow", nullptr);
    return hwnd;
}

float get_mouse_vector_x()
{
    HWND hwnd = find_war3_window();
    if (!hwnd) return 0.0f;

    POINT pt;
    GetCursorPos(&pt);
    ScreenToClient(hwnd, &pt);
    return (float)pt.x;
}

float get_mouse_vector_y()
{
    HWND hwnd = find_war3_window();
    if (!hwnd) return 0.0f;

    POINT pt;
    GetCursorPos(&pt);
    ScreenToClient(hwnd, &pt);
    return (float)pt.y;
}

int get_window_width()
{
    HWND hwnd = find_war3_window();
    if (!hwnd) return 0;

    RECT rc;
    GetClientRect(hwnd, &rc);
    return rc.right - rc.left;
}

int get_window_height()
{
    HWND hwnd = find_war3_window();
    if (!hwnd) return 0;

    RECT rc;
    GetClientRect(hwnd, &rc);
    return rc.bottom - rc.top;
}

// ── FPS ───────────────────────────────────────────────────────

void show_fps_text(bool show)
{
    g_show_fps = show;
}

}  // namespace d3d9_renderer

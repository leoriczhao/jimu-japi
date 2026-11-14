// renderer.cpp — Text and texture rendering implementation
//
// Text rendering: D3DXFont with ARGB alpha blending
// Texture rendering: DrawPrimitiveUP with transformed textured vertices
//
// All rendering happens in on_end_scene(), called from the hooked EndScene().

#include "renderer.h"
#include "d3dx9_font_abi.h"
#include "resource_manager.h"
#include "status.h"
#include "texture_asset.h"
#include <d3d9.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <new>
#include <sstream>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace d3d9_renderer {

// ── State ─────────────────────────────────────────────────────

static IDirect3DDevice9* g_device = nullptr;

static std::map<font_handle_t, FontObj>      g_fonts;
static std::map<text_handle_t, TextObj>      g_texts;
static std::map<texture_handle_t, TextureObj> g_textures;
static std::map<std::string, std::weak_ptr<const std::vector<uint8_t>>> g_asset_cache;
static uint64_t g_next_creation_order = 1;

static HMODULE g_d3dx_module = nullptr;
static bool g_d3dx_load_attempted = false;
static HRESULT (WINAPI *g_create_texture_from_file)(
    IDirect3DDevice9*, const char*, IDirect3DTexture9**) = nullptr;
static D3DXCreateFontA_fn g_create_font = nullptr;

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

static void ensure_d3dx_loaded()
{
    if (g_d3dx_load_attempted) return;
    g_d3dx_load_attempted = true;

    g_d3dx_module = LoadLibraryA("d3dx9_42.dll");
    if (!g_d3dx_module) g_d3dx_module = LoadLibraryA("d3dx9_43.dll");
    if (!g_d3dx_module) g_d3dx_module = LoadLibraryA("d3dx9_33.dll");
    if (g_d3dx_module) {
        g_create_texture_from_file =
            reinterpret_cast<decltype(g_create_texture_from_file)>(
                GetProcAddress(g_d3dx_module, "D3DXCreateTextureFromFileA"));
        g_create_font = reinterpret_cast<D3DXCreateFontA_fn>(
            GetProcAddress(g_d3dx_module, "D3DXCreateFontA"));
    }
}

ID3DXFont* FontObj::get_handle(IDirect3DDevice9* device)
{
    if (!d3dFont && device) {
        ensure_d3dx_loaded();
        if (g_create_font) {
            ID3DXFont* created = nullptr;
            const HRESULT hr = g_create_font(
                device,
                height,
                static_cast<UINT>(width),
                static_cast<UINT>(weight),
                1,
                italic ? TRUE : FALSE,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLEARTYPE_QUALITY,
                DEFAULT_PITCH | FF_DONTCARE,
                faceName.c_str(),
                &created);
            if (SUCCEEDED(hr)) d3dFont = created;
        }
    }
    return d3dFont;
}

void FontObj::invalidate()
{
    if (d3dFont) {
        d3dFont->lpVtbl->Release(d3dFont);
        d3dFont = nullptr;
    }
}

void FontObj::destroy()
{
    invalidate();
}

void FontObj::on_device_lost()
{
    if (d3dFont) d3dFont->lpVtbl->OnLostDevice(d3dFont);
}

void FontObj::on_device_reset()
{
    if (d3dFont && FAILED(d3dFont->lpVtbl->OnResetDevice(d3dFont))) {
        invalidate();
    }
}

// ── Texture loading helper ────────────────────────────────────

// Load a texture from a file path (BMP/TGA/JPG/PNG).
// Uses D3DXCreateTextureFromFileA if d3dx9 is available,
// otherwise falls back to D3DXCreateTextureFromFileEx via LoadLibrary.
static IDirect3DTexture9* load_texture(IDirect3DDevice9* dev, const char* path)
{
    if (!path || !path[0]) return nullptr;

    ensure_d3dx_loaded();
    if (g_create_texture_from_file) {
        IDirect3DTexture9* tex = nullptr;
        HRESULT hr = g_create_texture_from_file(dev, path, &tex);
        if (SUCCEEDED(hr) && tex) return tex;
    }

    return nullptr;
}

static uint64_t hash_asset_bytes(const void* data, size_t size)
{
    const auto* bytes = static_cast<const uint8_t*>(data);
    uint64_t hash = 1469598103934665603ull;
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ull;
    }
    return hash;
}

static std::string asset_cache_key(const char* source, const void* data, size_t size)
{
    std::ostringstream key;
    key << (source ? source : "") << '#' << size << '#'
        << std::hex << hash_asset_bytes(data, size);
    return key.str();
}

static std::shared_ptr<const std::vector<uint8_t>> acquire_asset(
    const char* source, const void* data, size_t size)
{
    const std::string key = asset_cache_key(source, data, size);
    auto found = g_asset_cache.find(key);
    if (found != g_asset_cache.end()) {
        auto existing = found->second.lock();
        if (existing) return existing;
        g_asset_cache.erase(found);
    }
    const auto* begin = static_cast<const uint8_t*>(data);
    auto created = std::make_shared<const std::vector<uint8_t>>(begin, begin + size);
    g_asset_cache.emplace(key, created);
    return created;
}

static void purge_asset_cache()
{
    for (auto it = g_asset_cache.begin(); it != g_asset_cache.end();) {
        if (it->second.expired()) it = g_asset_cache.erase(it);
        else ++it;
    }
}

static TextureMemoryResult load_memory_texture(
    const std::shared_ptr<const std::vector<uint8_t>>& data,
    IDirect3DTexture9** out_texture, int* out_width, int* out_height)
{
    if (!data || data->empty()) return TextureMemoryResult::InvalidData;
    if (!g_device) return TextureMemoryResult::DeviceNotReady;
    uint32_t width = 0;
    uint32_t height = 0;
    const auto result = d3d9_texture_asset::create_texture(
        g_device, data->data(), data->size(), out_texture, &width, &height);
    if (result != d3d9_texture_asset::DecodeResult::Ok) {
        return result == d3d9_texture_asset::DecodeResult::InvalidData
            || result == d3d9_texture_asset::DecodeResult::UnsupportedFormat
            ? TextureMemoryResult::InvalidData
            : TextureMemoryResult::DecodeFailed;
    }
    *out_width = static_cast<int>(width);
    *out_height = static_cast<int>(height);
    return TextureMemoryResult::Ok;
}

// Reload a texture object's D3D texture
static void reload_texture(TextureObj& obj)
{
    if (obj.texture) {
        obj.texture->Release();
        obj.texture = nullptr;
    }
    obj.pixelWidth = 0;
    obj.pixelHeight = 0;
    if (g_device && obj.sourceData) {
        load_memory_texture(obj.sourceData, &obj.texture,
            &obj.pixelWidth, &obj.pixelHeight);
        if (obj.texture) d3d9_status::set(d3d9_status::TEXTURE_LOADED);
    } else if (g_device && !obj.path.empty()) {
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

    // D3DXFont retains the logical object while releasing default-pool data.
    for (auto& [h, font] : g_fonts) {
        font.on_device_lost();
    }
}

void on_device_reset()
{
    // Reload textures
    for (auto& [h, obj] : g_textures) {
        reload_texture(obj);
    }

    for (auto& [h, font] : g_fonts) {
        font.on_device_reset();
    }
}

// ── Rendering ─────────────────────────────────────────────────

static void render_text_object(IDirect3DDevice9* dev, TextObj& obj)
{
    if (obj.text.empty()) return;
    auto fit = g_fonts.find(obj.font);
    if (fit == g_fonts.end()) return;

    ID3DXFont* font = fit->second.get_handle(dev);
    if (!font) return;

    RECT rc = {};
    rc.left = static_cast<LONG>(obj.x);
    rc.top = static_cast<LONG>(obj.y);
    rc.right = rc.left + 2000;
    rc.bottom = rc.top + 2000;
    font->lpVtbl->DrawTextA(
        font,
        nullptr,
        obj.text.c_str(),
        static_cast<INT>(obj.text.size()),
        &rc,
        DT_LEFT | DT_TOP | DT_NOCLIP,
        static_cast<D3DCOLOR>(obj.color));
}

static void prepare_texture_render_state(IDirect3DDevice9* dev)
{
    dev->SetVertexShader(nullptr);
    dev->SetPixelShader(nullptr);
    dev->SetRenderState(D3DRS_ALPHABLENDENABLE, TRUE);
    dev->SetRenderState(D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
    dev->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
    dev->SetRenderState(D3DRS_LIGHTING, FALSE);
    dev->SetRenderState(D3DRS_ZENABLE, FALSE);
    dev->SetRenderState(D3DRS_ZWRITEENABLE, FALSE);
    dev->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
    dev->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_MODULATE);
    dev->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
    dev->SetTextureStageState(0, D3DTSS_COLORARG2, D3DTA_DIFFUSE);
    dev->SetTextureStageState(0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
    dev->SetTextureStageState(0, D3DTSS_ALPHAARG1, D3DTA_TEXTURE);
    dev->SetTextureStageState(0, D3DTSS_ALPHAARG2, D3DTA_DIFFUSE);
    dev->SetFVF(D3DFVF_TL);
}

static void render_texture_object(IDirect3DDevice9* dev, TextureObj& obj)
{
    prepare_texture_render_state(dev);
    dev->SetTexture(0, obj.texture);

    // Calculate source UVs
    float u0 = 0.0f, v0 = 0.0f, u1 = 1.0f, v1 = 1.0f;
    if (obj.srcRight > 0 && obj.srcBottom > 0 && obj.pixelWidth > 0 && obj.pixelHeight > 0) {
        u0 = obj.srcLeft / (float)obj.pixelWidth;
        v0 = obj.srcTop / (float)obj.pixelHeight;
        u1 = obj.srcRight / (float)obj.pixelWidth;
        v1 = obj.srcBottom / (float)obj.pixelHeight;
    }

    uint32_t col = obj.color;
    float cx = obj.x + obj.width * 0.5f;
    float cy = obj.y + obj.height * 0.5f;

    float hw = obj.width * 0.5f;
    float hh = obj.height * 0.5f;

    float cosR = 1.0f, sinR = 0.0f;
    if (obj.rotation != 0.0f) {
        float rad = obj.rotation * (float)M_PI / 180.0f;
        cosR = cosf(rad);
        sinR = sinf(rad);
    }

    struct { float dx, dy, u, v; } corners[4] = {
        { -hw, -hh, u0, v0 },
        {  hw, -hh, u1, v0 },
        {  hw,  hh, u1, v1 },
        { -hw,  hh, u0, v1 },
    };

    VertexTL verts[6];
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
    dev->SetTexture(0, nullptr);
}

static void render_objects(IDirect3DDevice9* dev)
{
    enum class RenderKind { Text, Texture };
    struct RenderEntry {
        int level;
        uint64_t creationOrder;
        RenderKind kind;
        void* object;
    };

    std::vector<RenderEntry> queue;
    queue.reserve(g_texts.size() + g_textures.size());
    for (auto& [h, obj] : g_texts) {
        if (obj.visible && !obj.text.empty()) {
            queue.push_back({obj.level, obj.creationOrder, RenderKind::Text, &obj});
        }
    }
    for (auto& [h, obj] : g_textures) {
        if (obj.visible && obj.texture) {
            queue.push_back({obj.level, obj.creationOrder, RenderKind::Texture, &obj});
        }
    }

    std::sort(queue.begin(), queue.end(), [](const RenderEntry& left, const RenderEntry& right) {
        if (left.level != right.level) return left.level < right.level;
        return left.creationOrder < right.creationOrder;
    });

    for (const RenderEntry& entry : queue) {
        if (entry.kind == RenderKind::Text) {
            render_text_object(dev, *static_cast<TextObj*>(entry.object));
        } else {
            render_texture_object(dev, *static_cast<TextureObj*>(entry.object));
        }
    }
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
            render_objects(pDevice);
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
    g_next_creation_order = 1;
    g_asset_cache.clear();

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

AssetCacheCounts asset_cache_counts()
{
    purge_asset_cache();
    AssetCacheCounts counts{};
    for (const auto& entry : g_asset_cache) {
        auto data = entry.second.lock();
        if (!data) continue;
        ++counts.entries;
        counts.bytes += data->size();
    }
    return counts;
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

const char* get_font_facename(font_handle_t h)
{
    auto it = g_fonts.find(h);
    return it != g_fonts.end() ? it->second.faceName.c_str() : "";
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
    obj.creationOrder = g_next_creation_order++;
    return h;
}

void destroy_text(text_handle_t h)
{
    if (g_texts.erase(h) != 0) {
        d3d9_resources::release(h, d3d9_resources::ResourceType::Text);
    }
}

const char* get_text_string(text_handle_t h)
{
    auto it = g_texts.find(h);
    return it != g_texts.end() ? it->second.text.c_str() : "";
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

bool get_text_visible(text_handle_t h)
{
    auto it = g_texts.find(h);
    return it != g_texts.end() && it->second.visible;
}

void set_text_visible(text_handle_t h, bool value)
{
    auto it = g_texts.find(h);
    if (it != g_texts.end()) it->second.visible = value;
}

int get_text_level(text_handle_t h)
{
    auto it = g_texts.find(h);
    return it != g_texts.end() ? it->second.level : 0;
}

void set_text_level(text_handle_t h, int value)
{
    auto it = g_texts.find(h);
    if (it != g_texts.end()) it->second.level = value;
}

font_handle_t get_text_font(text_handle_t h)
{
    auto it = g_texts.find(h);
    return it != g_texts.end() ? it->second.font : 0;
}

bool set_text_font(text_handle_t h, font_handle_t font)
{
    auto text = g_texts.find(h);
    if (text == g_texts.end()) return false;
    if (!d3d9_resources::validate(font, d3d9_resources::ResourceType::Font)) return false;
    text->second.font = font;
    return true;
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
    obj.creationOrder = g_next_creation_order++;

    if (g_device) {
        reload_texture(obj);
    }
    return h;
}

TextureMemoryResult create_texture_from_memory(
    const char* source, const void* data, size_t size,
    float x, float y, float width, float height, uint32_t color, int level,
    texture_handle_t* out_handle)
{
    if (!out_handle || !source || !data || size == 0) {
        return TextureMemoryResult::InvalidData;
    }
    *out_handle = 0;
    const auto inspected = d3d9_texture_asset::validate(data, size);
    if (inspected != d3d9_texture_asset::DecodeResult::Ok) {
        return TextureMemoryResult::InvalidData;
    }
    if (!g_device) return TextureMemoryResult::DeviceNotReady;
    try {
        auto asset = acquire_asset(source, data, size);
        IDirect3DTexture9* texture = nullptr;
        int pixel_width = 0;
        int pixel_height = 0;
        const TextureMemoryResult loaded = load_memory_texture(
            asset, &texture, &pixel_width, &pixel_height);
        if (loaded != TextureMemoryResult::Ok) {
            purge_asset_cache();
            return loaded;
        }

        TextureObj obj;
        try {
            obj.path = source;
            obj.sourceData = std::move(asset);
            obj.texture = texture;
            obj.x = x;
            obj.y = y;
            obj.width = width;
            obj.height = height;
            obj.color = color;
            obj.level = level;
            obj.rotation = 0.0f;
            obj.visible = true;
            obj.triggerEnabled = true;
            obj.creationOrder = g_next_creation_order;
            obj.pixelWidth = pixel_width;
            obj.pixelHeight = pixel_height;
        } catch (...) {
            texture->Release();
            throw;
        }

        const texture_handle_t handle =
            d3d9_resources::allocate(d3d9_resources::ResourceType::Texture);
        if (!handle) {
            texture->Release();
            purge_asset_cache();
            return TextureMemoryResult::CapacityExceeded;
        }
        try {
            const auto inserted = g_textures.emplace(handle, std::move(obj));
            if (!inserted.second) {
                texture->Release();
                d3d9_resources::release(handle, d3d9_resources::ResourceType::Texture);
                purge_asset_cache();
                return TextureMemoryResult::CapacityExceeded;
            }
        } catch (...) {
            texture->Release();
            d3d9_resources::release(handle, d3d9_resources::ResourceType::Texture);
            throw;
        }
        ++g_next_creation_order;
        d3d9_status::set(d3d9_status::TEXTURE_LOADED);
        *out_handle = handle;
        return TextureMemoryResult::Ok;
    } catch (const std::bad_alloc&) {
        purge_asset_cache();
        return TextureMemoryResult::CapacityExceeded;
    } catch (...) {
        purge_asset_cache();
        return TextureMemoryResult::DecodeFailed;
    }
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
        purge_asset_cache();
    }
}

bool get_font_italic(font_handle_t h)
{
    auto it = g_fonts.find(h);
    return it != g_fonts.end() && it->second.italic;
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

const char* get_texture_source(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() ? it->second.path.c_str() : "";
}

void set_texture(texture_handle_t h, const char* path)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) {
        it->second.path = path ? path : "";
        it->second.sourceData.reset();
        reload_texture(it->second);
        purge_asset_cache();
    }
}

TextureMemoryResult set_texture_from_memory(
    texture_handle_t h, const char* source, const void* data, size_t size)
{
    auto it = g_textures.find(h);
    if (it == g_textures.end() || !source || !data || size == 0) {
        return TextureMemoryResult::InvalidData;
    }
    const auto inspected = d3d9_texture_asset::validate(data, size);
    if (inspected != d3d9_texture_asset::DecodeResult::Ok) {
        return TextureMemoryResult::InvalidData;
    }
    if (!g_device) return TextureMemoryResult::DeviceNotReady;
    IDirect3DTexture9* texture = nullptr;
    try {
        std::string new_source(source);
        auto asset = acquire_asset(source, data, size);
        int pixel_width = 0;
        int pixel_height = 0;
        const TextureMemoryResult loaded = load_memory_texture(
            asset, &texture, &pixel_width, &pixel_height);
        if (loaded != TextureMemoryResult::Ok) {
            purge_asset_cache();
            return loaded;
        }

        if (it->second.texture) it->second.texture->Release();
        it->second.texture = texture;
        it->second.path = std::move(new_source);
        it->second.sourceData = std::move(asset);
        it->second.pixelWidth = pixel_width;
        it->second.pixelHeight = pixel_height;
        purge_asset_cache();
        d3d9_status::set(d3d9_status::TEXTURE_LOADED);
        return TextureMemoryResult::Ok;
    } catch (const std::bad_alloc&) {
        if (texture) texture->Release();
        purge_asset_cache();
        return TextureMemoryResult::CapacityExceeded;
    } catch (...) {
        if (texture) texture->Release();
        purge_asset_cache();
        return TextureMemoryResult::DecodeFailed;
    }
}

void set_texture_show(texture_handle_t h, bool value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.visible = value;
}

bool get_texture_show(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() && it->second.visible;
}

void set_texture_trigger(texture_handle_t h, bool value)
{
    auto it = g_textures.find(h);
    if (it != g_textures.end()) it->second.triggerEnabled = value;
}

bool get_texture_trigger(texture_handle_t h)
{
    auto it = g_textures.find(h);
    return it != g_textures.end() && it->second.triggerEnabled;
}

bool texture_contains(texture_handle_t h, float x, float y)
{
    auto it = g_textures.find(h);
    if (it == g_textures.end()) return false;
    const TextureObj& obj = it->second;
    if (!obj.visible || !obj.triggerEnabled) return false;

    // Drawing rotates around the rectangle center. Apply the inverse rotation
    // to the point so hit testing follows the rendered quad instead of its AABB.
    const float center_x = obj.x + obj.width * 0.5f;
    const float center_y = obj.y + obj.height * 0.5f;
    float local_x = x - center_x;
    float local_y = y - center_y;
    if (obj.rotation != 0.0f) {
        const float radians = -obj.rotation * static_cast<float>(M_PI) / 180.0f;
        const float cosine = cosf(radians);
        const float sine = sinf(radians);
        const float rotated_x = local_x * cosine - local_y * sine;
        const float rotated_y = local_x * sine + local_y * cosine;
        local_x = rotated_x;
        local_y = rotated_y;
    }
    const float half_width = std::fabs(obj.width) * 0.5f;
    const float half_height = std::fabs(obj.height) * 0.5f;
    return local_x >= -half_width && local_x < half_width
        && local_y >= -half_height && local_y < half_height;
}

std::vector<texture_handle_t> texture_hit_stack(float x, float y)
{
    struct HitEntry {
        texture_handle_t handle;
        int level;
        uint64_t creationOrder;
    };
    std::vector<HitEntry> hits;
    hits.reserve(g_textures.size());
    for (const auto& [handle, obj] : g_textures) {
        if (texture_contains(handle, x, y)) {
            hits.push_back({handle, obj.level, obj.creationOrder});
        }
    }
    std::sort(hits.begin(), hits.end(), [](const HitEntry& left, const HitEntry& right) {
        if (left.level != right.level) return left.level > right.level;
        return left.creationOrder > right.creationOrder;
    });
    std::vector<texture_handle_t> handles;
    handles.reserve(hits.size());
    for (const auto& hit : hits) handles.push_back(hit.handle);
    return handles;
}

bool get_mouse_in_texture(texture_handle_t h)
{
    auto it = g_textures.find(h);
    if (it == g_textures.end()) return false;

    const TextureObj& obj = it->second;
    if (!obj.texture) return false;

    const float mx = get_mouse_vector_x();
    const float my = get_mouse_vector_y();
    return texture_contains(h, mx, my);
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

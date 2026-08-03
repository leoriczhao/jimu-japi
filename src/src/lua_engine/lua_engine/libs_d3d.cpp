#include "../../d3d9/sdk_api.h"

#include <lua.hpp>
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>

namespace warcraft3::lua_engine::d3d {

namespace {

constexpr const char* kFontMeta = "jass.d3d.Font";
constexpr const char* kTextMeta = "jass.d3d.Text";
constexpr const char* kTextureMeta = "jass.d3d.Texture";
constexpr const char* kContextMeta = "jass.d3d.Context";
constexpr const char* kVersion = "0.2.0-dev";
constexpr int32_t kMinInt32 = (-2147483647 - 1);
constexpr int32_t kMaxInt32 = 2147483647;

struct ResourceUserdata {
    uint32_t session = 0;
    uint32_t handle = 0;
    uint32_t type = 0;
    bool destroyed = false;
};

struct ContextUserdata {
    bool owner = false;
};

D3DSdkApiV1 g_api{};
bool g_api_checked = false;
bool g_api_ready = false;
bool g_shutdown = false;
uint32_t g_session = 0;
std::string g_init_error;
char g_context_registry_key = 0;

std::string native_error(const char* fallback = "D3D SDK operation failed")
{
    if (!g_api.copy_last_error) return fallback;
    char buffer[512] = {};
    g_api.copy_last_error(buffer, sizeof(buffer));
    return buffer[0] ? buffer : fallback;
}

bool initialize_api()
{
    if (g_api_checked) return g_api_ready && !g_shutdown;
    g_api_checked = true;

    HMODULE proxy = GetModuleHandleA("d3d9.dll");
    if (!proxy) {
        g_init_error = "d3d9.dll is not loaded";
        return false;
    }

    using get_api_fn = bool (D3D_SDK_CALL *)(uint32_t, D3DSdkApiV1*);
    auto get_api = reinterpret_cast<get_api_fn>(GetProcAddress(proxy, "GetD3DSdkApi"));
    if (!get_api) {
        g_init_error = "the loaded d3d9.dll is not the map-inject D3D proxy";
        return false;
    }

    g_api = {};
    g_api.struct_size = sizeof(g_api);
    if (!get_api(D3D_SDK_ABI_VERSION_1, &g_api)) {
        g_init_error = "D3D SDK ABI v1 negotiation failed";
        return false;
    }

    const uint64_t required = D3D_SDK_CAP_SESSION
        | D3D_SDK_CAP_GENERATION_HANDLES
        | D3D_SDK_CAP_RESOURCE_COUNTS
        | D3D_SDK_CAP_SHARED_LEGACY_REGISTRY
        | D3D_SDK_CAP_CORE_PROPERTIES;
    if ((g_api.capabilities & required) != required) {
        g_init_error = "D3D proxy is missing required core SDK capabilities";
        return false;
    }
    if (!g_api.begin_session || !g_api.end_session || !g_api.get_resource_counts
        || !g_api.is_handle_alive || !g_api.create_font || !g_api.destroy_font
        || !g_api.create_text || !g_api.destroy_text || !g_api.create_texture
        || !g_api.destroy_texture || !g_api.copy_last_error || !g_api.get_window_size
        || !g_api.copy_font_face || !g_api.set_font_face || !g_api.get_font_height
        || !g_api.set_font_height || !g_api.get_font_width || !g_api.set_font_width
        || !g_api.get_font_weight || !g_api.set_font_weight || !g_api.get_font_italic
        || !g_api.set_font_italic || !g_api.copy_text_string || !g_api.set_text_string
        || !g_api.get_text_position || !g_api.set_text_position || !g_api.get_text_ttl
        || !g_api.set_text_ttl || !g_api.get_text_color || !g_api.set_text_color
        || !g_api.get_text_visible || !g_api.set_text_visible || !g_api.get_text_level
        || !g_api.set_text_level || !g_api.get_text_font || !g_api.set_text_font
        || !g_api.copy_texture_source || !g_api.set_texture_source
        || !g_api.get_texture_rect || !g_api.set_texture_rect
        || !g_api.get_texture_src_rect || !g_api.set_texture_src_rect
        || !g_api.get_texture_color || !g_api.set_texture_color
        || !g_api.get_texture_rotation || !g_api.set_texture_rotation
        || !g_api.get_texture_level || !g_api.set_texture_level
        || !g_api.get_texture_visible || !g_api.set_texture_visible
        || !g_api.get_texture_hit_test || !g_api.set_texture_hit_test
        || !g_api.get_texture_pixel_size || !g_api.texture_contains) {
        g_init_error = "D3D proxy core SDK function table is incomplete";
        return false;
    }

    uint32_t session = 0;
    uint32_t result = g_api.begin_session(&session);
    if (result == D3D_SDK_SESSION_ACTIVE) {
        D3DSdkResourceCountsV1 counts{};
        counts.struct_size = sizeof(counts);
        result = g_api.get_resource_counts(0, &counts);
        session = counts.session_id;
    }
    if (result != D3D_SDK_OK || session == 0) {
        g_init_error = native_error("unable to begin or adopt the D3D session");
        return false;
    }

    g_session = session;
    g_api_ready = true;
    g_shutdown = false;
    g_init_error.clear();
    return true;
}

int push_unavailable(lua_State* L)
{
    lua_pushnil(L);
    lua_pushlstring(L, g_init_error.data(), g_init_error.size());
    return 2;
}

int push_result_error(lua_State* L, const char* fallback = "D3D SDK operation failed")
{
    const std::string message = native_error(fallback);
    lua_pushnil(L);
    lua_pushlstring(L, message.data(), message.size());
    return 2;
}

int raise_result_error(lua_State* L, const char* fallback = "D3D SDK operation failed")
{
    char buffer[512] = {};
    if (g_api.copy_last_error) g_api.copy_last_error(buffer, sizeof(buffer));
    return luaL_error(L, "%s", buffer[0] ? buffer : fallback);
}

using CopyResourceStringFn = uint32_t (D3D_SDK_CALL *)(
    uint32_t, uint32_t, char*, uint32_t, uint32_t*);

int push_resource_string(
    lua_State* L, ResourceUserdata* self, CopyResourceStringFn copy)
{
    uint32_t required = 0;
    if (copy(self->session, self->handle, nullptr, 0, &required) != D3D_SDK_OK)
        return raise_result_error(L);
    const uint32_t capacity = required > 0 ? required : 1;
    auto* buffer = static_cast<char*>(lua_newuserdatauv(L, capacity, 0));
    if (copy(self->session, self->handle, buffer, capacity, &required) != D3D_SDK_OK) {
        lua_pop(L, 1);
        return raise_result_error(L);
    }
    const size_t length = required > 0 ? static_cast<size_t>(required - 1) : 0;
    lua_pushlstring(L, buffer, length);
    lua_remove(L, -2);
    return 1;
}

const char* meta_for_type(uint32_t type)
{
    switch (type) {
    case D3D_SDK_RESOURCE_FONT: return kFontMeta;
    case D3D_SDK_RESOURCE_TEXT: return kTextMeta;
    case D3D_SDK_RESOURCE_TEXTURE: return kTextureMeta;
    default: return "jass.d3d.Resource";
    }
}

ResourceUserdata* check_resource(
    lua_State* L, int index, uint32_t type, bool require_alive = true)
{
    auto* self = static_cast<ResourceUserdata*>(
        luaL_checkudata(L, index, meta_for_type(type)));
    if (require_alive) {
        uint32_t alive = 0;
        if (self->destroyed || !g_api_ready || g_session == 0
            || self->session != g_session
            || g_api.is_handle_alive(self->session, type, self->handle, &alive) != D3D_SDK_OK
            || alive == 0) {
            self->destroyed = true;
            luaL_error(L, "%s is destroyed or belongs to a closed session", meta_for_type(type));
        }
    }
    return self;
}

bool resource_alive(ResourceUserdata* self)
{
    if (!self || self->destroyed || !g_api_ready || g_session == 0
        || self->session != g_session) return false;
    uint32_t alive = 0;
    if (g_api.is_handle_alive(self->session, self->type, self->handle, &alive) != D3D_SDK_OK
        || alive == 0) {
        self->destroyed = true;
        return false;
    }
    return true;
}

uint32_t destroy_native(ResourceUserdata* self)
{
    if (!resource_alive(self)) {
        if (self) self->destroyed = true;
        return D3D_SDK_OK;
    }
    uint32_t result = D3D_SDK_INVALID_HANDLE;
    switch (self->type) {
    case D3D_SDK_RESOURCE_FONT:
        result = g_api.destroy_font(self->session, self->handle);
        break;
    case D3D_SDK_RESOURCE_TEXT:
        result = g_api.destroy_text(self->session, self->handle);
        break;
    case D3D_SDK_RESOURCE_TEXTURE:
        result = g_api.destroy_texture(self->session, self->handle);
        break;
    }
    if (result == D3D_SDK_OK || result == D3D_SDK_INVALID_HANDLE
        || result == D3D_SDK_NO_ACTIVE_SESSION || result == D3D_SDK_STALE_SESSION) {
        self->destroyed = true;
    }
    return result;
}

ResourceUserdata* push_resource(
    lua_State* L, uint32_t type, uint32_t handle, int uservalues)
{
    auto* self = static_cast<ResourceUserdata*>(
        lua_newuserdatauv(L, sizeof(ResourceUserdata), uservalues));
    new (self) ResourceUserdata();
    self->session = g_session;
    self->handle = handle;
    self->type = type;
    luaL_setmetatable(L, meta_for_type(type));
    return self;
}

uint32_t check_color(lua_State* L, int index)
{
    const lua_Integer value = luaL_checkinteger(L, index);
    if (value < 0 || static_cast<uint64_t>(value) > 0xFFFFFFFFull) {
        luaL_argerror(L, index, "color must be between 0 and 0xFFFFFFFF");
    }
    return static_cast<uint32_t>(value);
}

double number_field(lua_State* L, int table, const char* name, double fallback)
{
    lua_getfield(L, table, name);
    const double value = lua_isnil(L, -1) ? fallback : luaL_checknumber(L, -1);
    lua_pop(L, 1);
    return value;
}

int32_t check_int32(lua_State* L, int index)
{
    const lua_Integer value = luaL_checkinteger(L, index);
    if (value < kMinInt32 || value > kMaxInt32) {
        luaL_argerror(L, index, "integer is outside the signed 32-bit range");
    }
    return static_cast<int32_t>(value);
}

int32_t integer_field(lua_State* L, int table, const char* name, int32_t fallback)
{
    lua_getfield(L, table, name);
    const int32_t value = lua_isnil(L, -1) ? fallback : check_int32(L, -1);
    lua_pop(L, 1);
    return value;
}

bool boolean_field(lua_State* L, int table, const char* name, bool fallback)
{
    lua_getfield(L, table, name);
    const bool value = lua_isnil(L, -1) ? fallback : lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    return value;
}

std::string string_field(lua_State* L, int table, const char* name, const char* fallback)
{
    lua_getfield(L, table, name);
    const char* value = lua_isnil(L, -1) ? fallback : luaL_checkstring(L, -1);
    std::string result = value ? value : "";
    lua_pop(L, 1);
    return result;
}

uint32_t color_field(lua_State* L, int table, const char* name, uint32_t fallback)
{
    lua_getfield(L, table, name);
    uint32_t value = fallback;
    if (!lua_isnil(L, -1)) value = check_color(L, -1);
    lua_pop(L, 1);
    return value;
}

int resource_destroy(lua_State* L, uint32_t type)
{
    auto* self = check_resource(L, 1, type, false);
    const uint32_t result = destroy_native(self);
    if (result != D3D_SDK_OK) return push_result_error(L, "resource destruction failed");
    lua_pushboolean(L, 1);
    return 1;
}

int resource_gc(lua_State* L, uint32_t type)
{
    auto* self = static_cast<ResourceUserdata*>(luaL_testudata(L, 1, meta_for_type(type)));
    if (self) destroy_native(self);
    return 0;
}

int resource_is_destroyed(lua_State* L, uint32_t type)
{
    auto* self = check_resource(L, 1, type, false);
    lua_pushboolean(L, !resource_alive(self));
    return 1;
}

int resource_tostring(lua_State* L, uint32_t type)
{
    auto* self = check_resource(L, 1, type, false);
    char buffer[128];
    std::snprintf(buffer, sizeof(buffer), "%s(handle=0x%08X, %s)",
        meta_for_type(type), self->handle, resource_alive(self) ? "alive" : "destroyed");
    lua_pushstring(L, buffer);
    return 1;
}

int font_destroy(lua_State* L) { return resource_destroy(L, D3D_SDK_RESOURCE_FONT); }
int font_gc(lua_State* L) { return resource_gc(L, D3D_SDK_RESOURCE_FONT); }
int font_is_destroyed(lua_State* L) { return resource_is_destroyed(L, D3D_SDK_RESOURCE_FONT); }
int font_tostring(lua_State* L) { return resource_tostring(L, D3D_SDK_RESOURCE_FONT); }

int text_destroy(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXT, false);
    const uint32_t result = destroy_native(self);
    if (result != D3D_SDK_OK) return push_result_error(L, "resource destruction failed");
    lua_pushnil(L);
    lua_setiuservalue(L, 1, 1);
    lua_pushboolean(L, 1);
    return 1;
}

int text_gc(lua_State* L)
{
    auto* self = static_cast<ResourceUserdata*>(
        luaL_testudata(L, 1, kTextMeta));
    if (self) {
        destroy_native(self);
        lua_pushnil(L);
        lua_setiuservalue(L, 1, 1);
    }
    return 0;
}
int text_is_destroyed(lua_State* L) { return resource_is_destroyed(L, D3D_SDK_RESOURCE_TEXT); }
int text_tostring(lua_State* L) { return resource_tostring(L, D3D_SDK_RESOURCE_TEXT); }

int texture_destroy(lua_State* L) { return resource_destroy(L, D3D_SDK_RESOURCE_TEXTURE); }
int texture_gc(lua_State* L) { return resource_gc(L, D3D_SDK_RESOURCE_TEXTURE); }
int texture_is_destroyed(lua_State* L) { return resource_is_destroyed(L, D3D_SDK_RESOURCE_TEXTURE); }
int texture_tostring(lua_State* L) { return resource_tostring(L, D3D_SDK_RESOURCE_TEXTURE); }

int font_new(lua_State* L)
{
    if (!initialize_api()) return push_unavailable(L);
    if (g_shutdown) return push_unavailable(L);
    luaL_checktype(L, 1, LUA_TTABLE);

    const int32_t height = integer_field(L, 1, "height", 16);
    const int32_t width = integer_field(L, 1, "width", 0);
    const int32_t weight = integer_field(L, 1, "weight", 400);
    const bool italic = boolean_field(L, 1, "italic", false);
    if (height <= 0 || width < 0 || weight < 0 || weight > 1000) {
        lua_pushnil(L);
        lua_pushliteral(L, "invalid Font dimensions or weight");
        return 2;
    }
    const std::string face = string_field(L, 1, "face", "Arial");

    uint32_t handle = 0;
    uint32_t result = g_api.create_font(g_session, &handle);
    if (result == D3D_SDK_OK) result = g_api.set_font_face(g_session, handle, face.c_str());
    if (result == D3D_SDK_OK) result = g_api.set_font_height(g_session, handle, height);
    if (result == D3D_SDK_OK) result = g_api.set_font_width(g_session, handle, width);
    if (result == D3D_SDK_OK) result = g_api.set_font_weight(g_session, handle, weight);
    if (result == D3D_SDK_OK) result = g_api.set_font_italic(g_session, handle, italic ? 1u : 0u);
    if (result != D3D_SDK_OK) {
        const std::string error = native_error("Font construction failed");
        if (handle) g_api.destroy_font(g_session, handle);
        lua_pushnil(L);
        lua_pushlstring(L, error.data(), error.size());
        return 2;
    }

    push_resource(L, D3D_SDK_RESOURCE_FONT, handle, 0);
    return 1;
}

int font_get_face(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_FONT);
    return push_resource_string(L, self, g_api.copy_font_face);
}

int font_set_face(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_FONT);
    if (g_api.set_font_face(self->session, self->handle, luaL_checkstring(L, 2))
        != D3D_SDK_OK) return raise_result_error(L);
    lua_pushboolean(L, 1);
    return 1;
}

#define LUA_INT_METHODS(prefix, sdk_get, sdk_set, type, minimum, maximum)          \
    int prefix##_get(lua_State* L)                                                  \
    {                                                                               \
        auto* self = check_resource(L, 1, type);                                    \
        int32_t value = 0;                                                          \
        if (g_api.sdk_get(self->session, self->handle, &value) != D3D_SDK_OK)       \
            return raise_result_error(L);                                           \
        lua_pushinteger(L, value);                                                  \
        return 1;                                                                   \
    }                                                                               \
    int prefix##_set(lua_State* L)                                                  \
    {                                                                               \
        auto* self = check_resource(L, 1, type);                                    \
        const int32_t value = check_int32(L, 2);                                    \
        if (value < (minimum) || value > (maximum))                                 \
            return luaL_argerror(L, 2, #prefix " is outside the supported range"); \
        if (g_api.sdk_set(self->session, self->handle, value) != D3D_SDK_OK)        \
            return raise_result_error(L);                                           \
        lua_pushboolean(L, 1);                                                      \
        return 1;                                                                   \
    }

LUA_INT_METHODS(font_height, get_font_height, set_font_height,
    D3D_SDK_RESOURCE_FONT, 1, kMaxInt32)
LUA_INT_METHODS(font_width, get_font_width, set_font_width,
    D3D_SDK_RESOURCE_FONT, 0, kMaxInt32)
LUA_INT_METHODS(font_weight, get_font_weight, set_font_weight,
    D3D_SDK_RESOURCE_FONT, 0, 1000)

int font_get_italic(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_FONT);
    uint32_t value = 0;
    if (g_api.get_font_italic(self->session, self->handle, &value) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushboolean(L, value != 0);
    return 1;
}

int font_set_italic(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_FONT);
    if (g_api.set_font_italic(self->session, self->handle, lua_toboolean(L, 2) ? 1u : 0u)
        != D3D_SDK_OK) return raise_result_error(L);
    lua_pushboolean(L, 1);
    return 1;
}

int text_new(lua_State* L)
{
    if (!initialize_api()) return push_unavailable(L);
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "font");
    auto* font = check_resource(L, -1, D3D_SDK_RESOURCE_FONT);
    const int font_index = lua_gettop(L);

    const float x = static_cast<float>(number_field(L, 1, "x", 0.0));
    const float y = static_cast<float>(number_field(L, 1, "y", 0.0));
    lua_getfield(L, 1, "ttl");
    const float ttl = lua_isnil(L, -1) ? -1.0f : static_cast<float>(luaL_checknumber(L, -1));
    lua_pop(L, 1);
    const uint32_t color = color_field(L, 1, "color", 0xFFFFFFFFu);
    const bool visible = boolean_field(L, 1, "visible", true);
    const int32_t level = integer_field(L, 1, "z", 0);
    const std::string text = string_field(L, 1, "text", "");

    uint32_t handle = 0;
    uint32_t result = g_api.create_text(
        g_session, font->handle, text.c_str(), x, y, ttl, color, &handle);
    if (result == D3D_SDK_OK) result = g_api.set_text_visible(
        g_session, handle, visible ? 1u : 0u);
    if (result == D3D_SDK_OK) result = g_api.set_text_level(g_session, handle, level);
    if (result != D3D_SDK_OK) {
        const std::string error = native_error("Text construction failed");
        if (handle) g_api.destroy_text(g_session, handle);
        lua_pushnil(L);
        lua_pushlstring(L, error.data(), error.size());
        return 2;
    }

    push_resource(L, D3D_SDK_RESOURCE_TEXT, handle, 1);
    lua_pushvalue(L, font_index);
    lua_setiuservalue(L, -2, 1);
    lua_remove(L, font_index);
    return 1;
}

int text_get_text(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXT);
    return push_resource_string(L, self, g_api.copy_text_string);
}

int text_set_text(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXT);
    if (g_api.set_text_string(self->session, self->handle, luaL_checkstring(L, 2))
        != D3D_SDK_OK) return raise_result_error(L);
    lua_pushboolean(L, 1);
    return 1;
}

int text_get_position(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXT);
    float x = 0.0f, y = 0.0f;
    if (g_api.get_text_position(self->session, self->handle, &x, &y) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushnumber(L, x);
    lua_pushnumber(L, y);
    return 2;
}

int text_set_position(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXT);
    if (g_api.set_text_position(self->session, self->handle,
        static_cast<float>(luaL_checknumber(L, 2)),
        static_cast<float>(luaL_checknumber(L, 3))) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushboolean(L, 1);
    return 1;
}

int text_get_ttl(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXT);
    float value = -1.0f;
    if (g_api.get_text_ttl(self->session, self->handle, &value) != D3D_SDK_OK)
        return raise_result_error(L);
    if (value < 0.0f) lua_pushnil(L); else lua_pushnumber(L, value);
    return 1;
}

int text_set_ttl(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXT);
    const float value = lua_isnil(L, 2) ? -1.0f : static_cast<float>(luaL_checknumber(L, 2));
    if (g_api.set_text_ttl(self->session, self->handle, value) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushboolean(L, 1);
    return 1;
}

#define LUA_UINT_METHODS(prefix, sdk_get, sdk_set, type, push_expr, read_expr)      \
    int prefix##_get(lua_State* L)                                                  \
    {                                                                               \
        auto* self = check_resource(L, 1, type);                                    \
        uint32_t value = 0;                                                         \
        if (g_api.sdk_get(self->session, self->handle, &value) != D3D_SDK_OK)       \
            return raise_result_error(L);                                           \
        push_expr;                                                                  \
        return 1;                                                                   \
    }                                                                               \
    int prefix##_set(lua_State* L)                                                  \
    {                                                                               \
        auto* self = check_resource(L, 1, type);                                    \
        const uint32_t value = (read_expr);                                         \
        if (g_api.sdk_set(self->session, self->handle, value) != D3D_SDK_OK)        \
            return raise_result_error(L);                                           \
        lua_pushboolean(L, 1);                                                      \
        return 1;                                                                   \
    }

LUA_UINT_METHODS(text_color, get_text_color, set_text_color, D3D_SDK_RESOURCE_TEXT,
    lua_pushinteger(L, static_cast<lua_Integer>(value)), check_color(L, 2))
LUA_UINT_METHODS(text_visible, get_text_visible, set_text_visible, D3D_SDK_RESOURCE_TEXT,
    lua_pushboolean(L, value != 0), lua_toboolean(L, 2) ? 1u : 0u)
LUA_INT_METHODS(text_level, get_text_level, set_text_level,
    D3D_SDK_RESOURCE_TEXT, kMinInt32, kMaxInt32)

int text_get_font(lua_State* L)
{
    check_resource(L, 1, D3D_SDK_RESOURCE_TEXT);
    if (lua_getiuservalue(L, 1, 1) != LUA_TUSERDATA) {
        lua_pop(L, 1);
        lua_pushnil(L);
    }
    return 1;
}

int text_set_font(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXT);
    auto* font = check_resource(L, 2, D3D_SDK_RESOURCE_FONT);
    if (g_api.set_text_font(self->session, self->handle, font->handle) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushvalue(L, 2);
    lua_setiuservalue(L, 1, 1);
    lua_pushboolean(L, 1);
    return 1;
}

int text_is_alive(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXT, false);
    lua_pushboolean(L, resource_alive(self));
    return 1;
}

int texture_new(lua_State* L)
{
    if (!initialize_api()) return push_unavailable(L);
    luaL_checktype(L, 1, LUA_TTABLE);
    const float x = static_cast<float>(number_field(L, 1, "x", 0.0));
    const float y = static_cast<float>(number_field(L, 1, "y", 0.0));
    const float width = static_cast<float>(number_field(L, 1, "width", 0.0));
    const float height = static_cast<float>(number_field(L, 1, "height", 0.0));
    const uint32_t color = color_field(L, 1, "color", 0xFFFFFFFFu);
    const float rotation = static_cast<float>(number_field(L, 1, "rotation", 0.0));
    const int32_t level = integer_field(L, 1, "z", 0);
    const bool visible = boolean_field(L, 1, "visible", true);
    const bool hit_test = boolean_field(L, 1, "hit_test", true);
    const std::string source = string_field(L, 1, "source", "");

    uint32_t handle = 0;
    uint32_t result = g_api.create_texture(g_session, source.c_str(), x, y,
        width, height, color, level, &handle);
    if (result == D3D_SDK_OK) result = g_api.set_texture_rotation(
        g_session, handle, rotation);
    if (result == D3D_SDK_OK) result = g_api.set_texture_visible(
        g_session, handle, visible ? 1u : 0u);
    if (result == D3D_SDK_OK) result = g_api.set_texture_hit_test(
        g_session, handle, hit_test ? 1u : 0u);
    if (result != D3D_SDK_OK) {
        const std::string error = native_error("Texture construction failed");
        if (handle) g_api.destroy_texture(g_session, handle);
        lua_pushnil(L);
        lua_pushlstring(L, error.data(), error.size());
        return 2;
    }
    push_resource(L, D3D_SDK_RESOURCE_TEXTURE, handle, 0);
    return 1;
}

int texture_get_source(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    return push_resource_string(L, self, g_api.copy_texture_source);
}

int texture_set_source(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    if (g_api.set_texture_source(self->session, self->handle, luaL_checkstring(L, 2))
        != D3D_SDK_OK) return raise_result_error(L);
    lua_pushboolean(L, 1);
    return 1;
}

int texture_get_rect(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    float x = 0, y = 0, width = 0, height = 0;
    if (g_api.get_texture_rect(self->session, self->handle,
        &x, &y, &width, &height) != D3D_SDK_OK) return raise_result_error(L);
    lua_pushnumber(L, x); lua_pushnumber(L, y);
    lua_pushnumber(L, width); lua_pushnumber(L, height);
    return 4;
}

int texture_set_rect(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    if (g_api.set_texture_rect(self->session, self->handle,
        static_cast<float>(luaL_checknumber(L, 2)),
        static_cast<float>(luaL_checknumber(L, 3)),
        static_cast<float>(luaL_checknumber(L, 4)),
        static_cast<float>(luaL_checknumber(L, 5))) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushboolean(L, 1);
    return 1;
}

int texture_get_source_rect(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    float left = 0, top = 0, right = 0, bottom = 0;
    if (g_api.get_texture_src_rect(self->session, self->handle,
        &left, &top, &right, &bottom) != D3D_SDK_OK) return raise_result_error(L);
    lua_pushnumber(L, left); lua_pushnumber(L, top);
    lua_pushnumber(L, right); lua_pushnumber(L, bottom);
    return 4;
}

int texture_set_source_rect(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    if (g_api.set_texture_src_rect(self->session, self->handle,
        static_cast<float>(luaL_checknumber(L, 2)),
        static_cast<float>(luaL_checknumber(L, 3)),
        static_cast<float>(luaL_checknumber(L, 4)),
        static_cast<float>(luaL_checknumber(L, 5))) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushboolean(L, 1);
    return 1;
}

LUA_UINT_METHODS(texture_color, get_texture_color, set_texture_color,
    D3D_SDK_RESOURCE_TEXTURE, lua_pushinteger(L, static_cast<lua_Integer>(value)), check_color(L, 2))
LUA_INT_METHODS(texture_level, get_texture_level, set_texture_level,
    D3D_SDK_RESOURCE_TEXTURE, kMinInt32, kMaxInt32)
LUA_UINT_METHODS(texture_visible, get_texture_visible, set_texture_visible,
    D3D_SDK_RESOURCE_TEXTURE, lua_pushboolean(L, value != 0), lua_toboolean(L, 2) ? 1u : 0u)
LUA_UINT_METHODS(texture_hit_test, get_texture_hit_test, set_texture_hit_test,
    D3D_SDK_RESOURCE_TEXTURE, lua_pushboolean(L, value != 0), lua_toboolean(L, 2) ? 1u : 0u)

int texture_get_rotation(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    float value = 0.0f;
    if (g_api.get_texture_rotation(self->session, self->handle, &value) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushnumber(L, value);
    return 1;
}

int texture_set_rotation(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    if (g_api.set_texture_rotation(self->session, self->handle,
        static_cast<float>(luaL_checknumber(L, 2))) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushboolean(L, 1);
    return 1;
}

int texture_pixel_size(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    float width = 0.0f, height = 0.0f;
    if (g_api.get_texture_pixel_size(self->session, self->handle,
        &width, &height) != D3D_SDK_OK) return raise_result_error(L);
    lua_pushnumber(L, width);
    lua_pushnumber(L, height);
    return 2;
}

int texture_contains(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    uint32_t contains = 0;
    if (g_api.texture_contains(self->session, self->handle,
        static_cast<float>(luaL_checknumber(L, 2)),
        static_cast<float>(luaL_checknumber(L, 3)), &contains) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushboolean(L, contains != 0);
    return 1;
}

int module_is_available(lua_State* L)
{
    lua_pushboolean(L, initialize_api() && !g_shutdown);
    return 1;
}

int module_version(lua_State* L)
{
    lua_pushstring(L, kVersion);
    return 1;
}

int module_abi_version(lua_State* L)
{
    lua_pushinteger(L, g_api_ready ? g_api.abi_version : 0);
    return 1;
}

int module_capabilities(lua_State* L)
{
    initialize_api();
    lua_newtable(L);
    const auto set = [L](const char* name, bool value) {
        lua_pushboolean(L, value);
        lua_setfield(L, -2, name);
    };
    set("session", (g_api.capabilities & D3D_SDK_CAP_SESSION) != 0);
    set("generation_handles", (g_api.capabilities & D3D_SDK_CAP_GENERATION_HANDLES) != 0);
    set("resource_counts", (g_api.capabilities & D3D_SDK_CAP_RESOURCE_COUNTS) != 0);
    set("core_properties", (g_api.capabilities & D3D_SDK_CAP_CORE_PROPERTIES) != 0);
    set("text_alpha", (g_api.capabilities & D3D_SDK_CAP_TEXT_ALPHA) != 0);
    set("unified_render_queue",
        (g_api.capabilities & D3D_SDK_CAP_UNIFIED_RENDER_QUEUE) != 0);
    return 1;
}

int module_stats(lua_State* L)
{
    if (!initialize_api()) return push_unavailable(L);
    D3DSdkResourceCountsV1 counts{};
    counts.struct_size = sizeof(counts);
    if (g_api.get_resource_counts(g_session, &counts) != D3D_SDK_OK)
        return push_result_error(L);
    lua_newtable(L);
    lua_pushinteger(L, counts.session_id); lua_setfield(L, -2, "session_id");
    lua_pushinteger(L, counts.font_count); lua_setfield(L, -2, "fonts");
    lua_pushinteger(L, counts.text_count); lua_setfield(L, -2, "texts");
    lua_pushinteger(L, counts.texture_count); lua_setfield(L, -2, "textures");
    lua_pushboolean(L, counts.device_ready != 0); lua_setfield(L, -2, "device_ready");
    return 1;
}

int module_status(lua_State* L)
{
    const bool available = initialize_api() && !g_shutdown;
    lua_newtable(L);
    lua_pushboolean(L, available); lua_setfield(L, -2, "available");
    lua_pushboolean(L, g_shutdown); lua_setfield(L, -2, "shutdown");
    lua_pushinteger(L, g_session); lua_setfield(L, -2, "session_id");
    lua_pushlstring(L, g_init_error.data(), g_init_error.size()); lua_setfield(L, -2, "error");
    if (available) {
        D3DSdkResourceCountsV1 counts{};
        counts.struct_size = sizeof(counts);
        if (g_api.get_resource_counts(g_session, &counts) == D3D_SDK_OK) {
            lua_pushboolean(L, counts.device_ready != 0);
            lua_setfield(L, -2, "device_ready");
        }
    }
    return 1;
}

int module_window_size(lua_State* L)
{
    if (!initialize_api()) return push_unavailable(L);
    int32_t width = 0, height = 0;
    if (g_api.get_window_size(g_session, &width, &height) != D3D_SDK_OK)
        return push_result_error(L);
    lua_pushinteger(L, width);
    lua_pushinteger(L, height);
    return 2;
}

int module_rgba(lua_State* L)
{
    const lua_Integer r = luaL_checkinteger(L, 1);
    const lua_Integer g = luaL_checkinteger(L, 2);
    const lua_Integer b = luaL_checkinteger(L, 3);
    const lua_Integer a = luaL_optinteger(L, 4, 255);
    if (r < 0 || r > 255 || g < 0 || g > 255
        || b < 0 || b > 255 || a < 0 || a > 255) {
        return luaL_error(L, "rgba channels must be between 0 and 255");
    }
    const uint32_t color = (static_cast<uint32_t>(a) << 24)
        | (static_cast<uint32_t>(r) << 16)
        | (static_cast<uint32_t>(g) << 8)
        | static_cast<uint32_t>(b);
    lua_pushinteger(L, static_cast<lua_Integer>(color));
    return 1;
}

int module_shutdown(lua_State* L)
{
    if (g_shutdown || !g_api_ready || g_session == 0) {
        g_shutdown = true;
        g_init_error = "D3D session has been shut down";
        lua_pushboolean(L, 1);
        return 1;
    }
    const uint32_t result = g_api.end_session(g_session);
    if (result != D3D_SDK_OK && result != D3D_SDK_NO_ACTIVE_SESSION
        && result != D3D_SDK_STALE_SESSION) return push_result_error(L, "D3D shutdown failed");
    g_session = 0;
    g_shutdown = true;
    g_init_error = "D3D session has been shut down";
    lua_pushboolean(L, 1);
    return 1;
}

int context_gc(lua_State* L)
{
    auto* context = static_cast<ContextUserdata*>(luaL_testudata(L, 1, kContextMeta));
    if (context && context->owner && g_api_ready && g_session != 0) {
        g_api.end_session(g_session);
    }
    g_api = {};
    g_api_checked = false;
    g_api_ready = false;
    g_shutdown = false;
    g_session = 0;
    g_init_error.clear();
    return 0;
}

void make_metatable(lua_State* L, const char* name,
                    const luaL_Reg* metamethods, const luaL_Reg* methods)
{
    luaL_newmetatable(L, name);
    luaL_setfuncs(L, metamethods, 0);
    lua_newtable(L);
    luaL_setfuncs(L, methods, 0);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
}

void push_class(lua_State* L, lua_CFunction constructor)
{
    lua_newtable(L);
    lua_pushcfunction(L, constructor);
    lua_setfield(L, -2, "new");
}

}  // namespace

int open(lua_State* L)
{
    static const luaL_Reg font_meta[] = {
        {"__gc", font_gc}, {"__close", font_gc}, {"__tostring", font_tostring},
        {nullptr, nullptr},
    };
    static const luaL_Reg font_methods[] = {
        {"get_face", font_get_face}, {"set_face", font_set_face},
        {"get_height", font_height_get}, {"set_height", font_height_set},
        {"get_width", font_width_get}, {"set_width", font_width_set},
        {"get_weight", font_weight_get}, {"set_weight", font_weight_set},
        {"get_italic", font_get_italic}, {"set_italic", font_set_italic},
        {"is_destroyed", font_is_destroyed}, {"destroy", font_destroy},
        {nullptr, nullptr},
    };
    static const luaL_Reg text_meta[] = {
        {"__gc", text_gc}, {"__close", text_gc}, {"__tostring", text_tostring},
        {nullptr, nullptr},
    };
    static const luaL_Reg text_methods[] = {
        {"get_text", text_get_text}, {"set_text", text_set_text},
        {"get_position", text_get_position}, {"set_position", text_set_position},
        {"get_ttl", text_get_ttl}, {"set_ttl", text_set_ttl},
        {"get_color", text_color_get}, {"set_color", text_color_set},
        {"get_visible", text_visible_get}, {"set_visible", text_visible_set},
        {"get_z", text_level_get}, {"set_z", text_level_set},
        {"get_font", text_get_font}, {"set_font", text_set_font},
        {"is_alive", text_is_alive}, {"is_destroyed", text_is_destroyed},
        {"destroy", text_destroy},
        {nullptr, nullptr},
    };
    static const luaL_Reg texture_meta[] = {
        {"__gc", texture_gc}, {"__close", texture_gc}, {"__tostring", texture_tostring},
        {nullptr, nullptr},
    };
    static const luaL_Reg texture_methods[] = {
        {"get_source", texture_get_source}, {"set_source", texture_set_source},
        {"get_rect", texture_get_rect}, {"set_rect", texture_set_rect},
        {"get_source_rect", texture_get_source_rect}, {"set_source_rect", texture_set_source_rect},
        {"get_color", texture_color_get}, {"set_color", texture_color_set},
        {"get_rotation", texture_get_rotation}, {"set_rotation", texture_set_rotation},
        {"get_z", texture_level_get}, {"set_z", texture_level_set},
        {"get_visible", texture_visible_get}, {"set_visible", texture_visible_set},
        {"get_hit_test", texture_hit_test_get}, {"set_hit_test", texture_hit_test_set},
        {"pixel_size", texture_pixel_size}, {"contains", texture_contains},
        {"is_destroyed", texture_is_destroyed}, {"destroy", texture_destroy},
        {nullptr, nullptr},
    };
    static const luaL_Reg context_meta[] = {
        {"__gc", context_gc}, {nullptr, nullptr},
    };

    make_metatable(L, kFontMeta, font_meta, font_methods);
    make_metatable(L, kTextMeta, text_meta, text_methods);
    make_metatable(L, kTextureMeta, texture_meta, texture_methods);
    luaL_newmetatable(L, kContextMeta);
    luaL_setfuncs(L, context_meta, 0);
    lua_pop(L, 1);

    initialize_api();
    lua_pushlightuserdata(L, &g_context_registry_key);
    lua_rawget(L, LUA_REGISTRYINDEX);
    const bool has_context = luaL_testudata(L, -1, kContextMeta) != nullptr;
    lua_pop(L, 1);
    if (!has_context) {
        lua_pushlightuserdata(L, &g_context_registry_key);
        auto* context = static_cast<ContextUserdata*>(
            lua_newuserdatauv(L, sizeof(ContextUserdata), 0));
        new (context) ContextUserdata();
        context->owner = g_api_ready;
        luaL_setmetatable(L, kContextMeta);
        lua_rawset(L, LUA_REGISTRYINDEX);
    }

    lua_newtable(L);
    static const luaL_Reg module_functions[] = {
        {"is_available", module_is_available},
        {"version", module_version},
        {"abi_version", module_abi_version},
        {"capabilities", module_capabilities},
        {"status", module_status},
        {"stats", module_stats},
        {"window_size", module_window_size},
        {"rgba", module_rgba},
        {"shutdown", module_shutdown},
        {nullptr, nullptr},
    };
    luaL_setfuncs(L, module_functions, 0);
    push_class(L, font_new); lua_setfield(L, -2, "Font");
    push_class(L, text_new); lua_setfield(L, -2, "Text");
    push_class(L, texture_new); lua_setfield(L, -2, "Texture");
    return 1;
}

#undef LUA_INT_METHODS
#undef LUA_UINT_METHODS

}  // namespace warcraft3::lua_engine::d3d

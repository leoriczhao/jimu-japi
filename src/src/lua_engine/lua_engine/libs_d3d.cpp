#include "../../d3d9/sdk_api.h"
#include "callback.h"
#include "common.h"
#include "debug_log.h"
#include "libs_d3d.h"
#include "libs_message.h"
#include "storm.h"

#include <lua.hpp>
#include <warcraft3/keyboard_code.h>
#include <windows.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace warcraft3::lua_engine::d3d {

namespace {

constexpr const char* kFontMeta = "jass.d3d.Font";
constexpr const char* kTextMeta = "jass.d3d.Text";
constexpr const char* kTextureMeta = "jass.d3d.Texture";
constexpr const char* kSubscriptionMeta = "jass.d3d.Subscription";
constexpr const char* kContextMeta = "jass.d3d.Context";
constexpr const char* kVersion = "0.3.0-dev";
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

enum class SubscriptionEvent : uint32_t {
    Enter,
    Leave,
    MouseDown,
    MouseUp,
    Click,
    KeyDown,
    KeyUp,
    // Module-level lifecycle events (d3d.on); they have no Texture target.
    Resize,
    DeviceLost,
    DeviceReset,
};

struct SubscriptionUserdata {
    uint32_t session = 0;
    uint32_t id = 0;
    bool active = false;
};

struct SubscriptionEntry {
    uint32_t id = 0;
    uint32_t session = 0;
    uint32_t texture = 0;
    SubscriptionEvent event = SubscriptionEvent::Enter;
    int32_t filter_code = -1;
    bool propagate = false;
    bool hover_only = true;
    bool keep_on_error = false;
};

struct PendingInputEvent {
    InputKind kind = InputKind::KeyDown;
    int32_t code = 0;
    float x = 0.0f;
    float y = 0.0f;
    double timestamp = 0.0;
};

struct PointerCapture {
    uint32_t texture = 0;
    float down_x = 0.0f;
    float down_y = 0.0f;
};

D3DSdkApiV1 g_api{};
bool g_api_checked = false;
bool g_api_ready = false;
bool g_shutdown = false;
uint32_t g_session = 0;
std::string g_init_error;
char g_context_registry_key = 0;
char g_subscription_registry_key = 0;
std::map<uint32_t, SubscriptionEntry> g_subscriptions;
std::deque<PendingInputEvent> g_pending_input;
std::vector<uint32_t> g_hover_stack;
std::map<int32_t, PointerCapture> g_pointer_capture;
uint32_t g_next_subscription_id = 1;
uint32_t g_event_timer = 0;
uint32_t g_event_code = 0;
bool g_event_dispatching = false;
// Lifecycle baseline for d3d.on: the first poll of a session only records the
// current state, so subscribing never reports historical resets as new ones.
bool g_lifecycle_known = false;
bool g_lifecycle_device_ready = false;
uint32_t g_lifecycle_generation = 0;
int32_t g_lifecycle_width = 0;
int32_t g_lifecycle_height = 0;
constexpr size_t kMaxPendingInput = 256;
constexpr float kClickMoveThreshold = 6.0f;

void cancel_texture_subscriptions(lua_State* L, uint32_t session, uint32_t texture);
void cancel_all_subscriptions(lua_State* L);
void cancel_subscription_by_id(lua_State* L, uint32_t id, int index = 0);
bool push_subscription_userdata(lua_State* L, uint32_t id);
void dispatch_leave_before_disable(lua_State* L, uint32_t texture);
void texture_local_coordinates(
    uint32_t texture, float x, float y, float* out_x, float* out_y);

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
        | D3D_SDK_CAP_CORE_PROPERTIES
        | D3D_SDK_CAP_ASSET_MEMORY
        | D3D_SDK_CAP_INPUT_HIT_STACK;
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
        || !g_api.get_texture_pixel_size || !g_api.texture_contains
        || !g_api.create_texture_from_memory || !g_api.set_texture_source_memory
        || !g_api.get_texture_hit_stack) {
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

struct AssetPayload {
    std::string canonical_uri;
    std::vector<uint8_t> bytes;
};

constexpr size_t kMaxAssetBytes = 64u * 1024u * 1024u;

std::string lower_ascii(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

bool normalize_asset_uri(
    const std::string& input, std::string* canonical,
    std::string* storm_path, uint32_t* search_scope, std::string* error)
{
    if (!canonical || !storm_path || !search_scope || !error) return false;
    if (input.empty() || input.size() > 4096 || input.find('\0') != std::string::npos) {
        *error = "D3D asset URI rejected: asset URI is empty or invalid";
        return false;
    }

    std::string scheme = "asset";
    std::string path = input;
    const size_t scheme_end = input.find("://");
    if (scheme_end != std::string::npos) {
        scheme = lower_ascii(input.substr(0, scheme_end));
        path = input.substr(scheme_end + 3u);
        if (scheme == "file") {
            *error = "D3D asset URI rejected: file:// is disabled";
            return false;
        }
        if (scheme != "asset" && scheme != "game") {
            *error = "D3D asset URI rejected: unsupported URI scheme";
            return false;
        }
    }

    std::replace(path.begin(), path.end(), '\\', '/');
    const std::string rejected_uri = scheme + "://" + path;
    if (path.empty() || path.front() == '/'
        || (path.size() >= 2 && std::isalpha(static_cast<unsigned char>(path[0]))
            && path[1] == ':')
        || path.find(':') != std::string::npos) {
        *error = "D3D asset URI rejected: " + rejected_uri;
        return false;
    }

    std::vector<std::string> segments;
    size_t begin = 0;
    while (begin <= path.size()) {
        const size_t end = path.find('/', begin);
        const std::string segment = path.substr(
            begin, end == std::string::npos ? std::string::npos : end - begin);
        if (segment == "..") {
            *error = "D3D asset URI rejected: " + rejected_uri;
            return false;
        }
        if (!segment.empty() && segment != ".") segments.push_back(segment);
        if (end == std::string::npos) break;
        begin = end + 1u;
    }
    if (segments.empty()) {
        *error = "D3D asset URI rejected: " + rejected_uri;
        return false;
    }

    std::string normalized;
    for (size_t i = 0; i < segments.size(); ++i) {
        if (i) normalized.push_back('/');
        normalized += segments[i];
    }
    *canonical = scheme + "://" + normalized;
    *storm_path = normalized;
    std::replace(storm_path->begin(), storm_path->end(), '/', '\\');
    *search_scope = scheme == "asset" ? 1u : 0u;
    return true;
}

bool load_asset(const std::string& uri, AssetPayload* payload, std::string* error)
{
    if (!payload || !error) return false;
    std::string storm_path;
    uint32_t search_scope = 0;
    if (!normalize_asset_uri(uri, &payload->canonical_uri,
        &storm_path, &search_scope, error)) return false;

    auto& storm = warcraft3::storm_s::instance();
    if (!storm.valid()) {
        *error = "D3D asset loader unavailable: " + payload->canonical_uri;
        return false;
    }
    const void* buffer = nullptr;
    size_t size = 0;
    if (!storm.load_file(nullptr, storm_path.c_str(), &buffer, &size,
        0, search_scope, nullptr) || !buffer) {
        *error = "D3D asset not found: " + payload->canonical_uri;
        return false;
    }

    bool ok = false;
    if (size == 0 || size > kMaxAssetBytes) {
        *error = "D3D asset size rejected: " + payload->canonical_uri;
    } else {
        try {
            const auto* bytes = static_cast<const uint8_t*>(buffer);
            payload->bytes.assign(bytes, bytes + size);
            ok = true;
        } catch (...) {
            *error = "D3D asset allocation failed: " + payload->canonical_uri;
        }
    }
    storm.unload_file(buffer);
    return ok;
}

std::string source_field(lua_State* L, int table)
{
    lua_getfield(L, table, "source");
    size_t length = 0;
    const char* value = luaL_checklstring(L, -1, &length);
    std::string result(value, length);
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

int texture_destroy(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE, false);
    if (resource_alive(self)) dispatch_leave_before_disable(L, self->handle);
    cancel_texture_subscriptions(L, self->session, self->handle);
    const uint32_t result = destroy_native(self);
    if (result != D3D_SDK_OK) return push_result_error(L, "resource destruction failed");
    lua_pushboolean(L, 1);
    return 1;
}

int texture_gc(lua_State* L)
{
    auto* self = static_cast<ResourceUserdata*>(luaL_testudata(L, 1, kTextureMeta));
    if (self) {
        cancel_texture_subscriptions(L, self->session, self->handle);
        destroy_native(self);
    }
    return 0;
}

int texture_is_destroyed(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE, false);
    const bool destroyed = !resource_alive(self);
    if (destroyed) cancel_texture_subscriptions(L, self->session, self->handle);
    lua_pushboolean(L, destroyed);
    return 1;
}
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
    const std::string source = source_field(L, 1);
    AssetPayload asset;
    std::string asset_error;
    if (!load_asset(source, &asset, &asset_error)) {
        lua_pushnil(L);
        lua_pushlstring(L, asset_error.data(), asset_error.size());
        return 2;
    }

    uint32_t handle = 0;
    uint32_t result = g_api.create_texture_from_memory(
        g_session, asset.canonical_uri.c_str(), asset.bytes.data(),
        static_cast<uint32_t>(asset.bytes.size()), x, y,
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
    size_t length = 0;
    const char* source = luaL_checklstring(L, 2, &length);
    AssetPayload asset;
    std::string asset_error;
    if (!load_asset(std::string(source, length), &asset, &asset_error)) {
        lua_pushnil(L);
        lua_pushlstring(L, asset_error.data(), asset_error.size());
        return 2;
    }
    if (g_api.set_texture_source_memory(
        self->session, self->handle, asset.canonical_uri.c_str(),
        asset.bytes.data(), static_cast<uint32_t>(asset.bytes.size())) != D3D_SDK_OK) {
        return push_result_error(L, "texture asset update failed");
    }
    lua_pushboolean(L, 1);
    return 1;
}

bool copy_texture_source_value(ResourceUserdata* self, std::string* out)
{
    if (!self || !out) return false;
    uint32_t required = 0;
    if (g_api.copy_texture_source(
        self->session, self->handle, nullptr, 0, &required) != D3D_SDK_OK
        || required == 0) return false;
    std::vector<char> buffer(required);
    if (g_api.copy_texture_source(self->session, self->handle,
        buffer.data(), required, &required) != D3D_SDK_OK) return false;
    out->assign(buffer.data());
    return true;
}

int texture_reload(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    std::string source;
    if (!copy_texture_source_value(self, &source)) {
        return push_result_error(L, "unable to read texture source");
    }
    AssetPayload asset;
    std::string asset_error;
    if (!load_asset(source, &asset, &asset_error)) {
        lua_pushnil(L);
        lua_pushlstring(L, asset_error.data(), asset_error.size());
        return 2;
    }
    if (g_api.set_texture_source_memory(
        self->session, self->handle, asset.canonical_uri.c_str(),
        asset.bytes.data(), static_cast<uint32_t>(asset.bytes.size())) != D3D_SDK_OK) {
        return push_result_error(L, "texture reload failed");
    }
    lua_pushboolean(L, 1);
    return 1;
}

int texture_state(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    D3DSdkResourceCountsV1 counts{};
    counts.struct_size = sizeof(counts);
    if (g_api.get_resource_counts(self->session, &counts) != D3D_SDK_OK) {
        return raise_result_error(L);
    }
    lua_pushstring(L, counts.device_ready ? "ready" : "lost");
    return 1;
}

int texture_error(lua_State* L)
{
    check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    lua_pushnil(L);
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

int texture_visible_get(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    uint32_t value = 0;
    if (g_api.get_texture_visible(self->session, self->handle, &value) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushboolean(L, value != 0);
    return 1;
}

int texture_visible_set(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    const bool value = lua_toboolean(L, 2) != 0;
    if (g_api.set_texture_visible(self->session, self->handle, value ? 1u : 0u)
        != D3D_SDK_OK) return raise_result_error(L);
    if (!value) dispatch_leave_before_disable(L, self->handle);
    lua_pushboolean(L, 1);
    return 1;
}

int texture_hit_test_get(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    uint32_t value = 0;
    if (g_api.get_texture_hit_test(self->session, self->handle, &value) != D3D_SDK_OK)
        return raise_result_error(L);
    lua_pushboolean(L, value != 0);
    return 1;
}

int texture_hit_test_set(lua_State* L)
{
    auto* self = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    const bool value = lua_toboolean(L, 2) != 0;
    if (g_api.set_texture_hit_test(self->session, self->handle, value ? 1u : 0u)
        != D3D_SDK_OK) return raise_result_error(L);
    if (!value) dispatch_leave_before_disable(L, self->handle);
    lua_pushboolean(L, 1);
    return 1;
}

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

const char* subscription_event_name(SubscriptionEvent event)
{
    switch (event) {
    case SubscriptionEvent::Enter: return "enter";
    case SubscriptionEvent::Leave: return "leave";
    case SubscriptionEvent::MouseDown: return "mouse_down";
    case SubscriptionEvent::MouseUp: return "mouse_up";
    case SubscriptionEvent::Click: return "click";
    case SubscriptionEvent::KeyDown: return "key_down";
    case SubscriptionEvent::KeyUp: return "key_up";
    case SubscriptionEvent::Resize: return "resize";
    case SubscriptionEvent::DeviceLost: return "device_lost";
    case SubscriptionEvent::DeviceReset: return "device_reset";
    }
    return "unknown";
}

bool parse_subscription_event(const char* name, SubscriptionEvent* event)
{
    if (!name || !event) return false;
    if (std::strcmp(name, "enter") == 0) *event = SubscriptionEvent::Enter;
    else if (std::strcmp(name, "leave") == 0) *event = SubscriptionEvent::Leave;
    else if (std::strcmp(name, "mouse_down") == 0) *event = SubscriptionEvent::MouseDown;
    else if (std::strcmp(name, "mouse_up") == 0) *event = SubscriptionEvent::MouseUp;
    else if (std::strcmp(name, "click") == 0) *event = SubscriptionEvent::Click;
    else if (std::strcmp(name, "key_down") == 0) *event = SubscriptionEvent::KeyDown;
    else if (std::strcmp(name, "key_up") == 0) *event = SubscriptionEvent::KeyUp;
    else return false;
    return true;
}

bool parse_module_event(const char* name, SubscriptionEvent* event)
{
    if (!name || !event) return false;
    if (std::strcmp(name, "resize") == 0) *event = SubscriptionEvent::Resize;
    else if (std::strcmp(name, "device_lost") == 0) *event = SubscriptionEvent::DeviceLost;
    else if (std::strcmp(name, "device_reset") == 0) *event = SubscriptionEvent::DeviceReset;
    else return false;
    return true;
}

bool is_module_event(SubscriptionEvent event)
{
    return event == SubscriptionEvent::Resize
        || event == SubscriptionEvent::DeviceLost
        || event == SubscriptionEvent::DeviceReset;
}

bool is_mouse_event(SubscriptionEvent event)
{
    return event == SubscriptionEvent::MouseDown
        || event == SubscriptionEvent::MouseUp
        || event == SubscriptionEvent::Click;
}

bool is_key_event(SubscriptionEvent event)
{
    return event == SubscriptionEvent::KeyDown || event == SubscriptionEvent::KeyUp;
}

double event_timestamp()
{
    return static_cast<double>(GetTickCount64()) / 1000.0;
}

int readonly_event_newindex(lua_State* L)
{
    return luaL_error(L, "D3D event tables are read-only");
}

int readonly_event_next(lua_State* L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_settop(L, 2);
    lua_pushvalue(L, 2);
    return lua_next(L, 1) ? 2 : 0;
}

int readonly_event_pairs(lua_State* L)
{
    lua_pushcfunction(L, readonly_event_next);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_pushnil(L);
    return 3;
}

void push_readonly_event(lua_State* L, const SubscriptionEntry& entry,
    SubscriptionEvent event, int32_t code, float x, float y, double timestamp,
    int target_index)
{
    target_index = lua_absindex(L, target_index);
    float local_x = x;
    float local_y = y;
    texture_local_coordinates(entry.texture, x, y, &local_x, &local_y);

    lua_newtable(L);
    const int values_index = lua_gettop(L);
    lua_pushstring(L, subscription_event_name(event)); lua_setfield(L, values_index, "type");
    lua_pushvalue(L, target_index); lua_setfield(L, values_index, "target");
    lua_pushnumber(L, x); lua_setfield(L, values_index, "x");
    lua_pushnumber(L, y); lua_setfield(L, values_index, "y");
    lua_pushnumber(L, local_x); lua_setfield(L, values_index, "local_x");
    lua_pushnumber(L, local_y); lua_setfield(L, values_index, "local_y");
    lua_pushnumber(L, timestamp); lua_setfield(L, values_index, "timestamp");
    if (is_mouse_event(event)) {
        lua_pushinteger(L, code); lua_setfield(L, values_index, "button");
    } else if (is_key_event(event)) {
        lua_pushinteger(L, code); lua_setfield(L, values_index, "key");
    }

    lua_newtable(L);
    const int event_index = lua_gettop(L);
    lua_newtable(L);
    lua_pushvalue(L, values_index); lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, readonly_event_newindex); lua_setfield(L, -2, "__newindex");
    lua_pushvalue(L, values_index);
    lua_pushcclosure(L, readonly_event_pairs, 1); lua_setfield(L, -2, "__pairs");
    lua_pushliteral(L, "read-only D3D event"); lua_setfield(L, -2, "__metatable");
    lua_setmetatable(L, event_index);
    lua_remove(L, values_index);
}

void push_readonly_module_event(lua_State* L, SubscriptionEvent event,
    int32_t width, int32_t height, uint32_t generation)
{
    lua_newtable(L);
    const int values_index = lua_gettop(L);
    lua_pushstring(L, subscription_event_name(event)); lua_setfield(L, values_index, "type");
    lua_pushnumber(L, event_timestamp()); lua_setfield(L, values_index, "timestamp");
    if (event == SubscriptionEvent::Resize) {
        lua_pushinteger(L, width); lua_setfield(L, values_index, "width");
        lua_pushinteger(L, height); lua_setfield(L, values_index, "height");
    } else {
        lua_pushinteger(L, static_cast<lua_Integer>(generation));
        lua_setfield(L, values_index, "generation");
    }

    lua_newtable(L);
    const int event_index = lua_gettop(L);
    lua_newtable(L);
    lua_pushvalue(L, values_index); lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, readonly_event_newindex); lua_setfield(L, -2, "__newindex");
    lua_pushvalue(L, values_index);
    lua_pushcclosure(L, readonly_event_pairs, 1); lua_setfield(L, -2, "__pairs");
    lua_pushliteral(L, "read-only D3D event"); lua_setfield(L, -2, "__metatable");
    lua_setmetatable(L, event_index);
    lua_remove(L, values_index);
}

bool fire_module_subscription(lua_State* L, uint32_t id,
    SubscriptionEvent event, int32_t width, int32_t height, uint32_t generation)
{
    const auto found = g_subscriptions.find(id);
    if (found == g_subscriptions.end()) return false;
    const SubscriptionEntry entry = found->second;
    const int base = lua_gettop(L);
    if (!push_subscription_userdata(L, id)) {
        cancel_subscription_by_id(L, id);
        return false;
    }
    const int subscription_index = lua_gettop(L);
    if (lua_getiuservalue(L, subscription_index, 1) != LUA_TFUNCTION) {
        lua_settop(L, base);
        cancel_subscription_by_id(L, id);
        return false;
    }
    push_readonly_module_event(L, event, width, height, generation);
    lua_remove(L, subscription_index);
    const int call_result = safe_call_not_sleep(L, 1, 0, true);
    lua_settop(L, base);
    if (call_result != LUA_OK && !entry.keep_on_error) {
        DBG_LOG("[D3D SDK] lifecycle subscription %u cancelled after callback error", id);
        cancel_subscription_by_id(L, id);
    }
    return call_result == LUA_OK;
}

void dispatch_module_event(lua_State* L, SubscriptionEvent event,
    int32_t width, int32_t height, uint32_t generation)
{
    std::vector<uint32_t> ids;
    for (const auto& [id, entry] : g_subscriptions) {
        if (entry.session == g_session && entry.texture == 0 && entry.event == event)
            ids.push_back(id);
    }
    for (uint32_t id : ids) {
        fire_module_subscription(L, id, event, width, height, generation);
        if (g_shutdown) return;
    }
}

void push_subscription_registry(lua_State* L)
{
    lua_pushlightuserdata(L, &g_subscription_registry_key);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (lua_istable(L, -1)) return;
    lua_pop(L, 1);
    lua_newtable(L);
    lua_newtable(L);
    lua_pushliteral(L, "v");
    lua_setfield(L, -2, "__mode");
    lua_setmetatable(L, -2);
    lua_pushlightuserdata(L, &g_subscription_registry_key);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

bool push_subscription_userdata(lua_State* L, uint32_t id)
{
    push_subscription_registry(L);
    lua_rawgeti(L, -1, static_cast<lua_Integer>(id));
    lua_remove(L, -2);
    if (!luaL_testudata(L, -1, kSubscriptionMeta)) {
        lua_pop(L, 1);
        return false;
    }
    return true;
}

void register_subscription_userdata(lua_State* L, uint32_t id, int index)
{
    index = lua_absindex(L, index);
    push_subscription_registry(L);
    lua_pushvalue(L, index);
    lua_rawseti(L, -2, static_cast<lua_Integer>(id));
    lua_pop(L, 1);
}

void clear_subscription_userdata(lua_State* L, int index)
{
    index = lua_absindex(L, index);
    auto* self = static_cast<SubscriptionUserdata*>(
        luaL_testudata(L, index, kSubscriptionMeta));
    if (self) self->active = false;
    lua_pushnil(L);
    lua_setiuservalue(L, index, 1);
    lua_pushnil(L);
    lua_setiuservalue(L, index, 2);
}

void stop_event_timer()
{
    if (g_event_timer) {
        jass::call("PauseTimer", g_event_timer);
        jass::call("DestroyTimer", g_event_timer);
        jass::handle_unref(g_event_timer);
        g_event_timer = 0;
    }
    message::release_input_dispatch();
}

void cancel_subscription_by_id(lua_State* L, uint32_t id, int known_userdata)
{
    g_subscriptions.erase(id);
    if (known_userdata != 0) clear_subscription_userdata(L, known_userdata);
    if (push_subscription_userdata(L, id)) {
        clear_subscription_userdata(L, -1);
        lua_pop(L, 1);
    }
    push_subscription_registry(L);
    lua_pushnil(L);
    lua_rawseti(L, -2, static_cast<lua_Integer>(id));
    lua_pop(L, 1);
    if (g_subscriptions.empty()) {
        g_pending_input.clear();
        g_hover_stack.clear();
        g_pointer_capture.clear();
        stop_event_timer();
    }
}

void cancel_texture_subscriptions(lua_State* L, uint32_t session, uint32_t texture)
{
    std::vector<uint32_t> ids;
    for (const auto& [id, entry] : g_subscriptions) {
        if (entry.session == session && entry.texture == texture) ids.push_back(id);
    }
    for (uint32_t id : ids) cancel_subscription_by_id(L, id);
    g_hover_stack.erase(std::remove(g_hover_stack.begin(), g_hover_stack.end(), texture),
        g_hover_stack.end());
    for (auto it = g_pointer_capture.begin(); it != g_pointer_capture.end();) {
        if (it->second.texture == texture) it = g_pointer_capture.erase(it);
        else ++it;
    }
}

void cancel_all_subscriptions(lua_State* L)
{
    std::vector<uint32_t> ids;
    ids.reserve(g_subscriptions.size());
    for (const auto& [id, entry] : g_subscriptions) ids.push_back(id);
    for (uint32_t id : ids) cancel_subscription_by_id(L, id);
    g_subscriptions.clear();
    g_pending_input.clear();
    g_hover_stack.clear();
    g_pointer_capture.clear();
    stop_event_timer();
}

bool get_texture_hit_stack(float x, float y, std::vector<uint32_t>* out)
{
    if (!out || !g_api_ready || !g_api.get_texture_hit_stack || g_session == 0) return false;
    uint32_t required = 0;
    uint32_t result = g_api.get_texture_hit_stack(
        g_session, x, y, nullptr, 0, &required);
    if (result != D3D_SDK_OK) return false;
    out->assign(required, 0);
    if (required == 0) return true;
    result = g_api.get_texture_hit_stack(
        g_session, x, y, out->data(), required, &required);
    if (result != D3D_SDK_OK) {
        out->clear();
        return false;
    }
    out->resize(required);
    return true;
}

void texture_local_coordinates(
    uint32_t texture, float x, float y, float* out_x, float* out_y)
{
    float tx = 0.0f, ty = 0.0f, width = 0.0f, height = 0.0f;
    float rotation = 0.0f;
    if (g_api.get_texture_rect(g_session, texture, &tx, &ty, &width, &height)
            != D3D_SDK_OK
        || g_api.get_texture_rotation(g_session, texture, &rotation) != D3D_SDK_OK) {
        *out_x = x;
        *out_y = y;
        return;
    }
    const float center_x = tx + width * 0.5f;
    const float center_y = ty + height * 0.5f;
    const float radians = -rotation * 3.14159265358979323846f / 180.0f;
    const float dx = x - center_x;
    const float dy = y - center_y;
    *out_x = dx * std::cos(radians) - dy * std::sin(radians) + width * 0.5f;
    *out_y = dx * std::sin(radians) + dy * std::cos(radians) + height * 0.5f;
}

bool subscription_matches(
    const SubscriptionEntry& entry, SubscriptionEvent event,
    int32_t code, int hover_filter)
{
    if (entry.session != g_session || entry.event != event) return false;
    if ((is_mouse_event(event) || is_key_event(event))
        && entry.filter_code >= 0 && entry.filter_code != code) return false;
    if (is_key_event(event) && hover_filter >= 0
        && entry.hover_only != (hover_filter != 0)) return false;
    return true;
}

bool fire_subscription(
    lua_State* L, uint32_t id, SubscriptionEvent event,
    int32_t code, float x, float y, double timestamp)
{
    const auto found = g_subscriptions.find(id);
    if (found == g_subscriptions.end()) return false;
    const SubscriptionEntry entry = found->second;
    const int base = lua_gettop(L);
    if (!push_subscription_userdata(L, id)) {
        cancel_subscription_by_id(L, id);
        return false;
    }
    const int subscription_index = lua_gettop(L);
    if (lua_getiuservalue(L, subscription_index, 1) != LUA_TFUNCTION) {
        lua_settop(L, base);
        cancel_subscription_by_id(L, id);
        return false;
    }
    if (lua_getiuservalue(L, subscription_index, 2) != LUA_TUSERDATA) {
        lua_settop(L, base);
        cancel_subscription_by_id(L, id);
        return false;
    }
    const int target_index = lua_gettop(L);
    push_readonly_event(L, entry, event, code, x, y, timestamp, target_index);
    lua_remove(L, target_index);
    lua_remove(L, subscription_index);
    const int call_result = safe_call_not_sleep(L, 1, 0, true);
    lua_settop(L, base);
    if (call_result != LUA_OK && !entry.keep_on_error) {
        DBG_LOG("[D3D SDK] subscription %u cancelled after callback error", id);
        cancel_subscription_by_id(L, id);
    }
    return call_result == LUA_OK;
}

struct DispatchResult {
    bool matched = false;
    bool propagate = false;
};

DispatchResult dispatch_to_texture(
    lua_State* L, uint32_t texture, SubscriptionEvent event,
    int32_t code, float x, float y, double timestamp, int hover_filter = -1)
{
    std::vector<uint32_t> ids;
    for (const auto& [id, entry] : g_subscriptions) {
        if (entry.texture == texture
            && subscription_matches(entry, event, code, hover_filter)) ids.push_back(id);
    }
    DispatchResult result;
    for (uint32_t id : ids) {
        const auto found = g_subscriptions.find(id);
        if (found == g_subscriptions.end()) continue;
        result.matched = true;
        result.propagate = result.propagate || found->second.propagate;
        fire_subscription(L, id, event, code, x, y, timestamp);
        if (g_shutdown) break;
    }
    return result;
}

void dispatch_hit_stack(
    lua_State* L, const std::vector<uint32_t>& hits, SubscriptionEvent event,
    int32_t code, float x, float y, double timestamp, int hover_filter = -1)
{
    for (uint32_t texture : hits) {
        const DispatchResult result = dispatch_to_texture(
            L, texture, event, code, x, y, timestamp, hover_filter);
        if (!result.matched || !result.propagate || g_shutdown) break;
    }
}

bool has_texture_subscription(uint32_t texture)
{
    for (const auto& [id, entry] : g_subscriptions) {
        if (entry.session == g_session && entry.texture == texture) return true;
    }
    return false;
}

bool texture_propagates_hover(uint32_t texture)
{
    for (const auto& [id, entry] : g_subscriptions) {
        if (entry.session == g_session && entry.texture == texture && entry.propagate)
            return true;
    }
    return false;
}

std::vector<uint32_t> make_hover_stack(const std::vector<uint32_t>& hits)
{
    std::vector<uint32_t> hovered;
    for (uint32_t texture : hits) {
        if (has_texture_subscription(texture)) hovered.push_back(texture);
        if (!texture_propagates_hover(texture)) break;
    }
    return hovered;
}

bool vector_contains(const std::vector<uint32_t>& values, uint32_t value)
{
    return std::find(values.begin(), values.end(), value) != values.end();
}

void poll_hover(lua_State* L)
{
    float x = 0.0f;
    float y = 0.0f;
    if (!message::get_client_cursor(&x, &y)) return;
    std::vector<uint32_t> hits;
    if (!get_texture_hit_stack(x, y, &hits)) return;
    const std::vector<uint32_t> hovered = make_hover_stack(hits);
    const double timestamp = event_timestamp();
    const std::vector<uint32_t> previous = g_hover_stack;
    g_hover_stack = hovered;
    for (uint32_t texture : previous) {
        if (!vector_contains(hovered, texture)) {
            dispatch_to_texture(L, texture, SubscriptionEvent::Leave,
                -1, x, y, timestamp);
        }
    }
    for (uint32_t texture : hovered) {
        if (!vector_contains(previous, texture)) {
            dispatch_to_texture(L, texture, SubscriptionEvent::Enter,
                -1, x, y, timestamp);
        }
    }
}

void dispatch_leave_before_disable(lua_State* L, uint32_t texture)
{
    if (!vector_contains(g_hover_stack, texture)) return;
    g_hover_stack.erase(std::remove(g_hover_stack.begin(), g_hover_stack.end(), texture),
        g_hover_stack.end());
    float x = 0.0f;
    float y = 0.0f;
    message::get_client_cursor(&x, &y);
    dispatch_to_texture(L, texture, SubscriptionEvent::Leave,
        -1, x, y, event_timestamp());
}

void dispatch_key_event(lua_State* L, const PendingInputEvent& input)
{
    const SubscriptionEvent event = input.kind == InputKind::KeyDown
        ? SubscriptionEvent::KeyDown : SubscriptionEvent::KeyUp;
    std::vector<uint32_t> global_ids;
    for (const auto& [id, entry] : g_subscriptions) {
        if (!entry.hover_only && subscription_matches(entry, event, input.code, 0))
            global_ids.push_back(id);
    }
    for (uint32_t id : global_ids) {
        fire_subscription(L, id, event, input.code,
            input.x, input.y, input.timestamp);
        if (g_shutdown) return;
    }
    std::vector<uint32_t> hits;
    if (get_texture_hit_stack(input.x, input.y, &hits)) {
        dispatch_hit_stack(L, hits, event, input.code,
            input.x, input.y, input.timestamp, 1);
    }
}

void dispatch_mouse_event(lua_State* L, const PendingInputEvent& input)
{
    std::vector<uint32_t> hits;
    get_texture_hit_stack(input.x, input.y, &hits);
    if (input.kind == InputKind::MouseDown) {
        if (!hits.empty()) {
            g_pointer_capture[input.code] = {hits.front(), input.x, input.y};
        }
        dispatch_hit_stack(L, hits, SubscriptionEvent::MouseDown,
            input.code, input.x, input.y, input.timestamp);
        return;
    }

    const auto captured = g_pointer_capture.find(input.code);
    if (captured == g_pointer_capture.end()) {
        dispatch_hit_stack(L, hits, SubscriptionEvent::MouseUp,
            input.code, input.x, input.y, input.timestamp);
        return;
    }
    const PointerCapture capture = captured->second;
    g_pointer_capture.erase(captured);
    dispatch_to_texture(L, capture.texture, SubscriptionEvent::MouseUp,
        input.code, input.x, input.y, input.timestamp);
    const float dx = input.x - capture.down_x;
    const float dy = input.y - capture.down_y;
    if ((dx * dx + dy * dy) <= kClickMoveThreshold * kClickMoveThreshold
        && vector_contains(hits, capture.texture)) {
        dispatch_to_texture(L, capture.texture, SubscriptionEvent::Click,
            input.code, input.x, input.y, input.timestamp);
    }
}

void dispatch_pending_input(lua_State* L)
{
    std::deque<PendingInputEvent> pending;
    pending.swap(g_pending_input);
    for (const auto& input : pending) {
        if (g_shutdown || g_subscriptions.empty()) break;
        if (input.kind == InputKind::KeyDown || input.kind == InputKind::KeyUp)
            dispatch_key_event(L, input);
        else
            dispatch_mouse_event(L, input);
    }
}

void poll_lifecycle_events(lua_State* L)
{
    if (!g_api_ready || g_session == 0 || !g_api.get_resource_counts) return;
    D3DSdkResourceCountsV1 counts{};
    counts.struct_size = sizeof(counts);
    if (g_api.get_resource_counts(g_session, &counts) != D3D_SDK_OK) return;
    int32_t width = 0;
    int32_t height = 0;
    if (g_api.get_window_size) g_api.get_window_size(g_session, &width, &height);

    if (!g_lifecycle_known) {
        g_lifecycle_known = true;
        g_lifecycle_device_ready = counts.device_ready != 0;
        g_lifecycle_generation = counts.device_generation;
        g_lifecycle_width = width;
        g_lifecycle_height = height;
        return;
    }

    const bool was_ready = g_lifecycle_device_ready;
    const uint32_t previous_generation = g_lifecycle_generation;
    const bool ready = counts.device_ready != 0;
    g_lifecycle_device_ready = ready;
    g_lifecycle_generation = counts.device_generation;

    if (was_ready && !ready) {
        dispatch_module_event(L, SubscriptionEvent::DeviceLost, 0, 0, counts.device_generation);
    } else if (ready && (!was_ready || counts.device_generation != previous_generation)) {
        dispatch_module_event(L, SubscriptionEvent::DeviceReset, 0, 0, counts.device_generation);
    }

    if (width > 0 && height > 0
        && (width != g_lifecycle_width || height != g_lifecycle_height)) {
        g_lifecycle_width = width;
        g_lifecycle_height = height;
        dispatch_module_event(L, SubscriptionEvent::Resize, width, height, counts.device_generation);
    }
}

bool device_is_ready()
{
    if (!g_api_ready || !g_api.get_resource_counts || g_session == 0) return false;
    D3DSdkResourceCountsV1 counts{};
    counts.struct_size = sizeof(counts);
    return g_api.get_resource_counts(g_session, &counts) == D3D_SDK_OK
        && counts.device_ready != 0;
}

int event_timer_tick(lua_State* L)
{
    if (g_event_dispatching || g_shutdown || g_subscriptions.empty()) {
        lua_pushboolean(L, 1);
        return 1;
    }
    g_event_dispatching = true;
    try {
        // Lifecycle events must be observed even while the device is lost,
        // otherwise a lost->reset transition would go unnoticed.
        poll_lifecycle_events(L);
        if (device_is_ready()) {
            message::poll_input_devices();
            poll_hover(L);
            dispatch_pending_input(L);
        } else {
            // Raw input captured while the D3D device is lost must not be
            // replayed against a later reset generation.
            g_pending_input.clear();
            g_pointer_capture.clear();
        }
    } catch (...) {
        DBG_LOG("[D3D SDK] input dispatch dropped an internal exception");
    }
    g_event_dispatching = false;
    lua_pushboolean(L, 1);
    return 1;
}

bool start_event_timer(lua_State* L)
{
    message::ensure_input_dispatch(L);
    if (g_event_timer) return true;
    if (!g_event_code) {
        lua_pushcfunction(L, event_timer_tick);
        g_event_code = cfunction_to_code(L, static_cast<uint32_t>(lua_gettop(L)));
        lua_pop(L, 1);
        if (!g_event_code) return false;
    }
    const uint32_t timer = static_cast<uint32_t>(jass::call("CreateTimer"));
    const jass::func_value* timer_start = jass::jass_func("TimerStart");
    if (!timer || !timer_start) {
        if (timer) jass::call("DestroyTimer", timer);
        return false;
    }
    jass::handle_ref(timer);
    jass::call_param params(4);
    params.push<uintptr_t>(0, timer);
    params.push_real(1, jass::to_real(0.02f));
    params.push<bool>(2, true);
    params.push<uintptr_t>(3, g_event_code);
    timer_start->call(params);
    g_event_timer = timer;
    return true;
}

uint32_t allocate_subscription_id()
{
    for (uint64_t attempt = 0;
         attempt < (std::numeric_limits<uint32_t>::max)(); ++attempt) {
        uint32_t id = g_next_subscription_id++;
        if (g_next_subscription_id == 0) g_next_subscription_id = 1;
        if (id != 0 && g_subscriptions.find(id) == g_subscriptions.end()) return id;
    }
    return 0;
}

int texture_on(lua_State* L)
{
    auto* texture = check_resource(L, 1, D3D_SDK_RESOURCE_TEXTURE);
    SubscriptionEvent event;
    const char* event_name = luaL_checkstring(L, 2);
    if (!parse_subscription_event(event_name, &event)) {
        return luaL_argerror(L, 2, "unsupported D3D Texture event");
    }
    luaL_checktype(L, 3, LUA_TFUNCTION);
    if (!lua_isnoneornil(L, 4)) luaL_checktype(L, 4, LUA_TTABLE);

    SubscriptionEntry entry;
    entry.id = allocate_subscription_id();
    if (!entry.id) {
        lua_pushnil(L);
        lua_pushliteral(L, "D3D subscription capacity exceeded");
        return 2;
    }
    entry.session = texture->session;
    entry.texture = texture->handle;
    entry.event = event;
    if (lua_istable(L, 4)) {
        lua_getfield(L, 4, is_mouse_event(event) ? "button" : "key");
        if (!lua_isnil(L, -1)) entry.filter_code = check_int32(L, -1);
        lua_pop(L, 1);
        entry.propagate = boolean_field(L, 4, "propagate", false);
        entry.hover_only = boolean_field(L, 4, "hover_only", true);
        entry.keep_on_error = boolean_field(L, 4, "keep_on_error", false);
    }
    if (is_mouse_event(event) && (entry.filter_code < -1 || entry.filter_code > 4)) {
        return luaL_argerror(L, 4, "mouse button must be LEFT, RIGHT, MIDDLE, X1 or X2");
    }
    if (is_key_event(event) && (entry.filter_code < -1 || entry.filter_code > WARK_F12)) {
        return luaL_argerror(L, 4, "keyboard code is outside the public WARK range");
    }

    auto* subscription = static_cast<SubscriptionUserdata*>(
        lua_newuserdatauv(L, sizeof(SubscriptionUserdata), 2));
    new (subscription) SubscriptionUserdata();
    subscription->session = entry.session;
    subscription->id = entry.id;
    subscription->active = true;
    luaL_setmetatable(L, kSubscriptionMeta);
    const int subscription_index = lua_gettop(L);
    lua_pushvalue(L, 3);
    lua_setiuservalue(L, subscription_index, 1);
    lua_pushvalue(L, 1);
    lua_setiuservalue(L, subscription_index, 2);
    register_subscription_userdata(L, entry.id, subscription_index);
    try {
        g_subscriptions.emplace(entry.id, entry);
    } catch (...) {
        clear_subscription_userdata(L, subscription_index);
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "D3D subscription allocation failed");
        return 2;
    }
    if (!start_event_timer(L)) {
        cancel_subscription_by_id(L, entry.id, subscription_index);
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "D3D input dispatcher could not start");
        return 2;
    }
    return 1;
}

int module_on(lua_State* L)
{
    const char* event_name = luaL_checkstring(L, 1);
    SubscriptionEvent event;
    if (!parse_module_event(event_name, &event)) {
        return luaL_argerror(L, 1, "unsupported D3D lifecycle event");
    }
    luaL_checktype(L, 2, LUA_TFUNCTION);
    if (!lua_isnoneornil(L, 3)) luaL_checktype(L, 3, LUA_TTABLE);
    if (!initialize_api()) return push_unavailable(L);

    SubscriptionEntry entry;
    entry.id = allocate_subscription_id();
    if (!entry.id) {
        lua_pushnil(L);
        lua_pushliteral(L, "D3D subscription capacity exceeded");
        return 2;
    }
    entry.session = g_session;
    entry.texture = 0;  // module-level: no Texture target
    entry.event = event;
    entry.hover_only = false;
    if (lua_istable(L, 3)) entry.keep_on_error = boolean_field(L, 3, "keep_on_error", false);

    auto* subscription = static_cast<SubscriptionUserdata*>(
        lua_newuserdatauv(L, sizeof(SubscriptionUserdata), 2));
    new (subscription) SubscriptionUserdata();
    subscription->session = entry.session;
    subscription->id = entry.id;
    subscription->active = true;
    luaL_setmetatable(L, kSubscriptionMeta);
    const int subscription_index = lua_gettop(L);
    lua_pushvalue(L, 2);
    lua_setiuservalue(L, subscription_index, 1);
    register_subscription_userdata(L, entry.id, subscription_index);
    try {
        g_subscriptions.emplace(entry.id, entry);
    } catch (...) {
        clear_subscription_userdata(L, subscription_index);
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "D3D subscription allocation failed");
        return 2;
    }
    if (!start_event_timer(L)) {
        cancel_subscription_by_id(L, entry.id, subscription_index);
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushliteral(L, "D3D lifecycle dispatcher could not start");
        return 2;
    }
    return 1;
}

int subscription_cancel(lua_State* L)
{
    auto* self = static_cast<SubscriptionUserdata*>(
        luaL_checkudata(L, 1, kSubscriptionMeta));
    cancel_subscription_by_id(L, self->id, 1);
    lua_pushboolean(L, 1);
    return 1;
}

int subscription_gc(lua_State* L)
{
    auto* self = static_cast<SubscriptionUserdata*>(
        luaL_testudata(L, 1, kSubscriptionMeta));
    if (self) cancel_subscription_by_id(L, self->id, 1);
    return 0;
}

int subscription_is_active(lua_State* L)
{
    auto* self = static_cast<SubscriptionUserdata*>(
        luaL_checkudata(L, 1, kSubscriptionMeta));
    const bool active = self->active && self->session == g_session
        && g_subscriptions.find(self->id) != g_subscriptions.end();
    if (!active) self->active = false;
    lua_pushboolean(L, active);
    return 1;
}

int subscription_tostring(lua_State* L)
{
    auto* self = static_cast<SubscriptionUserdata*>(
        luaL_checkudata(L, 1, kSubscriptionMeta));
    char buffer[96];
    std::snprintf(buffer, sizeof(buffer), "jass.d3d.Subscription(id=%u, %s)",
        self->id, self->active && g_subscriptions.count(self->id) ? "active" : "cancelled");
    lua_pushstring(L, buffer);
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
    set("asset_memory", (g_api.capabilities & D3D_SDK_CAP_ASSET_MEMORY) != 0);
    set("input_hit_stack", (g_api.capabilities & D3D_SDK_CAP_INPUT_HIT_STACK) != 0);
    set("device_state", (g_api.capabilities & D3D_SDK_CAP_DEVICE_STATE) != 0);
    set("lifecycle_events", (g_api.capabilities & D3D_SDK_CAP_DEVICE_STATE) != 0);
    set("subscriptions", g_api_ready
        && (g_api.capabilities & D3D_SDK_CAP_INPUT_HIT_STACK) != 0);
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
    lua_pushinteger(L, static_cast<lua_Integer>(g_subscriptions.size()));
    lua_setfield(L, -2, "subscriptions");
    lua_pushboolean(L, counts.device_ready != 0); lua_setfield(L, -2, "device_ready");
    lua_pushinteger(L, static_cast<lua_Integer>(counts.device_generation));
    lua_setfield(L, -2, "device_generation");
    lua_newtable(L);
    lua_pushinteger(L, counts.asset_cache_entries); lua_setfield(L, -2, "entries");
    lua_pushinteger(L, static_cast<lua_Integer>(counts.asset_cache_bytes));
    lua_setfield(L, -2, "bytes");
    lua_setfield(L, -2, "asset_cache");
    return 1;
}

int module_status(lua_State* L)
{
    const bool available = initialize_api() && !g_shutdown;
    lua_newtable(L);
    lua_pushboolean(L, available); lua_setfield(L, -2, "available");
    lua_pushboolean(L, g_shutdown); lua_setfield(L, -2, "shutdown");
    lua_pushinteger(L, g_session); lua_setfield(L, -2, "session_id");
    lua_pushinteger(L, static_cast<lua_Integer>(g_pending_input.size()));
    lua_setfield(L, -2, "pending_callbacks");
    lua_pushlstring(L, g_init_error.data(), g_init_error.size()); lua_setfield(L, -2, "error");
    if (available) {
        D3DSdkResourceCountsV1 counts{};
        counts.struct_size = sizeof(counts);
        if (g_api.get_resource_counts(g_session, &counts) == D3D_SDK_OK) {
            lua_pushboolean(L, counts.device_ready != 0);
            lua_setfield(L, -2, "device_ready");
            lua_pushinteger(L, static_cast<lua_Integer>(counts.device_generation));
            lua_setfield(L, -2, "device_generation");
            lua_pushstring(L, counts.device_ready ? "active" : "lost");
            lua_setfield(L, -2, "state");
        }
    } else {
        lua_pushstring(L, g_shutdown ? "closed" : "unavailable");
        lua_setfield(L, -2, "state");
        lua_pushinteger(L, 0);
        lua_setfield(L, -2, "device_generation");
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
    cancel_all_subscriptions(L);
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
    g_lifecycle_known = false;
    lua_pushboolean(L, 1);
    return 1;
}

int context_gc(lua_State* L)
{
    auto* context = static_cast<ContextUserdata*>(luaL_testudata(L, 1, kContextMeta));
    cancel_all_subscriptions(L);
    if (context && context->owner && g_api_ready && g_session != 0) {
        g_api.end_session(g_session);
    }
    g_api = {};
    g_api_checked = false;
    g_api_ready = false;
    g_shutdown = false;
    g_session = 0;
    g_init_error.clear();
    g_event_code = 0;
    g_next_subscription_id = 1;
    g_lifecycle_known = false;
    g_lifecycle_device_ready = false;
    g_lifecycle_generation = 0;
    g_lifecycle_width = 0;
    g_lifecycle_height = 0;
    lua_pushlightuserdata(L, &g_subscription_registry_key);
    lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
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

void queue_input_event(InputKind kind, int32_t code, float x, float y)
{
    if (g_shutdown || g_subscriptions.empty() || !std::isfinite(x) || !std::isfinite(y))
        return;
    try {
        if (g_pending_input.size() >= kMaxPendingInput) g_pending_input.pop_front();
        g_pending_input.push_back({kind, code, x, y, event_timestamp()});
    } catch (...) {
        DBG_LOG("[D3D SDK] input event dropped after allocation failure");
    }
}

bool has_active_subscriptions()
{
    return !g_subscriptions.empty();
}

// ── VM / map lifecycle (called by lua_loader around lua_close) ───────

void prepare_vm_reset(bool jass_engine_alive)
{
    // The 0.02 s SDK tick timer holds a trampoline that re-enters the old
    // lua_State, so it must not outlive the VM. The underlying JASS timer can
    // only be destroyed while the JASS VM that owns the handle still exists.
    if (jass_engine_alive && g_event_timer) {
        jass::call("PauseTimer", g_event_timer);
        jass::call("DestroyTimer", g_event_timer);
        jass::handle_unref(g_event_timer);
    }
    g_event_timer = 0;
    g_event_code = 0;
    message::release_input_dispatch();
}

void reset_vm_state()
{
    // Runs after lua_close(): ContextUserdata's finalizer already cancelled
    // every subscription and ended the native session, so only the bookkeeping
    // that is read from outside Lua needs clearing here.
    g_subscriptions.clear();
    g_pending_input.clear();
    g_hover_stack.clear();
    g_pointer_capture.clear();
    g_event_timer = 0;
    g_event_code = 0;
    g_event_dispatching = false;
    DBG_LOG("[D3D SDK] VM reset: SDK state cleared");
}

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
        {"state", texture_state}, {"error", texture_error}, {"reload", texture_reload},
        {"get_rect", texture_get_rect}, {"set_rect", texture_set_rect},
        {"get_source_rect", texture_get_source_rect}, {"set_source_rect", texture_set_source_rect},
        {"get_color", texture_color_get}, {"set_color", texture_color_set},
        {"get_rotation", texture_get_rotation}, {"set_rotation", texture_set_rotation},
        {"get_z", texture_level_get}, {"set_z", texture_level_set},
        {"get_visible", texture_visible_get}, {"set_visible", texture_visible_set},
        {"get_hit_test", texture_hit_test_get}, {"set_hit_test", texture_hit_test_set},
        {"pixel_size", texture_pixel_size}, {"contains", texture_contains}, {"on", texture_on},
        {"is_destroyed", texture_is_destroyed}, {"destroy", texture_destroy},
        {nullptr, nullptr},
    };
    static const luaL_Reg subscription_meta[] = {
        {"__gc", subscription_gc}, {"__close", subscription_gc},
        {"__tostring", subscription_tostring}, {nullptr, nullptr},
    };
    static const luaL_Reg subscription_methods[] = {
        {"is_active", subscription_is_active}, {"cancel", subscription_cancel},
        {nullptr, nullptr},
    };
    static const luaL_Reg context_meta[] = {
        {"__gc", context_gc}, {nullptr, nullptr},
    };

    make_metatable(L, kFontMeta, font_meta, font_methods);
    make_metatable(L, kTextMeta, text_meta, text_methods);
    make_metatable(L, kTextureMeta, texture_meta, texture_methods);
    make_metatable(L, kSubscriptionMeta, subscription_meta, subscription_methods);
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
        {"on", module_on},
        {"shutdown", module_shutdown},
        {nullptr, nullptr},
    };
    luaL_setfuncs(L, module_functions, 0);
    push_class(L, font_new); lua_setfield(L, -2, "Font");
    push_class(L, text_new); lua_setfield(L, -2, "Text");
    push_class(L, texture_new); lua_setfield(L, -2, "Texture");
    lua_newtable(L); lua_setfield(L, -2, "Subscription");
    lua_newtable(L);
    lua_pushinteger(L, 0); lua_setfield(L, -2, "LEFT");
    lua_pushinteger(L, 1); lua_setfield(L, -2, "RIGHT");
    lua_pushinteger(L, 2); lua_setfield(L, -2, "MIDDLE");
    lua_pushinteger(L, 3); lua_setfield(L, -2, "X1");
    lua_pushinteger(L, 4); lua_setfield(L, -2, "X2");
    lua_setfield(L, -2, "mouse");
    lua_newtable(L);
#define SET_KEYBOARD(name) \
    lua_pushinteger(L, WARK_ ## name); \
    lua_setfield(L, -2, #name)
    SET_KEYBOARD_ALL()
#undef SET_KEYBOARD
    lua_setfield(L, -2, "key");
    return 1;
}

#undef LUA_INT_METHODS
#undef LUA_UINT_METHODS

}  // namespace warcraft3::lua_engine::d3d

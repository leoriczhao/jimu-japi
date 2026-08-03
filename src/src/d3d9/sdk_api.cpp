#include "sdk_api.h"

#include "renderer.h"
#include "resource_manager.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <type_traits>

namespace {

thread_local std::string g_last_error;
constexpr int32_t kMinInt32 = (-2147483647 - 1);
constexpr int32_t kMaxInt32 = 2147483647;

uint32_t fail(D3DSdkResult result, const char* message)
{
    g_last_error = message ? message : "D3D SDK error";
    return static_cast<uint32_t>(result);
}

uint32_t ok()
{
    g_last_error.clear();
    return D3D_SDK_OK;
}

uint32_t require_session(uint32_t session)
{
    const uint32_t active = d3d9_resources::active_session();
    if (active == 0) return fail(D3D_SDK_NO_ACTIVE_SESSION, "no active D3D session");
    if (session == 0 || session != active) {
        return fail(D3D_SDK_STALE_SESSION, "D3D session is stale or does not own this resource");
    }
    return D3D_SDK_OK;
}

uint32_t D3D_SDK_CALL begin_session(uint32_t* out_session)
{
    if (!out_session) return fail(D3D_SDK_INVALID_ARGUMENT, "out_session is null");
    *out_session = 0;
    const uint32_t session = d3d9_renderer::begin_session();
    if (session == 0) return fail(D3D_SDK_SESSION_ACTIVE, "a D3D session is already active");
    *out_session = session;
    return ok();
}

uint32_t D3D_SDK_CALL end_session(uint32_t session)
{
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    if (!d3d9_renderer::end_session(session)) {
        return fail(D3D_SDK_STALE_SESSION, "unable to close stale D3D session");
    }
    return ok();
}

uint32_t D3D_SDK_CALL get_resource_counts(
    uint32_t session, D3DSdkResourceCountsV1* out_counts)
{
    if (!out_counts || out_counts->struct_size < D3D_SDK_RESOURCE_COUNTS_V1_MIN_SIZE) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "resource count structure is missing or too small");
    }
    if (session != 0) {
        const uint32_t check = require_session(session);
        if (check != D3D_SDK_OK) return check;
    }

    const uint32_t caller_size = out_counts->struct_size;
    const auto counts = d3d9_renderer::resource_counts();
    D3DSdkResourceCountsV1 value{};
    value.struct_size = sizeof(value);
    value.session_id = d3d9_resources::active_session();
    value.font_count = counts.fonts;
    value.text_count = counts.texts;
    value.texture_count = counts.textures;
    value.device_ready = d3d9_renderer::is_device_ready() ? 1u : 0u;
    std::memcpy(out_counts, &value, std::min<uint32_t>(caller_size, sizeof(value)));
    return ok();
}

bool valid_resource_type(uint32_t resource_type)
{
    return resource_type >= D3D_SDK_RESOURCE_FONT
        && resource_type <= D3D_SDK_RESOURCE_TEXTURE;
}

uint32_t D3D_SDK_CALL is_handle_alive(
    uint32_t session, uint32_t resource_type, uint32_t handle,
    uint32_t* out_alive)
{
    if (!out_alive || !valid_resource_type(resource_type)) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "invalid handle query arguments");
    }
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    *out_alive = d3d9_resources::validate(
        handle, static_cast<d3d9_resources::ResourceType>(resource_type), session) ? 1u : 0u;
    return ok();
}

uint32_t D3D_SDK_CALL create_font(uint32_t session, uint32_t* out_handle)
{
    if (!out_handle) return fail(D3D_SDK_INVALID_ARGUMENT, "out_handle is null");
    *out_handle = 0;
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    *out_handle = d3d9_renderer::create_font();
    return *out_handle ? ok() : fail(D3D_SDK_CAPACITY_EXCEEDED, "font handle capacity exceeded");
}

uint32_t D3D_SDK_CALL destroy_font(uint32_t session, uint32_t handle)
{
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    if (!d3d9_resources::validate(handle, d3d9_resources::ResourceType::Font, session)) {
        return fail(D3D_SDK_INVALID_HANDLE, "font handle is invalid or already destroyed");
    }
    if (d3d9_renderer::font_in_use(handle)) {
        return fail(D3D_SDK_RESOURCE_IN_USE, "font is still referenced by a text object");
    }
    d3d9_renderer::destroy_font(handle);
    return ok();
}

uint32_t D3D_SDK_CALL create_text(
    uint32_t session, uint32_t font, const char* text,
    float x, float y, float ttl, uint32_t color, uint32_t* out_handle)
{
    if (!out_handle) return fail(D3D_SDK_INVALID_ARGUMENT, "out_handle is null");
    *out_handle = 0;
    if (!text || !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(ttl)) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "text creation arguments are invalid");
    }
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    if (!d3d9_resources::validate(font, d3d9_resources::ResourceType::Font, session)) {
        return fail(D3D_SDK_INVALID_HANDLE, "text font handle is invalid");
    }
    *out_handle = d3d9_renderer::create_text(font, text, x, y, ttl, color);
    return *out_handle ? ok() : fail(D3D_SDK_CAPACITY_EXCEEDED, "text handle capacity exceeded");
}

uint32_t D3D_SDK_CALL destroy_text(uint32_t session, uint32_t handle)
{
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    if (!d3d9_resources::validate(handle, d3d9_resources::ResourceType::Text, session)) {
        return fail(D3D_SDK_INVALID_HANDLE, "text handle is invalid or already destroyed");
    }
    d3d9_renderer::destroy_text(handle);
    return ok();
}

uint32_t D3D_SDK_CALL create_texture(
    uint32_t session, const char* path, float x, float y,
    float width, float height, uint32_t color, int32_t level,
    uint32_t* out_handle)
{
    if (!out_handle) return fail(D3D_SDK_INVALID_ARGUMENT, "out_handle is null");
    *out_handle = 0;
    if (!path || !std::isfinite(x) || !std::isfinite(y)
        || !std::isfinite(width) || !std::isfinite(height)
        || width < 0.0f || height < 0.0f) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "texture creation arguments are invalid");
    }
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    *out_handle = d3d9_renderer::create_texture(
        path, x, y, width, height, color, static_cast<int>(level));
    return *out_handle ? ok() : fail(D3D_SDK_CAPACITY_EXCEEDED, "texture handle capacity exceeded");
}

uint32_t D3D_SDK_CALL destroy_texture(uint32_t session, uint32_t handle)
{
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    if (!d3d9_resources::validate(handle, d3d9_resources::ResourceType::Texture, session)) {
        return fail(D3D_SDK_INVALID_HANDLE, "texture handle is invalid or already destroyed");
    }
    d3d9_renderer::destroy_texture(handle);
    return ok();
}

uint32_t D3D_SDK_CALL copy_last_error(char* buffer, uint32_t capacity)
{
    const uint32_t required = static_cast<uint32_t>(g_last_error.size() + 1u);
    if (buffer && capacity > 0) {
        const uint32_t count = std::min<uint32_t>(capacity - 1u, required - 1u);
        std::memcpy(buffer, g_last_error.data(), count);
        buffer[count] = '\0';
    }
    return required;
}

uint32_t require_resource(
    uint32_t session, uint32_t handle,
    d3d9_resources::ResourceType type, const char* message)
{
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    if (!d3d9_resources::validate(handle, type, session)) {
        return fail(D3D_SDK_INVALID_HANDLE, message);
    }
    return D3D_SDK_OK;
}

uint32_t copy_string(
    const char* value, char* buffer, uint32_t capacity,
    uint32_t* out_required)
{
    const char* text = value ? value : "";
    const uint32_t required = static_cast<uint32_t>(std::strlen(text) + 1u);
    if (out_required) *out_required = required;
    if (!buffer || capacity == 0) return ok();
    if (capacity < required) {
        buffer[0] = '\0';
        return fail(D3D_SDK_BUFFER_TOO_SMALL, "string output buffer is too small");
    }
    std::memcpy(buffer, text, required);
    return ok();
}

uint32_t D3D_SDK_CALL get_window_size(
    uint32_t session, int32_t* out_width, int32_t* out_height)
{
    if (!out_width || !out_height) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "window size output is null");
    }
    const uint32_t check = require_session(session);
    if (check != D3D_SDK_OK) return check;
    *out_width = d3d9_renderer::get_window_width();
    *out_height = d3d9_renderer::get_window_height();
    return ok();
}

uint32_t D3D_SDK_CALL copy_font_face(
    uint32_t session, uint32_t handle, char* buffer, uint32_t capacity,
    uint32_t* out_required)
{
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Font, "font handle is invalid");
    if (check != D3D_SDK_OK) return check;
    return copy_string(d3d9_renderer::get_font_facename(handle),
        buffer, capacity, out_required);
}

uint32_t D3D_SDK_CALL set_font_face(
    uint32_t session, uint32_t handle, const char* value)
{
    if (!value) return fail(D3D_SDK_INVALID_ARGUMENT, "font face is null");
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Font, "font handle is invalid");
    if (check != D3D_SDK_OK) return check;
    d3d9_renderer::set_font_facename(handle, value);
    return ok();
}

#define DEFINE_INT_PROPERTY(prefix, resource_type, getter, setter, minimum, maximum) \
    uint32_t D3D_SDK_CALL get_##prefix(                                             \
        uint32_t session, uint32_t handle, int32_t* out_value)                     \
    {                                                                               \
        if (!out_value) return fail(D3D_SDK_INVALID_ARGUMENT, #prefix " output is null"); \
        const uint32_t check = require_resource(session, handle, resource_type,     \
            #prefix " handle is invalid");                                        \
        if (check != D3D_SDK_OK) return check;                                      \
        *out_value = static_cast<int32_t>(d3d9_renderer::getter(handle));           \
        return ok();                                                                \
    }                                                                               \
    uint32_t D3D_SDK_CALL set_##prefix(                                             \
        uint32_t session, uint32_t handle, int32_t value)                          \
    {                                                                               \
        if (value < (minimum) || value > (maximum))                                 \
            return fail(D3D_SDK_INVALID_ARGUMENT, #prefix " value is out of range"); \
        const uint32_t check = require_resource(session, handle, resource_type,     \
            #prefix " handle is invalid");                                        \
        if (check != D3D_SDK_OK) return check;                                      \
        d3d9_renderer::setter(handle, static_cast<int>(value));                     \
        return ok();                                                                \
    }

DEFINE_INT_PROPERTY(font_height, d3d9_resources::ResourceType::Font,
    get_font_height, set_font_height, 1, kMaxInt32)
DEFINE_INT_PROPERTY(font_width, d3d9_resources::ResourceType::Font,
    get_font_width, set_font_width, 0, kMaxInt32)
DEFINE_INT_PROPERTY(font_weight, d3d9_resources::ResourceType::Font,
    get_font_weight, set_font_weight, 0, 1000)

uint32_t D3D_SDK_CALL get_font_italic(
    uint32_t session, uint32_t handle, uint32_t* out_value)
{
    if (!out_value) return fail(D3D_SDK_INVALID_ARGUMENT, "font italic output is null");
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Font, "font handle is invalid");
    if (check != D3D_SDK_OK) return check;
    *out_value = d3d9_renderer::get_font_italic(handle) ? 1u : 0u;
    return ok();
}

uint32_t D3D_SDK_CALL set_font_italic(
    uint32_t session, uint32_t handle, uint32_t value)
{
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Font, "font handle is invalid");
    if (check != D3D_SDK_OK) return check;
    d3d9_renderer::set_font_italic(handle, value != 0);
    return ok();
}

uint32_t D3D_SDK_CALL copy_text_string(
    uint32_t session, uint32_t handle, char* buffer, uint32_t capacity,
    uint32_t* out_required)
{
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Text, "text handle is invalid");
    if (check != D3D_SDK_OK) return check;
    return copy_string(d3d9_renderer::get_text_string(handle),
        buffer, capacity, out_required);
}

uint32_t D3D_SDK_CALL set_text_string(
    uint32_t session, uint32_t handle, const char* value)
{
    if (!value) return fail(D3D_SDK_INVALID_ARGUMENT, "text string is null");
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Text, "text handle is invalid");
    if (check != D3D_SDK_OK) return check;
    d3d9_renderer::set_text_string(handle, value);
    return ok();
}

uint32_t D3D_SDK_CALL get_text_position(
    uint32_t session, uint32_t handle, float* out_x, float* out_y)
{
    if (!out_x || !out_y) return fail(D3D_SDK_INVALID_ARGUMENT, "text position output is null");
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Text, "text handle is invalid");
    if (check != D3D_SDK_OK) return check;
    *out_x = d3d9_renderer::get_text_x(handle);
    *out_y = d3d9_renderer::get_text_y(handle);
    return ok();
}

uint32_t D3D_SDK_CALL set_text_position(
    uint32_t session, uint32_t handle, float x, float y)
{
    if (!std::isfinite(x) || !std::isfinite(y)) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "text position is not finite");
    }
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Text, "text handle is invalid");
    if (check != D3D_SDK_OK) return check;
    d3d9_renderer::set_text_x(handle, x);
    d3d9_renderer::set_text_y(handle, y);
    return ok();
}

#define DEFINE_FLOAT_PROPERTY(prefix, resource_type, getter, setter)               \
    uint32_t D3D_SDK_CALL get_##prefix(                                             \
        uint32_t session, uint32_t handle, float* out_value)                       \
    {                                                                               \
        if (!out_value) return fail(D3D_SDK_INVALID_ARGUMENT, #prefix " output is null"); \
        const uint32_t check = require_resource(session, handle, resource_type,     \
            #prefix " handle is invalid");                                        \
        if (check != D3D_SDK_OK) return check;                                      \
        *out_value = d3d9_renderer::getter(handle);                                 \
        return ok();                                                                \
    }                                                                               \
    uint32_t D3D_SDK_CALL set_##prefix(                                             \
        uint32_t session, uint32_t handle, float value)                            \
    {                                                                               \
        if (!std::isfinite(value))                                                  \
            return fail(D3D_SDK_INVALID_ARGUMENT, #prefix " value is not finite"); \
        const uint32_t check = require_resource(session, handle, resource_type,     \
            #prefix " handle is invalid");                                        \
        if (check != D3D_SDK_OK) return check;                                      \
        d3d9_renderer::setter(handle, value);                                       \
        return ok();                                                                \
    }

#define DEFINE_UINT_PROPERTY(prefix, resource_type, getter, setter)                \
    uint32_t D3D_SDK_CALL get_##prefix(                                             \
        uint32_t session, uint32_t handle, uint32_t* out_value)                    \
    {                                                                               \
        if (!out_value) return fail(D3D_SDK_INVALID_ARGUMENT, #prefix " output is null"); \
        const uint32_t check = require_resource(session, handle, resource_type,     \
            #prefix " handle is invalid");                                        \
        if (check != D3D_SDK_OK) return check;                                      \
        *out_value = static_cast<uint32_t>(d3d9_renderer::getter(handle));          \
        return ok();                                                                \
    }                                                                               \
    uint32_t D3D_SDK_CALL set_##prefix(                                             \
        uint32_t session, uint32_t handle, uint32_t value)                         \
    {                                                                               \
        const uint32_t check = require_resource(session, handle, resource_type,     \
            #prefix " handle is invalid");                                        \
        if (check != D3D_SDK_OK) return check;                                      \
        d3d9_renderer::setter(handle, value);                                       \
        return ok();                                                                \
    }

DEFINE_FLOAT_PROPERTY(text_ttl, d3d9_resources::ResourceType::Text,
    get_text_time, set_text_time)
DEFINE_UINT_PROPERTY(text_color, d3d9_resources::ResourceType::Text,
    get_text_color, set_text_color)
DEFINE_UINT_PROPERTY(text_visible, d3d9_resources::ResourceType::Text,
    get_text_visible, set_text_visible)
DEFINE_INT_PROPERTY(text_level, d3d9_resources::ResourceType::Text,
    get_text_level, set_text_level, kMinInt32, kMaxInt32)

uint32_t D3D_SDK_CALL get_text_font(
    uint32_t session, uint32_t handle, uint32_t* out_font)
{
    if (!out_font) return fail(D3D_SDK_INVALID_ARGUMENT, "text font output is null");
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Text, "text handle is invalid");
    if (check != D3D_SDK_OK) return check;
    *out_font = d3d9_renderer::get_text_font(handle);
    return ok();
}

uint32_t D3D_SDK_CALL set_text_font(
    uint32_t session, uint32_t handle, uint32_t font)
{
    uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Text, "text handle is invalid");
    if (check != D3D_SDK_OK) return check;
    check = require_resource(session, font,
        d3d9_resources::ResourceType::Font, "text font handle is invalid");
    if (check != D3D_SDK_OK) return check;
    return d3d9_renderer::set_text_font(handle, font)
        ? ok() : fail(D3D_SDK_INVALID_HANDLE, "unable to update text font");
}

uint32_t D3D_SDK_CALL copy_texture_source(
    uint32_t session, uint32_t handle, char* buffer, uint32_t capacity,
    uint32_t* out_required)
{
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Texture, "texture handle is invalid");
    if (check != D3D_SDK_OK) return check;
    return copy_string(d3d9_renderer::get_texture_source(handle),
        buffer, capacity, out_required);
}

uint32_t D3D_SDK_CALL set_texture_source(
    uint32_t session, uint32_t handle, const char* value)
{
    if (!value) return fail(D3D_SDK_INVALID_ARGUMENT, "texture source is null");
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Texture, "texture handle is invalid");
    if (check != D3D_SDK_OK) return check;
    d3d9_renderer::set_texture(handle, value);
    return ok();
}

uint32_t D3D_SDK_CALL get_texture_rect(
    uint32_t session, uint32_t handle, float* out_x, float* out_y,
    float* out_width, float* out_height)
{
    if (!out_x || !out_y || !out_width || !out_height) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "texture rect output is null");
    }
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Texture, "texture handle is invalid");
    if (check != D3D_SDK_OK) return check;
    *out_x = d3d9_renderer::get_texture_x(handle);
    *out_y = d3d9_renderer::get_texture_y(handle);
    *out_width = d3d9_renderer::get_texture_width(handle);
    *out_height = d3d9_renderer::get_texture_height(handle);
    return ok();
}

uint32_t D3D_SDK_CALL set_texture_rect(
    uint32_t session, uint32_t handle, float x, float y,
    float width, float height)
{
    if (!std::isfinite(x) || !std::isfinite(y)
        || !std::isfinite(width) || !std::isfinite(height)
        || width < 0.0f || height < 0.0f) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "texture rect is invalid");
    }
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Texture, "texture handle is invalid");
    if (check != D3D_SDK_OK) return check;
    d3d9_renderer::set_texture_x(handle, x);
    d3d9_renderer::set_texture_y(handle, y);
    d3d9_renderer::set_texture_width(handle, width);
    d3d9_renderer::set_texture_height(handle, height);
    return ok();
}

uint32_t D3D_SDK_CALL get_texture_src_rect(
    uint32_t session, uint32_t handle, float* out_left, float* out_top,
    float* out_right, float* out_bottom)
{
    if (!out_left || !out_top || !out_right || !out_bottom) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "texture source rect output is null");
    }
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Texture, "texture handle is invalid");
    if (check != D3D_SDK_OK) return check;
    d3d9_renderer::get_texture_src_rect(
        handle, out_left, out_top, out_right, out_bottom);
    return ok();
}

uint32_t D3D_SDK_CALL set_texture_src_rect(
    uint32_t session, uint32_t handle, float left, float top,
    float right, float bottom)
{
    if (!std::isfinite(left) || !std::isfinite(top)
        || !std::isfinite(right) || !std::isfinite(bottom)) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "texture source rect is not finite");
    }
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Texture, "texture handle is invalid");
    if (check != D3D_SDK_OK) return check;
    d3d9_renderer::set_texture_src_rect(handle, left, top, right, bottom);
    return ok();
}

DEFINE_UINT_PROPERTY(texture_color, d3d9_resources::ResourceType::Texture,
    get_texture_color, set_texture_color)
DEFINE_FLOAT_PROPERTY(texture_rotation, d3d9_resources::ResourceType::Texture,
    get_texture_rotation, set_texture_rotation)
DEFINE_INT_PROPERTY(texture_level, d3d9_resources::ResourceType::Texture,
    get_texture_level, set_texture_level, kMinInt32, kMaxInt32)
DEFINE_UINT_PROPERTY(texture_visible, d3d9_resources::ResourceType::Texture,
    get_texture_show, set_texture_show)
DEFINE_UINT_PROPERTY(texture_hit_test, d3d9_resources::ResourceType::Texture,
    get_texture_trigger, set_texture_trigger)

uint32_t D3D_SDK_CALL get_texture_pixel_size(
    uint32_t session, uint32_t handle, float* out_width, float* out_height)
{
    if (!out_width || !out_height) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "texture pixel size output is null");
    }
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Texture, "texture handle is invalid");
    if (check != D3D_SDK_OK) return check;
    *out_width = d3d9_renderer::get_texture_pixel_width(handle);
    *out_height = d3d9_renderer::get_texture_pixel_height(handle);
    return ok();
}

uint32_t D3D_SDK_CALL texture_contains(
    uint32_t session, uint32_t handle, float x, float y,
    uint32_t* out_contains)
{
    if (!out_contains) return fail(D3D_SDK_INVALID_ARGUMENT, "texture contains output is null");
    if (!std::isfinite(x) || !std::isfinite(y)) {
        return fail(D3D_SDK_INVALID_ARGUMENT, "texture hit-test point is not finite");
    }
    const uint32_t check = require_resource(session, handle,
        d3d9_resources::ResourceType::Texture, "texture handle is invalid");
    if (check != D3D_SDK_OK) return check;
    *out_contains = d3d9_renderer::texture_contains(handle, x, y) ? 1u : 0u;
    return ok();
}

#undef DEFINE_INT_PROPERTY
#undef DEFINE_FLOAT_PROPERTY
#undef DEFINE_UINT_PROPERTY

}  // namespace

extern "C" __declspec(dllexport) bool D3D_SDK_CALL GetD3DSdkApi(
    uint32_t requested_version, D3DSdkApiV1* out_api)
{
    if (!out_api || requested_version != D3D_SDK_ABI_VERSION_1) return false;
    const uint32_t caller_size = out_api->struct_size;
    if (caller_size < D3D_SDK_API_V1_MIN_SIZE) return false;

    D3DSdkApiV1 api{};
    api.abi_version = D3D_SDK_ABI_VERSION_1;
    api.struct_size = sizeof(api);
    api.capabilities = D3D_SDK_CAP_SESSION
        | D3D_SDK_CAP_GENERATION_HANDLES
        | D3D_SDK_CAP_RESOURCE_COUNTS
        | D3D_SDK_CAP_SHARED_LEGACY_REGISTRY
        | D3D_SDK_CAP_CORE_PROPERTIES
        | D3D_SDK_CAP_TEXT_ALPHA
        | D3D_SDK_CAP_UNIFIED_RENDER_QUEUE;
    api.begin_session = &begin_session;
    api.end_session = &end_session;
    api.get_resource_counts = &get_resource_counts;
    api.is_handle_alive = &is_handle_alive;
    api.create_font = &create_font;
    api.destroy_font = &destroy_font;
    api.create_text = &create_text;
    api.destroy_text = &destroy_text;
    api.create_texture = &create_texture;
    api.destroy_texture = &destroy_texture;
    api.copy_last_error = &copy_last_error;
    api.get_window_size = &get_window_size;
    api.copy_font_face = &copy_font_face;
    api.set_font_face = &set_font_face;
    api.get_font_height = &get_font_height;
    api.set_font_height = &set_font_height;
    api.get_font_width = &get_font_width;
    api.set_font_width = &set_font_width;
    api.get_font_weight = &get_font_weight;
    api.set_font_weight = &set_font_weight;
    api.get_font_italic = &get_font_italic;
    api.set_font_italic = &set_font_italic;
    api.copy_text_string = &copy_text_string;
    api.set_text_string = &set_text_string;
    api.get_text_position = &get_text_position;
    api.set_text_position = &set_text_position;
    api.get_text_ttl = &get_text_ttl;
    api.set_text_ttl = &set_text_ttl;
    api.get_text_color = &get_text_color;
    api.set_text_color = &set_text_color;
    api.get_text_visible = &get_text_visible;
    api.set_text_visible = &set_text_visible;
    api.get_text_level = &get_text_level;
    api.set_text_level = &set_text_level;
    api.get_text_font = &get_text_font;
    api.set_text_font = &set_text_font;
    api.copy_texture_source = &copy_texture_source;
    api.set_texture_source = &set_texture_source;
    api.get_texture_rect = &get_texture_rect;
    api.set_texture_rect = &set_texture_rect;
    api.get_texture_src_rect = &get_texture_src_rect;
    api.set_texture_src_rect = &set_texture_src_rect;
    api.get_texture_color = &get_texture_color;
    api.set_texture_color = &set_texture_color;
    api.get_texture_rotation = &get_texture_rotation;
    api.set_texture_rotation = &set_texture_rotation;
    api.get_texture_level = &get_texture_level;
    api.set_texture_level = &set_texture_level;
    api.get_texture_visible = &get_texture_visible;
    api.set_texture_visible = &set_texture_visible;
    api.get_texture_hit_test = &get_texture_hit_test;
    api.set_texture_hit_test = &set_texture_hit_test;
    api.get_texture_pixel_size = &get_texture_pixel_size;
    api.texture_contains = &texture_contains;
    std::memcpy(out_api, &api, std::min<uint32_t>(caller_size, sizeof(api)));
    return true;
}

static_assert(std::is_standard_layout<D3DSdkApiV1>::value,
    "D3DSdkApiV1 must remain a C-compatible standard-layout structure");

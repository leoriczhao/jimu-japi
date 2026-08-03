#include "sdk_api.h"

#include "renderer.h"
#include "resource_manager.h"

#include <algorithm>
#include <cstring>
#include <string>
#include <type_traits>

namespace {

thread_local std::string g_last_error;

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
        | D3D_SDK_CAP_SHARED_LEGACY_REGISTRY;
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
    std::memcpy(out_api, &api, std::min<uint32_t>(caller_size, sizeof(api)));
    return true;
}

static_assert(std::is_standard_layout<D3DSdkApiV1>::value,
    "D3DSdkApiV1 must remain a C-compatible standard-layout structure");

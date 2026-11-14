#pragma once

#include <cstddef>
#include <cstdint>

#if defined(_WIN32)
#define D3D_SDK_CALL __cdecl
#else
#define D3D_SDK_CALL
#endif

enum D3DSdkResult : uint32_t {
    D3D_SDK_OK = 0,
    D3D_SDK_INVALID_ARGUMENT = 1,
    D3D_SDK_SESSION_ACTIVE = 2,
    D3D_SDK_NO_ACTIVE_SESSION = 3,
    D3D_SDK_STALE_SESSION = 4,
    D3D_SDK_INVALID_HANDLE = 5,
    D3D_SDK_RESOURCE_IN_USE = 6,
    D3D_SDK_CAPACITY_EXCEEDED = 7,
    D3D_SDK_BUFFER_TOO_SMALL = 8,
    D3D_SDK_ASSET_INVALID = 9,
    D3D_SDK_DEVICE_NOT_READY = 10,
    D3D_SDK_DECODE_FAILED = 11,
};

enum D3DSdkCapability : uint64_t {
    D3D_SDK_CAP_SESSION = 1ull << 0,
    D3D_SDK_CAP_GENERATION_HANDLES = 1ull << 1,
    D3D_SDK_CAP_RESOURCE_COUNTS = 1ull << 2,
    D3D_SDK_CAP_SHARED_LEGACY_REGISTRY = 1ull << 3,
    D3D_SDK_CAP_CORE_PROPERTIES = 1ull << 4,
    D3D_SDK_CAP_TEXT_ALPHA = 1ull << 5,
    D3D_SDK_CAP_UNIFIED_RENDER_QUEUE = 1ull << 6,
    D3D_SDK_CAP_ASSET_MEMORY = 1ull << 7,
    D3D_SDK_CAP_INPUT_HIT_STACK = 1ull << 8,
};

enum D3DSdkResourceType : uint32_t {
    D3D_SDK_RESOURCE_FONT = 1,
    D3D_SDK_RESOURCE_TEXT = 2,
    D3D_SDK_RESOURCE_TEXTURE = 3,
};

#pragma pack(push, 4)
struct D3DSdkResourceCountsV1 {
    uint32_t struct_size;
    uint32_t session_id;
    uint32_t font_count;
    uint32_t text_count;
    uint32_t texture_count;
    uint32_t device_ready;
    uint32_t asset_cache_entries;
    uint32_t reserved;
    uint64_t asset_cache_bytes;
};

struct D3DSdkApiV1 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint64_t capabilities;

    uint32_t (D3D_SDK_CALL *begin_session)(uint32_t* out_session);
    uint32_t (D3D_SDK_CALL *end_session)(uint32_t session);
    uint32_t (D3D_SDK_CALL *get_resource_counts)(
        uint32_t session, D3DSdkResourceCountsV1* out_counts);
    uint32_t (D3D_SDK_CALL *is_handle_alive)(
        uint32_t session, uint32_t resource_type, uint32_t handle,
        uint32_t* out_alive);

    uint32_t (D3D_SDK_CALL *create_font)(
        uint32_t session, uint32_t* out_handle);
    uint32_t (D3D_SDK_CALL *destroy_font)(
        uint32_t session, uint32_t handle);
    uint32_t (D3D_SDK_CALL *create_text)(
        uint32_t session, uint32_t font, const char* text,
        float x, float y, float ttl, uint32_t color,
        uint32_t* out_handle);
    uint32_t (D3D_SDK_CALL *destroy_text)(
        uint32_t session, uint32_t handle);
    uint32_t (D3D_SDK_CALL *create_texture)(
        uint32_t session, const char* path, float x, float y,
        float width, float height, uint32_t color, int32_t level,
        uint32_t* out_handle);
    uint32_t (D3D_SDK_CALL *destroy_texture)(
        uint32_t session, uint32_t handle);

    uint32_t (D3D_SDK_CALL *copy_last_error)(char* buffer, uint32_t capacity);

    uint32_t (D3D_SDK_CALL *get_window_size)(
        uint32_t session, int32_t* out_width, int32_t* out_height);

    uint32_t (D3D_SDK_CALL *copy_font_face)(
        uint32_t session, uint32_t handle, char* buffer, uint32_t capacity,
        uint32_t* out_required);
    uint32_t (D3D_SDK_CALL *set_font_face)(
        uint32_t session, uint32_t handle, const char* value);
    uint32_t (D3D_SDK_CALL *get_font_height)(
        uint32_t session, uint32_t handle, int32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_font_height)(
        uint32_t session, uint32_t handle, int32_t value);
    uint32_t (D3D_SDK_CALL *get_font_width)(
        uint32_t session, uint32_t handle, int32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_font_width)(
        uint32_t session, uint32_t handle, int32_t value);
    uint32_t (D3D_SDK_CALL *get_font_weight)(
        uint32_t session, uint32_t handle, int32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_font_weight)(
        uint32_t session, uint32_t handle, int32_t value);
    uint32_t (D3D_SDK_CALL *get_font_italic)(
        uint32_t session, uint32_t handle, uint32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_font_italic)(
        uint32_t session, uint32_t handle, uint32_t value);

    uint32_t (D3D_SDK_CALL *copy_text_string)(
        uint32_t session, uint32_t handle, char* buffer, uint32_t capacity,
        uint32_t* out_required);
    uint32_t (D3D_SDK_CALL *set_text_string)(
        uint32_t session, uint32_t handle, const char* value);
    uint32_t (D3D_SDK_CALL *get_text_position)(
        uint32_t session, uint32_t handle, float* out_x, float* out_y);
    uint32_t (D3D_SDK_CALL *set_text_position)(
        uint32_t session, uint32_t handle, float x, float y);
    uint32_t (D3D_SDK_CALL *get_text_ttl)(
        uint32_t session, uint32_t handle, float* out_value);
    uint32_t (D3D_SDK_CALL *set_text_ttl)(
        uint32_t session, uint32_t handle, float value);
    uint32_t (D3D_SDK_CALL *get_text_color)(
        uint32_t session, uint32_t handle, uint32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_text_color)(
        uint32_t session, uint32_t handle, uint32_t value);
    uint32_t (D3D_SDK_CALL *get_text_visible)(
        uint32_t session, uint32_t handle, uint32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_text_visible)(
        uint32_t session, uint32_t handle, uint32_t value);
    uint32_t (D3D_SDK_CALL *get_text_level)(
        uint32_t session, uint32_t handle, int32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_text_level)(
        uint32_t session, uint32_t handle, int32_t value);
    uint32_t (D3D_SDK_CALL *get_text_font)(
        uint32_t session, uint32_t handle, uint32_t* out_font);
    uint32_t (D3D_SDK_CALL *set_text_font)(
        uint32_t session, uint32_t handle, uint32_t font);

    uint32_t (D3D_SDK_CALL *copy_texture_source)(
        uint32_t session, uint32_t handle, char* buffer, uint32_t capacity,
        uint32_t* out_required);
    uint32_t (D3D_SDK_CALL *set_texture_source)(
        uint32_t session, uint32_t handle, const char* value);
    uint32_t (D3D_SDK_CALL *get_texture_rect)(
        uint32_t session, uint32_t handle, float* out_x, float* out_y,
        float* out_width, float* out_height);
    uint32_t (D3D_SDK_CALL *set_texture_rect)(
        uint32_t session, uint32_t handle, float x, float y,
        float width, float height);
    uint32_t (D3D_SDK_CALL *get_texture_src_rect)(
        uint32_t session, uint32_t handle, float* out_left, float* out_top,
        float* out_right, float* out_bottom);
    uint32_t (D3D_SDK_CALL *set_texture_src_rect)(
        uint32_t session, uint32_t handle, float left, float top,
        float right, float bottom);
    uint32_t (D3D_SDK_CALL *get_texture_color)(
        uint32_t session, uint32_t handle, uint32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_texture_color)(
        uint32_t session, uint32_t handle, uint32_t value);
    uint32_t (D3D_SDK_CALL *get_texture_rotation)(
        uint32_t session, uint32_t handle, float* out_value);
    uint32_t (D3D_SDK_CALL *set_texture_rotation)(
        uint32_t session, uint32_t handle, float value);
    uint32_t (D3D_SDK_CALL *get_texture_level)(
        uint32_t session, uint32_t handle, int32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_texture_level)(
        uint32_t session, uint32_t handle, int32_t value);
    uint32_t (D3D_SDK_CALL *get_texture_visible)(
        uint32_t session, uint32_t handle, uint32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_texture_visible)(
        uint32_t session, uint32_t handle, uint32_t value);
    uint32_t (D3D_SDK_CALL *get_texture_hit_test)(
        uint32_t session, uint32_t handle, uint32_t* out_value);
    uint32_t (D3D_SDK_CALL *set_texture_hit_test)(
        uint32_t session, uint32_t handle, uint32_t value);
    uint32_t (D3D_SDK_CALL *get_texture_pixel_size)(
        uint32_t session, uint32_t handle, float* out_width, float* out_height);
    uint32_t (D3D_SDK_CALL *texture_contains)(
        uint32_t session, uint32_t handle, float x, float y,
        uint32_t* out_contains);

    // Appended v1 asset-memory boundary. Buffers are copied synchronously by
    // the proxy; ownership never crosses the DLL boundary.
    uint32_t (D3D_SDK_CALL *create_texture_from_memory)(
        uint32_t session, const char* source, const void* data,
        uint32_t data_size, float x, float y, float width, float height,
        uint32_t color, int32_t level, uint32_t* out_handle);
    uint32_t (D3D_SDK_CALL *set_texture_source_memory)(
        uint32_t session, uint32_t handle, const char* source,
        const void* data, uint32_t data_size);

    // Appended v1 P4 input boundary. Returns visible, hit-test-enabled
    // Texture handles under the point in top-most-first render order.
    uint32_t (D3D_SDK_CALL *get_texture_hit_stack)(
        uint32_t session, float x, float y, uint32_t* out_handles,
        uint32_t capacity, uint32_t* out_required);
};
#pragma pack(pop)

constexpr uint32_t D3D_SDK_ABI_VERSION_1 = 1;
constexpr uint32_t D3D_SDK_RESOURCE_COUNTS_V1_MIN_SIZE =
    static_cast<uint32_t>(offsetof(D3DSdkResourceCountsV1, device_ready)
        + sizeof(((D3DSdkResourceCountsV1*)nullptr)->device_ready));
constexpr uint32_t D3D_SDK_API_V1_MIN_SIZE =
    static_cast<uint32_t>(offsetof(D3DSdkApiV1, copy_last_error)
        + sizeof(((D3DSdkApiV1*)nullptr)->copy_last_error));

#ifdef __cplusplus
extern "C" __declspec(dllexport) bool D3D_SDK_CALL GetD3DSdkApi(
    uint32_t requested_version, D3DSdkApiV1* out_api);
#endif

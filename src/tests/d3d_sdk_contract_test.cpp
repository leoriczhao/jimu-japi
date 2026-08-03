#include "sdk_api.h"

#include <windows.h>

#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace {

int fail(const char* message)
{
    std::fprintf(stderr, "D3D SDK contract FAIL: %s\n", message);
    return 1;
}

#define CHECK(condition, message) do { if (!(condition)) return fail(message); } while (0)

}  // namespace

int main()
{
    HMODULE proxy = LoadLibraryA("newD3d9.dll");
    CHECK(proxy != nullptr, "unable to load newD3d9.dll");

    using get_api_fn = bool (D3D_SDK_CALL *)(uint32_t, D3DSdkApiV1*);
    auto get_api = reinterpret_cast<get_api_fn>(GetProcAddress(proxy, "GetD3DSdkApi"));
    CHECK(get_api != nullptr, "GetD3DSdkApi export is missing");

    D3DSdkApiV1 api{};
    api.struct_size = sizeof(api);
    CHECK(!get_api(999, &api), "unsupported ABI version was accepted");

    D3DSdkApiV1 too_small{};
    too_small.struct_size = sizeof(uint32_t) * 2;
    CHECK(!get_api(D3D_SDK_ABI_VERSION_1, &too_small), "undersized ABI structure was accepted");

    std::memset(&api, 0, sizeof(api));
    api.struct_size = sizeof(api);
    CHECK(get_api(D3D_SDK_ABI_VERSION_1, &api), "ABI v1 negotiation failed");
    CHECK(api.abi_version == D3D_SDK_ABI_VERSION_1, "wrong ABI version returned");
    CHECK(api.struct_size == sizeof(api), "wrong ABI structure size returned");
    const uint64_t required_caps = D3D_SDK_CAP_SESSION
        | D3D_SDK_CAP_GENERATION_HANDLES
        | D3D_SDK_CAP_RESOURCE_COUNTS
        | D3D_SDK_CAP_SHARED_LEGACY_REGISTRY
        | D3D_SDK_CAP_CORE_PROPERTIES
        | D3D_SDK_CAP_TEXT_ALPHA
        | D3D_SDK_CAP_UNIFIED_RENDER_QUEUE;
    CHECK((api.capabilities & required_caps) == required_caps,
        "required P3 rendering capabilities are missing");

    uint32_t session1 = 0;
    CHECK(api.begin_session(&session1) == D3D_SDK_OK && session1 != 0,
        "first session did not start");
    uint32_t duplicate_session = 0;
    CHECK(api.begin_session(&duplicate_session) == D3D_SDK_SESSION_ACTIVE,
        "concurrent session was not rejected");

    D3DSdkResourceCountsV1 counts{};
    counts.struct_size = sizeof(counts);
    CHECK(api.get_resource_counts(session1, &counts) == D3D_SDK_OK,
        "initial resource counts failed");
    CHECK(counts.session_id == session1 && counts.font_count == 0
        && counts.text_count == 0 && counts.texture_count == 0,
        "new session did not start empty");

    uint32_t font1 = 0;
    uint32_t text1 = 0;
    uint32_t texture1 = 0;
    CHECK(api.create_font(session1, &font1) == D3D_SDK_OK && font1 != 0,
        "font creation failed");
    CHECK(api.create_text(session1, font1, "contract", 1.0f, 2.0f, -1.0f,
        0xFFFFFFFFu, &text1) == D3D_SDK_OK && text1 != 0,
        "text creation failed");
    CHECK(api.create_texture(session1, "", 3.0f, 4.0f, 5.0f, 6.0f,
        0xFFFFFFFFu, 7, &texture1) == D3D_SDK_OK && texture1 != 0,
        "texture creation failed");

    CHECK(api.set_font_face(session1, font1, "Courier New") == D3D_SDK_OK,
        "font face setter failed");
    char text_buffer[128] = {};
    uint32_t required = 0;
    CHECK(api.copy_font_face(session1, font1, text_buffer, sizeof(text_buffer), &required)
        == D3D_SDK_OK && std::strcmp(text_buffer, "Courier New") == 0 && required == 12,
        "font face round-trip failed");
    CHECK(api.set_font_height(session1, font1, 28) == D3D_SDK_OK,
        "font height setter failed");
    CHECK(api.set_font_width(session1, font1, 2) == D3D_SDK_OK,
        "font width setter failed");
    CHECK(api.set_font_weight(session1, font1, 700) == D3D_SDK_OK,
        "font weight setter failed");
    CHECK(api.set_font_italic(session1, font1, 1) == D3D_SDK_OK,
        "font italic setter failed");
    int32_t int_value = 0;
    uint32_t uint_value = 0;
    CHECK(api.get_font_height(session1, font1, &int_value) == D3D_SDK_OK && int_value == 28,
        "font height round-trip failed");
    CHECK(api.get_font_width(session1, font1, &int_value) == D3D_SDK_OK && int_value == 2,
        "font width round-trip failed");
    CHECK(api.get_font_weight(session1, font1, &int_value) == D3D_SDK_OK && int_value == 700,
        "font weight round-trip failed");
    CHECK(api.get_font_italic(session1, font1, &uint_value) == D3D_SDK_OK && uint_value == 1,
        "font italic round-trip failed");
    CHECK(api.set_font_weight(session1, font1, 1001) == D3D_SDK_INVALID_ARGUMENT,
        "font weight range validation failed");

    CHECK(api.set_text_string(session1, text1, "updated") == D3D_SDK_OK,
        "text string setter failed");
    std::memset(text_buffer, 0, sizeof(text_buffer));
    CHECK(api.copy_text_string(session1, text1, text_buffer, sizeof(text_buffer), &required)
        == D3D_SDK_OK && std::strcmp(text_buffer, "updated") == 0,
        "text string round-trip failed");
    const std::string long_text(5400, 's');
    CHECK(api.set_text_string(session1, text1, long_text.c_str()) == D3D_SDK_OK,
        "long text setter failed");
    required = 0;
    CHECK(api.copy_text_string(session1, text1, nullptr, 0, &required) == D3D_SDK_OK
        && required == long_text.size() + 1, "long text size query failed");
    char short_buffer[8] = {};
    CHECK(api.copy_text_string(session1, text1, short_buffer, sizeof(short_buffer), &required)
        == D3D_SDK_BUFFER_TOO_SMALL && short_buffer[0] == '\0',
        "small text buffer was not rejected deterministically");
    std::vector<char> long_buffer(required);
    CHECK(api.copy_text_string(session1, text1, long_buffer.data(),
        static_cast<uint32_t>(long_buffer.size()), &required) == D3D_SDK_OK
        && std::strcmp(long_buffer.data(), long_text.c_str()) == 0,
        "long text round-trip failed");
    CHECK(api.set_text_string(session1, text1, "updated") == D3D_SDK_OK,
        "text string restore failed");
    CHECK(api.set_text_position(session1, text1, 11.0f, 12.0f) == D3D_SDK_OK,
        "text position setter failed");
    float value1 = 0.0f;
    float value2 = 0.0f;
    CHECK(api.get_text_position(session1, text1, &value1, &value2) == D3D_SDK_OK
        && value1 == 11.0f && value2 == 12.0f, "text position round-trip failed");
    CHECK(api.set_text_ttl(session1, text1, 3.5f) == D3D_SDK_OK,
        "text TTL setter failed");
    CHECK(api.get_text_ttl(session1, text1, &value1) == D3D_SDK_OK && value1 == 3.5f,
        "text TTL round-trip failed");
    CHECK(api.set_text_color(session1, text1, 0x80402010u) == D3D_SDK_OK,
        "text color setter failed");
    CHECK(api.get_text_color(session1, text1, &uint_value) == D3D_SDK_OK
        && uint_value == 0x80402010u, "text color round-trip failed");
    CHECK(api.set_text_visible(session1, text1, 0) == D3D_SDK_OK,
        "text visible setter failed");
    CHECK(api.get_text_visible(session1, text1, &uint_value) == D3D_SDK_OK && uint_value == 0,
        "text visible round-trip failed");
    CHECK(api.set_text_level(session1, text1, 33) == D3D_SDK_OK,
        "text level setter failed");
    CHECK(api.get_text_level(session1, text1, &int_value) == D3D_SDK_OK && int_value == 33,
        "text level round-trip failed");

    CHECK(api.set_texture_source(session1, texture1, "probe.bmp") == D3D_SDK_OK,
        "texture source setter failed");
    std::memset(text_buffer, 0, sizeof(text_buffer));
    CHECK(api.copy_texture_source(session1, texture1, text_buffer, sizeof(text_buffer), &required)
        == D3D_SDK_OK && std::strcmp(text_buffer, "probe.bmp") == 0,
        "texture source round-trip failed");
    CHECK(api.set_texture_rect(session1, texture1, 20.0f, 21.0f, 22.0f, 23.0f)
        == D3D_SDK_OK, "texture rect setter failed");
    float value3 = 0.0f;
    float value4 = 0.0f;
    CHECK(api.get_texture_rect(session1, texture1, &value1, &value2, &value3, &value4)
        == D3D_SDK_OK && value1 == 20.0f && value2 == 21.0f
        && value3 == 22.0f && value4 == 23.0f, "texture rect round-trip failed");
    CHECK(api.set_texture_src_rect(session1, texture1, 1.0f, 2.0f, 3.0f, 4.0f)
        == D3D_SDK_OK, "texture source rect setter failed");
    CHECK(api.get_texture_src_rect(session1, texture1, &value1, &value2, &value3, &value4)
        == D3D_SDK_OK && value1 == 1.0f && value2 == 2.0f
        && value3 == 3.0f && value4 == 4.0f, "texture source rect round-trip failed");
    CHECK(api.set_texture_color(session1, texture1, 0x10203040u) == D3D_SDK_OK,
        "texture color setter failed");
    CHECK(api.get_texture_color(session1, texture1, &uint_value) == D3D_SDK_OK
        && uint_value == 0x10203040u, "texture color round-trip failed");
    CHECK(api.set_texture_rotation(session1, texture1, 90.0f) == D3D_SDK_OK,
        "texture rotation setter failed");
    CHECK(api.get_texture_rotation(session1, texture1, &value1) == D3D_SDK_OK
        && value1 == 90.0f, "texture rotation round-trip failed");
    CHECK(api.set_texture_level(session1, texture1, 44) == D3D_SDK_OK,
        "texture level setter failed");
    CHECK(api.get_texture_level(session1, texture1, &int_value) == D3D_SDK_OK
        && int_value == 44, "texture level round-trip failed");
    CHECK(api.set_texture_visible(session1, texture1, 1) == D3D_SDK_OK
        && api.set_texture_hit_test(session1, texture1, 1) == D3D_SDK_OK,
        "texture visibility/hit-test setter failed");
    CHECK(api.get_texture_visible(session1, texture1, &uint_value) == D3D_SDK_OK
        && uint_value == 1, "texture visible round-trip failed");
    CHECK(api.get_texture_hit_test(session1, texture1, &uint_value) == D3D_SDK_OK
        && uint_value == 1, "texture hit-test round-trip failed");
    CHECK(api.set_texture_rect(session1, texture1, 0.0f, 0.0f, 100.0f, 20.0f)
        == D3D_SDK_OK, "rotated hit-test rect setup failed");
    CHECK(api.texture_contains(session1, texture1, 50.0f, 10.0f, &uint_value)
        == D3D_SDK_OK && uint_value == 1, "texture geometric contains failed");
    CHECK(api.texture_contains(session1, texture1, 90.0f, 10.0f, &uint_value)
        == D3D_SDK_OK && uint_value == 0, "rotated texture used its unrotated AABB");
    CHECK(api.set_texture_rect(session1, texture1, 0.0f, 0.0f, -1.0f, 20.0f)
        == D3D_SDK_INVALID_ARGUMENT, "negative texture dimensions were accepted");
    CHECK(api.set_texture_rotation(session1, texture1,
        std::numeric_limits<float>::quiet_NaN()) == D3D_SDK_INVALID_ARGUMENT,
        "non-finite texture rotation was accepted");

    counts = {};
    counts.struct_size = sizeof(counts);
    CHECK(api.get_resource_counts(session1, &counts) == D3D_SDK_OK,
        "populated resource counts failed");
    CHECK(counts.font_count == 1 && counts.text_count == 1 && counts.texture_count == 1,
        "resource counts do not match live resources");
    CHECK(api.destroy_font(session1, font1) == D3D_SDK_RESOURCE_IN_USE,
        "font dependency was not enforced");

    CHECK(api.end_session(session1) == D3D_SDK_OK, "session close failed");
    counts = {};
    counts.struct_size = sizeof(counts);
    CHECK(api.get_resource_counts(0, &counts) == D3D_SDK_OK,
        "post-close global resource counts failed");
    CHECK(counts.session_id == 0 && counts.font_count == 0
        && counts.text_count == 0 && counts.texture_count == 0,
        "session close did not clear every resource class");

    uint32_t session2 = 0;
    CHECK(api.begin_session(&session2) == D3D_SDK_OK && session2 != 0 && session2 != session1,
        "second session identity was not renewed");
    uint32_t alive = 1;
    CHECK(api.is_handle_alive(session2, D3D_SDK_RESOURCE_FONT, font1, &alive) == D3D_SDK_OK
        && alive == 0, "old handle survived into a new session");

    uint32_t font2 = 0;
    CHECK(api.create_font(session2, &font2) == D3D_SDK_OK && font2 != 0,
        "second-session font creation failed");
    CHECK(font2 != font1, "slot reuse did not change the handle generation");
    CHECK(api.destroy_font(session2, font2) == D3D_SDK_OK,
        "font destruction failed");
    CHECK(api.destroy_font(session2, font2) == D3D_SDK_INVALID_HANDLE,
        "repeat destruction did not return a stable invalid-handle result");
    char error[128] = {};
    CHECK(api.copy_last_error(error, sizeof(error)) > 1
        && std::strstr(error, "invalid") != nullptr,
        "last-error diagnostics did not describe the invalid handle");

    for (uint32_t i = 0; i < 1000; ++i) {
        uint32_t stress_font = 0;
        uint32_t stress_text = 0;
        uint32_t stress_texture = 0;
        CHECK(api.create_font(session2, &stress_font) == D3D_SDK_OK,
            "stress font creation failed");
        CHECK(api.create_text(session2, stress_font, "stress", 0.0f, 0.0f,
            -1.0f, 0xFFFFFFFFu, &stress_text) == D3D_SDK_OK,
            "stress text creation failed");
        CHECK(api.create_texture(session2, "", 0.0f, 0.0f, 1.0f, 1.0f,
            0xFFFFFFFFu, 0, &stress_texture) == D3D_SDK_OK,
            "stress texture creation failed");
        CHECK(api.destroy_text(session2, stress_text) == D3D_SDK_OK,
            "stress text destruction failed");
        CHECK(api.destroy_texture(session2, stress_texture) == D3D_SDK_OK,
            "stress texture destruction failed");
        CHECK(api.destroy_font(session2, stress_font) == D3D_SDK_OK,
            "stress font destruction failed");
    }
    counts = {};
    counts.struct_size = sizeof(counts);
    CHECK(api.get_resource_counts(session2, &counts) == D3D_SDK_OK
        && counts.font_count == 0 && counts.text_count == 0 && counts.texture_count == 0,
        "1000 lifecycle iterations did not return counts to baseline");
    CHECK(api.end_session(session2) == D3D_SDK_OK, "second session close failed");
    CHECK(api.end_session(session2) == D3D_SDK_NO_ACTIVE_SESSION,
        "repeat session close did not return a stable result");

    FreeLibrary(proxy);
    std::puts("D3D SDK contract PASS: ABI v1, sessions, generation handles, dependencies, alpha/z capabilities, counters, stress=1000");
    return 0;
}

#include "sdk_api.h"

#include <windows.h>

#include <cstdio>
#include <cstring>

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
        | D3D_SDK_CAP_SHARED_LEGACY_REGISTRY;
    CHECK((api.capabilities & required_caps) == required_caps, "required P1 capabilities are missing");

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
    std::puts("D3D SDK contract PASS: ABI v1, sessions, generation handles, dependencies, counters, stress=1000");
    return 0;
}

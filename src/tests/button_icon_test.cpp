// button_icon_test.cpp - offline tests for the standalone BLP/button-icon
// module. No Warcraft III process, D3D device, MPQ, or hook is involved.
//
// Build: src/build.bat produces src/build/bin/Release/button_icon_test.exe
// Run:   button_icon_test.exe [repo-root]
#include <image/blp_codec.h>
#include <image/blp_format.h>
#include <image/button_icon.h>
#include <image/pas_button_data.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

namespace {

int g_passed = 0;
int g_failed = 0;

void check(const char* name, bool condition, const std::string& detail = {})
{
    if (condition) {
        ++g_passed;
        std::cout << "  [PASS] " << name << "\n";
    } else {
        ++g_failed;
        std::cout << "  [FAIL] " << name;
        if (!detail.empty()) std::cout << " : " << detail;
        std::cout << "\n";
    }
}

uint64_t fnv1a(const uint8_t* data, size_t size)
{
    uint64_t hash = 0xcbf29ce484222325ull;
    for (size_t i = 0; i < size; ++i) {
        hash ^= data[i];
        hash *= 0x100000001b3ull;
    }
    return hash;
}

japi::image::Image synthetic_image(int seed)
{
    japi::image::Image image;
    image.width = 64;
    image.height = 64;
    image.bgra.resize(image.pixel_count() * 4u);
    for (int y = 0; y < 64; ++y) {
        for (int x = 0; x < 64; ++x) {
            uint8_t* p = image.bgra.data()
                + (static_cast<size_t>(y) * 64 + x) * 4u;
            if (seed == 0) {
                p[0] = static_cast<uint8_t>((x * 4 + y) & 0xFF);
                p[1] = static_cast<uint8_t>((x * 3 + y * 2) & 0xFF);
                p[2] = static_cast<uint8_t>((x + y * 5) & 0xFF);
                p[3] = static_cast<uint8_t>((x + y) & 0xFF);
            } else {
                p[0] = static_cast<uint8_t>((x * 7 + y * 3) & 0xFF);
                p[1] = static_cast<uint8_t>((x * 2 + y * 11) & 0xFF);
                p[2] = static_cast<uint8_t>((x * 13 + y * 5) & 0xFF);
                p[3] = static_cast<uint8_t>((x * 4 + y * 6) & 0xFF);
            }
        }
    }
    return image;
}

japi::image::Image small_palette_image()
{
    japi::image::Image image;
    image.width = 64;
    image.height = 64;
    image.bgra.resize(image.pixel_count() * 4u);
    for (int y = 0; y < 64; ++y) {
        for (int x = 0; x < 64; ++x) {
            uint8_t* p = image.bgra.data()
                + (static_cast<size_t>(y) * 64 + x) * 4u;
            const int index = (x / 8) + (y / 8) * 8;  // 64 exact colours
            p[0] = static_cast<uint8_t>(index * 3);
            p[1] = static_cast<uint8_t>(index * 2);
            p[2] = static_cast<uint8_t>(index);
            p[3] = static_cast<uint8_t>((x + y) & 0xFF);
        }
    }
    return image;
}

std::vector<uint8_t> make_blp2_palette_fixture()
{
    using namespace japi::image::blp;
    const uint32_t width = 4;
    const uint32_t height = 4;
    const uint32_t pixels = width * height;
    Blp2Header header{};
    header.magic = kBlp2;
    header.encoding = 1;
    header.alpha_depth = 8;
    header.width = width;
    header.height = height;
    header.offsets[0] = sizeof(header) + 256u * 4u;
    header.sizes[0] = pixels + pixels;

    std::vector<uint8_t> data(sizeof(header) + 256u * 4u + pixels * 2u, 0);
    std::memcpy(data.data(), &header, sizeof(header));
    uint8_t* palette = data.data() + sizeof(header);
    const uint8_t colors[4][4] = {
        { 0, 0, 0, 255 }, { 10, 20, 30, 255 },
        { 200, 100, 50, 255 }, { 255, 255, 255, 255 },
    };
    for (int i = 0; i < 4; ++i) {
        std::memcpy(palette + i * 4u, colors[i], 4);
    }
    uint8_t* indices = data.data() + header.offsets[0];
    uint8_t* alpha = indices + pixels;
    for (uint32_t i = 0; i < pixels; ++i) {
        indices[i] = static_cast<uint8_t>(i % 4u);
        alpha[i] = static_cast<uint8_t>(i * 17u);
    }
    return data;
}

std::vector<uint8_t> make_blp2_raw_fixture()
{
    using namespace japi::image::blp;
    const uint32_t width = 2;
    const uint32_t height = 2;
    const uint32_t pixels = width * height;
    Blp2Header header{};
    header.magic = kBlp2;
    header.encoding = 3;
    header.alpha_depth = 8;
    header.width = width;
    header.height = height;
    header.offsets[0] = sizeof(header);
    header.sizes[0] = pixels * 4u;
    std::vector<uint8_t> data(sizeof(header) + pixels * 4u, 0);
    std::memcpy(data.data(), &header, sizeof(header));
    for (uint32_t i = 0; i < pixels; ++i) {
        uint8_t* p = data.data() + sizeof(header) + i * 4u;
        p[0] = static_cast<uint8_t>(i * 10u);
        p[1] = static_cast<uint8_t>(i * 20u);
        p[2] = static_cast<uint8_t>(i * 30u);
        p[3] = static_cast<uint8_t>(255u - i * 10u);
    }
    return data;
}

void test_codec()
{
    std::cout << "-- BLP codec --\n";
    japi::image::Image image = small_palette_image();
    std::vector<uint8_t> encoded;
    std::string error;
    auto status = japi::image::encode_blp1_palette(image, encoded, &error);
    check("encode BLP1 palette", status == japi::image::Status::Ok, error);
    const auto* header = reinterpret_cast<const japi::image::blp::Blp1Header*>(
        encoded.data());
    check("encoded magic is BLP1",
          encoded.size() >= sizeof(*header)
              && header->magic == japi::image::blp::kBlp1);
    check("encoded compression/alpha fields",
          header->compression == 1 && header->alpha_bits == 8);
    check("encoded dimensions", header->width == 64 && header->height == 64);
    bool sizes_monotonic = true;
    uint64_t expected_offset = sizeof(*header) + 256u * 4u;
    for (int i = 0; i < 7; ++i) {
        sizes_monotonic = sizes_monotonic && header->offsets[i] == expected_offset;
        expected_offset += header->sizes[i];
    }
    check("encoded mip table is contiguous", sizes_monotonic);
    check("encoded total size matches mip table",
          expected_offset == encoded.size());

    japi::image::Image decoded;
    status = japi::image::decode_blp(encoded.data(), encoded.size(), decoded,
                                     &error);
    check("decode own BLP1 palette", status == japi::image::Status::Ok, error);
    check("round-trip dimensions",
          decoded.width == 64 && decoded.height == 64);
    check("round-trip pixels are exact",
          decoded.bgra == image.bgra);

    // A 1x1 image used to produce a duplicate mip with the old loop shape.
    japi::image::Image tiny;
    tiny.width = 1;
    tiny.height = 1;
    tiny.bgra = { 1, 2, 3, 4 };
    encoded.clear();
    status = japi::image::encode_blp1_palette(tiny, encoded, &error);
    check("encode 1x1", status == japi::image::Status::Ok, error);
    const auto* tiny_header = reinterpret_cast<const japi::image::blp::Blp1Header*>(
        encoded.data());
    check("1x1 has one mip",
          tiny_header->sizes[0] == 2 && tiny_header->sizes[1] == 0);

    std::vector<uint8_t> fixture = make_blp2_palette_fixture();
    decoded.reset();
    status = japi::image::decode_blp(fixture.data(), fixture.size(), decoded,
                                     &error);
    check("decode BLP2 palette", status == japi::image::Status::Ok, error);
    check("BLP2 palette first pixel",
          decoded.valid() && decoded.bgra[0] == 0 && decoded.bgra[1] == 0
              && decoded.bgra[2] == 0 && decoded.bgra[3] == 0);
    check("BLP2 palette last pixel",
          decoded.bgra.size() >= 64
              && decoded.bgra[60] == 255 && decoded.bgra[61] == 255
              && decoded.bgra[62] == 255 && decoded.bgra[63] == 15u * 17u);

    fixture = make_blp2_raw_fixture();
    decoded.reset();
    status = japi::image::decode_blp(fixture.data(), fixture.size(), decoded,
                                     &error);
    check("decode BLP2 raw", status == japi::image::Status::Ok, error);
    check("BLP2 raw pixels",
          decoded.valid() && decoded.bgra[4] == 10 && decoded.bgra[5] == 20
              && decoded.bgra[6] == 30 && decoded.bgra[7] == 245);

    using namespace japi::image::blp;
    Blp2Header dxt{};
    dxt.magic = kBlp2;
    dxt.encoding = 2;
    dxt.width = 4;
    dxt.height = 4;
    dxt.offsets[0] = sizeof(dxt);
    dxt.sizes[0] = 8;
    std::vector<uint8_t> dxt_data(sizeof(dxt) + 8u, 0);
    std::memcpy(dxt_data.data(), &dxt, sizeof(dxt));
    status = japi::image::decode_blp(dxt_data.data(), dxt_data.size(), decoded,
                                     &error);
    check("BLP2 DXT is rejected explicitly",
          status == japi::image::Status::UnsupportedFormat, error);

    const uint8_t junk[8] = { 'N', 'O', 'T', 'B', 'L', 'P', 0, 1 };
    status = japi::image::decode_blp(junk, sizeof(junk), decoded, &error);
    check("unknown magic is rejected",
          status == japi::image::Status::UnsupportedFormat, error);

    japi::image::blp::Blp1Header huge{};
    huge.magic = japi::image::blp::kBlp1;
    huge.compression = 1;
    huge.alpha_bits = 8;
    huge.width = 16384;
    huge.height = 16384;
    huge.offsets[0] = sizeof(huge) + 256u * 4u;
    huge.sizes[0] = 0;
    std::vector<uint8_t> huge_data(sizeof(huge) + 256u * 4u, 0);
    std::memcpy(huge_data.data(), &huge, sizeof(huge));
    status = japi::image::decode_blp(huge_data.data(), huge_data.size(),
                                     decoded, &error);
    check("oversized pixel count is rejected",
          status == japi::image::Status::InvalidData, error);
}

void test_algorithms()
{
    std::cout << "-- YDWE algorithms --\n";
    uint64_t table_hash = 0xcbf29ce484222325ull;
    for (uint32_t value : japi::image::kPasButton) {
        uint8_t bytes[4] = {
            static_cast<uint8_t>(value & 0xFF),
            static_cast<uint8_t>((value >> 8) & 0xFF),
            static_cast<uint8_t>((value >> 16) & 0xFF),
            static_cast<uint8_t>((value >> 24) & 0xFF),
        };
        for (uint8_t byte : bytes) {
            table_hash ^= byte;
            table_hash *= 0x100000001b3ull;
        }
    }
    check("PasButton table hash",
          table_hash == 0xa19493d568165a8bull,
          "expected a19493d568165a8b");

    japi::image::Image source = synthetic_image(0);
    japi::image::Image disabled;
    std::string error;
    check("make_disabled_icon succeeds",
          japi::image::make_disabled_icon(source, disabled, &error), error);
    check("disabled output is 64x64 BGRA",
          disabled.valid() && disabled.width == 64 && disabled.height == 64);
    check("disabled raw hash",
          fnv1a(disabled.bgra.data(), disabled.bgra.size())
              == 0x371a53cb505799acull);
    const uint8_t* p0 = disabled.bgra.data();
    const uint8_t* p1234 = disabled.bgra.data() + 1234u * 4u;
    check("disabled pixel 0",
          p0[0] == 0 && p0[1] == 0 && p0[2] == 0 && p0[3] == 255);
    check("disabled pixel 1234",
          p1234[0] == 45 && p1234[1] == 46 && p1234[2] == 56
              && p1234[3] == 37);

    japi::image::Image too_small;
    too_small.width = 32;
    too_small.height = 32;
    too_small.bgra.assign(32u * 32u * 4u, 0);
    check("make_disabled_icon rejects non-64x64",
          !japi::image::make_disabled_icon(too_small, disabled, &error));

    japi::image::Image a = synthetic_image(0);
    japi::image::Image b = synthetic_image(1);
    japi::image::Image blended;
    check("blend_button_icons succeeds",
          japi::image::blend_button_icons(a, b, blended, &error), error);
    check("blend raw hash",
          fnv1a(blended.bgra.data(), blended.bgra.size())
              == 0x239c4012989d1fcfull);
    const uint8_t* q0 = blended.bgra.data();
    const uint8_t* q1234 = blended.bgra.data() + 1234u * 4u;
    check("blend pixel 0",
          q0[0] == 0 && q0[1] == 0 && q0[2] == 0 && q0[3] == 0);
    check("blend pixel 1234",
          q1234[0] == 169 && q1234[1] == 222 && q1234[2] == 78
              && q1234[3] == 197);

    std::vector<uint8_t> encoded;
    error.clear();
    check("encode disabled output",
          japi::image::encode_blp1_palette(disabled, encoded, &error)
              == japi::image::Status::Ok, error);
    japi::image::Image decoded;
    check("decode disabled output",
          japi::image::decode_blp(encoded.data(), encoded.size(), decoded,
                                  &error)
              == japi::image::Status::Ok, error);
    bool alpha_exact = decoded.valid()
        && decoded.bgra.size() == disabled.bgra.size();
    int max_rgb_error = 0;
    if (alpha_exact) {
        for (size_t i = 0; i < decoded.pixel_count(); ++i) {
            const uint8_t* expected = disabled.bgra.data() + i * 4u;
            const uint8_t* actual = decoded.bgra.data() + i * 4u;
            if (actual[3] != expected[3]) {
                alpha_exact = false;
                break;
            }
            for (int c = 0; c < 3; ++c) {
                const int diff = static_cast<int>(expected[c]) - actual[c];
                max_rgb_error = (std::max)(max_rgb_error, diff < 0 ? -diff : diff);
            }
        }
    }
    check("disabled round-trip keeps alpha", alpha_exact);
    check("disabled round-trip RGB error <= 16",
          max_rgb_error <= 16, "max error " + std::to_string(max_rgb_error));
}

void test_paths()
{
    std::cout << "-- archive paths --\n";
    std::string out;
    std::string error;
    check("disabled path mapping",
          japi::image::disabled_icon_archive_path(
              "ReplaceableTextures/CommandButtons/BTNFoo.blp", out, &error)
              && out == "ReplaceableTextures\\CommandButtonsDisabled\\DISBTNFoo.blp",
          out + " " + error);
    check("basename",
          japi::image::archive_basename("a/b\\c.blp") == "c.blp");
    check("normalize slashes",
          japi::image::normalize_archive_path("a//b/./c.blp", out, &error)
              && out == "a\\b\\c.blp", out + " " + error);
    check("reject parent traversal",
          !japi::image::normalize_archive_path("..\\evil.blp", out, &error));
    check("reject nested parent traversal",
          !japi::image::normalize_archive_path("a\\..\\evil.blp", out, &error));
    check("reject absolute path",
          !japi::image::normalize_archive_path("\\evil.blp", out, &error));
    check("reject drive letter",
          !japi::image::normalize_archive_path("C:\\evil.blp", out, &error));
    check("reject reserved device name",
          !japi::image::normalize_archive_path("NUL.blp", out, &error));
    check("reject reserved device name with extension",
          !japi::image::normalize_archive_path("COM1.icon.blp", out, &error));
    check("reject non-BLP disabled source",
          !japi::image::disabled_icon_archive_path("BTNFoo.tga", out, &error));
}

void test_map_preview(const std::string& root)
{
    std::cout << "-- existing BLP1 JPEG asset --\n";
    const std::string path = root + "/reference/empty-map/war3mapMap.blp";
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        std::cout << "  [SKIP] " << path << " is not present\n";
        return;
    }
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(stream)),
                               std::istreambuf_iterator<char>());
    japi::image::Image image;
    std::string error;
    const auto status = japi::image::decode_blp(
        bytes.data(), bytes.size(), image, &error);
    check("decode war3mapMap.blp (BLP1 JPEG via WIC)",
          status == japi::image::Status::Ok, error + " " + japi::image::status_name(status));
    check("war3mapMap.blp dimensions", image.width == 256 && image.height == 256,
          std::to_string(image.width) + "x" + std::to_string(image.height));
    // BLP1 JPEG with alpha is a 4-component JPEG. The correct BGRA
    // reconstruction is 255 - CMYK; a plain WIC BGRA conversion gives
    // (108,97,91,255) here and drops alpha.
    check("war3mapMap.blp first pixel is CMYK-corrected",
          image.valid() && image.bgra[0] == 53 && image.bgra[1] == 99
              && image.bgra[2] == 142 && image.bgra[3] == 255,
          image.valid() ? (std::to_string(image.bgra[0]) + ","
              + std::to_string(image.bgra[1]) + ","
              + std::to_string(image.bgra[2]) + ","
              + std::to_string(image.bgra[3])) : "invalid");
}

}  // namespace

int main(int argc, char** argv)
{
    std::string root = ".";
    if (argc > 1) root = argv[1];
    std::cout << "Button icon offline test\n";
    test_codec();
    test_algorithms();
    test_paths();
    test_map_preview(root);
    std::cout << "Button icon offline: " << g_passed << " passed, "
              << g_failed << " failed, " << (g_passed + g_failed) << " total\n";
    return g_failed == 0 ? 0 : 1;
}

// blp_format.h - BLP1/BLP2 container definitions shared by the image module.
//
// The layout constants and read_alpha() semantics mirror the decoder that
// already ships in src/d3d9/texture_asset.cpp. They live here so the
// command-button icon code can validate the same subset of BLP that the D3D
// asset cache accepts, without pulling in d3d9.h or a D3D device.
#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>

namespace japi::image::blp {

constexpr uint32_t fourcc(char a, char b, char c, char d)
{
    return static_cast<uint32_t>(static_cast<uint8_t>(a))
        | (static_cast<uint32_t>(static_cast<uint8_t>(b)) << 8)
        | (static_cast<uint32_t>(static_cast<uint8_t>(c)) << 16)
        | (static_cast<uint32_t>(static_cast<uint8_t>(d)) << 24);
}

inline constexpr uint32_t kBlp1 = fourcc('B', 'L', 'P', '1');
inline constexpr uint32_t kBlp2 = fourcc('B', 'L', 'P', '2');
inline constexpr uint32_t kMaxDimension = 16384;
// The icon path only needs 64x64, but the same decoder is used by the CLI's
// probe command. Cap the CPU decode at 16M pixels (64 MiB BGRA) so a malformed
// header cannot force a multi-gigabyte allocation on Win32.
inline constexpr uint64_t kMaxPixels = 16ull * 1024ull * 1024ull;

#pragma pack(push, 1)
struct Blp1Header {
    uint32_t magic;
    uint32_t compression;
    uint32_t alpha_bits;
    uint32_t width;
    uint32_t height;
    uint32_t picture_type;
    uint32_t picture_subtype;
    uint32_t offsets[16];
    uint32_t sizes[16];
};

struct Blp2Header {
    uint32_t magic;
    uint32_t type;
    uint8_t encoding;
    uint8_t alpha_depth;
    uint8_t alpha_encoding;
    uint8_t has_mips;
    uint32_t width;
    uint32_t height;
    uint32_t offsets[16];
    uint32_t sizes[16];
};
#pragma pack(pop)

static_assert(sizeof(Blp1Header) == 156, "unexpected BLP1 header layout");
static_assert(sizeof(Blp2Header) == 148, "unexpected BLP2 header layout");

inline bool range_inside(size_t offset, size_t length, size_t total)
{
    return offset <= total && length <= total - offset;
}

inline bool dimensions_valid(uint32_t width, uint32_t height)
{
    return width > 0 && height > 0
        && width <= kMaxDimension && height <= kMaxDimension;
}

inline bool pixel_count(uint32_t width, uint32_t height, size_t* out)
{
    if (!dimensions_valid(width, height) || !out) return false;
    const uint64_t count = static_cast<uint64_t>(width) * height;
    if (count > kMaxPixels) return false;
    if (count > (std::numeric_limits<size_t>::max)()) return false;
    *out = static_cast<size_t>(count);
    return true;
}

inline size_t alpha_byte_count(size_t pixels, uint32_t bits)
{
    if (bits == 0) return 0;
    return (pixels * bits + 7u) / 8u;
}

inline uint8_t read_alpha(const uint8_t* alpha, size_t index, uint32_t bits)
{
    if (bits == 0) return 255;
    if (bits == 1) return (alpha[index >> 3] & (1u << (index & 7))) ? 255 : 0;
    if (bits == 4) {
        const uint8_t value = (index & 1)
            ? static_cast<uint8_t>(alpha[index >> 1] >> 4)
            : static_cast<uint8_t>(alpha[index >> 1] & 0x0F);
        return static_cast<uint8_t>(value * 17u);
    }
    return alpha[index];
}

}  // namespace japi::image::blp

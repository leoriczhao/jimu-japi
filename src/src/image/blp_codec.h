// blp_codec.h - standalone BLP reader/writer used by the command-button icon
// path and its offline tooling.
//
// Decode covers the same BLP1/BLP2 subsets as src/d3d9/texture_asset.cpp:
//   BLP1 JPEG (WIC), BLP1 palette, BLP2 palette, BLP2 raw BGRA.
// BLP2 DXT is intentionally rejected here; command-button icons are BLP1 and
// decoding DXT without a D3D device would add a second, untested codec.
//
// Encode writes BLP1 palette with 8-bit alpha. That is a native 1.27a format
// (many shipped icons use it) and keeps the output byte-deterministic and
// independently verifiable; YDWE's original BlpConv wrote BLP1 JPEG q95.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace japi::image {

struct Image {
    uint32_t width = 0;
    uint32_t height = 0;
    // Row-major BGRA, four bytes per pixel. This matches the byte order of
    // YDWE's image::rgba and the BGRA buffers returned by WIC.
    std::vector<uint8_t> bgra;

    void reset()
    {
        width = 0;
        height = 0;
        bgra.clear();
    }

    size_t pixel_count() const
    {
        return static_cast<size_t>(width) * static_cast<size_t>(height);
    }

    bool valid() const
    {
        if (width == 0 || height == 0) return false;
        const uint64_t count = static_cast<uint64_t>(width) * height;
        if (count > (static_cast<uint64_t>(SIZE_MAX) / 4u)) return false;
        return bgra.size() == static_cast<size_t>(count) * 4u;
    }
};

enum class Status {
    Ok,
    InvalidData,
    UnsupportedFormat,
    DecoderUnavailable,
};

const char* status_name(Status status);

// Reads the first mip level. `error` receives a human-readable reason on
// failure and is left untouched on success.
Status decode_blp(const void* data, size_t size, Image& out,
                  std::string* error = nullptr);

// Writes a BLP1 palette image with all mip levels down to 1x1. The output is
// deterministic for identical input bytes.
Status encode_blp1_palette(const Image& in, std::vector<uint8_t>& out,
                           std::string* error = nullptr);

}  // namespace japi::image

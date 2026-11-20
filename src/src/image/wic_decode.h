// wic_decode.h - CPU-only BGRA decode for JPEG/PNG-style memory buffers.
//
// Extracted from src/d3d9/texture_asset.cpp's decode_wic_bgra so both the D3D
// asset cache and the command-button icon module use one implementation. No
// D3D device, game memory or hook is involved.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace japi::image::wic {

enum class Status {
    Ok,
    InvalidData,
    DecoderUnavailable,
};

// Decodes the first frame to 32bpp BGRA. `out` is replaced on success.
Status decode_bgra(const void* data, size_t size, std::vector<uint8_t>& out,
                   uint32_t& width, uint32_t& height);

}  // namespace japi::image::wic

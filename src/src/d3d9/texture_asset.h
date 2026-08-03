#pragma once

#include <cstddef>
#include <cstdint>

struct IDirect3DDevice9;
struct IDirect3DTexture9;

namespace d3d9_texture_asset {

enum class DecodeResult {
    Ok,
    InvalidData,
    UnsupportedFormat,
    DecoderUnavailable,
    DeviceError,
};

// Validates the container structure without touching a D3D device. This is
// deliberately conservative: accepted data must also pass create_texture.
DecodeResult validate(const void* data, size_t size);

// Creates a managed-pool texture from BMP/PNG/JPG/TGA/DDS, BLP1, or the BLP2
// palette/DXT/raw subsets used by Warcraft III assets. No temporary file is
// created and ownership of data remains with the caller.
DecodeResult create_texture(
    IDirect3DDevice9* device,
    const void* data,
    size_t size,
    IDirect3DTexture9** out_texture,
    uint32_t* out_width,
    uint32_t* out_height);

}  // namespace d3d9_texture_asset

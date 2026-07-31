#pragma once

#include <cstdint>

namespace d3d9_status {

enum : uint32_t {
    PROXY_LOADED       = 0x01,
    API_REGISTERED     = 0x02,
    REAL_D3D9_LOADED   = 0x04,
    D3D9_WRAPPED       = 0x08,
    DEVICE_WRAPPED     = 0x10,
    FRAME_RENDERED     = 0x20,
    TEXTURE_LOADED     = 0x40,
};

void set(uint32_t flags);
uint32_t get();

}  // namespace d3d9_status

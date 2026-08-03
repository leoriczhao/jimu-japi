#pragma once

#include <cstdint>

namespace d3d9_resources {

enum class ResourceType : uint32_t {
    Font = 1,
    Text = 2,
    Texture = 3,
};

struct ResourceCounts {
    uint32_t fonts;
    uint32_t texts;
    uint32_t textures;
};

// Starts an explicit SDK session. Returns zero while another session is active.
uint32_t begin_session();

// Legacy bridge calls lazily share one implicit session with the SDK resource
// manager. This keeps old handlers and the versioned ABI on one registry.
uint32_t ensure_session();

uint32_t active_session();
bool invalidate_session(uint32_t session);

uint32_t allocate(ResourceType type);
bool release(uint32_t handle, ResourceType expected_type);
bool validate(uint32_t handle, ResourceType expected_type, uint32_t session = 0);
ResourceType handle_type(uint32_t handle);
ResourceCounts counts();

}  // namespace d3d9_resources

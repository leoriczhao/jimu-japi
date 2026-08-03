#include "resource_manager.h"

#include <array>
#include <vector>

namespace {

constexpr uint32_t kSlotMask = 0xFFFFu;
constexpr uint32_t kGenerationMask = 0x3FFFu;
constexpr uint32_t kGenerationShift = 16u;
constexpr uint32_t kTypeShift = 30u;
constexpr uint32_t kMaxSlots = kSlotMask;

struct Slot {
    uint16_t generation = 1;
    uint32_t session = 0;
    bool alive = false;
};

struct TypeRegistry {
    TypeRegistry()
    {
        slots.emplace_back();  // slot zero is always invalid
    }

    std::vector<Slot> slots;
    std::vector<uint16_t> free_slots;
    uint32_t alive_count = 0;
};

std::array<TypeRegistry, 3> g_registries;
uint32_t g_active_session = 0;
uint32_t g_next_session = 1;

size_t registry_index(d3d9_resources::ResourceType type)
{
    const uint32_t raw = static_cast<uint32_t>(type);
    return raw >= 1 && raw <= 3 ? static_cast<size_t>(raw - 1) : 3u;
}

uint16_t next_generation(uint16_t current)
{
    // Never wrap a slot back to an old generation: retire it at the maximum
    // and allocate a fresh slot. This prevents a very old userdata from ever
    // aliasing a new object after enough create/destroy cycles.
    if (current >= kGenerationMask) return 0;
    return static_cast<uint16_t>(current + 1u);
}

uint32_t encode(d3d9_resources::ResourceType type, uint16_t generation, uint16_t slot)
{
    return (static_cast<uint32_t>(type) << kTypeShift)
        | (static_cast<uint32_t>(generation) << kGenerationShift)
        | slot;
}

}  // namespace

namespace d3d9_resources {

uint32_t begin_session()
{
    if (g_active_session != 0) return 0;
    if (g_next_session == 0) ++g_next_session;
    g_active_session = g_next_session++;
    return g_active_session;
}

uint32_t ensure_session()
{
    if (g_active_session == 0) begin_session();
    return g_active_session;
}

uint32_t active_session()
{
    return g_active_session;
}

bool invalidate_session(uint32_t session)
{
    if (session == 0 || session != g_active_session) return false;

    for (auto& registry : g_registries) {
        for (uint32_t i = 1; i < registry.slots.size(); ++i) {
            Slot& slot = registry.slots[i];
            if (!slot.alive) continue;
            slot.alive = false;
            slot.session = 0;
            slot.generation = next_generation(slot.generation);
            if (slot.generation != 0) {
                registry.free_slots.push_back(static_cast<uint16_t>(i));
            }
        }
        registry.alive_count = 0;
    }

    g_active_session = 0;
    return true;
}

uint32_t allocate(ResourceType type)
{
    const size_t index = registry_index(type);
    if (index >= g_registries.size()) return 0;
    const uint32_t session = ensure_session();
    if (session == 0) return 0;

    TypeRegistry& registry = g_registries[index];
    uint16_t slot_index = 0;
    if (!registry.free_slots.empty()) {
        slot_index = registry.free_slots.back();
        registry.free_slots.pop_back();
    } else {
        if (registry.slots.size() > kMaxSlots) return 0;
        slot_index = static_cast<uint16_t>(registry.slots.size());
        registry.slots.emplace_back();
    }

    Slot& slot = registry.slots[slot_index];
    slot.alive = true;
    slot.session = session;
    ++registry.alive_count;
    return encode(type, slot.generation, slot_index);
}

bool release(uint32_t handle, ResourceType expected_type)
{
    if (!validate(handle, expected_type)) return false;
    TypeRegistry& registry = g_registries[registry_index(expected_type)];
    const uint16_t slot_index = static_cast<uint16_t>(handle & kSlotMask);
    Slot& slot = registry.slots[slot_index];
    slot.alive = false;
    slot.session = 0;
    slot.generation = next_generation(slot.generation);
    if (slot.generation != 0) {
        registry.free_slots.push_back(slot_index);
    }
    --registry.alive_count;
    return true;
}

bool validate(uint32_t handle, ResourceType expected_type, uint32_t session)
{
    if (handle == 0 || handle_type(handle) != expected_type) return false;
    const size_t index = registry_index(expected_type);
    if (index >= g_registries.size()) return false;

    const uint16_t slot_index = static_cast<uint16_t>(handle & kSlotMask);
    const uint16_t generation = static_cast<uint16_t>(
        (handle >> kGenerationShift) & kGenerationMask);
    const TypeRegistry& registry = g_registries[index];
    if (slot_index == 0 || slot_index >= registry.slots.size()) return false;

    const Slot& slot = registry.slots[slot_index];
    const uint32_t required_session = session == 0 ? g_active_session : session;
    return required_session != 0
        && slot.alive
        && slot.generation == generation
        && slot.session == required_session;
}

ResourceType handle_type(uint32_t handle)
{
    return static_cast<ResourceType>(handle >> kTypeShift);
}

ResourceCounts counts()
{
    return ResourceCounts{
        g_registries[0].alive_count,
        g_registries[1].alive_count,
        g_registries[2].alive_count,
    };
}

}  // namespace d3d9_resources

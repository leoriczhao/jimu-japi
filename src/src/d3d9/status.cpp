#include "status.h"

#include <atomic>

namespace {
std::atomic<uint32_t> g_status{0};
}

namespace d3d9_status {

void set(uint32_t flags)
{
    g_status.fetch_or(flags, std::memory_order_relaxed);
}

uint32_t get()
{
    return g_status.load(std::memory_order_relaxed);
}

}  // namespace d3d9_status

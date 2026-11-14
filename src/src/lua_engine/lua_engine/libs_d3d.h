#pragma once

#include <cstdint>

struct lua_State;

namespace warcraft3::lua_engine::d3d {

enum class InputKind : uint32_t {
    KeyDown,
    KeyUp,
    MouseDown,
    MouseUp,
};

// Called by the shared Warcraft message filter. This only captures immutable
// input data; Lua callbacks are dispatched later by the SDK timer tick.
void queue_input_event(InputKind kind, int32_t code, float x, float y);
bool has_active_subscriptions();

int open(lua_State* L);

}  // namespace warcraft3::lua_engine::d3d

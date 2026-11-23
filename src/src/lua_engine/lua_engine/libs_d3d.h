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

// Provide the runtime-extracted newD3d9 module handle when D3D was attached
// in-process (zero-restart path) instead of pre-installed as d3d9.dll.
void set_runtime_d3d_module(void* hmod);

// Map-boot VM reset hooks: called before / after lua_close() so the SDK
// timer, pending input and subscriptions never outlive their Lua state.
void prepare_vm_reset(bool jass_engine_alive);
void reset_vm_state();

}  // namespace warcraft3::lua_engine::d3d

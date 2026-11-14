#pragma once

struct lua_State;

namespace warcraft3::lua_engine::message {

void ensure_input_dispatch(lua_State* L);
void release_input_dispatch();
bool get_client_cursor(float* out_x, float* out_y);
void poll_input_devices();
void reset_vm_state();

}  // namespace warcraft3::lua_engine::message

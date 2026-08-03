cmake_minimum_required(VERSION 3.15)
project(yd_japi LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Build Lua 5.4 as static library
file(GLOB LUA_SOURCES "${CMAKE_SOURCE_DIR}/vendor/lua-5.4/src/*.c")
list(REMOVE_ITEM LUA_SOURCES
    "${CMAKE_SOURCE_DIR}/vendor/lua-5.4/src/lua.c"
    "${CMAKE_SOURCE_DIR}/vendor/lua-5.4/src/luac.c"
)
add_library(lua54 STATIC ${LUA_SOURCES})
target_include_directories(lua54 PUBLIC "${CMAKE_SOURCE_DIR}/vendor/lua-5.4/src")
# LUA_BUILD_AS_DLL: export the whole Lua C API from yd_japi.dll so that
# luadebug.dll's init() can auto-resolve the host API via
# GetProcAddress(yd_japi.dll, "lua_newstate") (see docs/planning/LUA-DEBUGGER-DESIGN.md)
target_compile_definitions(lua54 PRIVATE LUA_USE_WINDOWS LUA_BUILD_AS_DLL)

# yd_core (from ydwar3)
set(YD_CORE_SOURCES
    src/yd_core/warcraft3/jass.cpp
    src/yd_core/warcraft3/hashtable.cpp
    src/yd_core/warcraft3/war3_searcher.cpp
    src/yd_core/warcraft3/basic_searcher.cpp
    src/yd_core/warcraft3/event.cpp
    src/yd_core/warcraft3/jass/func_value.cpp
    src/yd_core/warcraft3/jass/hook.cpp
    src/yd_core/warcraft3/jass/inline_hook.cpp
    src/yd_core/warcraft3/jass/nf_register.cpp
    src/yd_core/warcraft3/jass/opcode.cpp
    src/yd_core/warcraft3/jass/global_variable.cpp
    src/yd_core/warcraft3/jass/trampoline.cpp
    src/yd_core/warcraft3/jass/trampoline_function.cpp
    src/yd_core/warcraft3/player.cpp
    src/yd_core/warcraft3/message_dispatch.cpp
    src/yd_core/warcraft3/detail/string_hash.cpp
    # udis86 disassembler (needed by basic_searcher)
    src/yd_core/warcraft3/udis86/udis86.c
    src/yd_core/warcraft3/udis86/udis86_decode.c
    src/yd_core/warcraft3/udis86/udis86_itab.c
)

# lua_engine (from yd_lua_engine)
set(LUA_ENGINE_SOURCES
    src/lua_engine/lua_engine/callback.cpp
    src/lua_engine/lua_engine/class_real.cpp
    src/lua_engine/lua_engine/class_handle.cpp
    src/lua_engine/lua_engine/class_array.cpp
    src/lua_engine/lua_engine/common.cpp
    src/lua_engine/lua_engine/jassbind.cpp
    src/lua_engine/lua_engine/lua_loader.cpp
    src/lua_engine/lua_engine/open_lua_engine.cpp
    src/lua_engine/lua_engine/storm.cpp
    src/lua_engine/lua_engine/libs_common.cpp
    src/lua_engine/lua_engine/libs_globals.cpp
    src/lua_engine/lua_engine/libs_hook.cpp
    src/lua_engine/lua_engine/libs_japi.cpp
    src/lua_engine/lua_engine/libs_runtime.cpp
    src/lua_engine/lua_engine/libs_debug.cpp
    src/lua_engine/lua_engine/libs_message.cpp
    src/lua_engine/lua_engine/libs_storm.cpp
    src/lua_engine/lua_engine/libs_sleep.cpp
    src/lua_engine/lua_engine/libs_slk.cpp
    src/lua_engine/lua_engine/libs_debugger.cpp
    src/lua_engine/lua_engine/libs_d3d.cpp
    src/lua_engine/lua_engine/fix_baselib.cpp
    src/lua_engine/lua_engine/bridge_dispatch.cpp
)

# SlkLib (from YDWE SlkLib, read-only MPQ access)
set(SLK_SOURCES
    src/slk/ObjectManager.cpp
    src/slk/Converter.cpp
    src/slk/table/VariableData.cpp
    src/slk/reader/CommonReader.cpp
    src/slk/reader/SlkReader.cpp
    src/slk/reader/MetaReader.cpp
    src/slk/reader/TxtReader.cpp
    src/slk/reader/ObjReader.cpp
    src/slk/reader/IniReader.cpp
    src/slk/reader/WtsReader.cpp
    src/slk/reader/WesReader.cpp
    src/slk/converter/AttributeMeta.cpp
    src/slk/converter/ConvertTable.cpp
)

set(EXT_SOURCES
    src/extensions/dllmain.cpp
    src/extensions/custom_natives.cpp
    src/extensions/ex_natives/Initialize.cpp
    src/extensions/ex_natives/UnitState.cpp
    src/extensions/ex_natives/GameInfo.cpp
    src/extensions/ex_natives/CodeRunLogs.cpp
    src/extensions/ex_natives/AbilityState.cpp
    src/extensions/ex_natives/ItemState.cpp
    src/extensions/ex_natives/Effect.cpp
    src/extensions/ex_natives/EventDamageData.cpp
    src/extensions/ex_natives/DisplayChat.cpp
    src/extensions/ex_natives/GameUI.cpp
    src/stubs.cpp
)

add_library(yd_japi SHARED
    ${YD_CORE_SOURCES}
    ${LUA_ENGINE_SOURCES}
    ${SLK_SOURCES}
    ${EXT_SOURCES}
)

target_include_directories(yd_japi PRIVATE
    "${CMAKE_SOURCE_DIR}/src"
    "${CMAKE_SOURCE_DIR}/src/yd_core"
    "${CMAKE_SOURCE_DIR}/vendor/lua-5.4/src"
    "${CMAKE_SOURCE_DIR}/vendor/bee-lua"
)

target_link_libraries(yd_japi PRIVATE lua54)

target_compile_definitions(yd_japi PRIVATE
    YDWE_WAR3_INLINE
    YDWE_BASE_INLINE
    SLKLIB_INLINE
    WIN32
    _WINDOWS
    _CRT_SECURE_NO_WARNINGS
    _SILENCE_ALL_CXX17_DEPRECATION_WARNINGS
)

# Debug logging (console + async file). Comment out for release.
target_compile_definitions(yd_japi PRIVATE JAPI_DEBUG)

if(MSVC)
    target_compile_options(yd_japi PRIVATE /W3 /EHsc)
    target_link_options(yd_japi PRIVATE /SAFESEH:NO)
endif()

set_target_properties(yd_japi PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    PREFIX ""
    SUFFIX ".dll"
)

# ===========================================================================
# newD3d9.dll — D3D9 proxy for War3 rendering overlay
# ===========================================================================
# This is a SEPARATE DLL from yd_japi.dll. It acts as a D3D9 proxy that
# War3 loads instead of the real d3d9.dll. It hooks EndScene for custom
# text/texture rendering and provides the d3d.* JASS API handlers.
#
# yd_japi.dll calls InitializeD3DAPI() to register the handlers with
# its UnitId bridge dispatch.

set(D3D9_SOURCES
    src/d3d9/dllmain.cpp
    src/d3d9/CDirect3D9.cpp
    src/d3d9/CDirect3DDevice9.cpp
    src/d3d9/d3dx9_font_abi.h
    src/d3d9/texture_asset.h
    src/d3d9/texture_asset.cpp
    src/d3d9/renderer.cpp
    src/d3d9/resource_manager.cpp
    src/d3d9/sdk_api.cpp
    src/d3d9/api.cpp
    src/d3d9/status.cpp
    src/d3d9/newD3d9.def
)

add_library(newD3d9 SHARED ${D3D9_SOURCES})

target_link_libraries(newD3d9 PRIVATE windowscodecs ole32)

target_include_directories(newD3d9 PRIVATE
    "${CMAKE_SOURCE_DIR}/src"
    "${CMAKE_SOURCE_DIR}/src/d3d9"
)

target_compile_definitions(newD3d9 PRIVATE
    WIN32
    _WINDOWS
    _CRT_SECURE_NO_WARNINGS
)

# The real Direct3DCreate9 entry is resolved from the absolute system DLL path.
# Do not import d3d9.dll here: this target is the proxy named d3d9.dll at deploy time.

if(MSVC)
    target_compile_options(newD3d9 PRIVATE /W3 /EHsc)
    target_link_options(newD3d9 PRIVATE /SAFESEH:NO)
endif()

set_target_properties(newD3d9 PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
    PREFIX ""
    SUFFIX ".dll"
)

# Native ABI/lifecycle contract harness. It loads the built proxy dynamically,
# so the test exercises the exported C boundary instead of linking internals.
add_executable(d3d_sdk_contract_test
    tests/d3d_sdk_contract_test.cpp
)
target_include_directories(d3d_sdk_contract_test PRIVATE
    "${CMAKE_SOURCE_DIR}/src/d3d9"
)
add_dependencies(d3d_sdk_contract_test newD3d9)
set_target_properties(d3d_sdk_contract_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

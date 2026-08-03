#pragma once

#include <windows.h>
#include "keyboard_code.h"

namespace warcraft3::input {

// WARK_* values are the builtin-japi keyboard ABI, not Win32 virtual-key
// values.  Keep this conversion in one header shared by yd_japi and the D3D
// compatibility surface so the two paths cannot drift again.
constexpr int wark_to_vk(int wark)
{
    if (wark == WARK_SPACE) return VK_SPACE;
    if (wark >= WARK_0 && wark <= WARK_9) return wark;
    if (wark >= WARK_A && wark <= WARK_Z) return wark;
    if (wark == WARK_SHIFT) return VK_SHIFT;
    if (wark == WARK_CTRL) return VK_CONTROL;
    if (wark == WARK_ALT) return VK_MENU;

    if (wark >= WARK_NUMPAD0 && wark <= WARK_NUMPAD9) {
        return VK_NUMPAD0 + (wark - WARK_NUMPAD0);
    }
    if (wark == WARK_ADD) return VK_ADD;
    if (wark == WARK_SUBTRACT) return VK_SUBTRACT;
    if (wark == WARK_MULTIPLY) return VK_MULTIPLY;
    if (wark == WARK_DIVIDE) return VK_DIVIDE;
    if (wark == WARK_DECIMAL) return VK_DECIMAL;

    if (wark == WARK_TILDE) return VK_OEM_3;
    if (wark == WARK_OEM_PLUS) return VK_OEM_PLUS;
    if (wark == WARK_OEM_MINUS) return VK_OEM_MINUS;
    if (wark == WARK_OEM_OBRACKE) return VK_OEM_4;
    if (wark == WARK_OEM_CBRACKE) return VK_OEM_6;
    if (wark == WARK_OEM_BACKSLASH) return VK_OEM_5;
    if (wark == WARK_OEM_SEMICOLON) return VK_OEM_1;
    if (wark == WARK_OEM_SQUOTMARKS) return VK_OEM_7;
    if (wark == WARK_OEM_COMMA) return VK_OEM_COMMA;
    if (wark == WARK_OEM_PERIOD) return VK_OEM_PERIOD;
    if (wark == WARK_OEM_SLASH) return VK_OEM_2;

    if (wark == WARK_ESC) return VK_ESCAPE;
    if (wark == WARK_ENTER) return VK_RETURN;
    if (wark == WARK_BACKSPACE) return VK_BACK;
    if (wark == WARK_TAB) return VK_TAB;
    if (wark == WARK_RIGHT) return VK_RIGHT;
    if (wark == WARK_UP) return VK_UP;
    if (wark == WARK_LEFT) return VK_LEFT;
    if (wark == WARK_DOWN) return VK_DOWN;
    if (wark == WARK_INSERT) return VK_INSERT;
    if (wark == WARK_DELETE) return VK_DELETE;
    if (wark == WARK_HOME) return VK_HOME;
    if (wark == WARK_END) return VK_END;
    if (wark == WARK_PAGEUP) return VK_PRIOR;
    if (wark == WARK_PAGEDOWN) return VK_NEXT;
    if (wark == WARK_CAPSLOCK) return VK_CAPITAL;
    if (wark == WARK_NUMLOCK) return VK_NUMLOCK;
    if (wark == WARK_SCROLLLOCK) return VK_SCROLL;
    if (wark == WARK_PAUSE) return VK_PAUSE;
    if (wark == WARK_PRINTSCREEN) return VK_SNAPSHOT;

    if (wark >= WARK_F1 && wark <= WARK_F12) {
        return VK_F1 + (wark - WARK_F1);
    }
    return 0;
}

static_assert(wark_to_vk(WARK_SHIFT) == VK_SHIFT, "modifier mapping");
static_assert(wark_to_vk(WARK_RIGHT) == VK_RIGHT, "navigation mapping");
static_assert(wark_to_vk(WARK_F12) == VK_F12, "function-key mapping");
static_assert(wark_to_vk(WARK_OEM_SLASH) == VK_OEM_2, "OEM mapping");
static_assert(wark_to_vk(WARK_NUMPAD9) == VK_NUMPAD9, "numpad mapping");
static_assert(wark_to_vk(WARK_Q) == 'Q', "ASCII mapping");
static_assert(wark_to_vk(-1) == 0, "invalid mapping");

}  // namespace warcraft3::input

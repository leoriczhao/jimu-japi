-- 示例 09 · JASS 扩展 native wrapper 与 jass.japi
-- 用途：打包时传入 --with-jass-wrappers 可在 war3map.j 中生成扩展 native 的 JASS 包装函数，
--       Lua 侧可直接通过 require "jass.japi" 调用同名扩展 native。
-- 打包：japi build examples/09-jass-wrappers --with-jass-wrappers
-- 运行：japi run   examples/09-jass-wrappers --with-jass-wrappers

local jass = require "jass.common"
local japi = require "jass.japi"

local t = jass.CreateTimer()
jass.TimerStart(t, 0.5, false, function()
    jass.DestroyTimer(t)

    local game_ver = japi.GetGameVersion()
    local plugin_ver = japi.GetPluginVersion()
    local hex_255 = japi.Hex(255)

    jass.DisplayTimedTextToPlayer(
        jass.GetLocalPlayer(), 0.0, 0.0, 8.0,
        string.format(
            "|cFF00FFCC[JAPI]|r GameVersion=%s, Plugin=%s, Hex(255)=%s",
            tostring(game_ver), tostring(plugin_ver), tostring(hex_255)
        )
    )
end)

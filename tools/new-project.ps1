#Requires -Version 5.1
<#
.SYNOPSIS
    Scaffold a new japi Lua SDK map project.

.DESCRIPTION
    Creates a map project that tools/pack.ps1 can turn into a .w3x:

        war3map.lua               entry point (requires the modules below)
        lib/util.lua              after() / fourcc() / clamp() / log()
        lib/check.lua             check() / skip() / finish() + the Results line
        tests/smoke.lua           9 engine checks that run ~1 s after map start
        config.lua                project config table (hud / tick / debug)
        config.local.lua.example  template for the gitignored local overrides
        base-map/                 verbatim copy of the base map
        README.md                 layout, the three commands, troubleshooting
        .gitignore

    The scaffold never launches Warcraft III and never edits tools/pack.ps1 or
    tools/deploy.ps1: it writes files and prints the exact commands to run next.

.PARAMETER Name
    Project directory name: letters, digits, '_' and '-' only.

.PARAMETER Path
    Parent directory that receives the project directory. Created when it does
    not exist yet. Default: the current directory.

.PARAMETER Base
    Base map. Either a directory of unpacked map sources (copied verbatim into
    <project>\base-map) or a .w3m/.w3x file (copied to
    <project>\base-map\base.w3m|.w3x - that file is what -BaseMap must point at).
    Default: <repo>\reference\empty-map.

.PARAMETER Force
    Required when the project directory already exists and is not empty.
    Scaffold files and the base-map copy are regenerated; any other file you
    added to the project is left untouched.

.EXAMPLE
    .\tools\new-project.ps1 -Name MyMap -Path ..\my-maps

.EXAMPLE
    .\tools\new-project.ps1 -Name MyMap -Base reference\vanilla_map -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Name,

    [string]$Path = ".",

    [string]$Base = "",

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Generated files use CRLF, like the rest of the repository, no matter how this
# script itself was checked out.
$LF = [string][char]10
$CRLF = [string][char]13 + [string][char]10

$script:RepoRoot = ''
$script:TargetDir = ''
$script:WrittenFiles = New-Object System.Collections.ArrayList

$AsciiEncoding = New-Object System.Text.ASCIIEncoding
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Normalize a here-string template: drop the line break that follows @' and use
# CRLF line endings.
function Get-ScaffoldText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $text = $Text.Replace($CRLF, $LF)
    if ($text.StartsWith($LF)) { $text = $text.Substring(1) }
    if (-not $text.EndsWith($LF)) { $text += $LF }
    return $text.Replace($LF, $CRLF)
}

function New-ScaffoldDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
}

# Repository-relative path when the target lives inside the repo, absolute
# otherwise. Keeps the printed commands short for the common case.
function Get-DisplayPath {
    param([Parameter(Mandatory = $true)][string]$FullPath)

    $prefix = $script:RepoRoot + "\"
    if ($FullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($prefix.Length)
    }
    return $FullPath
}

# '../../..' prefix that turns <repo>\docs\... into a path valid from $ToDir.
# Returns $null when the two paths cannot be related (different drive).
function Get-RepoRelativePrefix {
    param([Parameter(Mandatory = $true)][string]$FromDir, [Parameter(Mandatory = $true)][string]$ToDir)

    $fromParts = $FromDir.TrimEnd([char]92) -split '\\'
    $toParts = $ToDir.TrimEnd([char]92) -split '\\'
    if ($fromParts[0] -ne $toParts[0]) { return $null }

    $shared = 0
    while ($shared -lt $fromParts.Count -and $shared -lt $toParts.Count -and $fromParts[$shared] -eq $toParts[$shared]) {
        $shared = $shared + 1
    }

    $prefix = ''
    for ($i = 0; $i -lt ($toParts.Count - $shared); $i++) {
        $prefix = $prefix + '../'
    }
    return $prefix
}

# Writes one generated file and records it. Generated Lua/config files stay
# ASCII: the engine reads them as bytes, and a stray non-ASCII character would
# only ever show up as a mystery in game. README.md is UTF-8 without a BOM.
function Write-ScaffoldFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Text,
        [switch]$Utf8
    )

    $full = Join-Path $script:TargetDir $RelativePath
    $parent = Split-Path -Parent $full
    if ($parent) { New-ScaffoldDirectory $parent }

    if ($Utf8) {
        [System.IO.File]::WriteAllText($full, $Text, $Utf8NoBom)
    } else {
        if ($Text -match '[^\x00-\x7F]') {
            throw ("Internal error: generated file '" + $RelativePath + "' contains non-ASCII characters.")
        }
        [System.IO.File]::WriteAllText($full, $Text, $AsciiEncoding)
    }

    Write-Host ("  + " + $RelativePath)
    [void]$script:WrittenFiles.Add($RelativePath)
}

function Write-ScaffoldTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Template,
        [System.Collections.Hashtable]$Tokens,
        [switch]$Utf8
    )

    $text = Get-ScaffoldText $Template
    if ($Tokens) {
        foreach ($key in @($Tokens.Keys)) {
            $text = $text.Replace($key, [string]$Tokens[$key])
        }
    }
    Write-ScaffoldFile -RelativePath $RelativePath -Text $text -Utf8:$Utf8
}

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Base) {
    $Base = Join-Path $script:RepoRoot "reference\empty-map"
}

if ($Name -ne $Name.Trim()) {
    throw ("Invalid project name '" + $Name + "': leading or trailing whitespace.")
}
if ($Name -eq '.' -or $Name -eq '..') {
    throw ("Invalid project name '" + $Name + "'.")
}
if ($Name -notmatch '^[A-Za-z0-9_-]+$') {
    throw ("Invalid project name '" + $Name + "': use only A-Z, a-z, 0-9, '_' and '-' (no spaces, dots or path separators).")
}

if (-not (Test-Path -LiteralPath $Path)) {
    New-ScaffoldDirectory $Path
    Write-Host ("Created directory: " + $Path)
}
if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw ("Path is not a directory: " + $Path)
}
$parentDir = (Resolve-Path -LiteralPath $Path).Path

if (-not (Test-Path -LiteralPath $Base)) {
    throw ("Base map not found: " + $Base + "  (pass -Base <unpacked map dir | .w3m | .w3x>; the default is <repo>\reference\empty-map)")
}
$baseItem = Get-Item -LiteralPath $Base -Force
$baseIsDir = $baseItem.PSIsContainer
$baseFileName = ''
if (-not $baseIsDir) {
    $baseExtension = [System.IO.Path]::GetExtension($baseItem.Name).ToLowerInvariant()
    if ($baseExtension -ne '.w3m' -and $baseExtension -ne '.w3x') {
        throw ("Base map file must be .w3m or .w3x: " + $baseItem.FullName)
    }
    $baseFileName = 'base' + $baseExtension
}

$script:TargetDir = Join-Path $parentDir $Name

$existingItems = @()
if (Test-Path -LiteralPath $script:TargetDir) {
    if (-not (Test-Path -LiteralPath $script:TargetDir -PathType Container)) {
        throw ("Target already exists and is not a directory: " + $script:TargetDir)
    }
    $existingItems = @(Get-ChildItem -LiteralPath $script:TargetDir -Force)
    if ($existingItems.Count -gt 0 -and -not $Force) {
        throw ("Target directory already exists and is not empty: " + $script:TargetDir + "  (pass -Force to regenerate the scaffold)")
    }
}

$baseKindText = 'unpacked map sources'
if (-not $baseIsDir) { $baseKindText = 'map file' }

Write-Host ""
Write-Host "new-project: scaffolding a japi Lua SDK map project"
Write-Host ("  name      : " + $Name)
Write-Host ("  target    : " + $script:TargetDir)
Write-Host ("  base map  : " + $baseItem.FullName + " (" + $baseKindText + ")")
Write-Host ("  repo root : " + $script:RepoRoot)
Write-Host ""

# ---------------------------------------------------------------------------
# base map copy
# ---------------------------------------------------------------------------

New-ScaffoldDirectory $script:TargetDir

$baseMapDir = Join-Path $script:TargetDir "base-map"

# base-map is always a derived copy of -Base. With -Force the previous copy is
# removed first, so switching base maps cannot leave stale MPQ entries behind.
if (Test-Path -LiteralPath $baseMapDir) {
    Remove-Item -LiteralPath $baseMapDir -Recurse -Force
    Write-Host "  - removed the previous base-map copy"
}
New-ScaffoldDirectory $baseMapDir

if ($baseIsDir) {
    Get-ChildItem -LiteralPath $baseItem.FullName -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $baseMapDir -Recurse -Force
    }
    $copied = @(Get-ChildItem -LiteralPath $baseMapDir -Recurse -Force | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)
    foreach ($file in $copied) {
        $relative = $file.FullName.Substring($script:TargetDir.Length + 1)
        Write-Host ("  + " + $relative)
        [void]$script:WrittenFiles.Add($relative)
    }
    Write-Host ("  (" + $copied.Count + " base map files)")
} else {
    Copy-Item -LiteralPath $baseItem.FullName -Destination (Join-Path $baseMapDir $baseFileName) -Force
    $relative = "base-map\" + $baseFileName
    Write-Host ("  + " + $relative)
    [void]$script:WrittenFiles.Add($relative)
    Write-Host ("  (1 base map file, " + $baseItem.Length + " bytes)")
}

# What -BaseMap has to point at: the unpacked directory, or the map file itself
# (tools/pack.ps1 only unpacks a *file* base; a directory is copied as-is).
$baseMapArg = $baseMapDir
if (-not $baseIsDir) {
    $baseMapArg = Join-Path $baseMapDir $baseFileName
}

# ---------------------------------------------------------------------------
# templates: entry point + lib
# ---------------------------------------------------------------------------

$war3mapTemplate = @'
--[[ ==========================================================================
  @@PROJECT@@ - war3map.lua (entry point, loaded by the japi Lua engine)

  tools/pack.ps1 inlines every `require "module"` line that starts at column 0
  into this file, so the modules below end up inside the packed war3map.lua and
  need no file system at run time. The `jass.*` modules are C modules provided
  by yd_japi.dll and are left alone. Keep the requires at column 0: an indented
  or commented-out require is not inlined and will fail in game.

  require RETURNS the module table, it does not create a global of the same
  name: bind every module you use to a local. A bare `require "jass.globals"`
  leaves the global `globals` nil, so the first `globals.x = ...` line dies
  with "attempt to index a nil value (global 'globals')".
============================================================================= ]]

-- Built-in C modules, bound to locals (see the note about require above).
local jass    = require "jass.common"
local globals = require "jass.globals"
local runtime = require "jass.runtime"

local util = require "lib.util"
local chk = require "lib.check"
local config = require "config"
local smoke = require "tests.smoke"

-- Tell the JASS side (and any other script) that the Lua VM is up. Base maps
-- that do not declare udg_lua_japi_alive in war3map.j simply ignore the write.
globals.udg_lua_japi_alive = 1

print("")
print(string.format("[@@PROJECT@@] Lua engine is alive (jass.runtime %s)", tostring(runtime.version)))
print(string.format("[@@PROJECT@@] local player id = %d", jass.GetPlayerId(jass.GetLocalPlayer())))
print(string.format("[@@PROJECT@@] config: hud=%s tick=%s debug=%s",
    tostring(config.hud), tostring(config.tick), tostring(config.debug)))

-- Run the scaffold smoke test once the map has settled, then announce that the
-- project is ready for real code.
util.after(1.0, function()
    smoke.run()
end)

util.after(1.5, function()
    print("[@@PROJECT@@] ready - edit war3map.lua to start building")
end)

-- What to write next (see README.md and docs/guide/SDK-QUICKSTART.md):
--   1. add game logic to war3map.lua (timers, triggers, units) or to lib/,
--   2. copy real checks into tests/smoke.lua - tools/deploy.ps1 waits for the
--      "Results: N passed, M failed, T total" line that lib.check prints,
--   3. turn config.hud on and draw with jass.d3d (docs/guide/D3D-LUA-API.md),
--   4. read docs/STATUS.md before relying on an API the SDK marks as untested.
'@

$utilTemplate = @'
--[[ ==========================================================================
  lib/util.lua - small helpers shared by the map scripts.

  Loaded as: local util = require "lib.util"
============================================================================= ]]

local jass = require "jass.common"

local util = {}

--- Run fn once after a delay, in game seconds. The timer is destroyed before fn
-- runs, so fn may create new timers freely.
function util.after(seconds, fn)
    local timer = jass.CreateTimer()
    jass.TimerStart(timer, seconds, false, function()
        jass.DestroyTimer(timer)
        local ok, err = pcall(fn)
        if not ok then
            print("  [ERR ] delayed callback failed: " .. tostring(err))
        end
    end)
    return timer
end

--- FourCC string ('hfoo') to its integer id (0x68666F6F). Returns 0 when the
-- string is shorter than four characters.
function util.fourcc(text)
    local a, b, c, d = string.byte(text, 1, 4)
    if not d then
        return 0
    end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

--- Clamp value into [low, high].
function util.clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

--- string.format + print, prefixed so map output is easy to find in the log.
function util.log(fmt, ...)
    print("[map] " .. string.format(fmt, ...))
end

return util
'@

$checkTemplate = @'
--[[ ==========================================================================
  lib/check.lua - the smallest test harness that tools/deploy.ps1 understands.

  Usage:
      local chk = require "lib.check"
      chk.check("name", function() assert(1 + 1 == 2) end)
      chk.skip("name", "why this cannot run here")
      chk.finish("smoke")

  finish() prints one line of the form
      Results: N passed, M failed, T total (K skipped)
  which is exactly what tools/deploy.ps1 greps for in the engine log.
============================================================================= ]]

local chk = {}

local pass, fail, skipped = 0, 0, 0

--- Run one named check. Anything thrown (including a failed assert) counts as
-- a failure and does not stop the remaining checks.
function chk.check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("  [PASS] " .. name)
    else
        fail = fail + 1
        print("  [FAIL] " .. name .. " : " .. tostring(err))
    end
end

--- Record a check that cannot run on this map/install, without failing.
function chk.skip(name, why)
    skipped = skipped + 1
    print("  [SKIP] " .. name .. " : " .. tostring(why))
end

--- Print the summary line for the whole run. tag is an optional label.
function chk.finish(tag)
    local total = pass + fail + skipped
    if tag and tag ~= "" then
        print("[" .. tag .. "] " .. total .. " checks")
    end
    print(string.format(" Results: %d passed, %d failed, %d total (%d skipped)", pass, fail, total, skipped))
    if fail == 0 then
        print(string.format(" ALL CHECKS PASSED (%d/%d)", pass, total))
    else
        print(string.format(" SOME CHECKS FAILED (%d of %d)", fail, total))
    end
end

return chk
'@

# ---------------------------------------------------------------------------
# templates: tests + config + gitignore
# ---------------------------------------------------------------------------

$smokeTemplate = @'
--[[ ==========================================================================
  tests/smoke.lua - the checks every project should pass once yd_japi.dll is up.

  war3map.lua calls run() about one second after the map starts. The checks use
  only natives that this SDK already exercises, so a failure here means the
  install or the base map is wrong, not that your code is wrong.

  Every module is bound to a local here: require returns the module, it does
  not create a global (that is why `globals` below is a local, not `_G.globals`).
============================================================================= ]]

local jass = require "jass.common"
local runtime = require "jass.runtime"
local globals = require "jass.globals"
local util = require "lib.util"
local chk = require "lib.check"

local smoke = {}

function smoke.run()
    print("")
    print("--- smoke checks ---")

    chk.check("jass.Player(0) round trip", function()
        local player = jass.Player(0)
        assert(player ~= nil, "Player(0) returned nil")
        assert(jass.GetPlayerId(player) == 0, "GetPlayerId(Player(0)) is not 0")
    end)

    chk.check("local player is player 0", function()
        local player = jass.GetLocalPlayer()
        assert(player ~= nil, "GetLocalPlayer() returned nil")
        assert(jass.GetPlayerId(player) == 0, "GetPlayerId(GetLocalPlayer()) is not 0 (single player only)")
    end)

    chk.check("handle id is positive", function()
        local id = jass.GetHandleId(jass.Player(0))
        assert(type(id) == "number", "GetHandleId returned " .. type(id))
        assert(id > 0, "GetHandleId(Player(0)) is " .. tostring(id))
    end)

    chk.check("jass.OrderId('stop') is non-zero", function()
        local id = jass.OrderId("stop")
        assert(type(id) == "number", "OrderId returned " .. type(id))
        assert(id ~= 0, "OrderId('stop') is 0")
    end)

    chk.check("player start location is a number", function()
        local player = jass.Player(0)
        local x = jass.GetPlayerStartLocationX(player)
        local y = jass.GetPlayerStartLocationY(player)
        assert(type(x) == "number", "GetPlayerStartLocationX returned " .. type(x))
        assert(type(y) == "number", "GetPlayerStartLocationY returned " .. type(y))
    end)

    chk.check("timer create/destroy", function()
        local timer = jass.CreateTimer()
        assert(timer ~= nil, "CreateTimer returned nil")
        assert(jass.GetHandleId(timer) > 0, "timer handle id is not positive")
        jass.DestroyTimer(timer)
    end)

    chk.check("jass.runtime reports a version", function()
        local version = runtime.version
        assert(type(version) == "string", "runtime.version is " .. type(version))
        assert(#version > 0, "runtime.version is empty")
        assert(type(runtime.handle_level) == "number", "runtime.handle_level is not a number")
    end)

    chk.check("lib.util helpers", function()
        assert(util.fourcc("hfoo") == 0x68666F6F, "fourcc('hfoo') is not 0x68666F6F")
        assert(util.fourcc("ab") == 0, "fourcc('ab') should be 0")
        assert(util.clamp(5, 1, 3) == 3, "clamp(5, 1, 3) is not 3")
        assert(util.clamp(-1, 1, 3) == 1, "clamp(-1, 1, 3) is not 1")
        assert(util.clamp(2, 1, 3) == 2, "clamp(2, 1, 3) is not 2")
    end)

    -- udg_lua_japi_alive is written by war3map.lua. Only base maps whose
    -- war3map.j declares the global can see it, and a write to an unknown
    -- global is silently dropped, so report a skip instead of a failure.
    local read_ok, alive = pcall(function()
        return globals.udg_lua_japi_alive
    end)
    if not read_ok then
        chk.skip("globals.udg_lua_japi_alive == 1", "jass.globals unavailable: " .. tostring(alive))
    elseif alive == nil then
        chk.skip("globals.udg_lua_japi_alive == 1", "base map does not declare it in war3map.j")
    else
        chk.check("globals.udg_lua_japi_alive == 1", function()
            assert(alive == 1, "expected 1, got " .. tostring(alive))
        end)
    end

    chk.finish("smoke")
end

return smoke
'@

$configTemplate = @'
--[[ ==========================================================================
  config.lua - project settings.

  Values here are the defaults. Machine-local overrides live in
  config.local.lua, which is gitignored: copy config.local.lua.example to
  config.local.lua and uncomment the override block at the bottom of this file.
============================================================================= ]]

local config = {
    -- Draw a debug HUD. Needs the D3D proxy (tools/deploy.ps1 -InteractiveD3D);
    -- see docs/guide/D3D-LUA-QUICKSTART.md before turning this on.
    hud = false,

    -- Seconds between game logic ticks. 0.25 = four ticks per second.
    tick = 0.25,

    -- Verbose logging: set it and have your code call util.log(...) freely.
    debug = false,
}

-- Optional per-machine overrides. tools/pack.ps1 inlines every require that
-- starts at column 0, and it can only inline a file that exists - so these two
-- lines stay commented out until you create config.local.lua:
--
-- local overrides = require "config.local"
-- for key, value in pairs(overrides) do config[key] = value end

return config
'@

$configLocalTemplate = @'
--[[ ==========================================================================
  config.local.lua.example

  Copy to config.local.lua (gitignored) to override config.lua on this machine
  only, then uncomment the override block at the bottom of config.lua.
============================================================================= ]]

return {
    hud = true,
    debug = true,
}
'@

$gitignoreTemplate = @'
# Packed maps and intermediate files (tools/pack.ps1 defaults)
build/
*.w3x

# Local overrides: copy config.local.lua.example to config.local.lua
config.local.lua

# Engine debug logs (copy of C:\ProgramData\japi_debug.txt if you keep one here)
japi_debug*.txt
'@

# ---------------------------------------------------------------------------
# README sections that depend on the base map kind
# ---------------------------------------------------------------------------

$baseMapSectionDirTemplate = @'
`base-map\` 是一份**未打包的地图源文件目录**（从 `-Base` 原样复制而来，见上表）。打包时
`-BaseMap` 指向这个目录，`tools\pack.ps1` 会把它当作已经解包的源文件直接读走：

```powershell
.\tools\pack.ps1 -MapDir @@MAPDIR@@ -BaseMap @@BASEMAP@@ -WorkDir build\@@WORKDIR@@ -OutFile build\@@OUTFILE@@
```

换基座地图：重新跑一遍 `tools\new-project.ps1 -Name @@PROJECT@@ -Base your-map-dir -Force`，
脚本会删掉旧的 `base-map\` 再复制新的，项目里你自己写的东西不会被动。
'@

$baseMapSectionFileTemplate = @'
`base-map\base@@BASEEXT@@` 是一份**整张地图文件**（从 `-Base` 复制而来）。这种情况
`-BaseMap` 必须指向**这个文件本身**，而不是 `base-map\` 目录 —— 只有文件基座才会被
`tools\pack.ps1` 解包、替换 `war3map.lua` 后再重新打包；指向目录会把这整张地图当作已解包
源文件原样塞进 MPQ，结果是你的 Lua 根本没进去。

另外，基座地图本身不能是**已经注入过本插件**的地图（例如 `build\output.w3x`）：它的
`war3map.j` 里已经有初始化代码，再当基座用会在打包的 JASS 检查阶段报
`JapiForceAllocArrays multiply defined`。

```powershell
.\tools\pack.ps1 -MapDir @@MAPDIR@@ -BaseMap @@BASEMAP@@ -WorkDir build\@@WORKDIR@@ -OutFile build\@@OUTFILE@@
```

换基座地图：重新跑一遍 `tools\new-project.ps1 -Name @@PROJECT@@ -Base your-map.w3x -Force`。
'@

# ---------------------------------------------------------------------------
# README (Chinese, UTF-8 without BOM - the only non-ASCII file generated here)
# ---------------------------------------------------------------------------

$readmeTemplate = @'
# @@PROJECT@@ — japi Lua SDK 地图项目

由 `tools\new-project.ps1` 于 @@DATE@@ 生成的骨架项目：这是一个能被 `tools\pack.ps1` 打包成
`.w3x`、然后在 War3 里由 `yd_japi.dll` 提供 Lua 引擎的地图目录。

## 1. 目录约定

| 路径 | 作用 |
|------|------|
| `war3map.lua` | 入口脚本：require 各模块、置 Lua 存活标志、1 秒后跑冒烟测试 |
| `lib\util.lua` | 常用工具：`after(秒, fn)` 延时、`fourcc()`、`clamp()`、`log()` |
| `lib\check.lua` | 极简测试框架：`check()` / `skip()` / `finish()`，`finish()` 打印 Results 行 |
| `tests\smoke.lua` | 9 项冒烟检查，健康安装应当全过（个别基座地图会 1 项 skip） |
| `config.lua` | 项目配置：`hud` / `tick` / `debug` |
| `config.local.lua.example` | 本机覆盖配置的模板（复制成 `config.local.lua`，已被 gitignore） |
| `base-map\` | 基座地图（见第 2 节） |
| `.gitignore` | 忽略 `build/`、`*.w3x`、`config.local.lua`、`japi_debug*.txt` |

写代码时的三条硬约定：

1. `require "模块"` 必须写在**行首（第 0 列）**。`tools\pack.ps1` 只内联行首的 require，
   缩进或注释掉的 require 不会被内联，进游戏就会报模块找不到。
2. 模块名 = 相对项目根的路径去掉 `.lua`、把 `/` 换成 `.`：`lib\util.lua` → `require "lib.util"`。
   `jass.*` 是 DLL 提供的 C 模块，不要自己建同名文件。
3. `require` 只是**返回**模块表，不会创建同名全局变量：要写成 `local globals = require "jass.globals"`。
   裸写 `require "jass.globals"` 之后全局 `globals` 仍是 `nil`，第一次
   `globals.udg_xxx = 1` 就会报 `attempt to index a nil value (global 'globals')`，
   脚本当场中断，后面的 `print` 和冒烟检查都不会跑，日志里也就永远没有 `Results` 行。

## 2. 基座地图

@@BASEMAPDOC@@

## 3. 三条命令

全部在**仓库根目录**执行（`tools\` 就在那里）：

```powershell
# ① 打包：合并 Lua + 注入 DLL -> build\@@OUTFILE@@
.\tools\pack.ps1 -MapDir @@MAPDIR@@ -BaseMap @@BASEMAP@@ -WorkDir build\@@WORKDIR@@ -OutFile build\@@OUTFILE@@

# ② 部署 + 启动 War3 + 等结果（-MapName 决定放进 Maps\Test\ 的文件名）
.\tools\deploy.ps1 -MapDir @@MAPDIR@@ -BaseMap @@BASEMAP@@ -MapName @@MAPNAME@@

# ③ 看日志（deploy.ps1 等的就是这里的 Results 行）
Get-Content @@LOG@@ -Tail 40
```

打包成功的标志是最后一行 `Done -> build\@@OUTFILE@@`，以及中间那句
`Bundled N Lua files into war3map.lua`（本项目应为 5 个：入口 `war3map.lua` 加上 `lib\util.lua`、
`lib\check.lua`、`config.lua`、`tests\smoke.lua` 四个模块；这个数字数的是项目目录里的 `.lua` 文件数）。

`deploy.ps1` 会在日志里等 `Results: ... total` 这一行。本项目自带 9 项冒烟检查，健康的安装
应当打印：

```
 Results: 9 passed, 0 failed, 9 total (0 skipped)
 ALL CHECKS PASSED (9/9)
```

## 4. 失败排查

| 现象 | 原因与处理 |
|------|------------|
| 打包报 `Base map or source directory not found` / `Map dir not found` | 路径写错，或者没在仓库根目录执行；`-MapDir` 只需要有 `war3map.lua` |
| 日志里始终没有 `Results:` 行 | ① DLL 没加载：确认 `build\@@OUTFILE@@` 里有 `japi.tga`、游戏是从这次打包的地图启动的；② 基座地图的 `war3map.j` 没有 `call initializePlugin(  )` 锚点（`-BaseMap` 指向了自定义地图）；③ 日志被旧内容占住：`deploy.ps1` 只认启动之后写入的行，必要时看按进程分的 `C:\ProgramData\japi_debug_<pid>.txt`；④ 日志里有 `attempt to index a nil value (global 'xxx')`：裸 `require` 没绑定局部变量，见第 1 节第 3 条 |
| 日志里有 `[FAIL]` | 断言名字和报错都在行内；改 `tests\smoke.lua` 里对应的那一条。`[SKIP]` 不算失败（例如基座地图没声明 `udg_lua_japi_alive`） |

## 5. 接下来写什么

1. **写逻辑**：直接改 `war3map.lua`，或用 `util.after(秒, function() ... end)` 排周期任务；
   需要新模块就新建 `lib\xxx.lua`（`return` 一张表）再在 `war3map.lua` 行首 require。
2. **写测试**：在 `tests\smoke.lua` 里加 `chk.check("名字", function() ... end)`，
   失败就用 `assert(条件, "人话说明")`；`chk.skip` 用于本机跑不了的检查。
3. **开 HUD**：把 `config.hud` 改成 `true` 并接 `jass.d3d`（需要 D3D 代理，
   见 `docs\guide\D3D-LUA-QUICKSTART.md`）。
4. **本机覆盖**：`copy config.local.lua.example config.local.lua`，再把 `config.lua` 底部那两行
   覆盖代码的注释去掉 —— 注意删掉注释后才会内联，注释着的时候不会。

## 6. 参考文档

| 文档 | 内容 |
|------|------|
| [SDK 快速上手](@@DOCLINK@@) | 官方 SDK 入口文档（若链接打不开，见仓库 `docs\guide\` 目录） |
| `docs\STATUS.md` | 唯一权威状态：哪些 API 已验证、验证到什么程度 |
| `docs\guide\D3D-LUA-API.md` | HUD 绘制 API 参考 |
| `AGENT.md` | 仓库级工作流（打包、部署、日志约定） |

## 7. 验证状态

- 本骨架的**生成**与**打包**（`tools\pack.ps1` 输出 `Done -> ...`）在 2026-11-16 验证通过；
  冒烟检查用到的 native 都是本仓库 `map\` 下已在实际对局中验证过的那些。
- **游戏内运行**未由脚手架脚本验证：请按第 3 节自己跑一次 `deploy.ps1`，把日志里的
  `Results:` 行当成第一条基线。
'@

# ---------------------------------------------------------------------------
# write the scaffold
# ---------------------------------------------------------------------------

# Quote a value for a printed command line only when it needs quoting.
function Get-ArgText {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -match '[ \t]') { return '"' + $Value + '"' }
    return $Value
}

$readmeText = Get-ScaffoldText $readmeTemplate
# The README template is the only Chinese text in this script. If this check
# fires, the file was re-saved in an ANSI/GBK encoding and the template is
# already mangled - fail loudly instead of writing a broken README.
if (-not $readmeText.Contains([string][char]0x76EE)) {
    throw 'tools/new-project.ps1 lost its UTF-8 encoding: re-save the script as UTF-8 with BOM.'
}

$mapDirText = Get-DisplayPath $script:TargetDir
$baseMapText = Get-DisplayPath $baseMapArg
$outFileName = $Name + '.w3x'
$workDirName = $Name.ToLowerInvariant() + '-work'
$logPath = 'C:\ProgramData\japi_debug.txt'
$today = '2026-11-16'

# Link from the generated README back to the SDK docs. Falls back to a plain
# path when the project and the repo are on different drives.
$docsDir = Join-Path $script:RepoRoot 'docs\guide'
$docsPrefix = Get-RepoRelativePrefix -FromDir $script:TargetDir -ToDir $docsDir
if ($docsPrefix -eq $null) {
    $docLink = 'docs/guide/SDK-QUICKSTART.md'
} else {
    $docLink = ($docsPrefix + 'docs/guide/SDK-QUICKSTART.md').Replace('\', '/')
    if ($docLink.Contains(' ')) { $docLink = '<' + $docLink + '>' }
}

# Base map section of the README: a directory base and a map-file base are used
# very differently by tools/pack.ps1, so they get different wording.
$baseSectionTokens = @{
    '@@WORKDIR@@' = $workDirName
    '@@MAPDIR@@' = (Get-ArgText $mapDirText)
    '@@BASEMAP@@' = (Get-ArgText $baseMapText)
    '@@OUTFILE@@' = $outFileName
    '@@BASEEXT@@' = $baseExtension
}
if ($baseIsDir) {
    $baseMapSection = Get-ScaffoldText $baseMapSectionDirTemplate
} else {
    $baseMapSection = Get-ScaffoldText $baseMapSectionFileTemplate
}
foreach ($key in @($baseSectionTokens.Keys)) {
    $baseMapSection = $baseMapSection.Replace($key, [string]$baseSectionTokens[$key])
}
# The section is injected into the middle of README.md: drop the trailing line
# breaks so it ends with exactly the blank line the template already has.
$baseMapSection = $baseMapSection.TrimEnd()

$readmeTokens = @{
    '@@PROJECT@@' = $Name
    '@@DATE@@' = $today
    '@@MAPDIR@@' = (Get-ArgText $mapDirText)
    '@@BASEMAP@@' = (Get-ArgText $baseMapText)
    '@@OUTFILE@@' = $outFileName
    '@@MAPNAME@@' = $outFileName
    '@@WORKDIR@@' = $workDirName
    '@@LOG@@' = $logPath
    '@@DOCLINK@@' = $docLink
    '@@BASEMAPDOC@@' = $baseMapSection
}
$readmeBytes = Get-ScaffoldText $readmeTemplate
foreach ($key in @($readmeTokens.Keys)) {
    $readmeBytes = $readmeBytes.Replace($key, [string]$readmeTokens[$key])
}

$projectTokens = @{ '@@PROJECT@@' = $Name }

Write-Host ""
Write-Host "Writing the scaffold:"
Write-ScaffoldTemplate -RelativePath 'war3map.lua' -Template $war3mapTemplate -Tokens $projectTokens
Write-ScaffoldTemplate -RelativePath 'lib\util.lua' -Template $utilTemplate
Write-ScaffoldTemplate -RelativePath 'lib\check.lua' -Template $checkTemplate
Write-ScaffoldTemplate -RelativePath 'tests\smoke.lua' -Template $smokeTemplate
Write-ScaffoldTemplate -RelativePath 'config.lua' -Template $configTemplate
Write-ScaffoldTemplate -RelativePath 'config.local.lua.example' -Template $configLocalTemplate
Write-ScaffoldTemplate -RelativePath '.gitignore' -Template $gitignoreTemplate
Write-ScaffoldFile -RelativePath 'README.md' -Text $readmeBytes -Utf8

# ---------------------------------------------------------------------------
# what to run next
# ---------------------------------------------------------------------------

$baseMapFileCount = @(Get-ChildItem -LiteralPath $baseMapDir -Recurse -Force | Where-Object { -not $_.PSIsContainer }).Count
$total = $script:WrittenFiles.Count

Write-Host ""
Write-Host ("Done: wrote " + $total + " files into " + $script:TargetDir)
Write-Host ("      (" + $baseMapFileCount + " of them are the base-map copy, " + ($total - $baseMapFileCount) + " are scaffold files)")
Write-Host ""

$dllPath = Join-Path $script:RepoRoot 'src\build\bin\Release\yd_japi.dll'
if (-not (Test-Path -LiteralPath $dllPath)) {
    Write-Host "NOTE: src\build\bin\Release\yd_japi.dll is missing - run src\build.bat first,"
    Write-Host "      or pass -DllPath to tools\pack.ps1 and tools\deploy.ps1."
    Write-Host ""
}

$mapDirArg = Get-ArgText $mapDirText
$baseMapArgText = Get-ArgText $baseMapText
$outFileArg = Get-ArgText ('build\' + $outFileName)
$workDirArg = Get-ArgText ('build\' + $workDirName)

Write-Host "Next steps (run them from the repository root: $($script:RepoRoot)):"
Write-Host ""
Write-Host "  # 1) pack: inline the Lua modules and inject the DLL"
Write-Host ("  .\tools\pack.ps1 -MapDir " + $mapDirArg + " -BaseMap " + $baseMapArgText + " -WorkDir " + $workDirArg + " -OutFile " + $outFileArg)
Write-Host ""
Write-Host "  # 2) deploy: pack, copy into Maps\Test, start Warcraft III, wait for the results"
Write-Host ("  .\tools\deploy.ps1 -MapDir " + $mapDirArg + " -BaseMap " + $baseMapArgText + " -MapName " + $outFileName)
Write-Host ""
Write-Host "  # 3) read the engine log (deploy.ps1 waits for a 'Results: ... total' line in it)"
Write-Host ("  Get-Content " + $logPath + " -Tail 40")
Write-Host ""
Write-Host "The smoke test should print:"
Write-Host "   Results: 9 passed, 0 failed, 9 total (0 skipped)"
Write-Host "   ALL CHECKS PASSED (9/9)"
Write-Host "  (one check is reported as [SKIP] when the base map does not declare udg_lua_japi_alive)"
Write-Host ""
Write-Host ("Project README: " + (Join-Path $script:TargetDir 'README.md'))
Write-Host ""

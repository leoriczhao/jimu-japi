# tools/pack.ps1
# Pack map: bundle Lua sources + inject DLL + patch war3map.j + repack into .w3x
#
# Usage:
#   .\tools\pack.ps1                                    # empty-map base
#   .\tools\pack.ps1 -DllPath "path\to\yd_japi.dll"    # custom DLL
#   .\tools\pack.ps1 -BaseMap "other.w3m"               # custom map/archive/source dir
#   .\tools\pack.ps1 -BaseMap "foreign" -SkipJassCheck  # vJass maps: skip pjass validation
#   .\tools\pack.ps1 -OutFile "out\test.w3x"            # custom output
#   .\tools\pack.ps1 -Demo                             # playable vertical slice instead of the suite
param(
    [string]$DllPath  = "",
    [string]$BaseMap  = "",
    [string]$OutFile  = "",
    [string]$MapDir   = "",
    [switch]$InteractivePoint,
    [switch]$InteractiveUi,
    [switch]$InteractiveD3D,
    [switch]$WithDebugger,
    [switch]$Demo,
    [switch]$TestReboot,
    [switch]$SkipJassCheck
)

$Root = Split-Path -Parent $PSScriptRoot
$W3x2Lni = "$Root\tools\w3x2lni"
$Lua     = "$W3x2Lni\bin\w3x2lni-lua.exe"
$Script  = "$W3x2Lni\script"

# Defaults
if (-not $DllPath)  { $DllPath  = "$Root\src\build\bin\Release\yd_japi.dll" }
if (-not $BaseMap)  { $BaseMap = "$Root\reference\empty-map" }
if (-not $OutFile)  { $OutFile  = "$Root\build\output.w3x" }
if (-not $MapDir)   { $MapDir   = "$Root\map" }
$CbSrc   = "$Root\tools\callback"
$WorkDir = "$Root\build\work"

# Resolve to absolute paths
function Resolve-Abs($p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PWD.Path, $p))
}
$DllPath = Resolve-Abs $DllPath
$BaseMap = Resolve-Abs $BaseMap
$OutFile = Resolve-Abs $OutFile
$MapDir  = Resolve-Abs $MapDir

# Validate
if (-not (Test-Path $BaseMap)) { throw "Base map or source directory not found: $BaseMap" }
if (-not (Test-Path $DllPath)) { throw "DLL not found: $DllPath`n  Build first: src\build.bat" }
if (-not (Test-Path $Lua))     { throw "w3x2lni not found: $Lua" }
if (-not (Test-Path $CbSrc))   { throw "callback not found: $CbSrc" }
if (-not (Test-Path $MapDir))  { throw "Map dir not found: $MapDir" }

$MainLua = "$MapDir\war3map.lua"
if (-not (Test-Path $MainLua)) { throw "war3map.lua not found: $MainLua" }

Write-Host "  Base map: $BaseMap"
Write-Host "  Map dir:  $MapDir"
Write-Host "  DLL:      $DllPath"
Write-Host "  Output:   $OutFile"

# ── w3x2lni helper ──────────────────────────────────────────────
function Use-W3x2Lni {
    param($Mode, $Source, $Target)
    $cpath = Join-Path $W3x2Lni 'bin\?.dll'
    $ppath = (Join-Path $Script '?.lua') + ';' + (Join-Path $Script '?\init.lua')
    Push-Location $Script
    try {
        $env:PATH = (Join-Path $W3x2Lni 'bin') + ';' + $env:PATH
        & $Lua -E -e "_W2L_MODE='CLI';package.cpath=[[$cpath]];package.path=[[$ppath]]" main.lua $Mode $Source $Target 2>&1
        if ($LASTEXITCODE -ne 0) { throw "w3x2lni $Mode failed" }
    } finally { Pop-Location }
}

# ── Lua bundler ─────────────────────────────────────────────────
# Collects all .lua files under $MapDir, converts paths to module names,
# and inlines require() calls into a single war3map.lua.

function Get-ModuleName {
    param([string]$FilePath, [string]$BaseDir)
    # map/lib/util.lua → lib.util
    # map/tests/test_suite.lua → tests.test_suite
    # map/war3map.lua → war3map (entry point, not a module)
    $rel = $FilePath.Substring($BaseDir.Length).TrimStart('\', '/')
    $noext = $rel -replace '\\', '/' -replace '\.lua$', ''
    return $noext -replace '/', '.'
}

function Bundle-Lua {
    param([string]$MapDir, [string]$OutPath, [string]$Entry = "war3map")

    # Collect all .lua files
    $allFiles = Get-ChildItem -Path $MapDir -Filter "*.lua" -Recurse -File

    # Build module map: name → content
    $moduleMap = @{}
    foreach ($f in $allFiles) {
        $name = Get-ModuleName $f.FullName $MapDir
        $content = Get-Content $f.FullName -Raw -Encoding UTF8
        $moduleMap[$name] = $content
    }

    # Entry point. NOTE: PowerShell variables are case-insensitive, so this must
    # not be called $entry — that would overwrite the $Entry parameter.
    $entryCode = $moduleMap[$Entry]
    if (-not $entryCode) { throw "$Entry.lua not found in $MapDir" }

    # Inline require() calls recursively
    # Pattern: local xxx = require "module.name"  or  require "module.name"
    $requirePattern = '(?m)^(local\s+\w+\s*=\s*)?require\s+"([^"]+)"'

    function Inline-Requires {
        param([string]$code, [hashtable]$modules, [System.Collections.Generic.HashSet[string]]$visited)
        $result = $code
        $matches = [regex]::Matches($code, $requirePattern)
        foreach ($m in $matches) {
            $modName = $m.Groups[2].Value
            if (-not $modules.ContainsKey($modName)) { continue }
            $requirePart = "require `"$modName`""
            if ($visited.Contains($modName)) {
                # Already inlined — reference the module cache (NOT nil: the module
                # may be required again inside another module's scope)
                $result = $result.Replace($requirePart, "__modcache[`"$modName`"]")
                continue
            }
            $visited.Add($modName) | Out-Null
            $modCode = Inline-Requires $modules[$modName] $modules $visited
            # Only replace the require "..." part, keep the "local xxx = " prefix.
            # Wrap as IIFE that also records the module in __modcache for repeat requires.
            $replacement = "(function() local m = (function()`r`n$modCode`r`nend)() __modcache[`"$modName`"] = m return m end)()"
            $result = $result.Replace($requirePart, $replacement)
        }
        return $result
    }

    $isMainEntry = $Entry -eq "war3map"
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $visited.Add($Entry) | Out-Null
    $bundled = Inline-Requires $entryCode $moduleMap $visited
    $bundled = "local __modcache = {}`r`n" + $bundled
    if ($isMainEntry -and $InteractivePoint) {
        $bundled = "_G.__JAPI_TEST_INTERACTIVE_POINT = true`r`n" + $bundled
    }
    if ($isMainEntry -and $InteractiveUi) {
        $bundled = "_G.__JAPI_TEST_INTERACTIVE_UI = true`r`n" + $bundled
    }
    if ($isMainEntry -and $InteractiveD3D) {
        $bundled = "_G.__JAPI_TEST_INTERACTIVE_D3D = true`r`n" + $bundled
    }
    if ($isMainEntry -and $Demo) {
        $bundled = "_G.__JAPI_DEMO = true`r`n" + $bundled
    }
    if ($isMainEntry -and $TestReboot) {
        $bundled = "_G.__JAPI_REBOOT_PARENT = true`r`n" + $bundled
    }

    # Write UTF-8 without BOM (luaL_loadbuffer cannot skip a BOM, and ASCII
    # encoding would silently corrupt non-ASCII chars like Chinese text)
    $absOut = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)
    [System.IO.File]::WriteAllText($absOut, $bundled, (New-Object System.Text.UTF8Encoding($false)))
    $count = $moduleMap.Count
    Write-Host "  Bundled $count Lua files into $(Split-Path -Leaf $OutPath)"
}

# ── Main pipeline ───────────────────────────────────────────────

# 1. Clean and import base map
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory $WorkDir -Force | Out-Null
if ((Get-Item -LiteralPath $BaseMap).PSIsContainer) {
    Write-Host '  [1/5] Copy base-map source directory'
    Get-ChildItem -LiteralPath $BaseMap -Force | Copy-Item -Destination $WorkDir -Recurse -Force
} else {
    Write-Host '  [1/5] Unpack base map'
    Use-W3x2Lni 'unpack' $BaseMap $WorkDir
}

# Compile source-controlled LNI object definitions into the binary object
# files consumed by Warcraft III. The temporary archive round-trip lets the
# repository keep editable .ini data instead of committing generated .w3u.
$UnitObjectIni = "$WorkDir\war3map.w3u.ini"
if (Test-Path -LiteralPath $UnitObjectIni) {
    Write-Host '  [1b] Compile unit object data'
    $ObjectMap = "$Root\build\work-object.w3x"
    $ObjectDir = "$Root\build\work-object"
    if (Test-Path -LiteralPath $ObjectMap) { Remove-Item -LiteralPath $ObjectMap -Force }
    if (Test-Path -LiteralPath $ObjectDir) { Remove-Item -LiteralPath $ObjectDir -Recurse -Force }
    Use-W3x2Lni 'obj' $WorkDir $ObjectMap
    New-Item -ItemType Directory $ObjectDir -Force | Out-Null
    Use-W3x2Lni 'unpack' $ObjectMap $ObjectDir
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
    Move-Item -LiteralPath $ObjectDir -Destination $WorkDir
    Remove-Item -LiteralPath $ObjectMap -Force
}

$JFile = "$WorkDir\war3map.j"
if (-not (Test-Path $JFile)) {
    Set-Content $JFile "// empty war3map.j`r`n" -Encoding Ascii
    Write-Host '  No war3map.j found, created empty'
}

# 2. Bundle Lua sources
Write-Host '  [2/5] Bundle Lua'
Bundle-Lua $MapDir "$WorkDir\war3map.lua"
if ($TestReboot) {
    # Second script, loaded by the DLL after it resets the VM so the reboot
    # regression can assert the new state from inside the fresh Lua state.
    Write-Host '  [2b] Bundle reboot child script'
    $rebootScriptDir = "$WorkDir\script"
    if (-not (Test-Path $rebootScriptDir)) { New-Item -ItemType Directory $rebootScriptDir -Force | Out-Null }
    Bundle-Lua $MapDir "$rebootScriptDir\reboot_child.lua" -Entry "tests.reboot_child"
}

# 3. war3map.j — inject the japi bootstrap (plugin maps and foreign maps)
Write-Host '  [3/5] Patching war3map.j'
$jContent = Get-Content $JFile -Raw -Encoding ASCII
$nl = [string][char]13 + [string][char]10

# Lines that hand the shared hashtable over to the DLL and load war3map.lua.
# When the base map carries the bridge probe functions, exercise JASS -> Lua
# immediately after LoadScript (the Lua handlers register synchronously).
$loadScriptLines = '    call SaveStr(japi_ht, japi__key, 0, "()V")' + $nl +
    '    call UnitId("LoadScript")'
if ($jContent -match 'function LuaBridgeProbeCall') {
    $loadScriptLines += $nl +
        '    call LuaCallback1()' + $nl +
        '    set udg_lua_bridge_result = LuaBridgeProbeCall(10, 32)' + $nl +
        '    set udg_lua_error_result = LuaErrorProbeCall()' + $nl +
        '    set udg_lua_handle_result = LuaHandleProbeCall()'
}

if ($TestReboot) {
    # The VM reset must be driven by pure JASS: closing Lua from inside a Lua
    # frame would tear down a live lua_pcall. A one-shot timer keeps it off the
    # war3map.lua call stack.
    $loadScriptLines += $nl +
        '    call TimerStart(CreateTimer(), 6.00, false, function JapiRebootProbe)'
    $rebootProbeFunc = 'function JapiRebootProbe takes nothing returns nothing' + $nl +
        '    call UnitId("SimulateMapBoot")' + $nl +
        'endfunction' + $nl + $nl
    $rebootMain = [regex]::Match($jContent, '(?m)^[ \t]*function[ \t]+main[ \t]+takes')
    if (-not $rebootMain.Success) {
        throw "war3map.j has no 'function main takes' for -TestReboot: $BaseMap"
    }
    $jContent = $jContent.Substring(0, $rebootMain.Index) + $rebootProbeFunc +
        $jContent.Substring($rebootMain.Index)
}

# Inject a self-contained bootstrap into a map that knows nothing about japi:
# declare the bridge hashtable, load the DLL through StartCampaignAI, hand the
# hashtable handle over and load war3map.lua, all from map main().
function Add-JapiBootstrap {
    param([string]$Content, [string]$LoadScriptBlock)

    $bootstrap = '// japi bootstrap injected by tools/pack.ps1' + $nl +
        'function JapiBootstrap takes nothing returns nothing' + $nl +
        '    call StartCampaignAI(Player(PLAYER_NEUTRAL_AGGRESSIVE), "callback")' + $nl +
        '    call UnitId(I2S(GetHandleId(japi_ht)))' + $nl +
        $LoadScriptBlock + $nl +
        'endfunction' + $nl + $nl

    # A map that already carries japi/builtin-japi globals keeps them; only add
    # the missing declarations so the injected code does not multiply-define.
    $globalsDecl = ''
    if ($Content -notmatch '(?m)^[ \t]*hashtable[ \t]+japi_ht\b') {
        $globalsDecl += '    hashtable japi_ht = InitHashtable()' + $nl
    }
    if ($Content -notmatch '(?m)^[ \t]*integer[ \t]+japi__key\b') {
        $globalsDecl += '    integer japi__key = StringHash("jass")' + $nl
    }

    $mainMatch = [regex]::Match($Content, '(?m)^[ \t]*function[ \t]+main[ \t]+takes')
    if (-not $mainMatch.Success) {
        throw "war3map.j has no 'function main takes' to bootstrap: $BaseMap"
    }
    $endFunc = $Content.IndexOf('endfunction', $mainMatch.Index)
    if ($endFunc -lt 0) { throw "war3map.j main() has no endfunction: $BaseMap" }
    $Content = $Content.Substring(0, $endFunc) + '    call JapiBootstrap()' + $nl +
        $Content.Substring($endFunc)

    $mainStart = [regex]::Match($Content, '(?m)^[ \t]*function[ \t]+main[ \t]+takes').Index
    $Content = $Content.Substring(0, $mainStart) + $bootstrap + $Content.Substring($mainStart)

    if (-not $globalsDecl) { return $Content }
    $endGlobals = [regex]::Match($Content, '(?m)^[ \t]*endglobals')
    if ($endGlobals.Success) {
        return $Content.Substring(0, $endGlobals.Index) + $globalsDecl + $Content.Substring($endGlobals.Index)
    }
    return 'globals' + $nl + $globalsDecl + 'endglobals' + $nl + $nl + $Content
}

if ($jContent -match [regex]::Escape('call UnitId("LoadScript")')) {
    Write-Host '  Bootstrap: already present, left untouched'
} elseif ($jContent -match [regex]::Escape('call initializePlugin(  )')) {
    $jContent = $jContent.Replace('call initializePlugin(  )',
        'call initializePlugin(  )' + $nl + $loadScriptLines)
    Write-Host '  Bootstrap: plugin marker map'
} else {
    if ($jContent -match 'UnitId\s*\(') {
        Write-Host '  WARNING: map already uses UnitId(); review the injected bootstrap for conflicts'
    }
    $jContent = Add-JapiBootstrap $jContent $loadScriptLines
    Write-Host '  Bootstrap: injected into map main() (foreign map)'
}
Set-Content $JFile $jContent -Encoding ASCII -NoNewline

# 3b. Parse the patched script before it ever reaches the game. JassHelper/vJass
# maps can opt out with -SkipJassCheck.
if (-not $SkipJassCheck) {
    $commonJ = "$W3x2Lni\data\enUS-1.27.1\mpq\Scripts\Common.j"
    $blizzardJ = "$W3x2Lni\data\enUS-1.27.1\mpq\Scripts\Blizzard.j"
    $pjassExe = "$Root\tools\pjass.exe"
    if ((Test-Path $pjassExe) -and (Test-Path $commonJ) -and (Test-Path $blizzardJ)) {
        $jassOut = & $pjassExe $commonJ $blizzardJ $JFile 2>&1
        $jassText = ($jassOut | Out-String)
        if ($LASTEXITCODE -ne 0 -or $jassText -match '(?m)^\s*(Error|error)') {
            Write-Host ($jassOut | Select-Object -Last 15 | Out-String)
            throw "JASS syntax check failed: $JFile (pass -SkipJassCheck to bypass)"
        }
        Write-Host '  JASS syntax check OK'
    }
}

# 4. Inject DLL and callback
Write-Host '  [4/5] Inject DLL + callback'
Copy-Item $DllPath "$WorkDir\japi.tga" -Force
Copy-Item $CbSrc  "$WorkDir\callback" -Force

# Deterministic MPQ-only texture fixtures for the public D3D SDK acceptance.
# They intentionally never exist beside war3.exe, proving asset:// uses Storm.
if ($InteractiveD3D) {
    $probePng = 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAA5SURBVDhPY5Db8v8/Mv4fIIeCCckzEFJASH4QGIAuQEgDuvxwMABdgJAGdPnhYAC6ACEN6PLDwAAAlMCeH43ym2UAAAAASUVORK5CYII='
    [System.IO.File]::WriteAllBytes(
        "$WorkDir\d3d-sdk-probe.png", [Convert]::FromBase64String($probePng))
    [System.IO.File]::WriteAllBytes(
        "$WorkDir\d3d-sdk-corrupt.png", [System.Text.Encoding]::ASCII.GetBytes('not-an-image'))
}

# Update MPQ listfile so w3x2lni includes the new files
$listfile = "$WorkDir\(listfile)"
$needed = @("callback", "japi.tga")
if ($InteractiveD3D) {
    $needed += @("d3d-sdk-probe.png", "d3d-sdk-corrupt.png")
}
$existing = if (Test-Path $listfile) { Get-Content $listfile -Raw } else { "" }
foreach ($f in $needed) {
    if ($existing -notmatch [regex]::Escape($f)) {
        Add-Content $listfile "`n$f" -Encoding ASCII
    }
}

# DLL loads war3map.lua from script\war3map.lua in the MPQ
# Create script subdirectory and copy the bundled lua there
$scriptDir = "$WorkDir\script"
if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory $scriptDir -Force | Out-Null }
Copy-Item "$WorkDir\war3map.lua" "$scriptDir\war3map.lua" -Force
if ($existing -notmatch "script\\\\war3map\.lua") {
    Add-Content $listfile "`nscript\war3map.lua" -Encoding ASCII
}
if ($TestReboot -and (Get-Content $listfile -Raw) -notmatch 'reboot_child') {
    Add-Content $listfile "`nscript\reboot_child.lua" -Encoding ASCII
}

# 4b. Debugger resources (optional, -WithDebugger)
if ($WithDebugger) {
    Write-Host '  [4b] Inject debugger resources'
    $dbgSrc = "$Root\tools\debugger"
    $dbgDst = "$WorkDir\debugger"
    if (-not (Test-Path "$dbgSrc\luadebug.dll")) { throw "debugger payload not found: $dbgSrc" }
    Copy-Item "$dbgSrc\script" "$dbgDst\script" -Recurse -Force
    Copy-Item "$dbgSrc\luadebug.dll" "$dbgDst\luadebug.dll" -Force
    Copy-Item "$dbgSrc\LICENSE.lua-debug" "$dbgDst\" -Force

    # manifest.txt: one MPQ-relative path per line (used by libs_debugger to extract)
    $entries = @("luadebug.dll", "LICENSE.lua-debug")
    Get-ChildItem "$dbgDst\script" -Recurse -File | ForEach-Object {
        $entries += "script\" + $_.FullName.Substring("$dbgDst\script\".Length)
    }
    Set-Content "$dbgDst\manifest.txt" ($entries -join "`r`n") -Encoding Ascii

    # listfile
    Add-Content $listfile "`ndebugger\manifest.txt" -Encoding ASCII
    foreach ($e in $entries) {
        Add-Content $listfile "`ndebugger\$e" -Encoding ASCII
    }
}

# 5. Repack
Write-Host '  [5/5] Repack'
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir -Force | Out-Null }
Use-W3x2Lni 'pack' $WorkDir $OutFile

Write-Host "  Done -> $OutFile"

# tools/pack.ps1
# Pack map: bundle Lua sources + inject DLL + patch war3map.j + repack into .w3x
#
# Usage:
#   .\tools\pack.ps1                                    # empty-map base
#   .\tools\pack.ps1 -DllPath "path\to\yd_japi.dll"    # custom DLL
#   .\tools\pack.ps1 -BaseMap "other.w3m"               # custom map/archive/source dir
#   .\tools\pack.ps1 -BaseMap "foreign" -SkipJassCheck  # vJass maps: skip pjass validation
#   .\tools\pack.ps1 -OutFile "out\test.w3x"            # custom output
#   .\tools\pack.ps1 -MapDir "examples\01-hello-jass" -WorkDir "build\w1"  # pack a project tree, isolated scratch
#   .\tools\pack.ps1 -Demo                             # playable vertical slice instead of the suite
#   .\tools\pack.ps1 -WithJassWrappers                  # generate JASS wrappers for every bridge handler
#   .\tools\pack.ps1 -WithGetFuncAddr                   # expose builtin-style GetFuncAddr(code) in the map
#   .\tools\pack.ps1 -RequireReport                     # print every require classification
#   .\tools\pack.ps1 -StrictRequires                    # fail on missing/un-inlined map modules
#   .\tools\pack.ps1 -SkipRepack                        # stop after patching; inspect -WorkDir, write no .w3x
param(
    [string]$DllPath  = "",
    [string]$BaseMap  = "",
    [string]$OutFile  = "",
    [string]$MapDir   = "",
    [string]$WorkDir  = "",
    [switch]$InteractivePoint,
    [switch]$InteractiveUi,
    [switch]$InteractiveD3D,
    [switch]$WithDebugger,
    [switch]$Demo,
    [switch]$TestReboot,
    [switch]$SkipJassCheck,
    [switch]$NoArrayPrealloc,
    [switch]$WithJassWrappers,
    [switch]$WithGetFuncAddr,
    [switch]$RequireReport,
    [switch]$StrictRequires,
    [switch]$SkipRepack
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
if (-not $WorkDir)  { $WorkDir  = "$Root\build\work" }
$CbSrc   = "$Root\tools\callback"

# Resolve to absolute paths
function Resolve-Abs($p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PWD.Path, $p))
}
$DllPath = Resolve-Abs $DllPath
$BaseMap = Resolve-Abs $BaseMap
$OutFile = Resolve-Abs $OutFile
$MapDir  = Resolve-Abs $MapDir
$WorkDir = Resolve-Abs $WorkDir

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

# ── JASS injection anchor diagnostics ───────────────────────────
# Every patch below is a textual insertion into war3map.j. A missing or
# displaced anchor used to surface as a generic exception, and a whitespace
# difference silently fell through to foreign-map injection. Resolve all
# anchors once, print their line numbers, and fail with that report when a
# requested patch has nowhere safe to go.
function Get-LineNumberFromIndex {
    param([string]$Text, [int]$Index)
    if ($Index -le 0) { return 1 }
    return 1 + ([regex]::Matches($Text.Substring(0, $Index), "`n")).Count
}

function Find-JassAnchors {
    param([string]$Content)
    [pscustomobject]@{
        Globals          = [regex]::Match($Content, '(?m)^[ \t]*globals\b')
        EndGlobals       = [regex]::Match($Content, '(?m)^[ \t]*endglobals\b')
        Main             = [regex]::Match($Content, '(?m)^[ \t]*function[ \t]+main[ \t]+takes\b')
        FirstFunction    = [regex]::Match($Content, '(?m)^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+takes\b')
        InitializePlugin = [regex]::Matches($Content, '(?m)^[ \t]*call[ \t]+initializePlugin[ \t]*\([ \t]*\)')
        LoadScript       = [regex]::Matches($Content, '(?m)^[ \t]*call[ \t]+UnitId[ \t]*\([ \t]*"LoadScript"[ \t]*\)')
        SetHeroLevels    = [regex]::Matches($Content, '(?m)^[ \t]*native[ \t]+SetHeroLevels\b')
        HasBridgeProbe   = [bool]($Content -match '(?m)^[ \t]*function[ \t]+LuaBridgeProbeCall[ \t]+takes\b')
        HasWrapperProbe  = [bool]($Content -match '(?m)^[ \t]*integer[ \t]+udg_lua_wrapper_ready\b')
        HasGetFuncProbe  = [bool]($Content -match '(?m)^[ \t]*integer[ \t]+udg_lua_getfunc_ready\b')
    }
}

function Format-JassAnchorMatch {
    param([string]$Content, $Match, [string]$Name)
    if ($null -eq $Match -or -not $Match.Success) { return "$Name=absent" }
    return "$Name@$(Get-LineNumberFromIndex $Content $Match.Index)"
}

function Format-JassAnchorMatches {
    param([string]$Content, $Collection, [string]$Name)
    if ($null -eq $Collection -or $Collection.Count -eq 0) { return "$Name=absent" }
    $line = Get-LineNumberFromIndex $Content $Collection[0].Index
    if ($Collection.Count -gt 1) { return "$Name@$line(x$($Collection.Count))" }
    return "$Name@$line"
}

function Get-JassAnchorSummary {
    param([string]$Content)
    $a = Find-JassAnchors $Content
    $parts = @(
        (Format-JassAnchorMatch   $Content $a.Globals          'globals'),
        (Format-JassAnchorMatch   $Content $a.EndGlobals       'endglobals'),
        (Format-JassAnchorMatch   $Content $a.Main             'main'),
        (Format-JassAnchorMatch   $Content $a.FirstFunction    'first-function'),
        (Format-JassAnchorMatches $Content $a.InitializePlugin 'initializePlugin'),
        (Format-JassAnchorMatches $Content $a.LoadScript       'loadScript'),
        (Format-JassAnchorMatches $Content $a.SetHeroLevels    'native:SetHeroLevels')
    )
    $probes = @()
    if ($a.HasBridgeProbe)  { $probes += 'bridge' }
    if ($a.HasWrapperProbe) { $probes += 'wrapper' }
    if ($a.HasGetFuncProbe) { $probes += 'getfunc' }
    if ($probes.Count -eq 0) { $parts += 'probes=absent' }
    else { $parts += ('probes=' + ($probes -join ',')) }
    return ($parts -join ' ')
}

function Insert-AfterJassMatch {
    param([string]$Content, $Match, [string]$Text)
    $at = $Match.Index + $Match.Length
    return $Content.Substring(0, $at) + $Text + $Content.Substring($at)
}

# ── Lua bundler ─────────────────────────────────────────────────
# Collects all .lua files under $MapDir, converts paths to module names,
# and inlines require() calls into a single war3map.lua.

# Modules the DLL registers on package.preload (open_lua_engine.cpp). A require
# that resolves here stays in the bundle and is served at runtime; it is not a
# packaging error. The list is read from the source when present (repository
# checkout); the static copy keeps -SdkBundle working, where src\ is not shipped.
$EngineModules = [System.Collections.Generic.HashSet[string]]::new()
foreach ($engineModule in @(
    'jass.common', 'jass.globals', 'jass.japi', 'jass.hook', 'jass.runtime',
    'jass.debug', 'jass.message', 'jass.sleep', 'jass.storm', 'jass.slk',
    'jass.debugger', 'jass.d3d', 'jass.console', 'jass.log', 'jass.bignum')) {
    [void]$EngineModules.Add($engineModule)
}
$engineModuleSource = "$Root\src\src\lua_engine\lua_engine\open_lua_engine.cpp"
if (Test-Path -LiteralPath $engineModuleSource) {
    $engineModuleText = Get-Content -LiteralPath $engineModuleSource -Raw
    foreach ($m in [regex]::Matches($engineModuleText,
            'register_preload_lib\s*\(\s*L\s*,\s*"([^"]+)"')) {
        [void]$EngineModules.Add($m.Groups[1].Value)
    }
}

# Column-0 form the bundler can rewrite. Group 1 is the optional
# "local name = " prefix and must survive the replacement; group 2 is the
# module name. Anything else that looks like a require is reported by
# -RequireReport / -StrictRequires instead of being silently left in the bundle.
$RequirePattern    = '(?m)^((?:local\s+\w+\s*=\s*)?)require\s+"([^"]+)"'
# Diagnose literal requires at any position, excluding comments and strings.
# Dynamic expressions and shadowing of require are not statically resolved.
$AnyRequirePattern = '(?<![\w.:])\brequire\s*\(?\s*["'']([^"''\r\n]+)["'']'

# Mask Lua strings and comments without changing offsets or line numbers. A
# require mentioned in a long comment/string is data, not a dependency. This
# is a lexer for diagnostics, not a parser or a module-loader replacement.
function Get-LuaCodeMask {
    param([string]$Code)
    $chars = $Code.ToCharArray()
    $i = 0
    while ($i -lt $Code.Length) {
        $start = $i
        $comment = $i + 1 -lt $Code.Length -and $Code.Substring($i, 2) -eq '--'
        $quote = $Code[$i]
        $longAt = $i
        if ($comment) { $longAt += 2 }
        $long = $null
        if ($longAt -lt $Code.Length -and $Code[$longAt] -eq '[') {
            $long = [regex]::Match($Code.Substring($longAt), '^\[(=*)\[')
        }
        if ($null -ne $long -and $long.Success) {
            $close = ']' + $long.Groups[1].Value + ']'
            $end = $Code.IndexOf($close, $longAt + $long.Length, [StringComparison]::Ordinal)
            $i = if ($end -lt 0) { $Code.Length } else { $end + $close.Length }
        } elseif ($comment) {
            $end = $Code.IndexOf("`n", $i)
            $i = if ($end -lt 0) { $Code.Length } else { $end }
        } elseif ($quote -eq '"' -or $quote -eq "'") {
            $i++
            while ($i -lt $Code.Length) {
                if ($Code[$i] -eq '\') { $i = [Math]::Min($i + 2, $Code.Length); continue }
                if ($Code[$i] -eq $quote) { $i++; break }
                $i++
            }
        } else { $i++; continue }
        for ($j = $start; $j -lt $i; $j++) {
            if ($chars[$j] -ne "`r" -and $chars[$j] -ne "`n") { $chars[$j] = ' ' }
        }
    }
    return -join $chars
}

function Get-LuaLineNumber {
    param([string]$Text, [int]$Index)
    if ($Index -le 0) { return 1 }
    return 1 + ([regex]::Matches($Text.Substring(0, $Index), "`n")).Count
}

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

    # Build module map: name → content (and name → repo-relative path for reports)
    $moduleMap = @{}
    $moduleFiles = @{}
    foreach ($f in $allFiles) {
        $name = Get-ModuleName $f.FullName $MapDir
        # Root objects.lua is a build-only declaration, never a runtime module.
        if ($name -eq 'objects') { continue }
        $content = Get-Content $f.FullName -Raw -Encoding UTF8
        $moduleMap[$name] = $content
        $moduleFiles[$name] = ($f.FullName.Substring($MapDir.Length).TrimStart('\', '/') -replace '\\', '/')
    }

    # Entry point. NOTE: PowerShell variables are case-insensitive, so this must
    # not be called $entry — that would overwrite the $Entry parameter.
    $entryCode = $moduleMap[$Entry]
    if (-not $entryCode) { throw "$Entry.lua not found in $MapDir" }

    $records = [System.Collections.Generic.List[object]]::new()
    $active = [System.Collections.Generic.HashSet[string]]::new()
    [void]$active.Add($Entry)

    function Add-RequireRecord {
        param([string]$Source, [int]$Line, [string]$Module, [string]$Action, [string]$Note = '')
        [void]$records.Add([pscustomobject]@{
            Source = $Source; Line = $Line; Module = $Module; Action = $Action; Note = $Note
        })
    }

    # Inline require() calls recursively.
    # Pattern: local xxx = require "module.name"  or  require "module.name"
    function Inline-Requires {
        param(
            [string]$code,
            [hashtable]$modules,
            [hashtable]$files,
            [System.Collections.Generic.HashSet[string]]$visited,
            [string]$sourceFile
        )
        $mask = Get-LuaCodeMask $code
        $matches = @([regex]::Matches($code, $RequirePattern) | Where-Object {
            $mask.Substring($_.Index + $_.Groups[1].Length, 7) -eq 'require'
        })
        if ($matches.Count -eq 0) { return $code }

        # Replace by match position, not by literal text: the old
        # .Replace("require ""x""", ...) also rewrote indented or quoted
        # occurrences the regex never classified.
        $sb = [System.Text.StringBuilder]::new()
        $cursor = 0
        foreach ($m in $matches) {
            [void]$sb.Append($code.Substring($cursor, $m.Index - $cursor))
            $prefix = $m.Groups[1].Value
            $modName = $m.Groups[2].Value
            $line = Get-LuaLineNumber $code $m.Index
            if ($modules.ContainsKey($modName)) {
                if ($visited.Contains($modName)) {
                    # Already inlined — reference the module cache (NOT nil: the module
                    # may be required again inside another module's scope)
                    $cached = '__modcache["' + $modName + '"]'
                    # A bare table access is not a valid Lua statement.
                    if (-not $prefix) { $cached = 'do local _ = ' + $cached + ' end' }
                    [void]$sb.Append($prefix + $cached)
                    if ($active.Contains($modName)) {
                        Add-RequireRecord $sourceFile $line $modName 'cycle' 'module is still loading; its cache value is not ready'
                    } else {
                        Add-RequireRecord $sourceFile $line $modName 'cached' 'reused __modcache entry'
                    }
                } else {
                    # Mark before recursing so self/mutual requires hit the cache
                    # branch instead of recursing forever.
                    [void]$visited.Add($modName)
                    [void]$active.Add($modName)
                    $modCode = Inline-Requires -code $modules[$modName] -modules $modules `
                        -files $files -visited $visited -sourceFile $files[$modName]
                    [void]$active.Remove($modName)
                    # Keep the "local xxx = " prefix from the matched text; wrap the
                    # module as an IIFE that also records it in __modcache.
                    $replacement = "(function() local m = (function()`r`n$modCode`r`nend)() __modcache[`"$modName`"] = m return m end)()"
                    [void]$sb.Append($prefix + $replacement)
                    Add-RequireRecord $sourceFile $line $modName 'inlined' $files[$modName]
                }
            } elseif ($EngineModules.Contains($modName)) {
                # Leave the call intact: package.preload resolves it in-game.
                [void]$sb.Append($m.Value)
                Add-RequireRecord $sourceFile $line $modName 'engine' 'runtime module (package.preload)'
            } else {
                [void]$sb.Append($m.Value)
                Add-RequireRecord $sourceFile $line $modName 'missing' 'no map file and no engine module'
            }
            $cursor = $m.Index + $m.Length
        }
        [void]$sb.Append($code.Substring($cursor))
        return $sb.ToString()
    }

    # Requires outside the column-0 form are left untouched. Report them for the
    # files that are actually reachable: engine modules may appear anywhere and
    # still resolve at runtime, map modules cannot.
    function Find-UnmatchedRequires {
        param(
            [hashtable]$modules,
            [hashtable]$files,
            [System.Collections.Generic.HashSet[string]]$visited
        )
        foreach ($modName in $visited) {
            $code = $modules[$modName]
            $sourceFile = $files[$modName]
            $mask = Get-LuaCodeMask $code
            $spans = @()
            foreach ($p in [regex]::Matches($code, $RequirePattern)) {
                $spans += ,@($p.Index, ($p.Index + $p.Length))
            }
            foreach ($m in [regex]::Matches($code, $AnyRequirePattern)) {
                if ($mask.Substring($m.Index, 7) -ne 'require') { continue }
                $inside = $false
                foreach ($s in $spans) {
                    if ($m.Index -ge $s[0] -and $m.Index -lt $s[1]) { $inside = $true; break }
                }
                if ($inside) { continue }

                $target = $m.Groups[1].Value
                $line = Get-LuaLineNumber $code $m.Index
                if ($modules.ContainsKey($target)) {
                    Add-RequireRecord $sourceFile $line $target 'unmatched' `
                        'cannot be inlined here; put it at column 0 as: require "module"'
                } elseif ($EngineModules.Contains($target)) {
                    Add-RequireRecord $sourceFile $line $target 'engine' 'runtime module; not inlined'
                } else {
                    Add-RequireRecord $sourceFile $line $target 'missing' 'no map file and no engine module'
                }
            }
        }
    }

    $isMainEntry = $Entry -eq "war3map"
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    [void]$visited.Add($Entry)
    $bundled = Inline-Requires -code $entryCode -modules $moduleMap -files $moduleFiles `
        -visited $visited -sourceFile $moduleFiles[$Entry]
    Find-UnmatchedRequires -modules $moduleMap -files $moduleFiles -visited $visited

    # Conservative diagnostics for literal requires. External runtime loaders
    # may resolve missing modules; strict mode rejects them unless recognized.
    $missing = @($records | Where-Object { $_.Action -eq 'missing' })
    $unmatched = @($records | Where-Object { $_.Action -eq 'unmatched' })
    $cycles = @($records | Where-Object { $_.Action -eq 'cycle' })
    $unused = @($moduleMap.Keys | Where-Object { -not $visited.Contains($_) } | Sort-Object)

    if ($RequireReport) {
        Write-Host ("  Require report ({0}):" -f $moduleFiles[$Entry])
        foreach ($r in ($records | Sort-Object Source, Line, Module)) {
            Write-Host ("    [{0,-9}] {1,-28} <- {2}:{3}" -f $r.Action, $r.Module, $r.Source, $r.Line)
            if ($r.Note -and $r.Action -notin @('inlined', 'cached')) {
                Write-Host ("               {0}" -f $r.Note)
            }
        }
        if ($unused.Count -gt 0) {
            Write-Host ("  Unused Lua files (not reachable from {0}): {1}" -f $Entry, ($unused -join ', '))
        }
        $counts = @($records | Group-Object Action | Sort-Object Name |
            ForEach-Object { "$($_.Name)=$($_.Count)" })
        Write-Host ("  Require summary: " + ($counts -join ' ') +
            " modules=$($moduleMap.Count) reachable=$($visited.Count - 1) unused=$($unused.Count)")
    } elseif ($missing.Count -gt 0 -or $unmatched.Count -gt 0 -or $cycles.Count -gt 0) {
        Write-Host ("  WARNING: {0} missing, {1} un-inlined and {2} cyclic require(s); run with -RequireReport for detail" -f `
            $missing.Count, $unmatched.Count, $cycles.Count)
    }

    if ($StrictRequires -and ($missing.Count -gt 0 -or $unmatched.Count -gt 0 -or $cycles.Count -gt 0)) {
        foreach ($r in (@($missing) + @($unmatched) + @($cycles) | Sort-Object Source, Line)) {
            Write-Host ("  [require] {0}:{1}: {2} ({3})" -f $r.Source, $r.Line, $r.Module, $r.Action)
        }
        throw 'require validation failed: missing, unsupported or cyclic dependencies; resolve them before bundling, or drop -StrictRequires for runtime-managed modules'
    }

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
    # Derived from $WorkDir so concurrent pack runs (examples/scaffold checks)
    # with distinct -WorkDir values cannot clobber each other. With the default
    # -WorkDir this is still build\work-object{,.w3x}.
    $ObjectMap = "$WorkDir-object.w3x"
    $ObjectDir = "$WorkDir-object"
    if (Test-Path -LiteralPath $ObjectMap) { Remove-Item -LiteralPath $ObjectMap -Force }
    if (Test-Path -LiteralPath $ObjectDir) { Remove-Item -LiteralPath $ObjectDir -Recurse -Force }
    Use-W3x2Lni 'obj' $WorkDir $ObjectMap
    New-Item -ItemType Directory $ObjectDir -Force | Out-Null
    Use-W3x2Lni 'unpack' $ObjectMap $ObjectDir
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
    Move-Item -LiteralPath $ObjectDir -Destination $WorkDir
    Remove-Item -LiteralPath $ObjectMap -Force
}

# Opt in by placing objects.lua at the project root. Compiler stays outside MapDir.
$ObjectDeclarations = Join-Path $MapDir 'objects.lua'
if (Test-Path -LiteralPath $ObjectDeclarations) {
    Write-Host '  [1c] Compile code-defined unit/ability data'
    $ObjectCompiler = Join-Path $PSScriptRoot 'object-data\build.lua'
    if (-not (Test-Path -LiteralPath $ObjectCompiler)) { throw "Object compiler missing: $ObjectCompiler" }
    & $Lua -E $ObjectCompiler $ObjectDeclarations $WorkDir "$W3x2Lni\data\enUS-1.27.1"
    if ($LASTEXITCODE -ne 0) { throw 'Object declaration compilation failed' }
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
Write-Host ("  JASS anchors: " + (Get-JassAnchorSummary $jContent))

# Every array global is allocated lazily by the JASS VM on its first store, and
# the VM exposes no allocator. The only public way to materialise the block is a
# self-assign at the last legal index, so do it for every declared array before
# LoadScript: from then on jass.globals can write index > 0 uniformly. Cost is
# 32 KB per array (8192 * 4 bytes); -NoArrayPrealloc opts out.
$arrayGlobals = @()
if (-not $NoArrayPrealloc) {
    $arrayGlobals = @([regex]::Matches($jContent,
        '(?m)^[ \t]*(?:constant[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]+array[ \t]+([A-Za-z_][A-Za-z0-9_]*)') |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique)
}
$arrayAllocCall = ''
if ($arrayGlobals.Count -gt 0) {
    $arrayAllocCall = '    call JapiForceAllocArrays()' + $nl
    Write-Host ("  Array prealloc: " + $arrayGlobals.Count + " array globals")
}

# JASS wrappers: every UnitId bridge handler is exposed as a builtin-style
# five-step JASS wrapper, so map code can call it without hand-writing the
# hashtable dance. The generator reads the C++ registries, so the wrapper
# surface cannot drift.
#
# Native declarations are a separate axis (-WithGetFuncAddr): the map script is
# compiled before the plugin registers anything, yet a declaration DOES resolve
# when the name already exists in the engine's native table and the declaration
# precedes the first function. That is exactly how builtin-japi's GetFuncAddr
# works; see docs/planning/JASS-NATIVE-DECLARATIONS.md.
$jassWrapperBlock = ''
$wrapperProbe = ''
if ($WithJassWrappers) {
    $genScript = Join-Path $PSScriptRoot 'gen-jass-wrappers.ps1'
    if (-not (Test-Path $genScript)) { throw "missing generator: $genScript" }
    # Names the map already defines are left alone (the base map hand-writes a
    # few wrappers), everything else is generated.
    $mapFunctions = @([regex]::Matches($jContent,
        '(?m)^[ \t]*function[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]+takes') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $wrapperOut = "$WorkDir\jass-wrappers.j"
    $jassWrapperBlock = & $genScript -Root $Root -OutFile $wrapperOut -SkipNames $mapFunctions
    if (-not $jassWrapperBlock) { throw 'wrapper generator produced no output' }
    $wrapperCount = ([regex]::Matches($jassWrapperBlock, '(?m)^function ')).Count
    Write-Host ("  JASS wrappers: " + $wrapperCount + " generated, " + $mapFunctions.Count + " map functions left as-is")
    if ($jContent -match '(?m)^[ \t]*integer[ \t]+udg_lua_wrapper_ready\b' -and
        $jContent -notmatch '(?m)^[ \t]*function[ \t]+JapiWrapperProbeActions\b') {
        # The probe runs from a one-shot timer instead of inline map main():
        # the UI-backed handlers (GetLittleMapX / SetLittleMapX) are not ready
        # while the map is still on the loading screen, and a live value such
        # as GetFps cannot be sampled twice and compared.
        $wrapperProbe = $nl +
            '    set udg_lua_wrapper_ready = 1' + $nl +
            '    call TimerStart(CreateTimer(), 2.00, false, function JapiWrapperProbeActions)'
        $jassWrapperBlock += $nl +
            'function JapiWrapperProbeActions takes nothing returns nothing' + $nl +
            '    call DestroyTimer(GetExpiredTimer())' + $nl +
            '    set udg_lua_wrapper_int = GetGameVersion()' + $nl +
            '    set udg_lua_wrapper_hex = Hex(255)' + $nl +
            '    set udg_lua_wrapper_text = GetPluginVersion()' + $nl +
            '    set udg_lua_wrapper_real_base = GetLittleMapX()' + $nl +
            '    call SetLittleMapX(udg_lua_wrapper_real_base + 0.01)' + $nl +
            '    set udg_lua_wrapper_real = GetLittleMapX()' + $nl +
            '    call SetLittleMapX(udg_lua_wrapper_real_base)' + $nl +
            '    set udg_lua_wrapper_bool = GetChatState()' + $nl +
            'endfunction' + $nl
    }
}

# GetFuncAddr (-WithGetFuncAddr): builtin-japi's map side turns a JASS `code`
# into an integer via SetHeroLevels(f) + LoadInteger(ht, key, 0). SetHeroLevels is
# a real engine native -- registered by game.dll with signature "(C)V" -- that
# common.j never declares, so it is invisible to ordinary map code. Two rules
# make the declaration legal in callback mode: the name must already exist in
# the engine's native table, and the declaration must precede the first
# function. Our DLL then rewrites that node's func_address at load time, so the
# call reaches SetHeroLevels_capture instead of the engine's AI stub (which
# jumps to NULL outside an AI script). See docs/planning/JASS-NATIVE-DECLARATIONS.md.
$funcAddrDecl = ''
$funcAddrBlock = ''
$funcAddrProbe = ''
if ($WithGetFuncAddr) {
    $nativeDecls = [regex]::Matches($jContent, '(?m)^[ \t]*native[ \t]+SetHeroLevels\b')
    $declaredNative = $nativeDecls.Count -gt 0
    $declaredFunc = [bool]($jContent -match '(?m)^[ \t]*function[ \t]+GetFuncAddr[ \t]+takes\b')
    if ($nativeDecls.Count -gt 1) {
        $lines = @($nativeDecls | ForEach-Object { Get-LineNumberFromIndex $jContent $_.Index })
        throw ("war3map.j declares 'native SetHeroLevels' $($nativeDecls.Count) times (lines " +
            ($lines -join ', ') + '); the JASS compiler rejects duplicate declarations.`n' +
            "  JASS anchors: " + (Get-JassAnchorSummary $jContent) + "`n  Base map: $BaseMap")
    }
    if ($declaredNative) {
        # The declaration must precede the first function; a later declaration
        # is compiled after the script's function table is built and the map
        # silently drops back to the main menu. Do not try to "fix" this by
        # prepending a second declaration: that is a duplicate.
        $firstFunction = [regex]::Match($jContent,
            '(?m)^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+takes\b')
        if ($firstFunction.Success -and $nativeDecls[0].Index -gt $firstFunction.Index) {
            throw ("war3map.j declares 'native SetHeroLevels' at line " +
                (Get-LineNumberFromIndex $jContent $nativeDecls[0].Index) +
                ", after the first function at line " +
                (Get-LineNumberFromIndex $jContent $firstFunction.Index) +
                ". Move the declaration above every function (the globals block counts), or drop -WithGetFuncAddr.`n" +
                "  JASS anchors: " + (Get-JassAnchorSummary $jContent) + "`n  Base map: $BaseMap")
        }
    }
    if (-not $declaredNative) {
        $funcAddrDecl = '// japi: engine native that common.j omits; declared here so the map can take a code address.' + $nl +
            'native SetHeroLevels takes code f returns nothing' + $nl + $nl
    }
    if (-not $declaredFunc) {
        $funcAddrBlock = $nl +
            'function GetFuncAddr takes code f returns integer' + $nl +
            '    call SetHeroLevels(f)' + $nl +
            '    return LoadInteger(japi_ht, japi__key, 0)' + $nl +
            'endfunction' + $nl
    }
    if ($jContent -match '(?m)^[ \t]*integer[ \t]+udg_lua_getfunc_ready\b' -and
        $jContent -notmatch '(?m)^[ \t]*function[ \t]+JapiGetFuncAddrProbeActions\b') {
        # The probe runs from its own one-shot timer: map main() is too early for
        # the JASS globals it writes and for the DLL-registered natives it calls.
        $funcAddrProbe = $nl +
            '    call TimerStart(CreateTimer(), 2.20, false, function JapiGetFuncAddrProbeActions)'
        $funcAddrBlock += $nl +
            'function JapiGetFuncAddrTarget takes nothing returns nothing' + $nl +
            '    set udg_lua_getfunc_hits = udg_lua_getfunc_hits + 1' + $nl +
            'endfunction' + $nl +
            'function JapiGetFuncAddrTarget2 takes nothing returns nothing' + $nl +
            'endfunction' + $nl +
            'function JapiGetFuncAddrProbeActions takes nothing returns nothing' + $nl +
            '    call DestroyTimer(GetExpiredTimer())' + $nl +
            '    if udg_lua_japi_alive != 1 then' + $nl +
            '        return' + $nl +
            '    endif' + $nl +
            '    set udg_lua_getfunc_addr = GetFuncAddr(function JapiGetFuncAddrTarget)' + $nl +
            '    set udg_lua_getfunc_addr2 = GetFuncAddr(function JapiGetFuncAddrTarget2)' + $nl +
            '    set udg_lua_getfunc_addr3 = GetFuncAddr(function JapiGetFuncAddrTarget)' + $nl +
            '    call SaveStr(japi_ht, japi__key, 0, "(IS)V")' + $nl +
            '    call SaveInteger(japi_ht, japi__key, 1, udg_lua_getfunc_addr)' + $nl +
            '    call SaveStr(japi_ht, japi__key, 2, "jass-getfunc-target")' + $nl +
            '    call UnitId("func_bind_trigger_name")' + $nl +
            '    call SaveStr(japi_ht, japi__key, 0, "(I)V")' + $nl +
            '    call SaveInteger(japi_ht, japi__key, 1, udg_lua_getfunc_addr2)' + $nl +
            '    call UnitId("SaveFunc")' + $nl +
            '    set udg_lua_getfunc_ready = 1' + $nl +
            'endfunction' + $nl
    }
    if ($declaredNative -and $declaredFunc) {
        Write-Host '  GetFuncAddr: map already declares the native and the helper, nothing injected'
    } else {
        Write-Host '  GetFuncAddr: SetHeroLevels declaration + GetFuncAddr wrapper injected'
    }
}
# Lines that hand the shared hashtable over to the DLL and load war3map.lua.
# When the base map carries the bridge probe functions, exercise JASS -> Lua
# immediately after LoadScript (the Lua handlers register synchronously).
# A map that is already patched keeps its existing calls: prepending or
# appending duplicates is harmless at runtime but hides double injection.
$arrayAllocCallForScript = $arrayAllocCall
if ($arrayAllocCallForScript -and $jContent -match '(?m)^[ \t]*call[ \t]+JapiForceAllocArrays\b') {
    $arrayAllocCallForScript = ''
}
$wrapperProbeForScript = $wrapperProbe
if ($wrapperProbeForScript -and $jContent -match '(?m)^[ \t]*function[ \t]+JapiWrapperProbeActions[ \t]+takes\b') {
    $wrapperProbeForScript = ''
}
$funcAddrProbeForScript = $funcAddrProbe
if ($funcAddrProbeForScript -and $jContent -match '(?m)^[ \t]*function[ \t]+JapiGetFuncAddrProbeActions[ \t]+takes\b') {
    $funcAddrProbeForScript = ''
}
$loadScriptLines = $arrayAllocCallForScript +
    '    call SaveStr(japi_ht, japi__key, 0, "()V")' + $nl +
    '    call UnitId("LoadScript")' + $wrapperProbeForScript + $funcAddrProbeForScript
if ($jContent -match 'function LuaBridgeProbeCall') {
    $loadScriptLines += $nl +
        '    call LuaCallback1()' + $nl +
        '    set udg_lua_bridge_result = LuaBridgeProbeCall(10, 32)' + $nl +
        '    set udg_lua_error_result = LuaErrorProbeCall()' + $nl +
        '    set udg_lua_handle_result = LuaHandleProbeCall()'
}

$rebootProbeCall = ''
if ($TestReboot) {
    # The VM reset must be driven by pure JASS: closing Lua from inside a Lua
    # frame would tear down a live lua_pcall. A one-shot timer keeps it off the
    # war3map.lua call stack.
    if ($jContent -notmatch '(?m)^[ \t]*call[ \t]+TimerStart[^\r\n]*function[ \t]+JapiRebootProbe\b') {
        $rebootProbeCall = $nl +
            '    call TimerStart(CreateTimer(), 6.00, false, function JapiRebootProbe)'
        $loadScriptLines += $rebootProbeCall
    }
    $rebootProbeFunc = 'function JapiRebootProbe takes nothing returns nothing' + $nl +
        '    call UnitId("SimulateMapBoot")' + $nl +
        'endfunction' + $nl + $nl
    $rebootMain = [regex]::Match($jContent, '(?m)^[ \t]*function[ \t]+main[ \t]+takes\b')
    if (-not $rebootMain.Success) {
        throw ("war3map.j has no 'function main takes' for -TestReboot.`n" +
            "  JASS anchors: " + (Get-JassAnchorSummary $jContent) + "`n  Base map: $BaseMap")
    }
    if ($jContent -notmatch '(?m)^[ \t]*function[ \t]+JapiRebootProbe\b') {
        $jContent = $jContent.Substring(0, $rebootMain.Index) + $rebootProbeFunc +
            $jContent.Substring($rebootMain.Index)
    }
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

    $mainMatch = [regex]::Match($Content, '(?m)^[ \t]*function[ \t]+main[ \t]+takes\b')
    if (-not $mainMatch.Success) {
        throw ("war3map.j has no 'function main takes' to bootstrap.`n" +
            "  JASS anchors: " + (Get-JassAnchorSummary $Content) + "`n  Base map: $BaseMap")
    }
    $endFunc = [regex]::Match($Content.Substring($mainMatch.Index), '(?m)^[ \t]*endfunction\b')
    if (-not $endFunc.Success) {
        throw ("war3map.j main() (line " + (Get-LineNumberFromIndex $Content $mainMatch.Index) +
            ") has no matching 'endfunction'.`n  JASS anchors: " + (Get-JassAnchorSummary $Content) +
            "`n  Base map: $BaseMap")
    }
    $endFuncAt = $mainMatch.Index + $endFunc.Index
    $Content = $Content.Substring(0, $endFuncAt) + '    call JapiBootstrap()' + $nl +
        $Content.Substring($endFuncAt)

    $mainStart = [regex]::Match($Content, '(?m)^[ \t]*function[ \t]+main[ \t]+takes\b').Index
    $Content = $Content.Substring(0, $mainStart) + $bootstrap + $Content.Substring($mainStart)

    if (-not $globalsDecl) { return $Content }
    $anchors = Find-JassAnchors $Content
    if ($anchors.Globals.Success -and -not $anchors.EndGlobals.Success) {
        throw ("war3map.j has a 'globals' block (line " +
            (Get-LineNumberFromIndex $Content $anchors.Globals.Index) +
            ") but no 'endglobals'; cannot add japi_ht/japi__key safely.`n" +
            "  JASS anchors: " + (Get-JassAnchorSummary $Content) + "`n  Base map: $BaseMap")
    }
    if ($anchors.EndGlobals.Success) {
        $at = $anchors.EndGlobals.Index
        return $Content.Substring(0, $at) + $globalsDecl + $Content.Substring($at)
    }
    return 'globals' + $nl + $globalsDecl + 'endglobals' + $nl + $nl + $Content
}

$loadScriptMatches = [regex]::Matches($jContent,
    '(?m)^[ \t]*call[ \t]+UnitId[ \t]*\([ \t]*"LoadScript"[ \t]*\)')
$loadScriptMatch = $null
if ($loadScriptMatches.Count -gt 0) { $loadScriptMatch = $loadScriptMatches[0] }
if ($loadScriptMatches.Count -gt 1) {
    $lines = @($loadScriptMatches | ForEach-Object { Get-LineNumberFromIndex $jContent $_.Index })
    Write-Host ("  WARNING: found " + $loadScriptMatches.Count +
        " LoadScript calls (lines " + ($lines -join ', ') + '); patching the first only')
}
$initPluginMatches = [regex]::Matches($jContent,
    '(?m)^[ \t]*call[ \t]+initializePlugin[ \t]*\([ \t]*\)')

if ($null -ne $loadScriptMatch) {
    # Already patched (or a hand-written builtin-japi map). Add only the
    # requested pieces that the script does not already contain.
    $before = $arrayAllocCallForScript
    $after = $wrapperProbeForScript + $funcAddrProbeForScript + $rebootProbeCall
    if ($before -or $after) {
        $replacement = $before + $loadScriptMatch.Value + $after
        $jContent = $jContent.Substring(0, $loadScriptMatch.Index) + $replacement +
            $jContent.Substring($loadScriptMatch.Index + $loadScriptMatch.Length)
        $added = @()
        if ($arrayAllocCallForScript) { $added += 'array prealloc' }
        if ($wrapperProbeForScript) { $added += 'wrapper probe' }
        if ($funcAddrProbeForScript) { $added += 'GetFuncAddr probe' }
        if ($rebootProbeCall) { $added += 'VM reboot probe' }
        Write-Host ("  Bootstrap: LoadScript anchor present; added " + ($added -join ', '))
    } else {
        Write-Host '  Bootstrap: LoadScript anchor present, nothing to add'
    }
} elseif ($initPluginMatches.Count -gt 0) {
    if ($initPluginMatches.Count -gt 1) {
        $lines = @($initPluginMatches | ForEach-Object { Get-LineNumberFromIndex $jContent $_.Index })
        Write-Host ("  WARNING: found " + $initPluginMatches.Count +
            " initializePlugin calls (lines " + ($lines -join ', ') +
            '); patching the first only')
    }
    $jContent = Insert-AfterJassMatch $jContent $initPluginMatches[0] ($nl + $loadScriptLines)
    Write-Host '  Bootstrap: plugin marker map'
} else {
    if ($jContent -match 'UnitId\s*\(') {
        Write-Host ('  WARNING: map already uses UnitId() but has neither a LoadScript call nor an ' +
            'initializePlugin call; review the injected bootstrap for conflicts')
    }
    $jContent = Add-JapiBootstrap $jContent $loadScriptLines
    Write-Host '  Bootstrap: injected into map main() (foreign map)'
}

# The allocator function alone is not enough: without the call before
# LoadScript the arrays stay lazy and jass.globals drops every index > 0 write
# with only a debug-log line. Catch that here instead of in a live test.
if ($arrayGlobals.Count -gt 0 -and
    $jContent -notmatch '(?m)^[ \t]*call[ \t]+JapiForceAllocArrays\b') {
    throw ("war3map.j declares " + $arrayGlobals.Count +
        " array global(s) but the patched script has no JapiForceAllocArrays() call; " +
        "jass.globals writes past index 0 would be ignored.`n" +
        "  JASS anchors: " + (Get-JassAnchorSummary $jContent) + "`n  Base map: $BaseMap")
}

# Helper that materialises every declared array block. Defined right after
# endglobals so both the bootstrap above and map main() can call it.
if ($arrayGlobals.Count -gt 0) {
    $allocBody = ''
    foreach ($arrayName in $arrayGlobals) {
        $allocBody += '    set ' + $arrayName + '[8191] = ' + $arrayName + '[8191]' + $nl
    }
    $allocFunc = '// japi array preallocation injected by tools/pack.ps1' + $nl +
        '// JASS allocates an array block on its first store, so this self-assign is the' + $nl +
        '// only public way to make jass.globals writes legal at index > 0.' + $nl +
        'function JapiForceAllocArrays takes nothing returns nothing' + $nl +
        $allocBody +
        'endfunction' + $nl + $nl
    $endGlobals = [regex]::Match($jContent, '(?m)^[ \t]*endglobals\b')
    if (-not $endGlobals.Success) {
        throw ("war3map.j declares " + $arrayGlobals.Count +
            " array global(s) but has no top-level 'endglobals' anchor, so JapiForceAllocArrays " +
            "cannot be inserted safely (use -NoArrayPrealloc to skip it).`n" +
            "  JASS anchors: " + (Get-JassAnchorSummary $jContent) + "`n  Base map: $BaseMap")
    }
    $existingAlloc = [regex]::Match($jContent,
        '(?ms)^[ \t]*function[ \t]+JapiForceAllocArrays\b.*?^[ \t]*endfunction\b')
    if ($existingAlloc.Success) {
        $jContent = $jContent.Substring(0, $existingAlloc.Index) + $allocFunc +
            $jContent.Substring($existingAlloc.Index + $existingAlloc.Length)
        Write-Host '  Array prealloc: existing helper refreshed'
    } else {
        $anchor = $endGlobals.Index + $endGlobals.Length
        $jContent = $jContent.Substring(0, $anchor) + $nl + $nl + $allocFunc + $jContent.Substring($anchor)
        Write-Host '  Array prealloc: JapiForceAllocArrays injected'
    }
}

# Wrapper block goes right after endglobals: pjass wants every function defined
# before its first call, and both map code and the probe inside main() call them.
if ($jassWrapperBlock) {
    $endGlobals = [regex]::Match($jContent, '(?m)^[ \t]*endglobals\b')
    if (-not $endGlobals.Success) {
        throw ("war3map.j has no top-level 'endglobals' anchor for -WithJassWrappers; " +
            "the generated wrapper block cannot be inserted.`n" +
            "  JASS anchors: " + (Get-JassAnchorSummary $jContent) + "`n  Base map: $BaseMap")
    }
    $anchor = $endGlobals.Index + $endGlobals.Length
    $jContent = $jContent.Substring(0, $anchor) + $nl + $nl + $jassWrapperBlock + $jContent.Substring($anchor)
    Write-Host '  JASS wrappers: injected after endglobals'
}
# GetFuncAddr helper block also goes right after endglobals: pjass wants every
# function defined before its first call, and the probe timer calls it from main().
if ($funcAddrBlock) {
    $endGlobals = [regex]::Match($jContent, '(?m)^[ \t]*endglobals\b')
    if (-not $endGlobals.Success) {
        throw ("war3map.j has no top-level 'endglobals' anchor for -WithGetFuncAddr; " +
            "the GetFuncAddr helper cannot be inserted.`n" +
            "  JASS anchors: " + (Get-JassAnchorSummary $jContent) + "`n  Base map: $BaseMap")
    }
    $anchor = $endGlobals.Index + $endGlobals.Length
    $jContent = $jContent.Substring(0, $anchor) + $funcAddrBlock + $jContent.Substring($anchor)
    Write-Host '  GetFuncAddr: helper injected after endglobals'
}
# The native declaration is the one piece that has to precede the first function
# (the globals block counts): placed after any function the whole script fails to
# load, the game drops back to the main menu and the DLL never initializes.
if ($funcAddrDecl) {
    $jContent = $funcAddrDecl + $jContent
    Write-Host '  GetFuncAddr: native SetHeroLevels declared at top of war3map.j'
}
Set-Content $JFile $jContent -Encoding ASCII -NoNewline
Write-Host ("  JASS anchors after patch: " + (Get-JassAnchorSummary $jContent))

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


# Deterministic BLP2 fixtures for the D3D SDK asset acceptance. They are written
# into the map MPQ only: asset:// decoding goes through the in-memory palette /
# DXT / BGRA paths, which is the only BLP route the DLL supports (the BMP probe
# installed beside war3.exe only exercises the d3dx file path).
function New-Blp2Fixture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('raw', 'palette', 'dxt1', 'solid', 'bad')][string]$Kind,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height
    )

    $headerSize = 148
    $pixels = $Width * $Height
    $payload = New-Object System.Collections.Generic.List[byte]

    switch ($Kind) {
        'raw' {
            # encoding 3: straight BGRA, no palette and no d3dx involved.
            for ($y = 0; $y -lt $Height; $y++) {
                for ($x = 0; $x -lt $Width; $x++) {
                    $even = (((([math]::Floor($x / 8)) + ([math]::Floor($y / 8))) % 2) -eq 0)
                    if ($even) { $payload.AddRange([byte[]]@(40, 40, 220, 255)) }
                    else { $payload.AddRange([byte[]]@(220, 40, 40, 255)) }
                }
            }
            $dataSize = $payload.Count
        }
        'palette' {
            # encoding 1, alpha_depth 8: BGRA palette, indices, then one alpha byte per pixel.
            for ($i = 0; $i -lt 256; $i++) {
                $payload.AddRange([byte[]]@($i, (255 - $i), (($i * 7) % 256), 255))
            }
            for ($y = 0; $y -lt $Height; $y++) {
                for ($x = 0; $x -lt $Width; $x++) {
                    $even = (((([math]::Floor($x / 8)) + ([math]::Floor($y / 8))) % 2) -eq 0)
                    if ($even) { $payload.Add([byte]17) } else { $payload.Add([byte]203) }
                }
            }
            for ($i = 0; $i -lt $pixels; $i++) { $payload.Add([byte]255) }
            # sizes[0] covers indices plus the trailing alpha plane that
            # alpha_depth 8 implies; inspect_blp2 checks both.
            $dataSize = $pixels * 2
        }
        'dxt1' {
            # encoding 2, alpha_encoding 0: DXT1 blocks, opaque white colour0.
            $blocks = [int]([math]::Ceiling($Width / 4.0) * [math]::Ceiling($Height / 4.0))
            $block = [byte[]]@(0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
            for ($i = 0; $i -lt $blocks; $i++) { $payload.AddRange($block) }
            $dataSize = $payload.Count
        }
        'solid' {
            # encoding 3: one flat colour for the whole texture. The demo tints it
            # with the D3D vertex colour, so a 8x8 white sheet draws any bar.
            for ($i = 0; $i -lt $pixels; $i++) {
                $payload.AddRange([byte[]]@(255, 255, 255, 255))
            }
            $dataSize = $payload.Count
        }
        'bad' {
            # encoding 4 is outside the supported subset: validate() must reject
            # it as UnsupportedFormat even though offsets and sizes look sane.
            for ($i = 0; $i -lt ($pixels * 4); $i++) { $payload.Add([byte]0) }
            $dataSize = $payload.Count
        }
    }

    $encoding = switch ($Kind) { 'raw' { 3 } 'solid' { 3 } 'palette' { 1 } 'dxt1' { 2 } default { 4 } }
    $alphaDepth = if ($Kind -eq 'palette') { 8 } else { 0 }
    $paletteBytes = if ($Kind -eq 'palette') { 1024 } else { 0 }
    $dataOffset = $headerSize + $paletteBytes

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    $writer.Write([byte[]]@(0x42, 0x4C, 0x50, 0x32))  # 'BLP2'
    $writer.Write([uint32]0)                          # type
    $writer.Write([byte]$encoding)
    $writer.Write([byte]$alphaDepth)
    $writer.Write([byte]0)                            # alpha_encoding (DXT1 only)
    $writer.Write([byte]0)                            # has_mips
    $writer.Write([uint32]$Width)
    $writer.Write([uint32]$Height)
    for ($i = 0; $i -lt 16; $i++) {
        $writer.Write([uint32]$(if ($i -eq 0) { $dataOffset } else { 0 }))
    }
    for ($i = 0; $i -lt 16; $i++) {
        $writer.Write([uint32]$(if ($i -eq 0) { $dataSize } else { 0 }))
    }
    $writer.Write([byte[]]$payload.ToArray())
    $writer.Flush()
    [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
    $writer.Close()
}

# Deterministic MPQ-only texture fixtures for the public D3D SDK acceptance.
# They intentionally never exist beside war3.exe, proving asset:// uses Storm.
if ($InteractiveD3D) {
    $probePng = 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAA5SURBVDhPY5Db8v8/Mv4fIIeCCckzEFJASH4QGIAuQEgDuvxwMABdgJAGdPnhYAC6ACEN6PLDwAAAlMCeH43ym2UAAAAASUVORK5CYII='
    [System.IO.File]::WriteAllBytes(
        "$WorkDir\d3d-sdk-probe.png", [Convert]::FromBase64String($probePng))
    [System.IO.File]::WriteAllBytes(
        "$WorkDir\d3d-sdk-corrupt.png", [System.Text.Encoding]::ASCII.GetBytes('not-an-image'))

    # BLP2 subsets: raw BGRA, paletted, DXT1, plus one unsupported encoding.
    New-Blp2Fixture -Path "$WorkDir\d3d-sdk-blp2-raw.blp" -Kind raw -Width 48 -Height 32
    New-Blp2Fixture -Path "$WorkDir\d3d-sdk-blp2-palette.blp" -Kind palette -Width 64 -Height 48
    New-Blp2Fixture -Path "$WorkDir\d3d-sdk-blp2-dxt1.blp" -Kind dxt1 -Width 64 -Height 32
    New-Blp2Fixture -Path "$WorkDir\d3d-sdk-blp2-bad.blp" -Kind bad -Width 16 -Height 16
}

# One flat white sheet for the demo's D3D overlays: every bar is this texture
# tinted through set_color(), so no extra art is needed per bar colour.
if ($Demo -or $InteractiveD3D) {
    New-Blp2Fixture -Path "$WorkDir\japi-bar-white.blp" -Kind solid -Width 8 -Height 8
}

# Update MPQ listfile so w3x2lni includes the new files
$listfile = "$WorkDir\(listfile)"
$needed = @("callback", "japi.tga")
if ($InteractiveD3D) {
    $needed += @("d3d-sdk-probe.png", "d3d-sdk-corrupt.png")
    $needed += @("d3d-sdk-blp2-raw.blp", "d3d-sdk-blp2-palette.blp",
        "d3d-sdk-blp2-dxt1.blp", "d3d-sdk-blp2-bad.blp")
}
if ($Demo -or $InteractiveD3D) {
    $needed += @("japi-bar-white.blp")
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
if ($SkipRepack) {
    Write-Host '  [5/5] Repack skipped (-SkipRepack); no .w3x written'
    Write-Host "  Work dir: $WorkDir"
    return
}
Write-Host '  [5/5] Repack'
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir -Force | Out-Null }
Use-W3x2Lni 'pack' $WorkDir $OutFile

Write-Host "  Done -> $OutFile"

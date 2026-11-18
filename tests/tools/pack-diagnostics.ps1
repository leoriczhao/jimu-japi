# Regression checks for the actual pack.ps1 output. No game process is started.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests/tools/pack-diagnostics.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Pack = Join-Path $Root 'tools/pack.ps1'
$Lua = Join-Path $Root 'tools/w3x2lni/bin/w3x2lni-lua.exe'
$Scratch = Join-Path $Root ('build/pack-diagnostics-' + [guid]::NewGuid().ToString('N'))
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:passed = 0
$script:failed = 0
$DefaultJass = @'
globals
endglobals
function config takes nothing returns nothing
endfunction
function main takes nothing returns nothing
endfunction
'@

function Put([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] $Name : $_" }
}
function PackCase {
    param([string]$Name, [hashtable]$Files, [string]$Jass = $DefaultJass,
          [string[]]$Options = @(), [string]$Base = '')
    $dir = Join-Path $Scratch $Name
    foreach ($file in $Files.Keys) { Put (Join-Path "$dir/map" $file) $Files[$file] }
    if (-not $Base) { $Base = "$dir/base"; Put "$Base/war3map.j" $Jass }
    $cli = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Pack,
        '-BaseMap', $Base, '-MapDir', "$dir/map", '-WorkDir', "$dir/work",
        '-OutFile', "$dir/output.w3x", '-SkipRepack', '-RequireReport') + $Options
    # Native stderr is included in expected-failure cases rather than throwing
    # a PowerShell NativeCommandError before the diagnostic can be asserted.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = (& powershell.exe @cli 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return [pscustomobject]@{ Code = $code; Text = $text; Work = "$dir/work"; Out = "$dir/output.w3x" }
}

try {
    Case 'missing dependency includes source and line' {
        $r = PackCase missing @{'war3map.lua' = "-- comment`nrequire `"lib.absent`""} -Options '-StrictRequires'
        Assert ($r.Code -ne 0 -and $r.Text -match 'war3map.lua:2: lib.absent') $r.Text
    }
    Case 'default mode warns without blocking external runtime loaders' {
        $r = PackCase permissive @{'war3map.lua' = 'require "external"'}
        Assert ($r.Code -eq 0 -and $r.Text -match '\[missing') $r.Text
    }
    Case 'known engine modules remain runtime dependencies' {
        $r = PackCase engine @{'war3map.lua' = "local j = require `"jass.common`"`nlocal k = require('jass.japi')"} -Options '-StrictRequires'
        Assert ($r.Code -eq 0 -and $r.Text -match '\[engine') $r.Text
        Assert (-not (Test-Path $r.Out)) '-SkipRepack wrote an archive'
    }
    Case 'block comments and long strings are not dependencies or rewritten' {
        $source = @'
--[==[
require "missing.comment"
]==]
local text = [=[
require "lib.exists"
]=]
local escaped = "a\" require 'missing.string'"
-- require "missing.line"
local actual = require "lib.exists"
assert(actual.value == 42)
assert(text:find('require "lib.exists"', 1, true))
'@
        $r = PackCase quoted @{'war3map.lua' = $source; 'lib/exists.lua' = 'return {value = 42}'} -Options '-StrictRequires'
        Assert ($r.Code -eq 0) $r.Text
        & $Lua "$($r.Work)/war3map.lua"
        Assert ($LASTEXITCODE -eq 0) 'generated Lua changed string/comment semantics'
    }
    Case 'indented or parenthesized map require is diagnosed' {
        $r = PackCase unsupported @{'war3map.lua' = '  local a = require("lib.a")'; 'lib/a.lua' = 'return {}'} -Options '-StrictRequires'
        Assert ($r.Code -ne 0 -and $r.Text -match 'war3map.lua:1: lib.a \(unmatched\)') $r.Text
    }
    Case 'mid-line map require is diagnosed' {
        $r = PackCase midline @{'war3map.lua' = 'local x = 1; require "lib.a"'; 'lib/a.lua' = 'return {}'} -Options '-StrictRequires'
        Assert ($r.Code -ne 0 -and $r.Text -match '\(unmatched\)') $r.Text
    }
    Case 'cyclic dependencies are rejected in strict mode' {
        $r = PackCase cycle @{
            'war3map.lua' = 'local a = require "lib.a"'
            'lib/a.lua' = "local b = require `"lib.b`"`nreturn {}"
            'lib/b.lua' = "local a = require `"lib.a`"`nreturn {}"
        } -Options '-StrictRequires'
        Assert ($r.Code -ne 0 -and $r.Text -match 'lib/b.lua:1: lib.a \(cycle\)') $r.Text
    }
    Case 'repeated bare require compiles and initializes only once' {
        $r = PackCase repeated @{
            'war3map.lua' = "require `"lib.a`"`nrequire `"lib.a`"`nassert(_G.loads == 1)"
            'lib/a.lua' = '_G.loads = (_G.loads or 0) + 1; return {}'
        } -Options '-StrictRequires'
        Assert ($r.Code -eq 0) $r.Text
        & $Lua "$($r.Work)/war3map.lua"
        Assert ($LASTEXITCODE -eq 0) 'repeated bare require produced invalid Lua or reinitialized module'
    }
    Case 'missing main reports JASS anchors' {
        $r = PackCase anchor @{'war3map.lua' = 'return {}'} -Jass "globals`nendglobals"
        Assert ($r.Code -ne 0 -and $r.Text -match 'main=absent' -and $r.Text -match 'JASS anchors') $r.Text
    }
    Case 'native declarations after functions are rejected with position' {
        $r = PackCase native @{'war3map.lua' = 'return {}'} -Jass ($DefaultJass + "`nnative SetHeroLevels takes code f returns nothing") -Options '-WithGetFuncAddr'
        Assert ($r.Code -ne 0 -and $r.Text -match 'after the first function') $r.Text
    }
    Case 'repatch retains one allocator and one load call' {
        $jass = [regex]::Replace($DefaultJass, '(?m)^globals\r?$', "globals`n    integer array values")
        $r = PackCase arrays @{'war3map.lua' = 'return {}'} -Jass $jass
        Assert ($r.Code -eq 0) $r.Text
        $r2 = PackCase arrays_again @{'war3map.lua' = 'return {}'} -Base $r.Work
        Assert ($r2.Code -eq 0) $r2.Text
        $output = Get-Content "$($r2.Work)/war3map.j" -Raw
        Assert (([regex]::Matches($output, '(?m)^function JapiForceAllocArrays\b')).Count -eq 1) 'allocator duplicated'
        Assert (([regex]::Matches($output, 'call UnitId\("LoadScript"\)')).Count -eq 1) 'LoadScript duplicated'
    }
    Case 'wrapper and GetFuncAddr probes are not duplicated by repacking' {
        $options = @('-WithJassWrappers', '-WithGetFuncAddr')
        $r = PackCase probes @{'war3map.lua' = 'return {}'} -Base (Join-Path $Root 'reference/empty-map') -Options $options
        Assert ($r.Code -eq 0) $r.Text
        $r2 = PackCase probes_again @{'war3map.lua' = 'return {}'} -Base $r.Work -Options $options
        Assert ($r2.Code -eq 0) $r2.Text
        $output = Get-Content "$($r2.Work)/war3map.j" -Raw
        foreach ($name in @('JapiWrapperProbeActions', 'JapiGetFuncAddrProbeActions', 'GetFuncAddr')) {
            Assert (([regex]::Matches($output, "(?m)^function $name\b")).Count -eq 1) "$name duplicated"
        }
    }
    Case 'reboot probe survives repatching without duplicate functions/timers' {
        $files = @{'war3map.lua' = 'return {}'; 'tests/reboot_child.lua' = 'return {}'}
        $r = PackCase reboot $files -Options '-TestReboot'
        Assert ($r.Code -eq 0) $r.Text
        $r2 = PackCase reboot_again $files -Base $r.Work -Options '-TestReboot'
        Assert ($r2.Code -eq 0) $r2.Text
        $output = Get-Content "$($r2.Work)/war3map.j" -Raw
        Assert (([regex]::Matches($output, '(?m)^function JapiRebootProbe\b')).Count -eq 1) 'reboot function duplicated'
        Assert (([regex]::Matches($output, 'call TimerStart\(CreateTimer\(\), 6.00, false, function JapiRebootProbe\)')).Count -eq 1) 'reboot timer missing or duplicated'
    }
} finally {
    if (Test-Path -LiteralPath $Scratch) { Remove-Item -LiteralPath $Scratch -Recurse -Force }
}
Write-Host "Pack diagnostics: $script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }

# ============================================================================
# gen-jass-wrappers.ps1 - generate JASS wrappers for UnitId bridge handlers
#
# Callback mode cannot declare custom natives in war3map.j: the map script is
# compiled before the plugin registers anything, so a "native EXGetUnitString"
# line kills the load before main() runs. The supported shape is the builtin
# five-step wrapper: parameters go into hashtable slots 1..N, slot 0 carries the
# spec string, UnitId(name) dispatches, and the return value comes back in
# slot 0.
#
# This script derives the wrappers from the handler registries so they can never
# drift from the C++ side:
#   src/src/extensions/ex_natives/Initialize.cpp    EX* + game info handlers
#   src/src/d3d9/handler_manifest.json              D3D compatibility surface
#   src/src/lua_engine/lua_engine/libs_message.cpp  message/input surface
#
# Supported spec types: I R S B V H<type>;  (handle parameters are marshalled
# as integer ids - SaveInteger(GetHandleId(h)) - matching bridge_dispatch's
# ht_load_handle ABI; rect round-trips through SaveRectHandle/LoadRectHandle).
# Handle *returns* other than Hrect; are skipped: the bridge writes a raw
# integer id and 1.27a JASS has no integer -> handle cast.
#
# Usage:
#   .\tools\gen-jass-wrappers.ps1 -OutFile build\jass-wrappers.j
#   .\tools\gen-jass-wrappers.ps1 -SkipNames GetMouseX,GetMouseY
#   .\tools\gen-jass-wrappers.ps1 -Verbose   # list skipped handlers
# ============================================================================
[CmdletBinding()]
param(
    [string]$Root = "",
    [string]$OutFile = "",
    [string[]]$SkipNames = @()
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$nl = [string][char]13 + [string][char]10

# Handlers that must not be wrapped: they are plugin lifecycle entry points,
# not map-facing natives.
$BuiltinExclusions = @(
    'LoadScript',
    'SimulateMapBoot',
    'open_code_run_logs',
    'SaveFunc',
    'func_bind_trigger_name'
)

$SkipSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($n in $BuiltinExclusions) { [void]$SkipSet.Add($n) }
foreach ($n in $SkipNames) { if ($n) { [void]$SkipSet.Add($n) } }

function Get-Registry([string]$Path, [string]$Pattern, [string]$Source) {
    if (-not (Test-Path $Path)) { throw "handler registry not found: $Path" }
    $text = Get-Content $Path -Raw -Encoding UTF8
    $rows = @()
    foreach ($m in [regex]::Matches($text, $Pattern)) {
        $rows += [pscustomobject]@{
            Name   = $m.Groups[1].Value
            Spec   = $m.Groups[2].Value
            Source = $Source
        }
    }
    return $rows
}

function Get-SpecResult([string]$Spec) {
    # Tokenise a bridge spec such as "(SRRRRII)I" or "(IHrect;)V".
    $m = [regex]::Match($Spec, '^\(([^)]*)\)(.+)$')
    if (-not $m.Success) { return $null }
    $params = @()
    foreach ($p in [regex]::Matches($m.Groups[1].Value, 'H[a-z]+;|[IRSBV]')) {
        $params += $p.Value
    }
    $ret = $m.Groups[2].Value
    if ($ret -notmatch '^(H[a-z]+;|[IRSBV])$') { return $null }
    return [pscustomobject]@{ Params = $params; Ret = $ret }
}

$typeMap = @{
    'I' = @{ Jass = 'integer'; Save = 'SaveInteger'; Load = 'LoadInteger' }
    'R' = @{ Jass = 'real';    Save = 'SaveReal';    Load = 'LoadReal' }
    'S' = @{ Jass = 'string';  Save = 'SaveStr';     Load = 'LoadStr' }
    'B' = @{ Jass = 'boolean'; Save = 'SaveBoolean'; Load = 'LoadBoolean' }
}

function ConvertTo-JassType([string]$Token, [ref]$SaveCall) {
    if ($typeMap.ContainsKey($Token)) {
        $SaveCall.Value = $typeMap[$Token].Save
        return $typeMap[$Token].Jass
    }
    $h = [regex]::Match($Token, '^H([a-z]+);$')
    if (-not $h.Success) { throw "unsupported spec token: $Token" }
    $kind = $h.Groups[1].Value
    if ($kind -eq 'rect') { $SaveCall.Value = 'SaveRectHandle' } else { $SaveCall.Value = 'SaveInteger' }
    return $kind
}

$exSource = Join-Path $Root 'src/src/extensions/ex_natives/Initialize.cpp'
$msgSource = Join-Path $Root 'src/src/lua_engine/lua_engine/libs_message.cpp'
$manifestPath = Join-Path $Root 'src/src/d3d9/handler_manifest.json'

$registries = @()
$registries += Get-Registry $exSource 'register_cpp_handler\(\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*"([^"]+)"' 'ex-native'
$registries += Get-Registry $msgSource '\breg\(\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*"([^"]+)"' 'message'
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($h in $manifest.handlers) {
        $registries += [pscustomobject]@{ Name = $h.name; Spec = $h.spec; Source = 'd3d' }
    }
} else {
    Write-Warning "handler manifest not found: $manifestPath"
}

$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$bySource = [ordered]@{}
$skipped = @()
foreach ($row in $registries) {
    if (-not $row.Name -or -not $row.Spec) { continue }
    if ($SkipSet.Contains($row.Name)) {
        $skipped += ($row.Name + ' (excluded)')
        continue
    }
    if (-not $seen.Add($row.Name)) { continue }
    $parsed = Get-SpecResult $row.Spec
    if (-not $parsed) {
        $skipped += ($row.Name + ' ' + $row.Spec + ' (unsupported spec)')
        continue
    }
    if ($parsed.Ret -match '^H([a-z]+);$' -and $parsed.Ret -ne 'Hrect;') {
        $skipped += ($row.Name + ' ' + $row.Spec + ' (handle return needs a JASS cast)')
        continue
    }
    if (-not $bySource.Contains($row.Source)) { $bySource[$row.Source] = @() }
    $bySource[$row.Source] += [pscustomobject]@{ Name = $row.Name; Spec = $row.Spec; Parsed = $parsed }
}

$sourceTitles = @{
    'ex-native' = 'EX* / game info handlers (src/src/extensions/ex_natives/Initialize.cpp)'
    'message'   = 'message / input handlers (src/src/lua_engine/lua_engine/libs_message.cpp)'
    'd3d'       = 'D3D compatibility handlers (src/src/d3d9/handler_manifest.json)'
}

$total = 0
foreach ($src in $bySource.Keys) { $total += $bySource[$src].Count }

$lines = @()
$lines += '// ============================================================================'
$lines += '// Auto-generated by tools/gen-jass-wrappers.ps1 - do not edit by hand.'
$lines += ('// ' + $total + ' wrappers generated from the UnitId bridge registries.')
$lines += '//'
$lines += '// Callback-mode maps cannot declare custom natives, so each bridge handler gets'
$lines += '// a five-step JASS wrapper: params -> hashtable slots, slot 0 -> spec, UnitId()'
$lines += '// dispatch, return value back from slot 0. Regenerate with tools/pack.ps1'
$lines += '// -WithJassWrappers (or run the generator directly).'
$lines += '// ============================================================================'

foreach ($src in $bySource.Keys) {
    $entries = $bySource[$src] | Sort-Object Name
    $lines += ''
    $lines += ('// ---- ' + $sourceTitles[$src] + ' ----')
    foreach ($e in $entries) {
        $lines += ''
        $paramTypes = @()
        for ($i = 0; $i -lt $e.Parsed.Params.Count; $i++) {
            $saveCall = ''
            $jassType = ConvertTo-JassType $e.Parsed.Params[$i] ([ref]$saveCall)
            $paramTypes += ($jassType + ' arg' + ($i + 1))
        }
        $retType = 'nothing'
        $retLine = ''
        if ($e.Parsed.Ret -eq 'V') {
            $retLine = ''
        } elseif ($typeMap.ContainsKey($e.Parsed.Ret)) {
            $retType = $typeMap[$e.Parsed.Ret].Jass
            $retLine = '    return ' + $typeMap[$e.Parsed.Ret].Load + '(japi_ht, japi__key, 0)'
        } else {
            $retType = 'rect'
            $retLine = '    return LoadRectHandle(japi_ht, japi__key, 0)'
        }
        $signature = 'function ' + $e.Name + ' takes '
        if ($paramTypes.Count -eq 0) { $signature += 'nothing' } else { $signature += ($paramTypes -join ', ') }
        $signature += ' returns ' + $retType
        $lines += $signature
        $lines += '    call SaveStr(japi_ht, japi__key, 0, "' + $e.Spec + '")'
        for ($i = 0; $i -lt $e.Parsed.Params.Count; $i++) {
            $saveCall = ''
            [void](ConvertTo-JassType $e.Parsed.Params[$i] ([ref]$saveCall))
            $arg = 'arg' + ($i + 1)
            if ($e.Parsed.Params[$i] -match '^H' -and $e.Parsed.Params[$i] -ne 'Hrect;') {
                $arg = 'GetHandleId(' + $arg + ')'
            }
            $lines += '    call ' + $saveCall + '(japi_ht, japi__key, ' + ($i + 1) + ', ' + $arg + ')'
        }
        $lines += '    call UnitId("' + $e.Name + '")'
        if ($retLine) { $lines += $retLine }
        $lines += 'endfunction'
    }
}

$text = ($lines -join $nl) + $nl

if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    Set-Content -Path $OutFile -Value $text -Encoding ASCII -NoNewline
}

$summary = 'JASS wrappers: ' + $total + ' generated'
$parts = @()
foreach ($src in $bySource.Keys) { $parts += ($bySource[$src].Count.ToString() + ' ' + $src) }
if ($parts.Count -gt 0) { $summary += ' (' + ($parts -join ', ') + ')' }
if ($skipped.Count -gt 0) { $summary += ', ' + $skipped.Count + ' skipped' }
Write-Host $summary
foreach ($s in $skipped) { Write-Verbose ('  skipped: ' + $s) }

# Emit the wrapper text so callers can pipe it straight into a map script.
return $text

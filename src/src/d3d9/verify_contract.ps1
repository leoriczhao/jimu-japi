[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$ManifestPath = Join-Path $PSScriptRoot 'handler_manifest.json'
$ApiPath = Join-Path $PSScriptRoot 'api.cpp'
$MessagePath = Join-Path $RepoRoot 'src\src\lua_engine\lua_engine\libs_message.cpp'
$ExPath = Join-Path $RepoRoot 'src\src\extensions\ex_natives\Initialize.cpp'
$TestPath = Join-Path $RepoRoot 'map\tests\test_d3d.lua'

$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$handlers = @($manifest.handlers)
if ($handlers.Count -ne [int]$manifest.handler_count) {
    throw "manifest handler_count=$($manifest.handler_count), actual=$($handlers.Count)"
}
if ([int]$manifest.legacy_handler_count -ne $handlers.Count - 1) {
    throw 'legacy_handler_count must be the surface count before GetTextureSrcRect was restored'
}
$duplicates = $handlers | Group-Object name | Where-Object Count -gt 1
if ($duplicates) {
    throw "duplicate manifest names: $($duplicates.Name -join ', ')"
}

function Read-Registrations([string]$Path, [string]$Pattern) {
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    [regex]::Matches($text, $Pattern) | ForEach-Object {
        [pscustomobject]@{ Name = $_.Groups[1].Value; Spec = $_.Groups[2].Value }
    }
}

$apiRegs = @(Read-Registrations $ApiPath 'reg\s*\(\s*"([^"]+)"\s*,\s*"([^"]+)"')
$messageRegs = @(Read-Registrations $MessagePath 'reg\s*\(\s*"([^"]+)"\s*,\s*"([^"]+)"')
$exRegs = @(Read-Registrations $ExPath 'register_cpp_handler\s*\(\s*"([^"]+)"\s*,\s*"([^"]+)"')

$actual = @{}
foreach ($entry in $handlers) {
    $source = switch ($entry.owner) {
        'd3d_proxy' { $apiRegs }
        'message' { $messageRegs }
        'ex_game_ui' { $exRegs }
        default { throw "unknown manifest owner: $($entry.owner)" }
    }
    $matches = @($source | Where-Object Name -eq $entry.name)
    if ($matches.Count -ne 1) {
        throw "$($entry.name): expected one $($entry.owner) registration, found $($matches.Count)"
    }
    if ($matches[0].Spec -ne $entry.spec) {
        throw "$($entry.name): manifest spec $($entry.spec), source spec $($matches[0].Spec)"
    }
    $actual[$entry.name] = $true
}

$canonical = @('GetMouseVectorX', 'GetMouseVectorY', 'ShowConsole', 'ShowFpsText', 'SetKeyboard')
foreach ($name in $canonical) {
    if ($apiRegs.Name -contains $name) {
        throw "D3D proxy must not register canonical handler $name"
    }
}

$testText = Get-Content -LiteralPath $TestPath -Raw -Encoding UTF8
$fixtureNames = @(
    [regex]::Matches($testText, 'call\s*\(\s*"([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value }
    [regex]::Matches($testText, 'jass\.UnitId\s*\(\s*"([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value }
) | Sort-Object -Unique
$covered = @($handlers | Where-Object { $fixtureNames -contains $_.name })
$declaredCovered = @($handlers | Where-Object { $null -ne $_.test_id })
$coverageDiff = Compare-Object @($covered.name | Sort-Object) @($declaredCovered.name | Sort-Object)
if ($coverageDiff) {
    throw "manifest fixture coverage differs from test_d3d.lua: $($coverageDiff | Out-String)"
}

Write-Host ("D3D contract PASS: surface={0}, proxy={1}, canonical={2}, fixture={3}/{0}, untested={4}" -f `
    $handlers.Count, $apiRegs.Count, $canonical.Count, $covered.Count, ($handlers.Count - $covered.Count))

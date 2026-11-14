# tools/make-foreign-map.ps1
# Build a "foreign map" fixture: reference/empty-map with a war3map.j that has
# no japi marker and no bootstrap, so tools/pack.ps1 must inject everything.
#
# Usage:
#   .\tools\make-foreign-map.ps1
#   .\tools\deploy.ps1 -Demo -BaseMap build\foreign-map
param(
    [string]$OutDir = ""
)

$Root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = "$Root\build\foreign-map" }
if (-not [System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PWD.Path, $OutDir))
}
$Source = "$Root\reference\empty-map"
$Fixture = "$PSScriptRoot\fixtures\foreign-war3map.j"

if (-not (Test-Path $Source)) { throw "base map source not found: $Source" }
if (-not (Test-Path $Fixture)) { throw "fixture script not found: $Fixture" }

if (Test-Path $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $OutDir -Recurse -Force
Copy-Item -LiteralPath $Fixture -Destination "$OutDir\war3map.j" -Force

Write-Host "Foreign map fixture ready: $OutDir"

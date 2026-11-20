# tests/selector/run.ps1 - offline selector tests
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/selector/run.ps1
#
# No Warcraft III process, map loader, pack step or native DLL is started. The
# Lua interpreter ships with the w3x2lni fetch step.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$lua = Join-Path $root 'tools\w3x2lni\bin\w3x2lni-lua.exe'
if (-not (Test-Path -LiteralPath $lua)) {
    throw "Lua interpreter not found: $lua. Run .\tools\fetch-w3x2lni.ps1 first."
}

Push-Location $root
try {
    & $lua 'tests\selector\run.lua'
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "tests\selector\run.lua failed with exit code $LASTEXITCODE"
    }
    Write-Host 'SELECTOR OFFLINE: passed; no War3 process, map loader or pack step was started.'
} finally {
    Pop-Location
}

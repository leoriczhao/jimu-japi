# OFFLINE MOCK: no Warcraft III process is started here.
#
# Runs the mocked-adapter suite against the shipped library and the example
# copy, the focused smoke test, and the example protocol replay. The wrapper
# exits non-zero on the first failing script. Live input/D3D validation is a
# separate, manual/driver-run game test (see examples/12-ui-components).
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$lua = Join-Path $root 'tools\w3x2lni\bin\w3x2lni-lua.exe'
if (-not (Test-Path -LiteralPath $lua)) {
    throw "Lua interpreter not found: $lua. Run .\tools\fetch-w3x2lni.ps1 first."
}

$scripts = @(
    'tests/ui/run_suite.lua',
    'tests/ui/run.lua',
    'tests/ui/example_contract.lua'
)

Push-Location $root
try {
    foreach ($script in $scripts) {
        Write-Host "== $script =="
        & $lua $script
        if ($LASTEXITCODE -ne 0) {
            throw "$script failed with exit code $LASTEXITCODE"
        }
    }
    Write-Host 'OFFLINE MOCK TOTAL: 3/3 scripts passed; no War3 process or native D3D SDK was started.'
} finally {
    Pop-Location
}

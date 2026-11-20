# tests/ydwe-compat/run.ps1 - offline YDWE compatibility checks.
#
# Runs only local, offline tools:
#   * Python migration + icon tests (python -B)
#   * jass.ydwe Lua module tests through the vendored w3x2lni interpreter
#   * button_icon_test.exe (built by src\build.bat)
#
# It never starts War3, never invokes tools/pack.ps1 or tools/deploy.ps1, and
# never loads the exploit payload.
[CmdletBinding()]
param(
    [switch]$SkipBuildCheck
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) { $Python = Get-Command py -ErrorAction SilentlyContinue }
if (-not $Python) { throw 'Python 3 is required for the offline YDWE tests' }
$PythonExe = $Python.Source
$Lua = Join-Path $Root 'tools\w3x2lni\bin\w3x2lni-lua.exe'
$IconTest = Join-Path $Root 'src\build\bin\Release\button_icon_test.exe'
$IconTool = Join-Path $Root 'src\build\bin\Release\ydwe_button_icon.exe'

$steps = @()
function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host ""
    Write-Host "=== $Name ==="
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
    $script:steps += $Name
}

Push-Location $Root
try {
    Invoke-Step 'unit-state migration tests' {
        & $PythonExe -B (Join-Path $Root 'tests\ydwe-compat\test_unit_state_migrate.py')
    }

    if (-not (Test-Path -LiteralPath $Lua)) {
        throw "missing w3x2lni Lua interpreter: $Lua (run tools\fetch-w3x2lni.ps1)"
    }
    Invoke-Step 'jass.ydwe Lua module tests' {
        & $Lua (Join-Path $Root 'tests\ydwe-compat\run_lua.lua')
    }

    if (-not $SkipBuildCheck) {
        foreach ($path in @($IconTest, $IconTool)) {
            if (-not (Test-Path -LiteralPath $path)) {
                throw "missing offline icon binary: $path`nRun src\build.bat first."
            }
        }
    }
    if (Test-Path -LiteralPath $IconTest) {
        Invoke-Step 'C++ image module tests' {
            & $IconTest $Root
        }
    }
    if (Test-Path -LiteralPath $IconTool) {
        Invoke-Step 'end-to-end icon tool tests' {
            & $PythonExe -B (Join-Path $Root 'tests\ydwe-compat\test_button_icons.py')
        }
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host ("YDWE compat offline: {0} step(s) passed" -f $steps.Count)
foreach ($step in $steps) { Write-Host "  [PASS] $step" }

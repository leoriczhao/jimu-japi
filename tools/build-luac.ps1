# tools/build-luac.ps1
# Build a throwaway luac.exe (the Lua 5.4 compiler front-end) from the sources already
# vendored in src\vendor\lua-5.4\src, so tools\verify-examples.ps1 can syntax-check
# examples\<dir>\war3map.lua without launching War3.
#
# Why it exists: this machine has no Lua interpreter on PATH, and pjass only parses
# war3map.j -- a Lua chunk that does not compile (for example a missing ")" that
# tools\pack.ps1 bundles without complaint) otherwise only shows up as a live run with
# "no Results line", which is slow to diagnose. luac -p catches it in milliseconds.
#
# Usage:
#   .\tools\build-luac.ps1          # build only when the exe is missing (idempotent)
#   .\tools\build-luac.ps1 -Force   # always rebuild
#
# Output: build\scratch\luac\luac.exe
# gcc lookup order: $env:CC, gcc.exe on PATH, then D:\qt\Tools\mingw810_64\bin\gcc.exe.
# Nothing else in the repo consumes this exe; it is a local convenience tool.

[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'

$Root        = Split-Path -Parent $PSScriptRoot
$LuaSrcDir   = Join-Path $Root 'src\vendor\lua-5.4\src'
$OutDir      = Join-Path $Root 'build\scratch\luac'
$OutExe      = Join-Path $OutDir 'luac.exe'
$FallbackGcc = 'D:\qt\Tools\mingw810_64\bin\gcc.exe'

function Get-GccPath {
    if (-not [string]::IsNullOrEmpty($env:CC)) {
        if (Test-Path -LiteralPath $env:CC -PathType Leaf) { return $env:CC }
        $command = Get-Command $env:CC -ErrorAction SilentlyContinue
        if ($command -and $command.Source) { return $command.Source }
    }
    $command = Get-Command 'gcc.exe' -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return $command.Source }
    if (Test-Path -LiteralPath $FallbackGcc -PathType Leaf) { return $FallbackGcc }
    return ''
}

if (-not (Test-Path -LiteralPath $LuaSrcDir -PathType Container)) {
    throw "Lua 5.4 sources not found: $LuaSrcDir"
}

if ((Test-Path -LiteralPath $OutExe -PathType Leaf) -and -not $Force) {
    $existing = (Get-Item -LiteralPath $OutExe).Length
    Write-Host "luac already built: $OutExe ($existing bytes); pass -Force to rebuild"
    exit 0
}

$gcc = Get-GccPath
if ($gcc -eq '') {
    throw "gcc.exe not found: checked the CC environment variable, PATH, and $FallbackGcc. Install MinGW-w64 (or point CC at gcc.exe) and retry."
}

# luac = every C file except the standalone lua interpreter entry point.
$sources = @(Get-ChildItem -LiteralPath $LuaSrcDir -Filter '*.c' -File |
    Where-Object { $_.Name -ne 'lua.c' } |
    Sort-Object Name |
    ForEach-Object { $_.FullName })
if ($sources.Count -eq 0) { throw "no .c files under $LuaSrcDir" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-Host "Compiling luac from $($sources.Count) C files with $gcc"
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $output = & $gcc -O1 -o $OutExe @sources 2>&1
    $exitCode = $LASTEXITCODE
} catch {
    $output = @($_.Exception.Message)
    $exitCode = 1
} finally {
    $ErrorActionPreference = $previousEap
}
if ($exitCode -ne 0) {
    $text = (@($output) | ForEach-Object { [string]$_ }) -join [string][char]10
    throw ("gcc failed (exit " + $exitCode + "):" + [string][char]10 + $text)
}
if (-not (Test-Path -LiteralPath $OutExe -PathType Leaf)) { throw "gcc reported success but $OutExe is missing" }
$size = (Get-Item -LiteralPath $OutExe).Length
if ($size -lt 32768) { throw "luac.exe looks truncated: $OutExe ($size bytes)" }
Write-Host "luac built: $OutExe ($size bytes)"
Write-Host 'tools\verify-examples.ps1 now syntax-checks examples\*\war3map.lua with luac -p'
exit 0
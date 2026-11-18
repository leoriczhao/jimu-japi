$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$W2L = Join-Path $Root 'tools\w3x2lni'
$Lua = Join-Path $W2L 'bin\w3x2lni-lua.exe'
$Scratch = Join-Path $Root ('build\object-data-test-' + [guid]::NewGuid().ToString('N'))
function Convert-Map($Mode, $Source, $Target) {
    $cpath = Join-Path $W2L 'bin\?.dll'
    $ppath = (Join-Path $W2L 'script\?.lua') + ';' + (Join-Path $W2L 'script\?\init.lua')
    Push-Location (Join-Path $W2L 'script')
    try {
        & $Lua -E -e "_W2L_MODE='CLI';package.cpath=[[$cpath]];package.path=[[$ppath]]" main.lua $Mode $Source $Target
        if ($LASTEXITCODE -ne 0) { throw "Converter failed: $Mode" }
    } finally { Pop-Location }
}
try {
    New-Item -ItemType Directory $Scratch -Force | Out-Null
    $Source = Join-Path $Scratch 'source'
    New-Item -ItemType Directory $Source | Out-Null
    & $Lua -E (Join-Path $PSScriptRoot 'test.lua') $Root $Source
    if ($LASTEXITCODE -ne 0) { throw 'Object compiler tests failed' }
    # Real converter independently decodes our binary format to LNI.
    Copy-Item (Join-Path $Root 'reference\empty-map\*') $Source -Recurse -Force
    Remove-Item (Join-Path $Source 'war3map.w3u.ini') -ErrorAction SilentlyContinue
    $Archive = Join-Path $Scratch 'objects.w3x'
    $Lni = Join-Path $Scratch 'lni'
    Convert-Map 'pack' $Source $Archive
    Convert-Map 'lni' $Archive $Lni
    & $Lua -E (Join-Path $PSScriptRoot 'roundtrip.lua') $Lni
    if ($LASTEXITCODE -ne 0) { throw 'Converter roundtrip assertions failed' }
    # Exercise real pack integration and declaration exclusion, without starting War3.
    $Work = Join-Path $Scratch 'packed'
    & (Join-Path $Root 'tools\pack.ps1') -MapDir (Join-Path $Root 'examples\11-object-data') -WorkDir $Work -SkipRepack -StrictRequires
    if (-not (Test-Path (Join-Path $Work 'war3map.w3a'))) { throw 'Pack did not emit ability object data' }
    $Bundle = Get-Content (Join-Path $Work 'war3map.lua') -Raw
    if ($Bundle -match 'unit\s*\{|ability\s*\{|Build only:') { throw 'Build declaration leaked into runtime bundle' }
    $Legacy = Join-Path $Scratch 'legacy-project'
    New-Item -ItemType Directory $Legacy | Out-Null
    Set-Content (Join-Path $Legacy 'war3map.lua') 'print("legacy project")' -Encoding ASCII
    $LegacyWork = Join-Path $Scratch 'legacy-work'
    & (Join-Path $Root 'tools\pack.ps1') -MapDir $Legacy -WorkDir $LegacyWork -SkipRepack -StrictRequires
    if (Test-Path (Join-Path $LegacyWork 'war3map.w3a')) { throw 'Legacy project unexpectedly gained ability objects' }
    & $Lua -E (Join-Path $PSScriptRoot 'integration.lua') $Root $LegacyWork $Work
    if ($LASTEXITCODE -ne 0) { throw 'Base object preservation integration failed' }
    Write-Host 'Results: object-data compiler, converter roundtrip and pack integration passed'
} finally {
    if (Test-Path $Scratch) { Remove-Item $Scratch -Recurse -Force }
}

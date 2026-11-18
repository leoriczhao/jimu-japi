# Bounded release helper/source checks; no builds, worktrees, downloads or game processes.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$release = Join-Path $root 'tools/release-sdk.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($release, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load only pure packaging helpers, never the release entry point.
$names = @('Get-Sha256', 'Copy-FileTo', 'Copy-DirTo', 'Write-TreeChecksums', 'Get-DependencyInventory', 'Write-BundleReadme')
foreach ($name in $names) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw ('missing helper: ' + $name) }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
$source = Get-Content -LiteralPath $release -Raw -Encoding UTF8
Assert-True ($source.Contains('$templatePath = Join-Path $bundleSrc')) 'README template must come from pinned source'
Assert-True (-not $source.Contains('$tempCmd = Join-Path $env:TEMP')) 'build command must stay in workspace'
Assert-True ($source.Contains('local-vendor-snapshot:tools/w3x2lni/')) 'external vendor files need explicit snapshot provenance'
Assert-True ($source.Contains("'archive', '--format=tar'")) 'submodule must be exported from pinned local objects'
Assert-True ($source.Contains('} finally {') -and $source.Contains('release worktree has changes; preserved:')) 'failure cleanup must preserve edits'
Assert-True ($source.Contains("Write-TreeChecksums -Dir `$OutDir -OutName 'SHA256SUMS.txt'")) 'outer checksums must cover all package files'
foreach ($relative in @('tools/object-data', 'map/lib/ui.lua', 'tools/drive-ui-components.ps1')) {
    Assert-True ($source.Contains($relative)) ('bundle support missing: ' + $relative)
}
$cmake = Get-Content -LiteralPath (Join-Path $root 'src/CMakeLists.txt') -Raw
foreach ($flag in @('/Brepro', '/pathmap:', '/INCREMENTAL:NO', '/DEBUG:NONE')) {
    Assert-True ($cmake.Contains($flag)) ('determinism flag missing: ' + $flag)
}
$scratch = Join-Path $root ('build/release-helper-test-' + [guid]::NewGuid().ToString('N'))
try {
    $fixture = Join-Path $scratch 'fixture'
    $package = Join-Path $scratch 'package'
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'version.h'), '#define VERSION "fixture-1"')
    $inventory = @(Get-DependencyInventory -Dir $fixture -Origin 'git:fixture:vendor/')
    Assert-True ($inventory.Count -eq 1 -and $inventory[0].path -eq 'version.h') 'dependency path inventory mismatch'
    Assert-True ($inventory[0].sha256 -eq (Get-Sha256 (Join-Path $fixture 'version.h'))) 'dependency hash mismatch'
    Assert-True ($inventory[0].origin -eq 'git:fixture:vendor/') 'dependency origin lost'
    $json = @{ schema = 2; dependencies = $inventory } | ConvertTo-Json -Depth 8
    $roundtrip = $json | ConvertFrom-Json
    Assert-True ($roundtrip.dependencies[0].sha256 -eq $inventory[0].sha256) 'manifest JSON lost dependency hash'
    Copy-DirTo -Source $fixture -Destination (Join-Path $package 'sdk/tools/object-data') -Label 'fixture'
    Copy-FileTo -Source (Join-Path $fixture 'version.h') -Destination (Join-Path $package 'sdk/map/lib/ui.lua') -Label 'fixture'
    [IO.File]::WriteAllText((Join-Path $package 'manifest.json'), $json)
    $sdkSums = Write-TreeChecksums -Dir (Join-Path $package 'sdk') -OutName 'SHA256SUMS.txt'
    $outerSums = Write-TreeChecksums -Dir $package -OutName 'SHA256SUMS.txt'
    Assert-True ($sdkSums.Count -eq 2 -and $outerSums.Count -eq 4) 'checksum coverage must include manifest and nested checksum list'
    $first = [IO.File]::ReadAllText($outerSums.Path)
    Write-TreeChecksums -Dir $package -OutName 'SHA256SUMS.txt' | Out-Null
    Assert-True ($first -ceq [IO.File]::ReadAllText($outerSums.Path)) 'repeated checksum inventory changed'
    foreach ($line in [IO.File]::ReadAllLines($outerSums.Path)) {
        $hash, $relative = $line -split '  ', 2
        Assert-True ($hash -eq (Get-Sha256 (Join-Path $package $relative))) ('checksum invalid: ' + $relative)
    }
    [IO.File]::AppendAllText((Join-Path $fixture 'version.h'), ' changed')
    $changed = @(Get-DependencyInventory -Dir $fixture -Origin 'local-runtime-overlay:')
    Assert-True ($changed[0].sha256 -ne $inventory[0].sha256) 'dependency mutation must change provenance hash'
    $template = Get-Content -LiteralPath (Join-Path $root 'tools/sdk-bundle/README.template.md') -Raw -Encoding UTF8
    $replacements = @{}
    foreach ($match in [regex]::Matches($template, '@@[A-Z0-9_]+@@')) { $replacements[$match.Value] = 'fixture' }
    $readme = Join-Path $scratch 'README.md'
    Write-BundleReadme -Template $template -Target $readme -Tokens $replacements
    Assert-True ((Get-Content -LiteralPath $readme -Raw) -notmatch '@@[A-Z0-9_]+@@') 'README tokens remain'
    $rejected = $false
    try { Write-BundleReadme -Template '@@UNKNOWN@@' -Target $readme -Tokens @{} } catch { $rejected = $true }
    Assert-True $rejected 'unknown README tokens must fail'
    Write-Host 'PASS: release parser, source contracts, dependency provenance, manifest JSON, complete checksums, README rendering'
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

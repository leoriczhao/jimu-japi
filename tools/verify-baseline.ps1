# Compare two independently built, source-pinned SDK packages. Read-only.
# Usage: .\tools\verify-baseline.ps1 -First build\baseline-a -Second build\baseline-b
param(
    [Parameter(Mandatory=$true)][string]$First,
    [Parameter(Mandatory=$true)][string]$Second
)
$ErrorActionPreference='Stop'
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function Verify-Tree([string]$Dir) {
    $base=[IO.Path]::GetFullPath($Dir).TrimEnd([char]92,[char]47)
    $list=Join-Path $base 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $list -PathType Leaf)) { throw "Missing checksum inventory: $list" }
    $seen=@{}
    foreach($line in Get-Content -LiteralPath $list -Encoding ASCII) {
        if(-not $line) { continue }
        if($line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') { throw "Invalid checksum row: $list" }
        $expected=$Matches[1].ToUpperInvariant();$relative=$Matches[2]
        if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Unsafe checksum path' }
        $path=[IO.Path]::GetFullPath((Join-Path $base $relative))
        if(-not $path.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Checksum path outside package' }
        if($seen.ContainsKey($path)) { throw "Duplicate checksum path: $relative" }
        $seen[$path]=$true
        if(-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Hash $path) -ne $expected) { throw "Checksum mismatch: $relative" }
    }
    $files=@(Get-ChildItem -LiteralPath $base -Recurse -File -Force | Where-Object { $_.FullName -ne $list })
    foreach($file in $files) { if(-not $seen.ContainsKey($file.FullName)) { throw "Unlisted package file: $($file.FullName)" } }
    Write-Host ("Verified inventory: " + $base + ' (' + $seen.Count + ' files)')
}
$packages=@()
foreach($dir in @($First,$Second)) {
    $path=(Resolve-Path -LiteralPath $dir).Path
    Verify-Tree $path
    Verify-Tree (Join-Path $path 'sdk')
    $manifest=Get-Content -LiteralPath (Join-Path $path 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if(-not $manifest.built -or $manifest.artifact_source -ne 'clean_worktree' -or -not $manifest.clean_worktree_asserted -or $manifest.dirty) {
        throw 'A package was not built from an asserted clean worktree; -NoBuild is not a baseline'
    }
    if(-not $manifest.sdk_bundle.vendor.included) { throw 'Baseline SDK must contain its vendor runtime' }
    $packages+= [pscustomobject]@{Path=$path;Manifest=$manifest}
}
if($packages[0].Manifest.commit -ne $packages[1].Manifest.commit) { throw 'Source commits differ' }
if($packages[0].Manifest.version -ne $packages[1].Manifest.version) { throw 'SDK versions differ' }
foreach($name in @('yd_japi.dll','newD3d9.dll','d3d_sdk_contract_test.exe')) {
    $one=Hash (Join-Path $packages[0].Path $name)
    $two=Hash (Join-Path $packages[1].Path $name)
    if($one -ne $two) { throw "Independent builds differ: $name ($one vs $two)" }
    foreach($package in $packages) {
        $entry=@($package.Manifest.artifacts | Where-Object name -eq $name)
        if($entry.Count -ne 1 -or $entry[0].sha256 -ne $one) { throw "Artifact differs from manifest: $name" }
        if((Hash (Join-Path $package.Path ('sdk/src/build/bin/Release/'+$name))) -ne $one) { throw "SDK binary differs from its source artifact: $name" }
    }
    Write-Host ("Identical binary: $name $one")
}
function Vendor-Hashes([string]$Dir) {
    $out=@{}
    $root=Join-Path $Dir 'sdk/tools/w3x2lni'
    foreach($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $name=$file.FullName.Substring($root.Length).TrimStart([char]92,[char]47).Replace('\','/')
        $out[$name]=Hash $file.FullName
    }
    return $out
}
$a=Vendor-Hashes $packages[0].Path;$b=Vendor-Hashes $packages[1].Path
if($a.Count -ne $b.Count) { throw 'Vendor file counts differ' }
foreach($key in $a.Keys) { if(-not $b.ContainsKey($key) -or $a[$key] -ne $b[$key]) { throw "Vendor dependency differs: $key" } }
Write-Host ("Baseline verified: commit="+$packages[0].Manifest.commit+'; 3/3 binaries identical; vendor='+$a.Count+' identical files; all checksums match')
Write-Host 'Scope: same source, vendor, MSVC/Windows SDK and build configuration. Package timestamps/metadata may differ; cross-toolchain reproducibility is not asserted.'

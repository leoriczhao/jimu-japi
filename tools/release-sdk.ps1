# tools/release-sdk.ps1
# Cut a reproducible SDK release package from a pinned commit.
#
# What it does
#   1. resolve <Commit> to a full SHA and derive the SDK version from
#      src/src/lua_engine/lua_engine/libs_d3d.cpp (kVersion), unless -Version overrides it
#   2. create a detached clean worktree at build\clean-<sha7> and assert that it is
#      at that exact commit with an empty "git status --porcelain"
#   3. build it (vcvars32 + CMake "Visual Studio 17 2022" -A Win32 --config Release)
#      into build\cmake-<sha7> — outside the clean worktree, so the worktree stays
#      clean after a build and stays reusable across runs — or with -NoBuild copy
#      the already-built files from src\build\bin\Release
#   4. copy yd_japi.dll, newD3d9.dll and d3d_sdk_contract_test.exe into
#      build\sdk\<version>-<sha7>\
#   5. with -SdkBundle also assemble build\sdk\<version>-<sha7>\sdk\ : the author-facing
#      package (docs, examples, scaffold/pack/deploy scripts, the empty base map, the three
#      binaries and the w3x2lni vendor runtime) in the same repository shape the author
#      scripts expect, plus its own README.md and SHA256SUMS.txt
#   6. write manifest.json, then SHA256SUMS.txt last: it covers the artifacts, the
#      manifest and every file under sdk\ (the bundle also keeps its own, relative
#      to sdk\)
#   7. remove the clean worktree again — but only one this run created, and only
#      unless -Keep is passed
#
# Usage:
#   .\tools\release-sdk.ps1                                    # release HEAD with a real clean build
#   .\tools\release-sdk.ps1 -Commit 498a308                     # release an explicit commit
#   .\tools\release-sdk.ps1 -Commit 498a308 -NoBuild            # package local artifacts (smoke test only)
#   .\tools\release-sdk.ps1 -Commit 498a308 -NoBuild -Keep      # keep build\clean-<sha7> for inspection
#   .\tools\release-sdk.ps1 -SdkBundle                          # + the author SDK bundle (sdk\)
#   .\tools\release-sdk.ps1 -SdkBundle -NoVendor                # + the bundle without tools\w3x2lni
#
# Bundle content (docs, examples, tools, base map) is read from the clean worktree, i.e.
# from the released commit. Only tools\sdk-bundle\README.template.md and the gitignored
# tools\w3x2lni\bin\*.dll come from this local checkout (see docs\RELEASE.md).
#
# This script never launches War3 and never runs the regression suites. The live
# verification described in docs/RELEASE.md has to be done by hand.
#
# Requires: PowerShell 5.1 (or newer), git, and for a real build a working
# vcvars32.bat (Visual Studio 2019/2022 "Desktop development with C++") plus cmake.

param(
    [string]$Commit = 'HEAD',
    [string]$Version = '',
    [string]$OutDir = '',
    [switch]$NoBuild,
    [switch]$Keep,
    [switch]$SdkBundle,
    [switch]$NoVendor
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$LocalBin = Join-Path $Root 'src\build\bin\Release'
$LibsD3dFile = 'src/src/lua_engine/lua_engine/libs_d3d.cpp'
$BuildBat = Join-Path $Root 'src\build.bat'
$ExpectedArtifacts = @('yd_japi.dll', 'newD3d9.dll', 'd3d_sdk_contract_test.exe')

function Resolve-Abs([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).Path, $Path))
}

# Run a native executable and always come back with plain strings. In Windows
# PowerShell 5.1 any native stderr output becomes an ErrorRecord and, with
# $ErrorActionPreference = 'Stop', would abort the script (git prints things like
# "Preparing worktree" on stderr while succeeding), so the preference is relaxed
# for the duration of the call and the exit code is checked explicitly.
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
        })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
}

function Invoke-Git {
    param([string[]]$GitArgs, [string]$WorkDir = $Root)
    $result = Invoke-Native -FilePath 'git' -Arguments (@('-C', $WorkDir) + $GitArgs)
    if ($result.ExitCode -ne 0) {
        throw ('git ' + ($GitArgs -join ' ') + ' failed in ' + $WorkDir + ': ' + (($result.Lines | Out-String).Trim()))
    }
    return $result.Lines
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host ('== ' + $Text) -ForegroundColor Cyan
}

# --- sdk bundle helpers (only used with -SdkBundle) ---------------------------
function Copy-FileTo {
    param([string]$Source, [string]$Destination, [string]$Label)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw ('sdk bundle source missing: ' + $Source + '  [' + $Label + ']')
    }
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Copy-DirTo {
    param([string]$Source, [string]$Destination, [string]$Label)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw ('sdk bundle source missing: ' + $Source + '  [' + $Label + ']')
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-TreeStats {
    param([string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force)
    $bytes = [int64]0
    foreach ($file in $files) { $bytes += $file.Length }
    return [pscustomobject]@{ Files = [int64]$files.Count; Bytes = $bytes }
}

function Format-MB {
    param([int64]$Bytes)
    return ('{0:N1}' -f ($Bytes / 1MB))
}

# <hash>  <path relative to $Dir, forward slashes> - the same shape sha256sum writes,
# so the README snippet and any external tool can verify the bundle.
function Write-TreeChecksums {
    param([string]$Dir, [string]$OutName)
    $outPath = Join-Path $Dir $OutName
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force |
        Where-Object { $_.FullName -ne $outPath } | Sort-Object FullName)
    $lines = @()
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Dir.Length + 1).Replace('\', '/')
        $lines += ((Get-Sha256 $file.FullName) + '  ' + $relative)
    }
    [System.IO.File]::WriteAllText($outPath, (($lines -join [char]10) + [char]10), (New-Object System.Text.ASCIIEncoding))
    return [pscustomobject]@{ Path = $outPath; Count = [int64]$files.Count }
}

function New-BundleTokens {
    param([hashtable]$Base, [int64]$Files, [string]$Megabytes)
    $tokens = $Base.Clone()
    $tokens['@@TREEFILES@@'] = [string]$Files
    $tokens['@@TREEMB@@'] = $Megabytes
    $tokens['@@HASHCOUNT@@'] = [string]$Files
    return $tokens
}

function Write-BundleReadme {
    param([string]$Template, [string]$Target, [hashtable]$Tokens)
    $text = $Template
    foreach ($key in $Tokens.Keys) { $text = $text.Replace([string]$key, [string]$Tokens[$key]) }
    $leftover = [regex]::Match($text, '@@[A-Z0-9_]+@@')
    if ($leftover.Success) { throw ('sdk bundle README has an unreplaced token: ' + $leftover.Value) }
    [System.IO.File]::WriteAllText($Target, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# Read the CMake generator/arch/config out of src\build.bat so that this script
# follows the real build instead of hardcoding a second, drifting copy.
function Get-BuildSettings {
    $settings = @{ Generator = 'Visual Studio 17 2022'; Arch = 'Win32'; Config = 'Release' }
    if (-not (Test-Path -LiteralPath $BuildBat)) { return $settings }
    $text = Get-Content -LiteralPath $BuildBat -Raw
    $m = [regex]::Match($text, '-G\s+"([^"]+)"')
    if ($m.Success) { $settings.Generator = $m.Groups[1].Value }
    $m = [regex]::Match($text, '-A\s+([A-Za-z0-9_]+)')
    if ($m.Success) { $settings.Arch = $m.Groups[1].Value }
    $m = [regex]::Match($text, '--config\s+([A-Za-z0-9_]+)')
    if ($m.Success) { $settings.Config = $m.Groups[1].Value }
    return $settings
}

function Find-Vcvars32 {
    if (Test-Path -LiteralPath $BuildBat) {
        $text = Get-Content -LiteralPath $BuildBat -Raw
        # Both shapes build.bat has used: call "<path>" and set "VCVARS=<path>".
        $m = [regex]::Match($text, '"(?:[A-Za-z_][A-Za-z0-9_]*=)?([A-Za-z]:\\[^"]*vcvars32\.bat)"')
        if ($m.Success -and (Test-Path -LiteralPath $m.Groups[1].Value)) {
            return $m.Groups[1].Value
        }
    }
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($programFilesX86) {
        $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $vswhereResult = Invoke-Native -FilePath $vswhere -Arguments @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath')
            $installPath = ($vswhereResult.Lines | Where-Object { $_ -and $_.Trim() -ne '' } | Select-Object -First 1)
            if ($installPath) {
                $candidate = Join-Path $installPath.Trim() 'VC\Auxiliary\Build\vcvars32.bat'
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
        }
    }
    throw ('vcvars32.bat not found. Install the Visual Studio C++ build tools, or point ' + $BuildBat + ' at your vcvars32.bat.')
}

$buildSettings = Get-BuildSettings
$Generator = $buildSettings.Generator
$Arch = $buildSettings.Arch
$Config = $buildSettings.Config

Write-Step '0. Resolve commit and SDK version'
$commitSha = (@(Invoke-Git -GitArgs @('rev-parse', ($Commit + '^{commit}'))) -join '').Trim()
$sha7 = (@(Invoke-Git -GitArgs @('rev-parse', '--short', $commitSha)) -join '').Trim()
$commitDate = (@(Invoke-Git -GitArgs @('show', '-s', '--format=%aI', $commitSha)) -join '').Trim()
$commitSubject = (@(Invoke-Git -GitArgs @('show', '-s', '--format=%s', $commitSha)) -join '').Trim()
$branchNames = @(Invoke-Git -GitArgs @('branch', '--contains', $commitSha, '--format=%(refname:short)'))
$branchList = @($branchNames | Where-Object { $_ -ne $null -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
if ($branchList.Count -gt 0) { $branch = ($branchList -join ', ') } else { $branch = 'detached' }

$blob = (@(Invoke-Git -GitArgs @('--no-pager', 'show', ($commitSha + ':' + $LibsD3dFile))) -join [char]10)
$versionMatch = [regex]::Match($blob, 'constexpr\s+const\s+char\s*\*\s*kVersion\s*=\s*"([^"]+)"')
if (-not $versionMatch.Success) {
    throw ('kVersion not found in ' + $LibsD3dFile + ' at ' + $sha7)
}
$codeVersion = $versionMatch.Groups[1].Value
$versionSource = $LibsD3dFile + ' (kVersion)'
if ($Version) {
    if ($Version -ne $codeVersion) {
        Write-Host ('  WARNING: -Version ' + $Version + ' overrides the code version ' + $codeVersion) -ForegroundColor Yellow
        $versionSource = '-Version command line override'
    }
} else {
    $Version = $codeVersion
}
if ($Version -notmatch '^\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]+)?$') {
    throw ('invalid version string: ' + $Version)
}
Write-Host ('  commit : ' + $commitSha + ' (' + $sha7 + ')')
Write-Host ('  date   : ' + $commitDate)
Write-Host ('  subject: ' + $commitSubject)
Write-Host ('  branch : ' + $branch)
Write-Host ('  version: ' + $Version + '  [' + $versionSource + ']')

Write-Step '1. Prepare the output directory'
if (-not $OutDir) {
    $OutDir = Join-Path $Root ('build\sdk\' + $Version + '-' + $sha7)
}
$OutDir = Resolve-Abs $OutDir
$buildRoot = [System.IO.Path]::GetFullPath((Join-Path $Root 'build'))
# Trailing separator: "build" alone would also accept "build-anything", which is
# outside the directory this script is allowed to clear.
$buildRootPrefix = $buildRoot.TrimEnd('\') + '\'
if (-not $OutDir.StartsWith($buildRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ('refusing to write the package outside ' + $buildRoot + ': ' + $OutDir)
}
if (Test-Path -LiteralPath $OutDir) {
    Write-Host ('  clearing previous output: ' + $OutDir)
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Write-Host ('  output : ' + $OutDir)

Write-Step '2. Create the detached clean worktree'
$workPath = Join-Path $Root ('build\clean-' + $sha7)
$worktreeAdded = $false
$workPathGit = $workPath -replace '\\', '/'
$worktrees = @(Invoke-Git -GitArgs @('worktree', 'list', '--porcelain'))
$registered = $false
foreach ($line in $worktrees) {
    if ($line -match '^worktree\s+(.+)$') {
        if ($Matches[1].Trim() -ieq $workPathGit) { $registered = $true }
    }
}
if (Test-Path -LiteralPath $workPath) {
    if (-not $registered) {
        throw ('refusing to touch an existing directory that is not a git worktree: ' + $workPath + ' (remove it by hand)')
    }
    $head = (@(Invoke-Git -GitArgs @('rev-parse', 'HEAD') -WorkDir $workPath) -join '').Trim()
    if ($head -ne $commitSha) {
        throw ('existing worktree is at ' + $head + ', expected ' + $commitSha + ': ' + $workPath)
    }
    Write-Host ('  reusing existing worktree: ' + $workPath)
} else {
    Invoke-Git -GitArgs @('worktree', 'add', '--detach', $workPath, $commitSha) | Out-Null
    Write-Host ('  created worktree: ' + $workPath)
    $worktreeAdded = $true
}
# No unconditional "$worktreeAdded = $true" here: a worktree this run reused
# (left over from -Keep) must not be removed on behalf of its owner, and a
# worktree this run created must be removed even though the branch above is not
# the only way to reach this point.

$headNow = (@(Invoke-Git -GitArgs @('rev-parse', 'HEAD') -WorkDir $workPath) -join '').Trim()
if ($headNow -ne $commitSha) {
    throw ('clean worktree HEAD is ' + $headNow + ', expected ' + $commitSha)
}
$porcelain = @(Invoke-Git -GitArgs @('status', '--porcelain') -WorkDir $workPath)
$dirtyLines = @($porcelain | Where-Object { $_ -ne $null -and $_.Trim() -ne '' })
if ($dirtyLines.Count -gt 0) {
    throw ('clean worktree is dirty, refusing to release: ' + ($dirtyLines -join ' | '))
}
Write-Host ('  HEAD    : ' + $headNow)
Write-Host '  status  : clean (git status --porcelain is empty)'

Write-Step '3. Obtain the artifacts'
$vcvars = ''
$buildCommand = 'not run (-NoBuild)'
$built = $true
$artifactSource = 'clean_worktree'
if ($NoBuild) {
    Write-Host '  -NoBuild: copying artifacts from the local worktree build output.' -ForegroundColor Yellow
    Write-Host ('  WARNING: these files are NOT reproducible provenance artifacts: ' + $LocalBin)
    Write-Host '  WARNING: the local build may come from a dirty tree or from another commit.'
    Write-Host '  WARNING: never publish a package produced with -NoBuild.'
    $artifactDir = $LocalBin
    $built = $false
    $artifactSource = 'local_worktree'
} else {
    $vcvars = Find-Vcvars32
    $cleanSrc = Join-Path $workPath 'src'
    # Build outside the worktree. CMake drops hundreds of untracked files
    # (CMakeCache.txt, CMakeFiles\, *.vcxproj, *.obj) into its build directory and
    # only "build/" is gitignored, so an in-worktree "src\build-clean" left the
    # clean worktree dirty: the very next run on the same commit failed the
    # "git status --porcelain" assertion and nobody could tell why. Keeping the
    # build beside the package makes the worktree reusable and disposable.
    $cmakeDir = Join-Path $buildRoot ('cmake-' + $sha7)
    $tempCmd = Join-Path $env:TEMP ('japi-release-' + $sha7 + '.cmd')
    $cmdLines = @(
        '@echo off',
        ('call "' + $vcvars + '" >nul'),
        'if errorlevel 1 exit /b 2',
        ('cmake -S "' + $cleanSrc + '" -B "' + $cmakeDir + '" -G "' + $Generator + '" -A ' + $Arch),
        'if errorlevel 1 exit /b 3',
        ('cmake --build "' + $cmakeDir + '" --config ' + $Config),
        'exit /b %ERRORLEVEL%'
    )
    [System.IO.File]::WriteAllText($tempCmd, (($cmdLines -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object System.Text.ASCIIEncoding))
    Write-Host ('  vcvars32: ' + $vcvars)
    Write-Host ('  build   : ' + $Generator + ' -A ' + $Arch + ' --config ' + $Config + ' in ' + $cleanSrc)
    Write-Host ('  script  : ' + $tempCmd)
    & cmd.exe /d /c $tempCmd
    $buildExit = $LASTEXITCODE
    Remove-Item -LiteralPath $tempCmd -Force -ErrorAction SilentlyContinue
    if ($buildExit -ne 0) {
        throw ('clean build failed with exit code ' + $buildExit + ' (worktree kept: ' + $workPath + ')')
    }
    $buildCommand = ($cmdLines -join ' & ')
    $artifactDir = Join-Path $cmakeDir ('bin\' + $Config)
}
Write-Host ('  artifacts: ' + $artifactDir)

Write-Step '4. Copy artifacts'
$artifacts = @()
foreach ($name in $ExpectedArtifacts) {
    $source = Join-Path $artifactDir $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw ('expected artifact missing: ' + $source + ' -- build with src\build.bat first, or drop -NoBuild')
    }
    $target = Join-Path $OutDir $name
    Copy-Item -LiteralPath $source -Destination $target -Force
    $item = Get-Item -LiteralPath $target
    $hash = Get-Sha256 $target
    $artifacts += [ordered]@{ name = $name; bytes = [int64]$item.Length; sha256 = $hash }
    Write-Host ('  ' + $name + '  ' + $item.Length + ' bytes  ' + $hash)
}

# SHA256SUMS.txt is written at the very end of the run (step 6b), once the
# manifest and the optional sdk\ bundle exist: a checksum file that only covers
# the three binaries says nothing about the manifest that lists them, or about
# the 600-file bundle shipped beside it.
$sumPath = Join-Path $OutDir 'SHA256SUMS.txt'

$builtAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# -SdkBundle: the author-facing package. It mirrors the subset of the repository layout
# that the author scripts walk up to ($Root = <bundle>\: tools\..., reference\empty-map,
# src\build\bin\Release, examples\, docs\guide), which is what lets pack.ps1, deploy.ps1,
# new-project.ps1 and verify-examples.ps1 run unmodified, with their default arguments,
# from inside the bundle.
$bundleInfo = $null
if ($SdkBundle) {
    Write-Step '5. Assemble the author SDK bundle'
    $bt = [char]96
    $sdkDir = Join-Path $OutDir 'sdk'
    New-Item -ItemType Directory -Path $sdkDir -Force | Out-Null
    Write-Host ('  layout  : ' + $sdkDir)
    Write-Host '  content : docs/examples/tools/base map from the clean worktree (the released commit)'
    $bundleSrc = $workPath

    # Enumerated, not listed: every guide added under docs\guide must reach the
    # bundle, because examples\README.md and the guides link each other by
    # relative path and a missing file is a dead link in the shipped package.
    # (A hand-maintained list silently fell two guides behind: OBJECT-DATA-UI.md
    # and MINIMAL-GAME-LOOP.md were linked but not shipped.)
    $guideNames = @(Get-ChildItem -LiteralPath (Join-Path $bundleSrc 'docs\guide') -Filter '*.md' -File |
        Sort-Object Name | ForEach-Object { $_.Name })
    if ($guideNames.Count -lt 6) {
        throw ('sdk bundle: docs\guide has only ' + $guideNames.Count + ' guides; expected at least 6')
    }
    foreach ($name in $guideNames) {
        Copy-FileTo -Source (Join-Path $bundleSrc ('docs\guide\' + $name)) -Destination (Join-Path $sdkDir ('docs\guide\' + $name)) -Label ('docs/guide/' + $name)
    }
    # DOCS the guides link to themselves (../STATUS.md, ../RELEASE.md, ../planning/...), so the
    # bundle docs are not full of dead links. Everything else under docs\ stays in the repo.
    $extraDocs = @(
        'docs/STATUS.md',
        'docs/RELEASE.md',
        'docs/planning/JASS-NATIVE-DECLARATIONS.md',
        'docs/planning/D3D-LUA-SDK-DESIGN.md',
        'CHANGELOG.md'
    )
    foreach ($relative in $extraDocs) {
        Copy-FileTo -Source (Join-Path $bundleSrc $relative) -Destination (Join-Path $sdkDir $relative) -Label $relative
    }
    Write-Host ('  docs    : ' + ($guideNames.Count + $extraDocs.Count) + ' markdown files (' + $guideNames.Count + ' guides + STATUS + RELEASE + 2 planning docs + CHANGELOG)')

    Copy-DirTo -Source (Join-Path $bundleSrc 'examples') -Destination (Join-Path $sdkDir 'examples') -Label 'examples'
    $exampleDirs = @(Get-ChildItem -LiteralPath (Join-Path $sdkDir 'examples') -Directory -Force | Where-Object { $_.Name -match '^[0-9][0-9]-' })
    foreach ($dir in $exampleDirs) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'war3map.lua'))) {
            throw ('sdk bundle: example without war3map.lua: ' + $dir.FullName)
        }
    }
    # The catalogue, not a constant: examples\manifest.json is what
    # verify-examples.ps1 and the docs drive, so the bundle asserting against it
    # cannot drift the way a hardcoded "10" did when examples 11 and 12 landed.
    $exampleManifestPath = Join-Path $sdkDir 'examples\manifest.json'
    $exampleManifest = @()
    if (Test-Path -LiteralPath $exampleManifestPath) {
        $exampleManifest = @((Get-Content -LiteralPath $exampleManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).examples)
    }
    if ($exampleManifest.Count -eq 0) {
        throw ('sdk bundle: examples\manifest.json is missing or empty: ' + $exampleManifestPath)
    }
    if ($exampleDirs.Count -ne $exampleManifest.Count) {
        throw ('sdk bundle: manifest lists ' + $exampleManifest.Count + ' examples but ' +
            $exampleDirs.Count + ' directories are present')
    }
    $manifestIds = @($exampleManifest | ForEach-Object { $_.dir })
    foreach ($dir in $exampleDirs) {
        if ($manifestIds -notcontains $dir.Name) {
            throw ('sdk bundle: example directory not in manifest.json: ' + $dir.Name)
        }
    }
    Write-Host ('  examples: ' + $exampleDirs.Count + ' directories (manifest.json matches) + README.md')

    Copy-DirTo -Source (Join-Path $bundleSrc 'reference\empty-map') -Destination (Join-Path $sdkDir 'reference\empty-map') -Label 'reference/empty-map'
    $baseMapFiles = @(Get-ChildItem -LiteralPath (Join-Path $sdkDir 'reference\empty-map') -Recurse -File -Force).Count
    if ($baseMapFiles -lt 10) {
        throw ('sdk bundle: reference/empty-map looks incomplete (' + $baseMapFiles + ' files)')
    }
    Write-Host ('  base map: reference\empty-map  ' + $baseMapFiles + ' files (unpacked directory, the default -BaseMap)')

    $bundleBin = Join-Path $sdkDir 'src\build\bin\Release'
    foreach ($name in $ExpectedArtifacts) {
        Copy-FileTo -Source (Join-Path $OutDir $name) -Destination (Join-Path $bundleBin $name) -Label ('artifact ' + $name)
    }
    Write-Host '  binaries: src\build\bin\Release\  (the default -DllPath / -D3DProxyPath of pack.ps1 and deploy.ps1)'

    # pack.ps1 -WithJassWrappers (and therefore example 09) runs tools\gen-jass-wrappers.ps1,
    # which regex-scans three registry sources under src\. They are read as data - no
    # compiler is involved - so shipping just these three keeps src\src\ out of the bundle
    # without breaking the wrapper path.
    $registryFiles = @(
        'src\src\extensions\ex_natives\Initialize.cpp',
        'src\src\lua_engine\lua_engine\libs_message.cpp',
        'src\src\d3d9\handler_manifest.json'
    )
    foreach ($relative in $registryFiles) {
        Copy-FileTo -Source (Join-Path $bundleSrc $relative) -Destination (Join-Path $sdkDir $relative) -Label $relative
    }
    Write-Host ('  registry: ' + $registryFiles.Count + ' registry sources for gen-jass-wrappers.ps1 (pack.ps1 -WithJassWrappers, example 09)')

    # Every script the bundled scripts reach for through $PSScriptRoot, plus the
    # drivers verify-examples.ps1 launches. Missing one turns into a runtime
    # failure only when the bundle is used outside the repo, which is exactly the
    # wall people hit: drive-ui-components.ps1 (example 12) and object-data
    # (example 11) were both reachable from the bundle but not shipped in it.
    $toolNames = @(
        'new-project.ps1', 'pack.ps1', 'deploy.ps1', 'verify-examples.ps1',
        'build-luac.ps1', 'd3d-proxy.ps1', 'drive-interactive-d3d.ps1', 'drive-ui-components.ps1',
        'gen-jass-wrappers.ps1', 'config.example.ps1', 'pjass.exe', 'callback',
        '_war3ctl.ps1', 'kill-war3.ps1'
    )
    foreach ($name in $toolNames) {
        Copy-FileTo -Source (Join-Path $bundleSrc ('tools\' + $name)) -Destination (Join-Path $sdkDir ('tools\' + $name)) -Label ('tools/' + $name)
    }
    # pack.ps1 step [1c] runs tools\object-data\build.lua whenever a project has
    # objects.lua (example 11, and any author project that opts into code-defined
    # object data). The compiler is three Lua files read at pack time, so it ships
    # as-is; without it the bundle cannot pack example 11 at all.
    Copy-DirTo -Source (Join-Path $bundleSrc 'tools\object-data') -Destination (Join-Path $sdkDir 'tools\object-data') -Label 'tools/object-data'
    $objectCompiler = Join-Path $sdkDir 'tools\object-data\build.lua'
    if (-not (Test-Path -LiteralPath $objectCompiler -PathType Leaf)) {
        throw ('sdk bundle: object compiler missing: ' + $objectCompiler + ' (pack.ps1 [1c] would fail on example 11)')
    }
    Write-Host ('  tools   : ' + $toolNames.Count + ' files + tools\object-data\ (release-sdk.ps1, tools\debugger and tools\core stay in the repo)')

    $vendor = [ordered]@{ included = $false; files = [int64]0; bytes = [int64]0; overlaid_files = [int64]0; source = ''; note = '' }
    if ($NoVendor) {
        Write-Host '  -NoVendor: tools\w3x2lni left out; the bundle cannot pack maps until one is supplied.' -ForegroundColor Yellow
        $vendor['source'] = 'omitted (-NoVendor)'
        $vendor['note'] = 'pack.ps1 needs the w3x2lni runtime; pass -W3x2Lni <dir> and it works'
    } else {
        $vendorSource = Join-Path $bundleSrc 'tools\w3x2lni'
        $vendorTarget = Join-Path $sdkDir 'tools\w3x2lni'
        Copy-DirTo -Source $vendorSource -Destination $vendorTarget -Label 'tools/w3x2lni'
        # The repository .gitignore excludes "*.dll", so the clean worktree has the
        # w3x2lni launcher but not its 19 runtime DLLs. Overlay whatever is missing
        # from this checkout; they are hashed like every other bundle file.
        $overlaid = [int64]0
        $localVendor = Join-Path $Root 'tools\w3x2lni'
        if (Test-Path -LiteralPath $localVendor -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $localVendor -Recurse -File -Force)) {
                $relative = $file.FullName.Substring($localVendor.Length + 1)
                if ($relative -like 'log\*') { continue }
                $destination = Join-Path $vendorTarget $relative
                if (-not (Test-Path -LiteralPath $destination)) {
                    Copy-FileTo -Source $file.FullName -Destination $destination -Label ('vendor overlay ' + $relative)
                    $overlaid++
                }
            }
        }
        $vendorStats = Get-TreeStats $vendorTarget
        $vendor['included'] = $true
        $vendor['files'] = $vendorStats.Files
        $vendor['bytes'] = $vendorStats.Bytes
        $vendor['overlaid_files'] = $overlaid
        $vendor['source'] = 'clean worktree at the released commit, + ' + $overlaid + ' gitignored files from ' + $localVendor
        $vendor['note'] = 'tools/w3x2lni/bin/*.dll is excluded by the repository .gitignore (*.dll): a clean worktree cannot supply the runtime, so those files come from the local checkout and are hashed with the rest of the bundle'
        Write-Host ('  vendor  : tools\w3x2lni  ' + $vendorStats.Files + ' files / ' + (Format-MB $vendorStats.Bytes) + ' MB  (' + $overlaid + ' gitignored DLLs overlaid from the local checkout)')
        $launcher = Join-Path $vendorTarget 'bin\w3x2lni-lua.exe'
        if (-not (Test-Path -LiteralPath $launcher)) {
            throw ('sdk bundle: vendor launcher missing: ' + $launcher + ' (the bundle would not be able to pack maps)')
        }
    }

    # sdk\README.md - the entry point of the package. The template lives next to this
    # script (generator asset), the content it describes comes from the released commit.
    $templatePath = Join-Path $Root 'tools\sdk-bundle\README.template.md'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw ('sdk bundle: README template missing: ' + $templatePath)
    }
    $template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
    if (-not $template.Contains('@@VERSION@@')) {
        throw ('sdk bundle: README template does not look like a template: ' + $templatePath)
    }

    if ($NoVendor) {
        $vendorStatus = ('**未包含**（出包时用了 ' + $bt + '-NoVendor' + $bt + '）。' + $bt + 'pack.ps1' + $bt + ' 默认从这里找 ' + $bt + 'w3x2lni-lua.exe' + $bt + '，没有它就没法把 Lua 打成 MPQ；自备一份后传 ' + $bt + '-W3x2Lni <目录>' + $bt + ' 即可。')
    } else {
        $vendorStatus = ($bt + 'w3x2lni' + $bt + ' 运行时（vendor，' + $vendor['files'] + ' 个文件 / ' + (Format-MB ([int64]$vendor['bytes'])) + ' MB）：' + $bt + 'pack.ps1' + $bt + ' 靠它写 MPQ，删掉就没法打包。其中 ' + $vendor['overlaid_files'] + ' 个 ' + $bt + 'bin\*.dll' + $bt + ' 被仓库 ' + $bt + '.gitignore' + $bt + ' 的 ' + $bt + '*.dll' + $bt + ' 规则排除，来自出包机本地 checkout。')
    }

    if ($built) {
        $buildKind = ('二进制由本脚本在干净 worktree（' + $bt + 'build\clean-' + $sha7 + $bt + '）上用 ' + $Generator + ' -A ' + $Arch + ' --config ' + $Config + ' 现场构建，与提交严格对应。')
        $draftWarning = ''
    } else {
        $buildKind = '**二进制来自本地 -NoBuild 拷贝，不可复现**'
        $draftWarning = ('> **本包不是可发布产物。** 二进制由 ' + $bt + '-NoBuild' + $bt + ' 从本地 checkout 拷贝，无法证明与提交 ' + $sha7 + ' 的源码对应。仅供内部验证，不要对外分发。')
    }

    $artifactRows = @()
    foreach ($artifact in $artifacts) {
        $artifactRows += ('| ' + $bt + $artifact['name'] + $bt + ' | ' + $artifact['bytes'] + ' | ' + $bt + $artifact['sha256'] + $bt + ' |')
    }

    $baseTokens = @{
        '@@VERSION@@' = $Version
        '@@COMMIT7@@' = $sha7
        '@@COMMIT@@' = $commitSha
        '@@COMMITDATE@@' = $commitDate
        '@@BUILTAT@@' = $builtAtUtc
        '@@BUILDKIND@@' = $buildKind
        '@@DRAFTWARNING@@' = $draftWarning
        '@@VENDORSTATUS@@' = $vendorStatus
        '@@ARTIFACTROWS@@' = ($artifactRows -join [char]10)
    }

    # Two passes: the file/byte counts the README quotes have to include the README
    # itself, so write it once, measure, then rewrite with the measured numbers.
    $readmePath = Join-Path $sdkDir 'README.md'
    $estimate = Get-TreeStats $sdkDir
    Write-BundleReadme -Template $template -Target $readmePath -Tokens (New-BundleTokens -Base $baseTokens -Files ($estimate.Files + 1) -Megabytes (Format-MB ($estimate.Bytes + 10000)))
    $sdkStats = Get-TreeStats $sdkDir
    Write-BundleReadme -Template $template -Target $readmePath -Tokens (New-BundleTokens -Base $baseTokens -Files $sdkStats.Files -Megabytes (Format-MB $sdkStats.Bytes))
    $sdkStats = Get-TreeStats $sdkDir
    Write-Host ('  README  : ' + $readmePath + '  (template: tools\sdk-bundle\README.template.md)')

    $sdkSums = Write-TreeChecksums -Dir $sdkDir -OutName 'SHA256SUMS.txt'
    Write-Host ('  wrote   : ' + $sdkSums.Path + '  (' + $sdkSums.Count + ' files hashed)')

    $bundleInfo = [ordered]@{
        path = 'sdk'
        files = $sdkStats.Files
        bytes = $sdkStats.Bytes
        hashed_files = $sdkSums.Count
        readme = 'sdk/README.md'
        readme_template = 'tools/sdk-bundle/README.template.md'
        sha256sums = 'sdk/SHA256SUMS.txt'
        docs = @($guideNames | ForEach-Object { 'docs/guide/' + $_ }) + @($extraDocs)
        examples = @($exampleDirs | ForEach-Object { 'examples/' + $_.Name })
        tools = @($toolNames | ForEach-Object { 'tools/' + $_ })
        object_compiler = 'tools/object-data/ (build.lua + compiler.lua; pack.ps1 -MapDir with objects.lua)'
        base_map = 'reference/empty-map (' + $baseMapFiles + ' files)'
        binaries = @($ExpectedArtifacts | ForEach-Object { 'src/build/bin/Release/' + $_ })
        registries = @($registryFiles | ForEach-Object { $_ -replace '\\', '/' })
        vendor = $vendor
        layout = 'repository subset: the author scripts resolve $Root = Split-Path -Parent $PSScriptRoot and use default paths, so sdk\ works as a stand-alone repository root'
    }
    Write-Host ('  bundle  : ' + $sdkStats.Files + ' files / ' + (Format-MB $sdkStats.Bytes) + ' MB')
}

$regressions = @(
    [ordered]@{ name = 'default'; expected = '122 passed, 0 failed, 122 total'; recorded_date = '2026-11-15'; command = '.\tools\deploy.ps1' },
    [ordered]@{ name = 'with-jass-wrappers'; expected = '125 passed, 0 failed, 125 total'; recorded_date = '2026-11-15'; command = '.\tools\deploy.ps1 -WithJassWrappers' },
    [ordered]@{ name = 'with-getfuncaddr'; expected = '126 passed, 0 failed, 126 total'; recorded_date = '2026-11-16'; command = '.\tools\deploy.ps1 -WithGetFuncAddr' },
    [ordered]@{ name = 'd3d-interactive'; expected = '170 passed, 0 failed, 170 total'; recorded_date = '2026-11-16'; command = '.\tools\deploy.ps1 -InteractiveD3D -Hold' },
    [ordered]@{ name = 'map-boot-reboot'; expected = '9 passed, 0 failed, 9 total'; recorded_date = '2026-11-15'; command = '.\tools\deploy.ps1 -TestReboot' }
)

$cmakeVersion = ''
if (Get-Command cmake -ErrorAction SilentlyContinue) {
    $cmakeResult = Invoke-Native -FilePath 'cmake' -Arguments @('--version')
    $cmakeVersion = ($cmakeResult.Lines | Where-Object { $_ -and $_.Trim() -ne '' } | Select-Object -First 1)
}
$localStatus = @(Invoke-Git -GitArgs @('status', '--porcelain'))
$localDirty = @($localStatus | Where-Object { $_ -ne $null -and $_.Trim() -ne '' }).Count -gt 0

$manifest = [ordered]@{
    schema = 1
    version = $Version
    version_source = $versionSource
    commit = $commitSha
    commit_short = $sha7
    commit_date = $commitDate
    commit_subject = $commitSubject
    branch = $branch
    dirty = $false
    clean_worktree = ('build\clean-' + $sha7)
    clean_worktree_asserted = $true
    built = $built
    artifact_source = $artifactSource
    local_worktree_dirty = $localDirty
    built_at = $builtAtUtc
    build_command = $buildCommand
    artifacts = $artifacts
    regressions_source = 'docs/STATUS.md (header table, read 2026-11-16)'
    regressions_verified = $false
    regressions = $regressions
    docs = @(
        [ordered]@{ path = 'docs/STATUS.md'; anchor = 'section 4 (artifact provenance)' },
        [ordered]@{ path = 'docs/RELEASE.md'; anchor = 'steps 0-7 (release process)' },
        [ordered]@{ path = 'docs/planning/D3D-LUA-SDK-DESIGN.md'; anchor = 'section 14.4 (P6 provenance)' },
        [ordered]@{ path = 'docs/guide/D3D-LUA-API.md'; anchor = 'd3d.version()' },
        [ordered]@{ path = 'CHANGELOG.md'; anchor = 'version ' + $Version }
    )
    toolchain = [ordered]@{
        generator = $Generator
        arch = $Arch
        config = $Config
        vcvars32 = $(if ($vcvars) { $vcvars } else { 'not used (-NoBuild)' })
        cmake = $cmakeVersion
        powershell = $PSVersionTable.PSVersion.ToString()
        host = [Environment]::MachineName
    }
}
if ($bundleInfo) { $manifest['sdk_bundle'] = $bundleInfo }

Write-Step '6. Write manifest.json'
$manifestPath = Join-Path $OutDir 'manifest.json'
$json = ($manifest | ConvertTo-Json -Depth 8)
[System.IO.File]::WriteAllText($manifestPath, ($json + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('  wrote   : ' + $manifestPath)

Write-Step '6b. Write SHA256SUMS.txt (package-wide)'
# One checksum file for the whole package: the three artifacts, the manifest that
# documents them, and every file of the sdk\ bundle. Written last because the
# manifest and the bundle only exist by now; sdk\SHA256SUMS.txt lists the bundle
# relative to sdk\, this one lists everything relative to the package root.
$sumEntries = @()
foreach ($artifact in $artifacts) { $sumEntries += $artifact['name'] }
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { $sumEntries += 'manifest.json' }
if ($bundleInfo -and (Test-Path -LiteralPath (Join-Path $OutDir 'sdk') -PathType Container)) {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $OutDir 'sdk') -Recurse -File -Force | Sort-Object FullName)) {
        $sumEntries += ($file.FullName.Substring($OutDir.Length + 1) -replace '\\', '/')
    }
}
$sumLines = @()
foreach ($relative in $sumEntries) {
    $full = Join-Path $OutDir ($relative -replace '/', '\')
    $sumLines += ((Get-Sha256 $full) + '  ' + $relative)
}
[System.IO.File]::WriteAllText($sumPath, (($sumLines -join [char]10) + [char]10), (New-Object System.Text.ASCIIEncoding))
Write-Host ('  wrote   : ' + $sumPath + '  (' + $sumLines.Count + ' files hashed)')

Write-Step '7. Summary'
Write-Host ('  version : ' + $Version)
Write-Host ('  commit  : ' + $sha7 + '  (' + $commitDate + ')')
Write-Host ('  built   : ' + $built + '  [' + $artifactSource + ']')
foreach ($artifact in $artifacts) {
    Write-Host ('  ' + $artifact['name'].PadRight(26) + $artifact['bytes'].ToString().PadLeft(8) + ' B  ' + $artifact['sha256'])
}
Write-Host ('  package : ' + $OutDir)
if ($bundleInfo) {
    Write-Host ('  bundle  : ' + (Join-Path $OutDir 'sdk') + '  (' + $bundleInfo['files'] + ' files / ' + (Format-MB ([int64]$bundleInfo['bytes'])) + ' MB, ' + $bundleInfo['hashed_files'] + ' hashed)')
    if ($bundleInfo['vendor']['included']) {
        Write-Host ('            tools\w3x2lni ' + $bundleInfo['vendor']['files'] + ' files / ' + (Format-MB ([int64]$bundleInfo['vendor']['bytes'])) + ' MB, ' + $bundleInfo['vendor']['overlaid_files'] + ' gitignored DLLs from the local checkout')
    } else {
        Write-Host '            tools\w3x2lni NOT bundled (-NoVendor): pack.ps1 needs -W3x2Lni' -ForegroundColor Yellow
    }
}
Write-Host ''
Write-Host 'Next steps (full procedure: docs\RELEASE.md):'
Write-Host ('  1. re-read the checksums:  Get-FileHash "' + $OutDir + '\*.dll", "' + $OutDir + '\*.exe" -Algorithm SHA256')
Write-Host ('  2. live regression, one War3 instance at a time (the operator owns that):')
Write-Host ('       .\tools\deploy.ps1 -DllPath "' + $OutDir + '\yd_japi.dll" -D3DProxyPath "' + $OutDir + '\newD3d9.dll"')
Write-Host ('       .\tools\deploy.ps1 -WithJassWrappers -DllPath "' + $OutDir + '\yd_japi.dll" -D3DProxyPath "' + $OutDir + '\newD3d9.dll"')
Write-Host ('       .\tools\deploy.ps1 -WithGetFuncAddr  -DllPath "' + $OutDir + '\yd_japi.dll" -D3DProxyPath "' + $OutDir + '\newD3d9.dll"')
Write-Host ('       .\tools\deploy.ps1 -InteractiveD3D   -DllPath "' + $OutDir + '\yd_japi.dll" -D3DProxyPath "' + $OutDir + '\newD3d9.dll"')
Write-Host ('       .\tools\deploy.ps1 -TestReboot       -DllPath "' + $OutDir + '\yd_japi.dll" -D3DProxyPath "' + $OutDir + '\newD3d9.dll"')
Write-Host '  3. record the confirmed "Results:" lines plus this SHA-256 table in docs\STATUS.md, CHANGELOG.md'
Write-Host '     and manifest.json (regressions_verified: true).'
if ($bundleInfo) {
    $tempDir = [System.IO.Path]::GetTempPath()
    $scratch = Join-Path $tempDir ('sdk-standalone-' + $sha7)
    $smokeProject = Join-Path $tempDir ('japi-smoke-' + $sha7)
    Write-Host ''
    Write-Host '  4. author SDK bundle: prove it is self-contained by using it outside this repository:'
    Write-Host ('       Copy-Item "' + (Join-Path $OutDir 'sdk') + '" "' + $scratch + '" -Recurse -Force')
    Write-Host ('       cd "' + $scratch + '"; .\tools\verify-examples.ps1            # static + pack, expect ' + $exampleDirs.Count + '/' + $exampleDirs.Count)
    Write-Host ('       cd "' + $scratch + '"; .\tools\new-project.ps1 -Name Smoke -Path "' + $smokeProject + '" -Force')
    Write-Host '     then pack/deploy the scaffolded project from the bundle (sdk\README.md section 3).'
}

if ($worktreeAdded) {
    if ($Keep) {
        Write-Host ''
        Write-Host ('  keeping clean worktree: ' + $workPath) -ForegroundColor Yellow
    } else {
        $removeResult = Invoke-Native -FilePath 'git' -Arguments @('-C', $Root, 'worktree', 'remove', '--force', $workPath)
        if ($removeResult.ExitCode -ne 0) {
            Write-Host ('  WARNING: could not remove the clean worktree: ' + $workPath) -ForegroundColor Yellow
        } else {
            Write-Host ''
            Write-Host ('  removed clean worktree: ' + $workPath)
        }
    }
}

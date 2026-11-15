# tools/release-sdk.ps1
# Cut a reproducible SDK release package from a pinned commit.
#
# What it does
#   1. resolve <Commit> to a full SHA and derive the SDK version from
#      src/src/lua_engine/lua_engine/libs_d3d.cpp (kVersion), unless -Version overrides it
#   2. create a detached clean worktree at build\clean-<sha7> and assert that it is
#      at that exact commit with an empty "git status --porcelain"
#   3. build it (vcvars32 + CMake "Visual Studio 17 2022" -A Win32 --config Release),
#      or with -NoBuild copy the already-built files from src\build\bin\Release
#   4. copy yd_japi.dll, newD3d9.dll and d3d_sdk_contract_test.exe into
#      build\sdk\<version>-<sha7>\ together with SHA256SUMS.txt and manifest.json
#   5. remove the clean worktree again unless -Keep is passed
#
# Usage:
#   .\tools\release-sdk.ps1                                    # release HEAD with a real clean build
#   .\tools\release-sdk.ps1 -Commit 498a308                     # release an explicit commit
#   .\tools\release-sdk.ps1 -Commit 498a308 -NoBuild            # package local artifacts (smoke test only)
#   .\tools\release-sdk.ps1 -Commit 498a308 -NoBuild -Keep      # keep build\clean-<sha7> for inspection
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
    [switch]$Keep
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
        $m = [regex]::Match($text, '"([A-Za-z]:\\[^"]*vcvars32\.bat)"')
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
if (-not $OutDir.StartsWith($buildRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
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
$worktreeAdded = $true

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
    $tempCmd = Join-Path $env:TEMP ('japi-release-' + $sha7 + '.cmd')
    $cmdLines = @(
        '@echo off',
        ('call "' + $vcvars + '" >nul'),
        'if errorlevel 1 exit /b 2',
        ('cd /d "' + $cleanSrc + '"'),
        ('cmake -S . -B build-clean -G "' + $Generator + '" -A ' + $Arch),
        'if errorlevel 1 exit /b 3',
        ('cmake --build build-clean --config ' + $Config),
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
    $artifactDir = Join-Path $cleanSrc ('build-clean\bin\' + $Config)
}
Write-Host ('  artifacts: ' + $artifactDir)

Write-Step '4. Copy artifacts and write checksums'
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

$sumLines = @()
foreach ($artifact in $artifacts) {
    $sumLines += ($artifact['sha256'] + '  ' + $artifact['name'])
}
$sumPath = Join-Path $OutDir 'SHA256SUMS.txt'
[System.IO.File]::WriteAllText($sumPath, (($sumLines -join [char]10) + [char]10), (New-Object System.Text.ASCIIEncoding))
Write-Host ('  wrote   : ' + $sumPath)

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
    built_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
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
$manifestPath = Join-Path $OutDir 'manifest.json'
$json = ($manifest | ConvertTo-Json -Depth 8)
[System.IO.File]::WriteAllText($manifestPath, ($json + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('  wrote   : ' + $manifestPath)

Write-Step '5. Summary'
Write-Host ('  version : ' + $Version)
Write-Host ('  commit  : ' + $sha7 + '  (' + $commitDate + ')')
Write-Host ('  built   : ' + $built + '  [' + $artifactSource + ']')
foreach ($artifact in $artifacts) {
    Write-Host ('  ' + $artifact['name'].PadRight(26) + $artifact['bytes'].ToString().PadLeft(8) + ' B  ' + $artifact['sha256'])
}
Write-Host ('  package : ' + $OutDir)
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

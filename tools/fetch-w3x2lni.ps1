#Requires -Version 5.1
<#
.SYNOPSIS
  Restore the untracked w3x2lni tree (script/ data/ template/ config) from a pinned upstream commit.

.DESCRIPTION
  git tracks only the compiled runtime of w3x2lni (bin\*.dll, bin\w3x2lni-lua.exe, w2l.exe,
  w3x2lni.exe). Everything else -- script\, data\, template\, config.ini, LICENSE.txt, README.md --
  is untracked and comes from sumneko/w3x2lni at the commit pinned below.

  Run once after a fresh clone, before tools\pack.ps1 / tools\deploy.ps1.
  The folder is ~82 MB unpacked, so it is deliberately kept out of git.

.PARAMETER Ref
  Upstream git ref to fetch: a commit SHA (default, reproducible), a branch or a tag such as 2.7.3.

.PARAMETER Url
  Override the archive URL (default: codeload.github.com zipball for -Ref).

.PARAMETER Dest
  Target directory. Defaults to tools\w3x2lni next to this script.

.PARAMETER Force
  Wipe script\ data\ and template\ in the target before extracting.

.EXAMPLE
  .\tools\fetch-w3x2lni.ps1

.EXAMPLE
  .\tools\fetch-w3x2lni.ps1 -Ref 2.7.3 -Dest build\lni-scratch -Force
#>
param(
    [string]$Ref = '82916514a12b7edb15252d42225cd8cc8ce61cfd',
    [string]$Url = '',
    [string]$Dest = "$PSScriptRoot\w3x2lni",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Upstream ships pure-Lua / pure-data directories; the C++ build tree, tests and docs are useless here.
$Wanted = @('script', 'data', 'template', 'config.ini', 'LICENSE.txt', 'README.md')

if (-not $Url) { $Url = "https://codeload.github.com/sumneko/w3x2lni/zip/$Ref" }

function Write-Step([string]$Text) { Write-Host "[w3x2lni] $Text" }

Add-Type -AssemblyName System.IO.Compression.FileSystem

$Dest = [System.IO.Path]::GetFullPath($Dest)
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("w3x2lni-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $zipPath = Join-Path $tmp 'src.zip'
    Write-Step "downloading $Url"
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $zipPath -UseBasicParsing
    } finally {
        $ProgressPreference = $oldProgress
    }
    Write-Step ("downloaded " + [math]::Round((Get-Item $zipPath).Length / 1MB, 1) + " MB")

    # Extract only the wanted top-level entries into a staging dir first, so a broken
    # archive never leaves the live tree half-replaced. ZipFile also copes with the
    # UTF-8 names in upstream's test\ that Windows tar.exe chokes on.
    $stage = Join-Path $tmp 'stage'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $prefix = $zip.Entries[0].FullName.Split('/')[0]
        $written = 0
        foreach ($entry in $zip.Entries) {
            $rel = $entry.FullName.Substring($prefix.Length).TrimStart('/')
            if ([string]::IsNullOrEmpty($rel)) { continue }
            if ($Wanted -notcontains $rel.Split('/')[0]) { continue }
            $target = Join-Path $stage ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                $written++
            }
        }
        Write-Step "extracted $written files from $prefix"
    } finally {
        $zip.Dispose()
    }

    if ($Force) {
        foreach ($d in @('script', 'data', 'template')) {
            $p = Join-Path $Dest $d
            if (Test-Path $p) { Remove-Item -Recurse -Force $p }
        }
    }

    foreach ($item in $Wanted) {
        $from = Join-Path $stage $item
        if (-not (Test-Path $from)) { Write-Step "  skip (not in archive): $item"; continue }
        $to = Join-Path $Dest $item
        if (Test-Path $to) { Remove-Item -Recurse -Force $to }
        Move-Item -LiteralPath $from -Destination $to -Force
        Write-Step "  ok: $item"
    }

    $changelog = Join-Path $Dest 'script\share\changelog.lua'
    if (Test-Path $changelog) {
        $m = Select-String -LiteralPath $changelog -Pattern "version = '([0-9.]+)'" | Select-Object -First 1
        if ($m) { Write-Step ("version: " + $m.Matches[0].Groups[1].Value) }
    }

    $runtime = Join-Path $Dest 'bin\w3x2lni-lua.exe'
    if (-not (Test-Path $runtime)) {
        Write-Step "WARNING: runtime missing ($runtime) -- bin\ is tracked in git; check out the full repo"
    }

    Write-Step "done -> $Dest"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

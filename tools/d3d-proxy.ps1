[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Verify,
    [switch]$Uninstall,
    [string]$War3Dir = "",
    [string]$ProxyPath = "",
    [string]$ProbePath = ""
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

$actionCount = [int][bool]$Install + [int][bool]$Verify + [int][bool]$Uninstall
if ($actionCount -gt 1) {
    throw 'Choose exactly one action: -Install, -Verify, or -Uninstall'
}
if ($actionCount -eq 0) {
    $Verify = $true
}

if (-not $War3Dir) {
    $configPath = Join-Path $PSScriptRoot 'config.local.ps1'
    if (Test-Path -LiteralPath $configPath) {
        . $configPath
    }
}
if (-not $War3Dir) {
    throw 'War3Dir is required. Pass -War3Dir or set it in tools/config.local.ps1.'
}
$War3Dir = [System.IO.Path]::GetFullPath($War3Dir)
if (-not (Test-Path -LiteralPath $War3Dir -PathType Container)) {
    throw "War3 directory not found: $War3Dir"
}

$proxyTarget = Join-Path $War3Dir 'd3d9.dll'
$probeTarget = Join-Path $War3Dir 'japi_d3d_visual_probe.bmp'
$proxySidecar = Join-Path $War3Dir '.japi_d3d_proxy.sha256'
$probeSidecar = Join-Path $War3Dir '.japi_d3d_probe.sha256'
$d3dxTarget = Join-Path $War3Dir 'D3DX9_42.dll'

function Resolve-InputPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PWD.Path, $Path))
}

function Assert-War3Stopped {
    $running = @(Get-Process -Name 'war3' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $ids = ($running.Id | Sort-Object) -join ', '
        throw "War3 is running (PID: $ids). End the D3D session before install or uninstall."
    }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Read-OwnedHash([string]$Sidecar) {
    if (-not (Test-Path -LiteralPath $Sidecar -PathType Leaf)) {
        return $null
    }
    $value = (Get-Content -LiteralPath $Sidecar -Raw -Encoding Ascii).Trim()
    if ($value -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Invalid ownership sidecar: $Sidecar"
    }
    return $value.ToUpperInvariant()
}

function Assert-D3DProxyContract([string]$Path) {
    $objdump = Get-Command objdump.exe -ErrorAction SilentlyContinue
    if (-not $objdump) {
        throw 'objdump.exe is required to validate the D3D proxy contract'
    }
    $headers = (& $objdump.Source -f $Path 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $headers -notmatch 'file format pei-i386') {
        throw "D3D proxy must be a 32-bit PE image: $Path"
    }
    $pe = (& $objdump.Source -p $Path 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect D3D proxy: $Path"
    }
    if ($pe -notmatch '\bDirect3DCreate9\b' -or
        $pe -notmatch '\bInitializeD3DAPI\b' -or
        $pe -notmatch '\bGetD3DSdkApi\b') {
        throw "D3D proxy is missing Direct3DCreate9, InitializeD3DAPI, or GetD3DSdkApi: $Path"
    }
    if ($pe -match 'DLL Name:\s*d3d9\.dll') {
        throw "D3D proxy imports d3d9.dll and may recurse: $Path"
    }
}

function New-D3DProbeBmp([string]$Path) {
    $width = 128
    $height = 128
    $stride = $width * 3
    $pixelBytes = $stride * $height
    $bytes = New-Object byte[] (54 + $pixelBytes)
    $bytes[0] = [byte][char]'B'
    $bytes[1] = [byte][char]'M'
    [BitConverter]::GetBytes([int]$bytes.Length).CopyTo($bytes, 2)
    [BitConverter]::GetBytes([int]54).CopyTo($bytes, 10)
    [BitConverter]::GetBytes([int]40).CopyTo($bytes, 14)
    [BitConverter]::GetBytes([int]$width).CopyTo($bytes, 18)
    [BitConverter]::GetBytes([int]$height).CopyTo($bytes, 22)
    [BitConverter]::GetBytes([int16]1).CopyTo($bytes, 26)
    [BitConverter]::GetBytes([int16]24).CopyTo($bytes, 28)
    [BitConverter]::GetBytes([int]$pixelBytes).CopyTo($bytes, 34)
    for ($y = 0; $y -lt $height; $y++) {
        for ($x = 0; $x -lt $width; $x++) {
            $border = $x -lt 4 -or $y -lt 4 -or $x -ge ($width - 4) -or $y -ge ($height - 4)
            $even = (([int]($x / 16) + [int]($y / 16)) % 2) -eq 0
            if ($border) { $r = 255; $g = 255; $b = 0 }
            elseif ($even) { $r = 255; $g = 0; $b = 255 }
            else { $r = 0; $g = 255; $b = 255 }
            $offset = 54 + $y * $stride + $x * 3
            $bytes[$offset] = $b
            $bytes[$offset + 1] = $g
            $bytes[$offset + 2] = $r
        }
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Assert-InstallAllowed(
    [string]$Source,
    [string]$Destination,
    [string]$Sidecar,
    [string]$Label
) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "${Label} source not found: $Source"
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        return
    }
    $sourceHash = Get-Sha256 $Source
    $targetHash = Get-Sha256 $Destination
    if ($targetHash -eq $sourceHash) {
        return
    }
    $ownedHash = Read-OwnedHash $Sidecar
    if ($ownedHash -ne $targetHash) {
        throw "${Label} collision: refusing to overwrite unknown or modified file $Destination`n  source=$sourceHash`n  target=$targetHash"
    }
}

function Install-OwnedArtifact(
    [string]$Source,
    [string]$Destination,
    [string]$Sidecar,
    [string]$Label
) {
    $sourceHash = Get-Sha256 $Source
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $targetHash = Get-Sha256 $Destination
    if ($targetHash -ne $sourceHash) {
        throw "${Label} copy verification failed: $Destination"
    }
    [System.IO.File]::WriteAllText($Sidecar, $sourceHash, [System.Text.Encoding]::ASCII)
    Write-Host "  ${Label}: $Destination ($sourceHash)"
}

function Get-ArtifactState(
    [string]$Target,
    [string]$Sidecar,
    [string]$Label
) {
    $targetExists = Test-Path -LiteralPath $Target -PathType Leaf
    $sidecarExists = Test-Path -LiteralPath $Sidecar -PathType Leaf
    if (-not $targetExists -and -not $sidecarExists) {
        return [pscustomobject]@{ Label=$Label; State='Absent'; Target=$Target; Sidecar=$Sidecar; Hash=$null }
    }
    $ownedHash = Read-OwnedHash $Sidecar
    if ($targetExists -and -not $ownedHash) {
        throw "${Label} is present without a valid ownership sidecar: $Target"
    }
    if (-not $targetExists) {
        return [pscustomobject]@{ Label=$Label; State='StaleSidecar'; Target=$Target; Sidecar=$Sidecar; Hash=$ownedHash }
    }
    $targetHash = Get-Sha256 $Target
    if ($targetHash -ne $ownedHash) {
        throw "${Label} ownership mismatch: refusing to trust or remove $Target`n  sidecar=$ownedHash`n  target=$targetHash"
    }
    return [pscustomobject]@{ Label=$Label; State='Owned'; Target=$Target; Sidecar=$Sidecar; Hash=$targetHash }
}

function Get-InstallState {
    $proxy = Get-ArtifactState $proxyTarget $proxySidecar 'D3D proxy'
    $probe = Get-ArtifactState $probeTarget $probeSidecar 'D3D visual probe'
    return @($proxy, $probe)
}

if ($Install) {
    Assert-War3Stopped
    if (-not $ProxyPath) {
        $ProxyPath = Join-Path $Root 'src\build\bin\Release\newD3d9.dll'
    }
    $ProxyPath = Resolve-InputPath $ProxyPath
    if (-not $ProbePath) {
        $ProbePath = Join-Path $Root 'build\d3d\japi_d3d_visual_probe.bmp'
        New-D3DProbeBmp $ProbePath
    } else {
        $ProbePath = Resolve-InputPath $ProbePath
    }
    Assert-D3DProxyContract $ProxyPath
    if (-not (Test-Path -LiteralPath $d3dxTarget -PathType Leaf)) {
        throw "D3DX9_42.dll is required: $d3dxTarget"
    }
    # Preflight both artifacts before mutating either one.
    Assert-InstallAllowed $ProxyPath $proxyTarget $proxySidecar 'D3D proxy'
    Assert-InstallAllowed $ProbePath $probeTarget $probeSidecar 'D3D visual probe'
    Install-OwnedArtifact $ProxyPath $proxyTarget $proxySidecar 'D3D proxy'
    Install-OwnedArtifact $ProbePath $probeTarget $probeSidecar 'D3D visual probe'
    Write-Host 'D3D proxy status: Installed'
    return
}

if ($Uninstall) {
    Assert-War3Stopped
    # Validate the complete set before deleting anything.
    $states = @(Get-InstallState)
    foreach ($state in $states) {
        if ($state.State -eq 'Owned') {
            Remove-Item -LiteralPath $state.Target -Force
            Remove-Item -LiteralPath $state.Sidecar -Force
            Write-Host "  Removed $($state.Label): $($state.Target)"
        } elseif ($state.State -eq 'StaleSidecar') {
            Remove-Item -LiteralPath $state.Sidecar -Force
            Write-Host "  Removed stale $($state.Label) sidecar: $($state.Sidecar)"
        } else {
            Write-Host "  $($state.Label) already absent"
        }
    }
    Write-Host 'D3D proxy status: NotInstalled'
    return
}

$states = @(Get-InstallState)
$owned = @($states | Where-Object State -eq 'Owned')
$absent = @($states | Where-Object State -eq 'Absent')
if ($absent.Count -eq $states.Count) {
    Write-Host 'D3D proxy status: NotInstalled'
    return
}
if ($owned.Count -ne $states.Count) {
    $summary = ($states | ForEach-Object { "$($_.Label)=$($_.State)" }) -join ', '
    throw "Partial D3D installation: $summary"
}
Assert-D3DProxyContract $proxyTarget
if (-not (Test-Path -LiteralPath $d3dxTarget -PathType Leaf)) {
    throw "D3DX9_42.dll is required: $d3dxTarget"
}
foreach ($state in $states) {
    Write-Host "  $($state.Label): $($state.Target) ($($state.Hash))"
}
Write-Host 'D3D proxy status: InstalledAndVerified'

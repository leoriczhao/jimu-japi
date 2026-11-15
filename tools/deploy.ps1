# tools/deploy.ps1
# Pack map, deploy to War3, launch, wait for test results, then kill.
# Does NOT build the DLL — use src\build.bat for that.
#
# Usage:
#   .\tools\deploy.ps1                                  # all defaults
#   .\tools\deploy.ps1 -DllPath "path\to\yd_japi.dll"   # custom DLL
#   .\tools\deploy.ps1 -NoKill                          # leave War3 running after tests
#   .\tools\deploy.ps1 -Hold                            # keep the session: waits for build\war3.kill, then closes War3
#   .\tools\deploy.ps1 -InteractivePoint                # require a real Q key for LocalPointOrder
#   .\tools\deploy.ps1 -InteractiveUi                   # verify hover target and ability button UI
#   .\tools\deploy.ps1 -InteractiveD3D                  # deploy proxy + run visual D3D probe
#   .\tools\deploy.ps1 -Demo                            # deploy proxy + run the playable vertical slice
#   .\tools\deploy.ps1 -TestReboot                      # deploy proxy + verify the Lua VM resets on map boot
#   .\tools\deploy.ps1 -WithJassWrappers                # generate JASS wrappers for every bridge handler
#   .\tools\deploy.ps1 -WithGetFuncAddr                 # expose builtin-style GetFuncAddr(code) in the map
param(
    [string]$DllPath = "",
    [string]$D3DProxyPath = "",
    [string]$BaseMap = "",
    [string]$LogFile = "",
    [string]$MapName = "",
    [int]$Timeout    = 120,
    [switch]$NoKill,
    [switch]$Hold,
    [switch]$InteractivePoint,
    [switch]$InteractiveUi,
    [switch]$InteractiveD3D,
    [switch]$WithDebugger,
    [switch]$Demo,
    [switch]$TestReboot,
    [switch]$WithJassWrappers,
[switch]$WithGetFuncAddr
)

$Root     = Split-Path -Parent $PSScriptRoot
$War3Dir  = "D:\Warcraft III Frozen Throne 1.27a publish"
$War3Exe  = "$War3Dir\war3.exe"
$TestMap  = if ($MapName) { "Maps\Test\$MapName" } else { "Maps\Test\output.w3x" }
$PackScript = "$PSScriptRoot\pack.ps1"
$OutFile  = "$Root\build\output.w3x"
$D3DTarget = "$War3Dir\d3d9.dll"
$D3DProbeTarget = "$War3Dir\japi_d3d_visual_probe.bmp"

if (-not $LogFile) { $LogFile = "C:\ProgramData\japi_debug.txt" }
if (($InteractivePoint -or $InteractiveUi -or $InteractiveD3D) -and -not $PSBoundParameters.ContainsKey("Timeout")) {
    $Timeout = 3660
}
if ($TestReboot -and -not $PSBoundParameters.ContainsKey("Timeout")) {
    $Timeout = 180
}

# Resolve DllPath if provided
if ($DllPath) {
    if (-not [System.IO.Path]::IsPathRooted($DllPath)) {
        $DllPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PWD.Path, $DllPath))
    }
}
if (-not $D3DProxyPath) {
    $D3DProxyPath = "$Root\src\build\bin\Release\newD3d9.dll"
} elseif (-not [System.IO.Path]::IsPathRooted($D3DProxyPath)) {
    $D3DProxyPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PWD.Path, $D3DProxyPath))
}

# Validate
if (-not (Test-Path $War3Exe)) { throw "War3 not found: $War3Exe" }
if (($InteractiveD3D -or $Demo -or $TestReboot) -and -not (Test-Path $D3DProxyPath)) {
    throw "D3D proxy not found: $D3DProxyPath`n  Build first: src\build.bat"
}

function Assert-D3DProxyContract {
    param([string]$Path)
    $objdump = Get-Command objdump.exe -ErrorAction SilentlyContinue
    if (-not $objdump) { throw "objdump.exe is required to validate the D3D proxy exports" }
    $pe = (& $objdump.Source -p $Path 2>&1) -join "`n"
    if ($pe -notmatch "Direct3DCreate9" -or $pe -notmatch "InitializeD3DAPI") {
        throw "D3D proxy is missing Direct3DCreate9 or InitializeD3DAPI export: $Path"
    }
    if ($pe -match "DLL Name:\s*d3d9\.dll") {
        throw "D3D proxy imports d3d9.dll and may recurse: $Path"
    }
}

function New-D3DProbeBmp {
    param([string]$Path)
    $width = 128
    $height = 128
    $stride = $width * 3
    $pixelBytes = $stride * $height
    $bytes = New-Object byte[] (54 + $pixelBytes)
    $bytes[0] = [byte][char]'B'; $bytes[1] = [byte][char]'M'
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
            $bytes[$offset] = $b; $bytes[$offset + 1] = $g; $bytes[$offset + 2] = $r
        }
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Install-OwnedArtifact {
    param([string]$Source, [string]$Destination, [string]$Sidecar, [string]$Label)
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash
    if (Test-Path -LiteralPath $Destination) {
        $targetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
        if ($targetHash -ne $sourceHash) {
            $ownedHash = if (Test-Path -LiteralPath $Sidecar) {
                (Get-Content -LiteralPath $Sidecar -Raw -ErrorAction SilentlyContinue).Trim()
            } else { "" }
            if ($ownedHash -ne $targetHash) {
                throw "${Label} collision: refusing to overwrite unknown file $Destination`n  source=$sourceHash`n  target=$targetHash"
            }
        }
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    Set-Content -LiteralPath $Sidecar -Value $sourceHash -Encoding Ascii -NoNewline
    Write-Host "  ${Label}: $Destination ($sourceHash)"
}

# ── Step 1: Pack ────────────────────────────────────────────────
Write-Host "[1/4] Packing map..."
$packArgs = @{}
if ($DllPath) { $packArgs["DllPath"] = $DllPath }
if ($BaseMap) { $packArgs["BaseMap"] = $BaseMap }
if ($InteractivePoint) { $packArgs["InteractivePoint"] = $true }
if ($InteractiveUi) { $packArgs["InteractiveUi"] = $true }
if ($InteractiveD3D) { $packArgs["InteractiveD3D"] = $true }
if ($WithDebugger) { $packArgs["WithDebugger"] = $true }
if ($Demo) { $packArgs["Demo"] = $true }
if ($TestReboot) { $packArgs["TestReboot"] = $true }
if ($WithJassWrappers) { $packArgs["WithJassWrappers"] = $true }
if ($WithGetFuncAddr) { $packArgs["WithGetFuncAddr"] = $true }
$packResult = & $PackScript @packArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $packResult
    throw "pack.ps1 failed"
}
Write-Host "  Map packed OK"

# ── Step 2: Deploy ──────────────────────────────────────────────
Write-Host "[2/4] Deploying to War3..."
$destMap = Join-Path $War3Dir $TestMap
$destDir = Split-Path -Parent $destMap
if (-not (Test-Path $destDir)) { New-Item -ItemType Directory $destDir -Force | Out-Null }
Copy-Item $OutFile $destMap -Force -ErrorAction Stop
Write-Host "  Deployed to $destMap"

if ($InteractiveD3D -or $Demo -or $TestReboot) {
    Assert-D3DProxyContract $D3DProxyPath
    Install-OwnedArtifact $D3DProxyPath $D3DTarget "$War3Dir\.japi_d3d_proxy.sha256" "D3D proxy"
    # The renderer loads d3dx9 by name, so the DLL may live next to war3.exe or
    # in the 32-bit system directory (the usual DX redist location).
    $d3dxCandidates = @(
        "$War3Dir\D3DX9_42.dll",
        "$env:WINDIR\SysWOW64\D3DX9_42.dll",
        "$env:WINDIR\System32\D3DX9_42.dll"
    )
    if (-not ($d3dxCandidates | Where-Object { Test-Path $_ })) {
        throw "D3DX9_42.dll is required for D3D text; checked: $($d3dxCandidates -join ', ')"
    }
}

if ($InteractiveD3D) {
    $probeSource = "$Root\build\d3d\japi_d3d_visual_probe.bmp"
    New-D3DProbeBmp $probeSource
    Install-OwnedArtifact $probeSource $D3DProbeTarget "$War3Dir\.japi_d3d_probe.sha256" "D3D visual probe"
}

# ── Step 3: Launch War3 ────────────────────────────────────────
Write-Host "[3/4] Launching War3..."
Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
$stalePrimary = Test-Path $LogFile
if ($stalePrimary) {
    Write-Host "  NOTE: $LogFile is locked by a stale instance; per-pid log will be used by the DLL."
}
$war3 = Start-Process -FilePath $War3Exe -WorkingDirectory $War3Dir -ArgumentList "-window", "-loadfile", "$TestMap" -PassThru
$launchTime = Get-Date
$altLogFile = "C:\ProgramData\japi_debug_$($war3.Id).txt"
# Watch both, but ONLY match a "Results:" line in a file whose mtime is after
# launch — a stale log can contain an old Results line and must never match.
$logCandidates = @($altLogFile, $LogFile)

if ($InteractiveD3D -or $TestReboot) {
    $proxyLoaded = $false
    for ($i = 0; $i -lt 40 -and -not $war3.HasExited; $i++) {
        try {
            $proxyModule = (Get-Process -Id $war3.Id -ErrorAction Stop).Modules |
                Where-Object { $_.ModuleName -ieq "d3d9.dll" -and $_.FileName -ieq $D3DTarget } |
                Select-Object -First 1
            if ($proxyModule) { $proxyLoaded = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    if (-not $proxyLoaded) {
        if ($war3.HasExited) {
            throw "War3 exited before D3D proxy verification: $D3DTarget"
        }
        Write-Host "  WARNING: module enumeration could not prove the proxy path; GetD3DStatus will provide the in-process proof"
    } else {
        Write-Host "  Verified loaded module: $D3DTarget"
    }
}

# ── Step 4: Wait for results ───────────────────────────────────
Write-Host "[4/4] Waiting for test results (${Timeout}s timeout)..."
$elapsed = 0
$ready = $false
$tmpLog = "$env:TEMP\japi-debug-tmp.log"

while ($elapsed -lt $Timeout) {
    foreach ($cand in $logCandidates) {
        if (Test-Path $cand) {
            try {
                $mtime = (Get-Item $cand).LastWriteTime
                if ($mtime -lt $launchTime.AddSeconds(-2)) { continue }  # stale
                Copy-Item $cand $tmpLog -Force -ErrorAction Stop
                $log = Get-Content $tmpLog -Raw -ErrorAction SilentlyContinue
                if ($log -and $log -match "Results:.*total") {
                    $ready = $true
                    $LogFile = $cand
                    break
                }
            } catch {}
        }
    }
    if ($ready) { break }
    Start-Sleep -Seconds 3
    $elapsed += 3
}

# ── Cleanup ─────────────────────────────────────────────────────
# Only the process that launched War3 holds its creation handle; a fresh shell
# cannot OpenProcess a War3 that runs at a higher integrity level. -Hold keeps
# this launcher alive so the session can be closed later by touching the kill
# file, instead of leaving an unkillable orphan behind.
$killFile = "$Root\build\war3.kill"
if ($Hold) {
    Remove-Item $killFile -Force -ErrorAction SilentlyContinue
    Write-Host "  Holding War3 session; touch $killFile to close it"
    while (-not $war3.HasExited -and -not (Test-Path $killFile)) {
        Start-Sleep -Seconds 1
    }
    Remove-Item $killFile -Force -ErrorAction SilentlyContinue
}

if (-not $NoKill) {
    if (-not $war3.HasExited) {
        $war3.Kill()
        Start-Sleep -Seconds 1
    }
    Write-Host "  War3 terminated"
} else {
    Write-Host "  War3 left running (-NoKill)"
}

# Read final log
Start-Sleep -Seconds 1
if (Test-Path $LogFile) {
    try {
        Copy-Item $LogFile $tmpLog -Force -ErrorAction SilentlyContinue
        $log = Get-Content $tmpLog -Raw -ErrorAction SilentlyContinue
    } catch {}
}

if ($log) {
    $lines = $log -split '\r?\n'
    $start = [Math]::Max(0, $lines.Count - 35)
    Write-Host ""
    for ($i = $start; $i -lt $lines.Count; $i++) {
        Write-Host $lines[$i]
    }
    Write-Host ""
} else {
    Write-Host "  WARNING: No log content read"
    if (-not $ready) {
        Write-Host "  Timed out after ${Timeout}s — tests may still be running"
    }
}
Remove-Item $tmpLog -Force -ErrorAction SilentlyContinue

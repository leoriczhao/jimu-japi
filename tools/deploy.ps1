# tools/deploy.ps1
# Pack map, deploy to War3, launch, wait for test results, then kill.
# Does NOT build the DLL — use src\build.bat for that.
#
# Usage:
#   .\tools\deploy.ps1                                  # all defaults
#   .\tools\deploy.ps1 -DllPath "path\to\yd_japi.dll"   # custom DLL
#   .\tools\deploy.ps1 -NoKill                          # leave War3 running after tests
#   .\tools\deploy.ps1 -InteractivePoint                # require a real Q key for LocalPointOrder
#   .\tools\deploy.ps1 -InteractiveUi                   # verify hover target and ability button UI
param(
    [string]$DllPath = "",
    [string]$BaseMap = "",
    [string]$LogFile = "",
    [string]$MapName = "",
    [int]$Timeout    = 120,
    [switch]$NoKill,
    [switch]$InteractivePoint,
    [switch]$InteractiveUi,
    [switch]$WithDebugger
)

$Root     = Split-Path -Parent $PSScriptRoot
$War3Dir  = "D:\Warcraft III Frozen Throne 1.27a publish"
$War3Exe  = "$War3Dir\war3.exe"
$TestMap  = if ($MapName) { "Maps\Test\$MapName" } else { "Maps\Test\output.w3x" }
$PackScript = "$PSScriptRoot\pack.ps1"
$OutFile  = "$Root\build\output.w3x"

if (-not $LogFile) { $LogFile = "C:\ProgramData\japi_debug.txt" }
if (($InteractivePoint -or $InteractiveUi) -and -not $PSBoundParameters.ContainsKey("Timeout")) {
    $Timeout = 3660
}

# Resolve DllPath if provided
if ($DllPath) {
    if (-not [System.IO.Path]::IsPathRooted($DllPath)) {
        $DllPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PWD.Path, $DllPath))
    }
}

# Validate
if (-not (Test-Path $War3Exe)) { throw "War3 not found: $War3Exe" }

# ── Step 1: Pack ────────────────────────────────────────────────
Write-Host "[1/4] Packing map..."
$packArgs = @{}
if ($DllPath) { $packArgs["DllPath"] = $DllPath }
if ($BaseMap) { $packArgs["BaseMap"] = $BaseMap }
if ($InteractivePoint) { $packArgs["InteractivePoint"] = $true }
if ($InteractiveUi) { $packArgs["InteractiveUi"] = $true }
if ($WithDebugger) { $packArgs["WithDebugger"] = $true }
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

# ── Step 3: Launch War3 ────────────────────────────────────────
Write-Host "[3/4] Launching War3..."
Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
$stalePrimary = Test-Path $LogFile
if ($stalePrimary) {
    Write-Host "  NOTE: $LogFile is locked by a stale instance; per-pid log will be used by the DLL."
}
$war3 = Start-Process -FilePath $War3Exe -ArgumentList "-window", "-loadfile", "$TestMap" -PassThru
$launchTime = Get-Date
$altLogFile = "C:\ProgramData\japi_debug_$($war3.Id).txt"
# Watch both, but ONLY match a "Results:" line in a file whose mtime is after
# launch — a stale log can contain an old Results line and must never match.
$logCandidates = @($altLogFile, $LogFile)

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

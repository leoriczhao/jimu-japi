# tools/verify-examples.ps1
# Verify the examples/ tree.
#
#   static : manifest shape, file layout, the A/B/C markers, the single
#            " Results: <N> passed, <M> failed, <T> total" contract, self-contained requires
#   pack   : tools/pack.ps1 -MapDir examples\<dir> -WorkDir build\scratch\ex-<id>\work
#            -OutFile build\scratch\ex-<id>\out.w3x (+ -WithJassWrappers / -WithGetFuncAddr
#            from the manifest), then assert the w3x looks like a real map
#   live   : tools/deploy.ps1 -MapDir ... -MapName vx-<id>.w3x -Timeout <timeout>, then read
#            C:\ProgramData\japi_debug*.txt, take the LAST "Results:" line of this run and
#            require failed == 0 and total >= 3. Serial: one war3.exe at a time.
#
# Usage:
#   .\tools\verify-examples.ps1                     # static + pack (game not touched)
#   .\tools\verify-examples.ps1 -SkipPack           # static only (fast)
#   .\tools\verify-examples.ps1 -Filter '03|08'     # subset, matched against manifest ids as a regex
#   .\tools\verify-examples.ps1 -Live               # + one game run per example, serial
#   .\tools\verify-examples.ps1 -Live -Timeout 180 -KeepWork
#
# Exit code: 0 when every selected example passed, 1 otherwise.
# Scratch dirs of passed examples are removed unless -KeepWork; failed ones are always kept.

[CmdletBinding()]
param(
    [string]$Filter = '',
    [switch]$Live,
    [switch]$SkipPack,
    [int]$Timeout = 120,
    [switch]$KeepWork,
    [string]$War3Dir = ''
)

$ErrorActionPreference = 'Stop'

$Root           = Split-Path -Parent $PSScriptRoot
$ExamplesDir    = Join-Path $Root 'examples'
$ManifestPath   = Join-Path $ExamplesDir 'manifest.json'
$PackScript     = Join-Path $PSScriptRoot 'pack.ps1'
$DeployScript   = Join-Path $PSScriptRoot 'deploy.ps1'
$D3DProxyScript = Join-Path $PSScriptRoot 'd3d-proxy.ps1'
$ConfigLocal    = Join-Path $PSScriptRoot 'config.local.ps1'
$ProxyBuild     = Join-Path $Root 'src\build\bin\Release\newD3d9.dll'
# Mirrors tools\deploy.ps1's default $War3Dir so authors do not have to pass -War3Dir by hand.
$DefaultWar3Dir = 'D:\Warcraft III Frozen Throne 1.27a publish'
$ScratchDir     = Join-Path $Root 'build\scratch'
$VerifyLogDir   = Join-Path $Root 'build\verify-examples'
$LogDir         = 'C:\ProgramData'
$MinMapBytes    = 131072
$MinChecks      = 3
$ResultsRegex   = [regex]'Results:\s*(\d+)\s+passed,\s*(\d+)\s+failed,\s*(\d+)\s+total'

# ---------------------------------------------------------------- helpers

function Get-SwitchNames {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $text = Get-Content -LiteralPath $Path -Raw
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($text, '\[switch\]\s*\$(\w+)')) {
        $names.Add($match.Groups[1].Value)
    }
    return $names.ToArray()
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Get-MapMagic {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] 4
        $read = $stream.Read($buffer, 0, 4)
        if ($read -lt 4) { return '' }
        return [System.Text.Encoding]::ASCII.GetString($buffer, 0, 4)
    } finally {
        $stream.Dispose()
    }
}

function New-ExampleResult {
    param($Example)
    return [pscustomobject]@{
        Id     = [string]$Example.id
        D3D    = [bool]$Example.d3d
        Static = '-'
        Pack   = '-'
        Live   = '-'
        Ok     = $false
        Note   = ''
    }
}

function Add-Note {
    param($Result, [string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    if ([string]::IsNullOrEmpty($Result.Note)) { $Result.Note = $Text }
    else { $Result.Note = $Result.Note + ' | ' + $Text }
}

# ---------------------------------------------------------------- static

function Test-ExampleStatic {
    param($Example, [string[]]$PackSwitches, [string[]]$DeploySwitches)

    $errors = @()
    $dir = Join-Path $ExamplesDir ([string]$Example.dir)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        return @("examples\$($Example.dir) is missing")
    }

    $luaPath = Join-Path $dir 'war3map.lua'
    $readmePath = Join-Path $dir 'README.md'
    if (-not (Test-Path -LiteralPath $luaPath -PathType Leaf)) { $errors += "examples\$($Example.dir)\war3map.lua is missing" }
    if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) { $errors += "examples\$($Example.dir)\README.md is missing" }

    if ([string]$Example.id -ne [string]$Example.dir) {
        $errors += "manifest id '$($Example.id)' does not match dir '$($Example.dir)'"
    }
    if ([string]$Example.id -notmatch '^\d{2}-[a-z0-9-]+$') {
        $errors += "manifest id '$($Example.id)' must look like 01-lowercase-name"
    }

    $modules = @()
    if ($null -ne $Example.modules) { $modules = @($Example.modules) }
    if ($modules.Count -eq 0) { $errors += 'manifest modules[] is empty' }
    foreach ($module in $modules) {
        if ([string]$module -notmatch '^jass\.[a-z][a-z0-9]*$') { $errors += "manifest module '$module' is not a jass.* module" }
    }

    $switches = @()
    if ($null -ne $Example.pack) { $switches = @($Example.pack) }
    foreach ($switchName in $switches) {
        if ($PackSwitches -notcontains $switchName) { $errors += "manifest pack switch -$switchName is not a tools\pack.ps1 switch" }
        if ($DeploySwitches -notcontains $switchName) { $errors += "manifest pack switch -$switchName is not a tools\deploy.ps1 switch (a live run would drop it)" }
    }

    if (-not (Test-Path -LiteralPath $luaPath -PathType Leaf)) { return $errors }

    $lines = @(Get-Content -LiteralPath $luaPath -Encoding UTF8)
    $text = $lines -join [string][char]10

    # A/B/C layout: 4 rule lines - header open, header close, paste marker, self-check marker.
    $markers = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^-- ={8,}') { $markers += $i }
    }
    if ($markers.Count -ne 4) {
        $errors += "expected 4 '-- =====' rule lines (header open/close, paste marker, self-check marker), found $($markers.Count)"
    } else {
        if ($lines[$markers[2]] -notmatch 'war3map\.lua ={8,}') {
            $errors += 'the paste marker line must end with "war3map.lua ====..." so it stays findable'
        }
    }

    # Exactly one printed Results line, in the agreed format.
    $resultsLines = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Results:') { $resultsLines += $i }
    }
    if ($resultsLines.Count -ne 1) {
        $errors += "war3map.lua must contain exactly one line with 'Results:', found $($resultsLines.Count)"
    }
    if ($text -notmatch 'string\.format\(\s*" Results: %d passed, %d failed, %d total') {
        $errors += 'war3map.lua must print string.format(" Results: %d passed, %d failed, %d total", ...)'
    }

    $checkCalls = ([regex]::Matches($text, 'check\("')).Count
    if ($checkCalls -lt $MinChecks) {
        $errors += "expected at least $MinChecks inline check(...) assertions, found $checkCalls (a healthy run must report total >= 3)"
    }
    if ($text -notmatch 'jass\.TimerStart\(') {
        $errors += 'war3map.lua must start a timer (jass.TimerStart) that prints the Results line'
    }

    # Self-contained: every require is a jass.* module and lives inside the pasteable section.
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*--') { continue }
        foreach ($match in [regex]::Matches($line, 'require\s+"([^"]+)"')) {
            $name = $match.Groups[1].Value
            if ($name -notmatch '^jass\.[a-z][a-z0-9]*$') {
                $errors += "line $($i + 1): require ""$name"" is not a jass.* module (examples must stay self-contained)"
            }
            if ($markers.Count -eq 4 -and ($i -lt $markers[2] -or $i -gt $markers[3])) {
                $errors += "line $($i + 1): require ""$name"" must live inside the pasteable section"
            }
        }
    }

    return $errors
}

# ---------------------------------------------------------------- pack

function Invoke-ExamplePack {
    param($Example)

    $tagDir = Join-Path $ScratchDir ('ex-' + [string]$Example.id)
    $workDir = Join-Path $tagDir 'work'
    $outFile = Join-Path $tagDir 'out.w3x'
    $packLog = Join-Path $tagDir 'pack.log'

    if (Test-Path -LiteralPath $tagDir) { Remove-Item -LiteralPath $tagDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tagDir -Force | Out-Null

    $arguments = @{
        MapDir  = (Join-Path $ExamplesDir ([string]$Example.dir))
        WorkDir = $workDir
        OutFile = $outFile
    }
    if ($null -ne $Example.pack) {
        foreach ($switchName in @($Example.pack)) { $arguments[$switchName] = $true }
    }

    $failure = ''
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $PackScript @arguments *>&1 | Out-File -LiteralPath $packLog -Encoding UTF8
    } catch {
        $failure = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $previousEap
    }

    if ($failure -eq '' -and -not (Test-Path -LiteralPath $outFile -PathType Leaf)) {
        $failure = 'pack.ps1 finished without producing the output map'
    }
    if ($failure -eq '') {
        $size = (Get-Item -LiteralPath $outFile).Length
        if ($size -lt $MinMapBytes) {
            $failure = "packed map is only $size bytes (expected at least $MinMapBytes)"
        } else {
            $magic = Get-MapMagic -Path $outFile
            if ($magic -ne 'HM3W') { $failure = "packed map magic is '$magic', expected HM3W" }
        }
    }
    if ($failure -ne '' -and (Test-Path -LiteralPath $packLog -PathType Leaf)) {
        $tail = @(Get-Content -LiteralPath $packLog -Tail 3 -Encoding UTF8 | Where-Object { $_ -ne '' })
        if ($tail.Count -gt 0) { $failure = $failure + ' ; ' + ($tail -join ' / ') }
    }

    return [pscustomobject]@{
        Ok      = ($failure -eq '')
        Note    = $failure
        OutFile = $outFile
        Log     = $packLog
    }
}

# ---------------------------------------------------------------- live

function Find-ExampleLog {
    param([datetime]$Since)

    if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $LogDir -Filter 'japi_debug*.txt' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending)
}

function Invoke-ExampleLive {
    param($Example)

    $tagDir = Join-Path $ScratchDir ('ex-' + [string]$Example.id)
    if (-not (Test-Path -LiteralPath $tagDir -PathType Container)) {
        New-Item -ItemType Directory -Path $tagDir -Force | Out-Null
    }
    # deploy.ps1 console output goes to build\verify-examples\<id>.log (never -LogFile:
    # the DLL writes C:\ProgramData\japi_debug.txt unconditionally).
    if (-not (Test-Path -LiteralPath $VerifyLogDir -PathType Container)) {
        New-Item -ItemType Directory -Path $VerifyLogDir -Force | Out-Null
    }
    $deployLog = Join-Path $VerifyLogDir ([string]$Example.id + '.log')
    $mapName = 'vx-' + [string]$Example.id + '.w3x'

    $running = @(Get-Process -Name war3 -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $ids = ($running | ForEach-Object { $_.Id }) -join ', '
        throw "war3.exe is already running (PID: $ids). -Live runs one game at a time; close it (or wait for the other deploy run) and retry."
    }

    $startedAt = Get-Date
    $arguments = @{
        MapDir  = (Join-Path $ExamplesDir ([string]$Example.dir))
        MapName = $mapName
        Timeout = $Timeout
    }
    if ($null -ne $Example.pack) {
        foreach ($switchName in @($Example.pack)) { $arguments[$switchName] = $true }
    }

    $deployError = ''
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $DeployScript @arguments *>&1 | Out-File -LiteralPath $deployLog -Encoding UTF8
    } catch {
        $deployError = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $previousEap
    }
    # deploy.ps1 now exits 1 when the run observed failed > 0; the verdict here still comes
    # from the parsed Results line, the exit code is only carried into the note.
    $deployExit = $LASTEXITCODE

    $left = @(Get-Process -Name war3 -ErrorAction SilentlyContinue)
    $war3Left = ($left.Count -gt 0)

    $logPath = ''
    $passed = 0
    $failedCount = 0
    $totalCount = 0
    $found = $false
    $failLine = ''

    foreach ($candidate in (Find-ExampleLog -Since $startedAt)) {
        $logText = $null
        try { $logText = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 } catch { $logText = $null }
        if ([string]::IsNullOrEmpty($logText)) { continue }
        $hits = $ResultsRegex.Matches($logText)
        if ($hits.Count -eq 0) { continue }

        $last = $hits[$hits.Count - 1]
        $passed = [int]$last.Groups[1].Value
        $failedCount = [int]$last.Groups[2].Value
        $totalCount = [int]$last.Groups[3].Value
        $logPath = $candidate.FullName
        $found = $true

        if ($failedCount -gt 0 -or $totalCount -lt 3) {
            $failLines = @($logText -split '\r?\n' | Where-Object { $_ -match '\[FAIL\]' })
            if ($failLines.Count -gt 0) { $failLine = $failLines[0].Trim() }
            else { $failLine = "Results line reports $failedCount failed of $totalCount" }
            if ($failLine.Length -gt 160) { $failLine = $failLine.Substring(0, 160) }
        }
        break
    }

    $notes = @()
    if ($found) {
        $notes += "$passed/$totalCount passed, log $logPath"
    } else {
        $notes += "no fresh Results line under $LogDir\japi_debug*.txt within $($Timeout)s ($deployLog)"
    }
    if ($failLine -ne '') { $notes += $failLine }
    if ($deployError -ne '') { $notes += "deploy.ps1: $deployError" }
    if ($null -ne $deployExit -and [int]$deployExit -ne 0) { $notes += "deploy.ps1 exit $deployExit" }
    if ($war3Left) {
        $ids = ($left | ForEach-Object { $_.Id }) -join ', '
        $notes += "war3.exe still running after deploy (PID: $ids)"
    }

    $ok = $found -and -not $war3Left -and $failedCount -eq 0 -and $totalCount -ge 3
    return [pscustomobject]@{
        Ok      = $ok
        Note    = ($notes -join ' | ')
        LogPath = $logPath
    }
}

# ---------------------------------------------------------------- report

function Write-SummaryTable {
    param($Results)

    $format = '{0,-18} {1,-5} {2,-7} {3,-6} {4,-6} {5}'
    Write-Host ''
    Write-Host ($format -f 'Example', 'D3D', 'Static', 'Pack', 'Live', 'Note')
    Write-Host ($format -f ('-' * 18), ('-' * 5), ('-' * 7), ('-' * 6), ('-' * 6), ('-' * 24))
    foreach ($result in $Results) {
        $d3d = 'no'
        if ($result.D3D) { $d3d = 'yes' }
        $note = [string]$result.Note
        if ($note.Length -gt 110) { $note = $note.Substring(0, 110) + '...' }
        Write-Host ($format -f $result.Id, $d3d, $result.Static, $result.Pack, $result.Live, $note)
    }
}

# ---------------------------------------------------------------- main

$mode = 'static'
if (-not $SkipPack) { $mode = 'static+pack' }
if ($Live) { $mode = $mode + '+live' }

Write-Host "verify-examples  mode=$mode  timeout=$($Timeout)s  root=$Root"

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    Write-Host "[fail] missing $ManifestPath"
    exit 1
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $manifest -or $null -eq $manifest.examples) {
    Write-Host "[fail] $ManifestPath has no examples[] array"
    exit 1
}

$allExamples = @($manifest.examples)
$selected = $allExamples
if ($Filter -ne '') {
    $selected = @($allExamples | Where-Object { $_.id -match $Filter })
    if ($selected.Count -eq 0) {
        $ids = ($allExamples | ForEach-Object { $_.id }) -join ', '
        Write-Host "[fail] -Filter '$Filter' matched none of: $ids"
        exit 1
    }
}
$idsText = ($selected | ForEach-Object { $_.id }) -join ' '
Write-Host "  examples=$($selected.Count) of $($allExamples.Count): $idsText"

$packSwitches = @(Get-SwitchNames -Path $PackScript)
$deploySwitches = @(Get-SwitchNames -Path $DeployScript)

# D3D proxy: deploy.ps1 only installs it in -InteractiveD3D / -Demo / -TestReboot mode, so a
# plain -MapDir live run needs it installed here. An already installed+verified proxy is left
# alone (reinstall needs war3 stopped and is pointless when the hash agrees).
if ($Live) {
    $needsD3D = @($selected | Where-Object { $_.d3d }).Count -gt 0
    if ($needsD3D) {
        if ($War3Dir -eq '' -and (Test-Path -LiteralPath $ConfigLocal -PathType Leaf)) {
            . $ConfigLocal
        }
        if ($War3Dir -eq '' -and (Test-Path -LiteralPath $DefaultWar3Dir -PathType Container)) {
            $War3Dir = $DefaultWar3Dir
            Write-Host "  [info] no -War3Dir and no tools\config.local.ps1; using the deploy.ps1 default: $War3Dir"
        }
        if ($War3Dir -eq '') {
            Write-Host "[fail] D3D examples selected but no War3 directory found: pass -War3Dir 'D:\Warcraft III Frozen Throne 1.27a publish' or set War3Dir in tools\config.local.ps1"
            exit 1
        }
        $sidecar = Join-Path $War3Dir '.japi_d3d_proxy.sha256'
        $installed = Join-Path $War3Dir 'd3d9.dll'
        $alreadyInstalled = $false
        if ((Test-Path -LiteralPath $installed -PathType Leaf) -and (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
            $ownedHashPre = (Get-Content -LiteralPath $sidecar -Raw -Encoding ASCII).Trim().ToUpperInvariant()
            if ($ownedHashPre -eq (Get-Sha256 -Path $installed)) {
                $probeText = ''
                try { $probeText = (& $D3DProxyScript -Verify -War3Dir $War3Dir *>&1) -join ' ' } catch { $probeText = $_.Exception.Message }
                if ($probeText -match 'InstalledAndVerified') { $alreadyInstalled = $true }
            }
        }
        if ($alreadyInstalled) {
            Write-Host "  [ok] d3d9 proxy already installed and verified in $War3Dir; leaving it alone"
        } else {
            $running = @(Get-Process -Name war3 -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) {
                $ids = ($running | ForEach-Object { $_.Id }) -join ', '
                Write-Host "[fail] war3.exe is already running (PID: $ids); the d3d9 proxy is missing or stale, so it cannot be installed now. Close the game and retry."
                exit 1
            }
            Write-Host "[live] installing d3d9 proxy into $War3Dir"
            $proxyError = ''
            $previousEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $D3DProxyScript -Install -War3Dir $War3Dir *>&1 | ForEach-Object { Write-Host "  $_" }
            } catch {
                $proxyError = $_.Exception.Message
            } finally {
                $ErrorActionPreference = $previousEap
            }
            if ($proxyError -ne '') {
                Write-Host "[fail] d3d-proxy.ps1 -Install: $proxyError"
                exit 1
            }
        }
        if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) {
            Write-Host "[fail] d3d9 proxy missing from the game directory: $installed"
            exit 1
        }
        if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
            Write-Host "[fail] d3d proxy ownership sidecar missing: $sidecar"
            exit 1
        }
        $ownedHash = (Get-Content -LiteralPath $sidecar -Raw -Encoding ASCII).Trim().ToUpperInvariant()
        $installedHash = Get-Sha256 -Path $installed
        if ($ownedHash -ne $installedHash) {
            Write-Host "[fail] d3d9.dll does not match its sidecar: sidecar=$ownedHash installed=$installedHash"
            exit 1
        }
        Write-Host "  [ok] d3d9.dll sha256 $installedHash (sidecar agrees)"
        if (Test-Path -LiteralPath $ProxyBuild -PathType Leaf) {
            $buildHash = Get-Sha256 -Path $ProxyBuild
            if ($buildHash -ne $installedHash) {
                Write-Host "  [warn] installed proxy differs from src\build\bin\Release\newD3d9.dll ($buildHash); rebuild and reinstall if the D3D examples fail"
            }
        }
        $verifyText = ''
        try { $verifyText = (& $D3DProxyScript -Verify -War3Dir $War3Dir *>&1) -join ' ' } catch { $verifyText = $_.Exception.Message }
        if ($verifyText -notmatch 'InstalledAndVerified') {
            Write-Host "[fail] d3d-proxy.ps1 -Verify did not report InstalledAndVerified: $verifyText"
            exit 1
        }
        Write-Host '  [ok] d3d-proxy.ps1 -Verify: InstalledAndVerified'
    }
}

$results = New-Object System.Collections.Generic.List[object]
$abortLive = ''
foreach ($example in $selected) {
    $result = New-ExampleResult -Example $example
    Write-Host ''
    Write-Host "[$($example.id)] $($example.title)"

    $staticErrors = @(Test-ExampleStatic -Example $example -PackSwitches $packSwitches -DeploySwitches $deploySwitches)
    if ($staticErrors.Count -eq 0) {
        $result.Static = 'ok'
        Write-Host '  [static] ok'
    } else {
        $result.Static = 'fail'
        foreach ($message in $staticErrors) {
            Write-Host "  [static] $message"
            Add-Note -Result $result -Text $message
        }
    }

    if (-not $SkipPack) {
        $pack = Invoke-ExamplePack -Example $example
        if ($pack.Ok) {
            $result.Pack = 'ok'
            $size = (Get-Item -LiteralPath $pack.OutFile).Length
            Write-Host "  [pack] ok ($size bytes)"
        } else {
            $result.Pack = 'fail'
            Write-Host "  [pack] $($pack.Note)"
            Write-Host "         log: $($pack.Log)"
            Add-Note -Result $result -Text $pack.Note
        }
    }

    if ($Live) {
        if ($abortLive -ne '') {
            $result.Live = 'skip'
            Add-Note -Result $result -Text $abortLive
            Write-Host "  [live] skipped: $abortLive"
        } elseif (-not $example.live) {
            $result.Live = 'skip'
            Write-Host '  [live] skipped: manifest live=false'
        } else {
            try {
                $live = Invoke-ExampleLive -Example $example
                if ($live.Ok) {
                    $result.Live = 'ok'
                    Write-Host "  [live] ok ($($live.Note))"
                } else {
                    $result.Live = 'fail'
                    Write-Host "  [live] $($live.Note)"
                    Add-Note -Result $result -Text $live.Note
                }
                $stillRunning = @(Get-Process -Name war3 -ErrorAction SilentlyContinue)
                if ($stillRunning.Count -gt 0) {
                    $abortLive = "war3.exe is still running after $($example.id); remaining live runs cancelled"
                }
            } catch {
                $result.Live = 'fail'
                Write-Host "  [live] $($_.Exception.Message)"
                Add-Note -Result $result -Text $_.Exception.Message
                $abortLive = 'live run aborted: ' + $_.Exception.Message
            }
        }
    }

    $ok = ($result.Static -eq 'ok')
    if (-not $SkipPack -and $result.Pack -ne 'ok') { $ok = $false }
    if ($Live -and $result.Live -ne 'ok') { $ok = $false }
    $result.Ok = $ok
    $results.Add($result)
}

Write-SummaryTable -Results $results

$passedCount = @($results | Where-Object { $_.Ok }).Count
$failedCount = $results.Count - $passedCount

if ($Live) {
    Write-Host ''
    Write-Host '  deployed test maps stay in <War3Dir>\Maps\Test as vx-<id>.w3x (one per example)'
}

if (-not $KeepWork) {
    foreach ($result in $results) {
        if (-not $result.Ok) { continue }
        $tagDir = Join-Path $ScratchDir ('ex-' + $result.Id)
        if (Test-Path -LiteralPath $tagDir) { Remove-Item -LiteralPath $tagDir -Recurse -Force }
    }
    $kept = @($results | Where-Object { -not $_.Ok } | ForEach-Object { 'build\scratch\ex-' + $_.Id })
    if ($kept.Count -gt 0) { Write-Host "  kept scratch of failed examples: $($kept -join ' ')" }
}

Write-Host ''
Write-Host ("Examples: {0} passed, {1} failed, {2} total" -f $passedCount, $failedCount, $results.Count)
if ($failedCount -gt 0) { exit 1 }
exit 0

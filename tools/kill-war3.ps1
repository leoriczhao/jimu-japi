# tools/kill-war3.ps1
# Close a running War3 1.27a from any shell, even one that did not start it.
#
# War3 1.27a's Game.dll denies PROCESS_TERMINATE/PROCESS_QUERY to every process
# but its creator, so taskkill and Stop-Process answer "Access is denied" and a
# game whose launcher died becomes an orphan that keeps the single-instance lock
# and the shared log. The process owner still holds READ_CONTROL+WRITE_DAC, so
# this script repairs the DACL and then terminates the game -- no admin rights,
# nothing changed in the game installation (see tools\_war3ctl.ps1).
#
# Usage:
#   .\tools\kill-war3.ps1                    # close every running war3.exe
#   .\tools\kill-war3.ps1 -ProcessId 1234    # close one specific pid
#   .\tools\kill-war3.ps1 -DryRun            # only list what would be closed
param(
    [int[]]$ProcessId = @(),
    [switch]$DryRun,
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_war3ctl.ps1')

if (-not $ProcessId.Count) {
    $ProcessId = @(Get-War3ProcessId)
}
if (-not $ProcessId.Count) {
    Write-Host "kill-war3: no war3.exe is running."
    exit 0
}

if ($DryRun) {
    foreach ($id in $ProcessId) {
        $alive = Test-War3ProcessAlive -ProcessId $id
        $denied = ([JapiWar3Ctl]::OpenError($id, [JapiWar3Ctl]::PROCESS_TERMINATE) -ne 0)
        Write-Host ("kill-war3: pid {0} alive={1} terminateAccess={2}" -f $id, $alive, (-not $denied))
    }
    exit 0
}

$failed = 0
foreach ($id in $ProcessId) {
    if (-not (Test-War3ProcessAlive -ProcessId $id)) {
        Write-Host "kill-war3: pid $id is already gone."
        continue
    }
    $result = Stop-War3Process -ProcessId $id -TimeoutSeconds $TimeoutSeconds
    if ($result.Ok) {
        Write-Host ("kill-war3: pid {0} closed ({1})" -f $id, $result.Method)
    } else {
        $failed++
        Write-Host ("kill-war3: pid {0} FAILED: {1}" -f $id, $result.Note)
    }
}
if ($failed) {
    Write-Host "kill-war3: $failed process(es) survived."
    exit 1
}
Write-Host "kill-war3: done."
exit 0

# Drives the interactive D3D fixture (-InteractiveD3D) with synthetic mouse/keyboard input.
#
# The fixtures in map/tests/test_d3d.lua and map/tests/test_d3d_sdk.lua print [WAIT] markers and
# only advance once real input arrives, so this script follows those markers:
#   gate 1  hover the probe texture, tap Shift, click, then drag with the left button held outside
#   gate 2  release the capture outside, then tap Q outside the texture
#   gate 3  resize the game window while the device lifecycle probe watches for resize/reset
#
# Usage (from the repo root, while deploy.ps1 -InteractiveD3D -Hold is running):
#   .\tools\drive-interactive-d3d.ps1
#   .\tools\drive-interactive-d3d.ps1 -ResizeCount 24 -TimeoutSeconds 300
#
# Exit codes: 0 = results line observed, 1 = no results line, 2 = no war3 process, 3 = no window.
#
# Notes:
# - Window discovery enumerates top-level windows by pid and class name "Warcraft III" and requires
#   a client area of at least 320x240. Get-Process MainWindowHandle picks the wrong window and
#   FindWindowW returns 0 from an unelevated shell.
# - The game window is raised to HWND_TOPMOST while driving (so synthetic clicks land on it) and
#   restored to HWND_NOTOPMOST at the end.
# - -InsideOffsetX/-InsideOffsetY default to the centre-ish of the probe texture, whose client
#   rectangle is (72,136,256,192) in map/tests/test_d3d.lua; the offsets are relative to the
#   client origin, so they survive the window moving between runs.
param(
    [int]$ResizeCount = 24,
    [int]$TimeoutSeconds = 300,
    [string]$LogPath = "C:\ProgramData\japi_debug.txt",
    [int]$InsideOffsetX = 200,
    [int]$InsideOffsetY = 232,
    [int]$OutsideOffsetX = 900,
    [int]$OutsideOffsetY = 520
)

$ErrorActionPreference = "Continue"

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class JapiDrive {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  public static IntPtr FindGame(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, p) => {
      uint wpid; GetWindowThreadProcessId(h, out wpid);
      if (wpid != pid) return true;
      var cn = new StringBuilder(256); GetClassName(h, cn, 256);
      if (cn.ToString() != "Warcraft III") return true;
      RECT c; GetClientRect(h, out c);
      if (c.Right < 320 || c.Bottom < 240) return true;
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }

  public static bool Focus(IntPtr h) {
    uint pid; uint tid = GetWindowThreadProcessId(h, out pid);
    uint mine = GetCurrentThreadId();
    AttachThreadInput(mine, tid, true);
    ShowWindow(h, 9);
    SetWindowPos(h, (IntPtr)(-1), 0, 0, 0, 0, 0x13);
    BringWindowToTop(h);
    bool ok = SetForegroundWindow(h);
    AttachThreadInput(mine, tid, false);
    return ok;
  }
}
"@

function Get-LogText {
    try { return (Get-Content $LogPath -Raw) } catch { return "" }
}

function Wait-Marker([string]$pattern, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $text = Get-LogText
        if ($text -match $pattern) { return $true }
        if ($text -match "Results:\s*\d+ passed") {
            Write-Output ("gate '" + $pattern + "' skipped: the suite already finished")
            return $false
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Output ("TIMEOUT waiting for marker: " + $pattern)
    return $false
}

function Wait-Foreground([IntPtr]$h, [int]$tries) {
    for ($i = 0; $i -lt $tries; $i++) {
        $null = [JapiDrive]::Focus($h)
        Start-Sleep -Milliseconds 150
        if ([JapiDrive]::GetForegroundWindow() -eq $h) { return $true }
    }
    return $false
}

function Invoke-KeyTap([byte]$vk) {
    [JapiDrive]::keybd_event($vk, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 90
    [JapiDrive]::keybd_event($vk, 0, 2, [IntPtr]::Zero); Start-Sleep -Milliseconds 90
}

function Invoke-LeftDown { [JapiDrive]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero) }
function Invoke-LeftUp { [JapiDrive]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero) }

$proc = Get-Process -Name war3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Output "FAIL: no war3 process"; exit 2 }
$hwnd = [JapiDrive]::FindGame([uint32]$proc.Id)
if ($hwnd -eq [IntPtr]::Zero) { Write-Output "FAIL: game window not found"; exit 3 }

# War3 shows a splash window before the map window settles, so the first focus attempt can be
# wasted. Wait for the fixture's own gate marker before claiming the foreground; a gesture sent
# while another window owns the foreground is silently dropped, which shows up later as a
# duplicate click from a retry and a false failure of the exact-click-count assertions.
$focused = Wait-Foreground $hwnd 40

$origin = New-Object JapiDrive+POINT
$null = [JapiDrive]::ClientToScreen($hwnd, [ref]$origin)
$client = New-Object JapiDrive+RECT
$null = [JapiDrive]::GetClientRect($hwnd, [ref]$client)
$summary = "window=0x{0:X} pid={1} focused={2} origin=({3},{4}) client={5}x{6}" -f $hwnd.ToInt64(), $proc.Id, $focused, $origin.X, $origin.Y, $client.Right, $client.Bottom
Write-Output $summary
if (-not $focused) { Write-Output "WARN: the game window did not take the foreground" }

$inX = $origin.X + $InsideOffsetX
$inY = $origin.Y + $InsideOffsetY
$outX = $origin.X + $OutsideOffsetX
$outY = $origin.Y + $OutsideOffsetY
$results = $null

try {
    # Gate 1: hover the probe texture, tap Shift, click inside, then hold and drag outside.
    # The first synthetic gesture can be swallowed while the window finishes taking focus, so retry
    # a few times and watch the log for progress instead of trusting a single attempt.
    if (Wait-Marker "\[WAIT\] click inside, press Shift" $TimeoutSeconds) {
        Write-Output "gate 1: pointer gestures (inside=($inX,$inY) outside=($outX,$outY))"
        if (-not (Wait-Foreground $hwnd 30)) {
            Write-Output "WARN: could not hold the game foreground; gestures may be dropped"
        }
        Start-Sleep -Milliseconds 300
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $null = Wait-Foreground $hwnd 20
            $null = [JapiDrive]::SetCursorPos($inX, $inY); Start-Sleep -Milliseconds 400
            Invoke-KeyTap 0x10
            Invoke-LeftDown; Start-Sleep -Milliseconds 110
            Invoke-LeftUp; Start-Sleep -Milliseconds 250
            Invoke-LeftDown; Start-Sleep -Milliseconds 120
            for ($step = 1; $step -le 8; $step++) {
                $nextX = [int]($inX + ($outX - $inX) * $step / 8)
                $nextY = [int]($inY + ($outY - $inY) * $step / 8)
                $null = [JapiDrive]::SetCursorPos($nextX, $nextY)
                Start-Sleep -Milliseconds 60
            }
            Start-Sleep -Milliseconds 150
            Invoke-LeftUp
            Start-Sleep -Milliseconds 500
            if ((Get-LogText) -match "\[WAIT\] release the captured left button") {
                Write-Output ("gate 1: fixture advanced on attempt " + $attempt)
                break
            }
            Write-Output ("gate 1: no progress on attempt " + $attempt + ", retrying")
        }
    }

    # Gate 2: release the captured button outside the texture, then press Q outside it.
    if (Wait-Marker "\[WAIT\] release the captured left button" 180) {
        Write-Output "gate 2: capture release outside + Q"
        $null = Wait-Foreground $hwnd 20
        $null = [JapiDrive]::SetCursorPos($outX, $outY); Start-Sleep -Milliseconds 400
        Invoke-LeftDown; Start-Sleep -Milliseconds 110
        Invoke-LeftUp; Start-Sleep -Milliseconds 350
        Invoke-KeyTap 0x51
        Start-Sleep -Milliseconds 600
    }

    # Gate 3: resize the window repeatedly while the lifecycle probe watches for resize/reset.
    if (Wait-Marker "\[WAIT\] resize the War3 window" 240) {
        Write-Output ("gate 3: " + $ResizeCount + " window resizes")
        $sizes = @(@(1521, 770), @(1200, 700), @(1600, 830), @(1280, 720), @(1400, 760), @(1100, 660))
        $null = [JapiDrive]::SetCursorPos($outX, $outY)
        for ($i = 0; $i -lt $ResizeCount; $i++) {
            $size = $sizes[$i % $sizes.Count]
            $null = [JapiDrive]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, [int]$size[0], [int]$size[1], 0x0006 -bor 0x0010)
            Start-Sleep -Milliseconds 300
        }
        $null = [JapiDrive]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 1521, 770, 0x0006 -bor 0x0010)
        Start-Sleep -Milliseconds 500
    }

    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        $m = [regex]::Match((Get-LogText), "Results:\s*\d+ passed[^\r\n]*")
        if ($m.Success) { $results = $m.Value; break }
        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { Write-Output "game exited"; break }
        Start-Sleep -Milliseconds 500
    }
}
finally {
    $null = [JapiDrive]::SetWindowPos($hwnd, [IntPtr](-2), 0, 0, 0, 0, 0x13)
}

Write-Output "--- lifecycle / result lines ---"
((Get-LogText) -split "\r?\n") | Where-Object { $_ -match "\[LIFE\]|\[SKIP\]|\[FAIL\]|lifecycle|Results:|ALL TESTS" } | Select-Object -Last 14 | ForEach-Object { Write-Output ("  " + $_) }
if ($results) { Write-Output ("RESULT LINE: " + $results); exit 0 }
Write-Output "NO RESULT LINE"
exit 1

# tools/drive-demo.ps1 - drive a live "-Demo -Hold" session with real input.
#
# deploy.ps1 -Demo leaves the self-check run behind and keeps the game open with
# -Hold. This script focuses that window, takes screenshots and sends a real
# left click (engine move order), a real Q cast and a real R restart, so the
# playable path is exercised by OS-level input rather than by synthetic Lua
# messages.
param(
    [string]$ShotPrefix = "build\demo-live",
    [double]$MoveX = 0.62,
    [double]$MoveY = 0.42
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repo "build"))) { New-Item -ItemType Directory (Join-Path $repo "build") | Out-Null }
$shotDir = Split-Path -Parent $ShotPrefix
if ($shotDir -and -not (Test-Path $shotDir)) { New-Item -ItemType Directory $shotDir | Out-Null }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ("DemoDrive" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class DemoDrive {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
'@
}

$script:gameHwnd = [IntPtr]::Zero
$target = Get-Process war3 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $target) { Write-Host "FAIL: no war3 process"; exit 2 }
[DemoDrive]::EnumWindows({ param($h, $p)
    $pid2 = 0
    [void][DemoDrive]::GetWindowThreadProcessId($h, [ref]$pid2)
    if ($pid2 -eq $target.Id) {
        $sb = New-Object System.Text.StringBuilder 64
        [void][DemoDrive]::GetClassName($h, $sb, 64)
        if ($sb.ToString() -eq "Warcraft III") { $script:gameHwnd = $h; return $false }
    }
    return $true
}, [IntPtr]::Zero) | Out-Null
if ($script:gameHwnd -eq [IntPtr]::Zero) { Write-Host "FAIL: no game window"; exit 3 }
$hwnd = $script:gameHwnd

function Focus-Game {
    [void][DemoDrive]::ShowWindow($hwnd, 9)
    [void][DemoDrive]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x13)
    $fg = [DemoDrive]::GetForegroundWindow()
    $fgThread = [DemoDrive]::GetWindowThreadProcessId($fg, [ref]([uint32]0))
    $mine = [DemoDrive]::GetCurrentThreadId()
    [void][DemoDrive]::AttachThreadInput($fgThread, $mine, $true)
    [void][DemoDrive]::BringWindowToTop($hwnd)
    [void][DemoDrive]::SetForegroundWindow($hwnd)
    [void][DemoDrive]::AttachThreadInput($fgThread, $mine, $false)
    Start-Sleep -Milliseconds 400
}

function Get-ClientOrigin {
    $r = New-Object DemoDrive+RECT
    [void][DemoDrive]::GetClientRect($hwnd, [ref]$r)
    $pt = New-Object DemoDrive+POINT
    $pt.X = 0; $pt.Y = 0
    [void][DemoDrive]::ClientToScreen($hwnd, [ref]$pt)
    return @{ X = $pt.X; Y = $pt.Y; W = ($r.Right - $r.Left); H = ($r.Bottom - $r.Top) }
}

function Save-Shot([string]$name) {
    $rect = Get-ClientOrigin
    $bmp = New-Object System.Drawing.Bitmap $rect.W, $rect.H
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen($rect.X, $rect.Y, 0, 0, $bmp.Size)
    $gfx.Dispose()
    $path = "$ShotPrefix-$name.png"
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("shot: " + $path + " (" + $rect.W + "x" + $rect.H + ")")
}

function Tap-Key([byte]$vk) {
    [DemoDrive]::keybd_event($vk, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [DemoDrive]::keybd_event($vk, 0, 2, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 120
}

Focus-Game
$fg = [DemoDrive]::GetForegroundWindow()
Write-Host ("foreground=" + $fg.ToString("X") + " game=" + $hwnd.ToString("X"))
Save-Shot "start"

$rect = Get-ClientOrigin
$cx = [int]($rect.X + $rect.W * $MoveX)
$cy = [int]($rect.Y + $rect.H * $MoveY)
Write-Host ("client=" + $rect.X + "," + $rect.Y + " " + $rect.W + "x" + $rect.H + " click=" + $cx + "," + $cy)

# plain left click: the engine's own move order drives the selected hero
[void][DemoDrive]::SetCursorPos($cx, $cy)
Start-Sleep -Milliseconds 120
[DemoDrive]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 90
[DemoDrive]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 900
Save-Shot "after-move"

# real Q press: the game script casts Blizzard at the cursor
Tap-Key 0x51
Start-Sleep -Milliseconds 1200
Save-Shot "after-cast"

# real R press: restart through the same input hook
Tap-Key 0x52
Start-Sleep -Milliseconds 1500
Save-Shot "after-restart"

[void][DemoDrive]::SetWindowPos($hwnd, [IntPtr](-2), 0, 0, 0, 0, 0x13)
Write-Host "log tail:"
Get-Content "C:\ProgramData\japi_debug.txt" -Tail 24 | ForEach-Object { Write-Host ("  " + $_) }

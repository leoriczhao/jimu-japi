# tools/game-shot.ps1 - park the cursor in the live game window, optionally click or
# tap keys, and save a screenshot of the client area.
#
# Used to eyeball what a "-Demo -Hold" or "-InteractiveD3D -Hold" session actually
# renders at a known client coordinate (cursor indicators, HUD text, unit states).
param(
    [int]$X = 760,
    [int]$Y = 520,
    [string]$Shot = "build\game-shot.png",
    [string]$Keys = "",
    [switch]$Click,
    [int]$WaitMs = 900
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repo "build"))) { New-Item -ItemType Directory (Join-Path $repo "build") | Out-Null }
$shotDir = Split-Path -Parent $Shot
if ($shotDir -and -not (Test-Path $shotDir)) { New-Item -ItemType Directory $shotDir | Out-Null }

Add-Type -AssemblyName System.Drawing

if (-not ("GameShot" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class GameShot {
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
[GameShot]::EnumWindows({ param($h, $p)
    $owner = 0
    [void][GameShot]::GetWindowThreadProcessId($h, [ref]$owner)
    if ($owner -eq $target.Id) {
        $sb = New-Object System.Text.StringBuilder 64
        [void][GameShot]::GetClassName($h, $sb, 64)
        if ($sb.ToString() -eq "Warcraft III") { $script:gameHwnd = $h; return $false }
    }
    return $true
}, [IntPtr]::Zero) | Out-Null
if ($script:gameHwnd -eq [IntPtr]::Zero) { Write-Host "FAIL: no game window"; exit 3 }
$hwnd = $script:gameHwnd

# raise the game above everything: the synthetic input only counts while it is focused
[void][GameShot]::ShowWindow($hwnd, 9)
[void][GameShot]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x13)
$fg = [GameShot]::GetForegroundWindow()
$fgThread = [GameShot]::GetWindowThreadProcessId($fg, [ref]([uint32]0))
[void][GameShot]::AttachThreadInput($fgThread, [GameShot]::GetCurrentThreadId(), $true)
[void][GameShot]::BringWindowToTop($hwnd)
[void][GameShot]::SetForegroundWindow($hwnd)
[void][GameShot]::AttachThreadInput($fgThread, [GameShot]::GetCurrentThreadId(), $false)
Start-Sleep -Milliseconds 300

$rect = New-Object GameShot+RECT
[void][GameShot]::GetClientRect($hwnd, [ref]$rect)
$origin = New-Object GameShot+POINT
$origin.X = 0; $origin.Y = 0
[void][GameShot]::ClientToScreen($hwnd, [ref]$origin)
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
Write-Host ("client=" + $origin.X + "," + $origin.Y + " " + $w + "x" + $h + " cursor=" + $X + "," + $Y)

[void][GameShot]::SetCursorPos(($origin.X + $X), ($origin.Y + $Y))
Start-Sleep -Milliseconds 250

if ($Click) {
    [GameShot]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 90
    [GameShot]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 400
}

if ($Keys) {
    foreach ($k in $Keys.Split(",")) {
        $vk = [Convert]::ToByte($k.Trim(), 16)
        [GameShot]::keybd_event($vk, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 70
        [GameShot]::keybd_event($vk, 0, 2, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 200
    }
}

Start-Sleep -Milliseconds $WaitMs

$bmp = New-Object System.Drawing.Bitmap $w, $h
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bmp.Size)
$gfx.Dispose()
$bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
[void][GameShot]::SetWindowPos($hwnd, [IntPtr](-2), 0, 0, 0, 0, 0x13)
Write-Host ("shot: " + $Shot + " (" + $w + "x" + $h + ")")
$foreground = [GameShot]::GetForegroundWindow()
Write-Host ("foreground-after=" + $foreground.ToString("X") + " game=" + $hwnd.ToString("X"))

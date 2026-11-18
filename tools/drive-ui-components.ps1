# Drive the real War3 window for examples/12-ui-components. Coordinate markers
# are emitted by the map, so the driver does not call the Lua click callbacks.
# The exact marker sequence is documented in that example's README.
param(
    [string]$LogPath = 'C:\ProgramData\japi_debug.txt',
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ComponentDriver {
    public delegate bool EnumProc(IntPtr h, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int count);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint first, uint second, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public static void Focus(IntPtr h) {
        uint pid;
        uint target = GetWindowThreadProcessId(h, out pid);
        uint current = GetCurrentThreadId();
        AttachThreadInput(current, target, true);
        try { ShowWindow(h, 9); BringWindowToTop(h); SetForegroundWindow(h); }
        finally { AttachThreadInput(current, target, false); }
    }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, IntPtr extra);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public static IntPtr Find(uint pid) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((h, data) => {
            uint candidate; GetWindowThreadProcessId(h, out candidate);
            var name = new StringBuilder(128); GetClassName(h, name, 128);
            RECT r;
            if(candidate == pid && name.ToString() == "Warcraft III" && GetClientRect(h, out r) && r.Right >= 320 && r.Bottom >= 240) {
                result = h; return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@
function Read-Log {
    # The DLL holds the log open while writing. Share read/write/delete and
    # retry transient access failures instead of abandoning the input driver.
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } catch { return '' }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}
function Wait-Text([string]$Pattern) {
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $text = Read-Log
        $m = [regex]::Match($text, $Pattern)
        if ($m.Success) { return $m }
        if ($text -match 'Results:\s*\d+ passed') { throw "Suite ended before $Pattern" }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $end)
    throw "Timeout waiting for $Pattern"
}
function Click-Client([int]$X, [int]$Y) {
    $p = New-Object ComponentDriver+POINT
    $p.X = $X; $p.Y = $Y
    [void][ComponentDriver]::ClientToScreen($script:Window, [ref]$p)
    [void][ComponentDriver]::SetCursorPos($p.X, $p.Y)
    Start-Sleep -Milliseconds 250
    [ComponentDriver]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [ComponentDriver]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 350
}
$script:Window = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    foreach ($process in @(Get-Process war3 -ErrorAction SilentlyContinue)) {
        $script:Window = [ComponentDriver]::Find([uint32]$process.Id)
        if ($script:Window -ne [IntPtr]::Zero) { break }
    }
    if ($script:Window -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 200
} while ((Get-Date) -lt $deadline)
if ($script:Window -eq [IntPtr]::Zero) { throw 'No War3 client window found' }
$original = New-Object ComponentDriver+RECT
[void][ComponentDriver]::GetWindowRect($script:Window, [ref]$original)
try {
    [void][ComponentDriver]::ShowWindow($script:Window, 9)
    [void][ComponentDriver]::SetWindowPos($script:Window, [IntPtr](-1), 0, 0, 0, 0, 0x13)
    # Windows may refuse a background process's first foreground request.
    # Activate outside the sample and retry before sending any control input.
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        [ComponentDriver]::Focus($script:Window)
        if ([ComponentDriver]::GetForegroundWindow() -eq $script:Window) { break }
        Click-Client 24 200
        Start-Sleep -Milliseconds 300
    }
    if ([ComponentDriver]::GetForegroundWindow() -ne $script:Window) { throw 'War3 could not obtain foreground focus' }
    Write-Host '  War3 foreground confirmed'
    function Click-Marker([string]$Name) {
        $marker = Wait-Text ('UI12 ' + $Name + ' phase=[^\r\n]+')
        $rect = [regex]::Match($marker.Value, ' x=(-?\d+) y=(-?\d+) width=(\d+) height=(\d+)')
        if (-not $rect.Success) { throw "Missing client rectangle in $($marker.Value)" }
        $x = [int]$rect.Groups[1].Value + [int]([int]$rect.Groups[3].Value / 2)
        $y = [int]$rect.Groups[2].Value + [int]([int]$rect.Groups[4].Value / 2)
        Write-Host ("  $Name client click $x,$y")
        Click-Client $x $y
    }
    Click-Marker 'READY'
    Click-Marker 'ENABLED'
    [void](Wait-Text 'UI12 WAIT_RESIZE phase=[^\r\n]+')
    # Resize the actual HWND, not a Lua layout function. The component listens
    # to the native resize subscription and prints its new position.
    $client = New-Object ComponentDriver+RECT
    [void][ComponentDriver]::GetClientRect($script:Window, [ref]$client)
    $targetW = if ($client.Right -gt 1100) { 1100 } else { 1300 }
    [void][ComponentDriver]::SetWindowPos($script:Window, [IntPtr](-1), 0, 0, $targetW, 720, 0x16)
    Click-Marker 'RELAYOUT'
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $summary = [regex]::Match((Read-Log), 'Results:\s*(\d+) passed,\s*(\d+) failed,\s*(\d+) total')
        if ($summary.Success) { break }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $end)
    if (-not $summary.Success) { throw 'No Results line after real input sequence' }
    Write-Host $summary.Value
    if ($summary.Groups[2].Value -ne '0' -or [int]$summary.Groups[1].Value -lt 3 -or
        $summary.Groups[1].Value -ne $summary.Groups[3].Value) { throw 'UI interaction checks failed' }
} finally {
    [ComponentDriver]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
    [void][ComponentDriver]::SetWindowPos($script:Window, [IntPtr](-2), $original.Left, $original.Top,
        $original.Right - $original.Left, $original.Bottom - $original.Top, 0x10)
}

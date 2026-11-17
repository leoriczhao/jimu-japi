# tools\_war3ctl.ps1
# Shared helper: take control of a running War3 1.27a process and close it.
#
# Why this exists: War3 1.27a's Game.dll installs a deny-only DACL on its own
# process object (a single DENY ACE granting 0x001FFFFF to Everyone), so every
# process that did not create it gets "Access is denied" from OpenProcess,
# taskkill and Stop-Process -- the game outlives its launcher as an orphan and
# keeps the single-instance lock plus the shared log. The process OWNER still
# holds READ_CONTROL and WRITE_DAC implicitly (a DACL cannot take those away),
# so a process running as the same user can rewrite that DACL -- no admin
# rights, no changes to the game installation -- and then terminate the game
# normally. Measured on this machine with a running game: SetSecurityInfo
# returned 0, taskkill /F then reported SUCCESS, and the game kept running
# undisturbed until that point (it does not restore its own deny ACE).
#
# Optional job object: assigning the game to a job with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE lets the kernel kill it when the last job
# handle closes, which needs no process access at all. That is the backstop for
# "the launcher itself was killed": Windows closes its handles, the game dies.
#
# Dot-source this file (". $PSScriptRoot\_war3ctl.ps1"); it only defines
# functions and does nothing until one of them is called.

function Initialize-War3Ctl {
    if ('JapiWar3Ctl' -as [type]) { return }
    # C# 5 only: PowerShell 5.1 compiles with the .NET Framework CodeDom
    # provider, so no tuples, no string interpolation, no expression bodies.
    $source = @'
using System;
using System.Runtime.InteropServices;

public static class JapiWar3Ctl
{
    public const int PROCESS_TERMINATE = 0x0001;
    public const int READ_CONTROL = 0x00020000;
    public const int WRITE_DAC = 0x00040000;
    public const int SYNCHRONIZE = 0x00100000;
    public const int SE_KERNEL_OBJECT = 6;
    public const int DACL_SECURITY_INFORMATION = 4;
    public const int ACL_REVISION = 2;
    public const int PROCESS_ALL_ACCESS = 0x001FFFFF;
    public const uint LPTR = 0x0040;
    public const int JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    public const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalAlloc(uint uFlags, UIntPtr uBytes);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool InitializeAcl(IntPtr pAcl, int nAclLength, int dwAclRevision);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AddAccessAllowedAceEx(IntPtr pAcl, int dwAceRevision, int aceFlags, int accessMask, IntPtr pSid);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int SetSecurityInfo(IntPtr handle, int objectType, int securityInfo,
        IntPtr psidOwner, IntPtr psidGroup, IntPtr pDacl, IntPtr pSacl);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool ConvertStringSidToSidW(string stringSid, out IntPtr sid);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PROCESSENTRY32W
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32W entry);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32W entry);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObjectW(IntPtr jobAttributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int infoLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    // 0 when the access check passes, otherwise the Win32 error (5 = access denied).
    public static int OpenError(int pid, int access)
    {
        IntPtr handle = OpenProcess(access, false, pid);
        if (handle == IntPtr.Zero) { return Marshal.GetLastWin32Error(); }
        CloseHandle(handle);
        return 0;
    }

    // Rewrites the process DACL to "Everyone-owner + SYSTEM may do anything".
    // Returns 0 on success, otherwise the Win32 error.
    public static int RepairAcl(int pid, string userSid)
    {
        IntPtr hProcess = OpenProcess(READ_CONTROL | WRITE_DAC, false, pid);
        if (hProcess == IntPtr.Zero) { return Marshal.GetLastWin32Error(); }
        IntPtr sidSystem = IntPtr.Zero;
        IntPtr sidUser = IntPtr.Zero;
        IntPtr pAcl = IntPtr.Zero;
        try
        {
            if (!ConvertStringSidToSidW("S-1-5-18", out sidSystem)) { return Marshal.GetLastWin32Error(); }
            if (!ConvertStringSidToSidW(userSid, out sidUser)) { return Marshal.GetLastWin32Error(); }
            pAcl = LocalAlloc(LPTR, (UIntPtr)1024);
            if (pAcl == IntPtr.Zero) { return Marshal.GetLastWin32Error(); }
            if (!InitializeAcl(pAcl, 1024, ACL_REVISION)) { return Marshal.GetLastWin32Error(); }
            if (!AddAccessAllowedAceEx(pAcl, ACL_REVISION, 0, PROCESS_ALL_ACCESS, sidSystem)) { return Marshal.GetLastWin32Error(); }
            if (!AddAccessAllowedAceEx(pAcl, ACL_REVISION, 0, PROCESS_ALL_ACCESS, sidUser)) { return Marshal.GetLastWin32Error(); }
            return SetSecurityInfo(hProcess, SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION,
                IntPtr.Zero, IntPtr.Zero, pAcl, IntPtr.Zero);
        }
        finally
        {
            if (pAcl != IntPtr.Zero) { LocalFree(pAcl); }
            if (sidUser != IntPtr.Zero) { LocalFree(sidUser); }
            if (sidSystem != IntPtr.Zero) { LocalFree(sidSystem); }
            CloseHandle(hProcess);
        }
    }

    // Returns 0 when the process was terminated, otherwise the Win32 error.
    public static int Terminate(int pid)
    {
        IntPtr handle = OpenProcess(PROCESS_TERMINATE, false, pid);
        if (handle == IntPtr.Zero) { return Marshal.GetLastWin32Error(); }
        try
        {
            return TerminateProcess(handle, 0) ? 0 : Marshal.GetLastWin32Error();
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    // 0 = exited, 258 = still running, 87 (invalid parameter) = already gone,
    // 5 = cannot observe (caller has no SYNCHRONIZE access).
    public static int WaitForExit(int pid, int timeoutMs)
    {
        IntPtr handle = OpenProcess(SYNCHRONIZE, false, pid);
        if (handle == IntPtr.Zero) { return Marshal.GetLastWin32Error(); }
        try
        {
            uint rc = WaitForSingleObject(handle, (uint)timeoutMs);
            if (rc == 0) { return 0; }
            if (rc == 258) { return 258; }
            return (int)rc;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    // Job with KILL_ON_JOB_CLOSE; IntPtr.Zero on failure (error is set).
    public static IntPtr CreateKillOnCloseJob(out int error)
    {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return IntPtr.Zero; }
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = (uint)JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        bool ok = SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info,
            Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
        if (!ok)
        {
            error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            return IntPtr.Zero;
        }
        error = 0;
        return job;
    }

    public static int AssignToJob(IntPtr job, IntPtr process)
    {
        return AssignProcessToJobObject(job, process) ? 0 : Marshal.GetLastWin32Error();
    }

    public static int TerminateJob(IntPtr job)
    {
        return TerminateJobObject(job, 0) ? 0 : Marshal.GetLastWin32Error();
    }

    public static bool CloseObjectHandle(IntPtr handle)
    {
        if (handle == IntPtr.Zero) { return false; }
        return CloseHandle(handle);
    }

    // True while the pid still exists. Uses a Toolhelp snapshot, which needs no
    // access to the target process -- the only way to tell "still running" from
    // "access denied" once the game has installed its deny ACE.
    public static bool Exists(int pid)
    {
        IntPtr snapshot = CreateToolhelp32Snapshot(0x00000002, 0);
        if (snapshot == new IntPtr(-1)) { return false; }
        try
        {
            PROCESSENTRY32W entry = new PROCESSENTRY32W();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
            if (!Process32FirstW(snapshot, ref entry)) { return false; }
            do
            {
                if ((int)entry.th32ProcessID == pid) { return true; }
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
            }
            while (Process32NextW(snapshot, ref entry));
            return false;
        }
        finally
        {
            CloseHandle(snapshot);
        }
    }
}
'@
    Add-Type -TypeDefinition $source -ErrorAction Stop
}

# Applies the DACL repair once. Returns 0 on success, otherwise the Win32 error.
function Repair-War3ProcessAcl {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    Initialize-War3Ctl
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return [JapiWar3Ctl]::RepairAcl($ProcessId, $sid)
}

# True when this process may terminate the given process right now.
function Test-War3Terminable {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    Initialize-War3Ctl
    return ([JapiWar3Ctl]::OpenError($ProcessId, [JapiWar3Ctl]::PROCESS_TERMINATE) -eq 0)
}

# Repairs the DACL until termination access sticks. The game installs its deny
# ACE while it boots, so a single repair can be undone by a later boot step;
# requiring a few consecutive clean checks makes this state "stable", not "just
# repaired". Returns an object: Ok, Attempts, Error, Gone.
function Wait-War3ProcessControl {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$TimeoutMs = 20000,
        [int]$PollMs = 400,
        [int]$StableChecks = 3
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $attempts = 0
    $stable = 0
    $lastError = 0
    while ($true) {
        $attempts++
        $repairError = Repair-War3ProcessAcl -ProcessId $ProcessId
        $accessError = [JapiWar3Ctl]::OpenError($ProcessId, [JapiWar3Ctl]::PROCESS_TERMINATE)
        if ($accessError -eq 0) {
            $stable++
            if ($stable -ge $StableChecks) {
                return [pscustomobject]@{ Ok = $true; Attempts = $attempts; Error = 0; Gone = $false }
            }
        } else {
            $stable = 0
            $lastError = $accessError
            if ($accessError -eq 87 -or $accessError -eq 1168) {   # invalid parameter / not found
                return [pscustomobject]@{ Ok = $false; Attempts = $attempts; Error = $accessError; Gone = $true }
            }
            if ($repairError -ne 0) { $lastError = $repairError }
        }
        if ((Get-Date) -gt $deadline) {
            return [pscustomobject]@{ Ok = $false; Attempts = $attempts; Error = $lastError; Gone = $false }
        }
        Start-Sleep -Milliseconds $PollMs
    }
}

# Process ids of every running War3, found without touching them (CIM, with
# tasklist as the fallback). Process.Get-Process -Name skips processes it cannot
# open, which is exactly the case this file exists for.
function Get-War3ProcessId {
    param([string]$Name = 'war3')
    $ids = @()
    try {
        $ids = @(Get-CimInstance -ClassName Win32_Process -Filter ("Name='" + $Name + ".exe'") -ErrorAction Stop |
            ForEach-Object { [int]$_.ProcessId })
    } catch {
        $ids = @()
    }
    if (-not $ids.Count) {
        $rows = & tasklist.exe /FI ("IMAGENAME eq " + $Name + ".exe") /FO CSV /NH 2>$null
        foreach ($row in @($rows)) {
            if ($row -match '^"[^"]+","(\d+)"') { $ids += [int]$Matches[1] }
        }
    }
    return @($ids | Sort-Object -Unique)
}

# Liveness via a Toolhelp snapshot: unlike OpenProcess (or Process.GetProcesses,
# which silently skips processes it cannot open) this needs no access to the
# target, so it still answers after the game has denied everything.
function Test-War3ProcessAlive {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    Initialize-War3Ctl
    return [JapiWar3Ctl]::Exists($ProcessId)
}

# 0 = exited, 258 = still running; any other value is treated as "no longer there".
function Wait-War3ProcessExit {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$TimeoutMs = 10000
    )
    if (-not (Test-War3ProcessAlive -ProcessId $ProcessId)) { return $true }
    if ($TimeoutMs -le 0) { return $false }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if (-not (Test-War3ProcessAlive -ProcessId $ProcessId)) { return $true }
    }
    return $false
}

# Terminates the game: the creation handle first, then the DACL repair. Both are
# retried until the process is really gone, because a booting game can re-install
# its deny ACE between the repair and the terminate call.
# Returns an object: Ok, Method, Error, Note.
function Stop-War3Process {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 20
    )
    Initialize-War3Ctl
    $method = ''
    $note = ''
    $lastError = 0
    if ($Process) {
        try {
            if (-not $Process.HasExited) { $Process.Kill() }
            $method = 'creation handle'
        } catch {
            $note = $_.Exception.Message
        }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if (Wait-War3ProcessExit -ProcessId $ProcessId -TimeoutMs 0) {
            if (-not $method) { $method = 'already gone' }
            return [pscustomobject]@{ Ok = $true; Method = $method; Error = 0; Note = $note }
        }
        # The process is either dying or unreachable; give the kernel a moment.
        if (Wait-War3ProcessExit -ProcessId $ProcessId -TimeoutMs 1500) {
            if (-not $method) { $method = 'already gone' }
            return [pscustomobject]@{ Ok = $true; Method = $method; Error = 0; Note = $note }
        }
        if ((Get-Date) -gt $deadline) { break }
        $repairError = Repair-War3ProcessAcl -ProcessId $ProcessId
        $accessError = [JapiWar3Ctl]::OpenError($ProcessId, [JapiWar3Ctl]::PROCESS_TERMINATE)
        if ($accessError -eq 0) {
            $terminateError = [JapiWar3Ctl]::Terminate($ProcessId)
            if ($terminateError -eq 0) {
                $method = 'dacl repair + terminate'
            } else {
                $lastError = $terminateError
            }
        } elseif ($accessError -eq 87 -or $accessError -eq 1168) {
            return [pscustomobject]@{ Ok = $true; Method = 'already gone'; Error = 0; Note = $note }
        } else {
            $lastError = $accessError
        }
        if ($repairError -ne 0 -and $lastError -eq 0) { $lastError = $repairError }
    }
    return [pscustomobject]@{
        Ok = $false
        Method = 'failed'
        Error = $lastError
        Note = 'still running after ' + $TimeoutSeconds + 's; win32 error ' + $lastError
    }
}

# Creates a job that kills every member when its last handle closes.
function New-War3Job {
    Initialize-War3Ctl
    $error = 0
    $job = [JapiWar3Ctl]::CreateKillOnCloseJob([ref]$error)
    return [pscustomobject]@{ Handle = $job; Error = $error }
}

# Adds a process (its handle needs PROCESS_SET_QUOTA + PROCESS_TERMINATE, which
# the creation handle of Start-Process -PassThru has) to the job.
function Add-War3ProcessToJob {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Job,
        [Parameter(Mandatory = $true)][IntPtr]$ProcessHandle
    )
    Initialize-War3Ctl
    return [JapiWar3Ctl]::AssignToJob($Job, $ProcessHandle)
}

# Closes the job handle; with KILL_ON_JOB_CLOSE the kernel terminates the game.
function Close-War3Job {
    param([Parameter(Mandatory = $true)][IntPtr]$Job)
    Initialize-War3Ctl
    $error = [JapiWar3Ctl]::TerminateJob($Job)
    [void][JapiWar3Ctl]::CloseObjectHandle($Job)
    return $error
}

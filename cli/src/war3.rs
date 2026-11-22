use anyhow::{bail, Context, Result};
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::ffi::OsString;
#[cfg(windows)]
use std::os::windows::ffi::{OsStrExt, OsStringExt};

/// Validate a 32-bit PE D3D proxy DLL in pure Rust (zero objdump.exe dependency):
/// - Must export `Direct3DCreate9` and `InitializeD3DAPI`
/// - Must NOT import `d3d9.dll` (would recurse into itself)
pub fn assert_d3d_proxy_contract(path: &Path) -> Result<()> {
    let bytes = fs::read(path).with_context(|| format!("Failed to read proxy {}", path.display()))?;
    let (exports, imports) = parse_pe_exports_and_imports(&bytes)
        .with_context(|| format!("Failed to parse PE headers of {}", path.display()))?;

    let has_d3d = exports.iter().any(|e| e == "Direct3DCreate9");
    let has_init = exports.iter().any(|e| e == "InitializeD3DAPI");
    if !has_d3d || !has_init {
        bail!(
            "D3D proxy is missing Direct3DCreate9 or InitializeD3DAPI export: {} (found exports: {:?})",
            path.display(),
            exports
        );
    }
    if imports.iter().any(|i| i.eq_ignore_ascii_case("d3d9.dll")) {
        bail!(
            "D3D proxy imports d3d9.dll and would recurse: {}",
            path.display()
        );
    }
    Ok(())
}

fn read_u16(b: &[u8], off: usize) -> Result<u16> {
    if off + 2 > b.len() {
        bail!("unexpected EOF reading u16 at 0x{:X}", off);
    }
    Ok(u16::from_le_bytes([b[off], b[off + 1]]))
}

fn read_u32(b: &[u8], off: usize) -> Result<u32> {
    if off + 4 > b.len() {
        bail!("unexpected EOF reading u32 at 0x{:X}", off);
    }
    Ok(u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]))
}

fn read_cstr(b: &[u8], off: usize) -> Option<String> {
    if off >= b.len() {
        return None;
    }
    let end = b[off..].iter().position(|&c| c == 0)?;
    Some(String::from_utf8_lossy(&b[off..off + end]).into_owned())
}

struct PeSection {
    virtual_addr: u32,
    virtual_size: u32,
    raw_ptr: u32,
    raw_size: u32,
}

fn rva_to_offset(sections: &[PeSection], rva: u32) -> Option<usize> {
    for s in sections {
        let span = s.virtual_size.max(s.raw_size);
        if rva >= s.virtual_addr && rva < s.virtual_addr.saturating_add(span) {
            let delta = rva - s.virtual_addr;
            if delta < s.raw_size {
                return Some((s.raw_ptr + delta) as usize);
            }
        }
    }
    None
}

fn parse_pe_exports_and_imports(b: &[u8]) -> Result<(Vec<String>, Vec<String>)> {
    if b.len() < 0x40 || &b[0..2] != b"MZ" {
        bail!("not a PE/MZ executable");
    }
    let pe_off = read_u32(b, 0x3C)? as usize;
    if pe_off + 24 > b.len() || &b[pe_off..pe_off + 4] != b"PE\0\0" {
        bail!("missing PE signature");
    }
    let num_sections = read_u16(b, pe_off + 6)? as usize;
    let opt_size = read_u16(b, pe_off + 20)? as usize;
    let opt_off = pe_off + 24;
    let magic = read_u16(b, opt_off)?;
    let dd_off = match magic {
        0x10B => opt_off + 96,  // PE32
        0x20B => opt_off + 112, // PE32+
        _ => bail!("unknown PE optional header magic 0x{:X}", magic),
    };
    let num_rva = read_u32(b, dd_off - 4)? as usize;

    let sec_table_off = opt_off + opt_size;
    let mut sections = Vec::with_capacity(num_sections);
    for i in 0..num_sections {
        let off = sec_table_off + i * 40;
        sections.push(PeSection {
            virtual_size: read_u32(b, off + 8)?,
            virtual_addr: read_u32(b, off + 12)?,
            raw_size: read_u32(b, off + 16)?,
            raw_ptr: read_u32(b, off + 20)?,
        });
    }

    let mut exports = Vec::new();
    if num_rva > 0 {
        let exp_rva = read_u32(b, dd_off)?;
        let exp_size = read_u32(b, dd_off + 4)?;
        if exp_rva != 0 && exp_size != 0 {
            if let Some(exp_off) = rva_to_offset(&sections, exp_rva) {
                let num_names = read_u32(b, exp_off + 24)? as usize;
                let names_rva = read_u32(b, exp_off + 32)?;
                if let Some(names_off) = rva_to_offset(&sections, names_rva) {
                    for i in 0..num_names {
                        let name_rva = read_u32(b, names_off + i * 4)?;
                        if let Some(name_off) = rva_to_offset(&sections, name_rva) {
                            if let Some(name) = read_cstr(b, name_off) {
                                exports.push(name);
                            }
                        }
                    }
                }
            }
        }
    }

    let mut imports = Vec::new();
    if num_rva > 1 {
        let imp_rva = read_u32(b, dd_off + 8)?;
        let imp_size = read_u32(b, dd_off + 12)?;
        if imp_rva != 0 && imp_size != 0 {
            if let Some(mut desc_off) = rva_to_offset(&sections, imp_rva) {
                loop {
                    if desc_off + 20 > b.len() {
                        break;
                    }
                    let orig_first_thunk = read_u32(b, desc_off)?;
                    let name_rva = read_u32(b, desc_off + 12)?;
                    let first_thunk = read_u32(b, desc_off + 16)?;
                    if orig_first_thunk == 0 && name_rva == 0 && first_thunk == 0 {
                        break;
                    }
                    if let Some(name_off) = rva_to_offset(&sections, name_rva) {
                        if let Some(dll_name) = read_cstr(b, name_off) {
                            imports.push(dll_name);
                        }
                    }
                    desc_off += 20;
                }
            }
        }
    }

    Ok((exports, imports))
}

#[cfg(windows)]
pub fn find_war3_pids() -> Vec<u32> {
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };

    let mut pids = Vec::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap == INVALID_HANDLE_VALUE || snap.is_null() {
            return pids;
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snap, &mut entry) != 0 {
            loop {
                let len = entry
                    .szExeFile
                    .iter()
                    .position(|&c| c == 0)
                    .unwrap_or(entry.szExeFile.len());
                let name = OsString::from_wide(&entry.szExeFile[..len])
                    .to_string_lossy()
                    .into_owned();
                if name.eq_ignore_ascii_case("war3.exe") {
                    pids.push(entry.th32ProcessID);
                }
                if Process32NextW(snap, &mut entry) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);
    }
    pids.sort_unstable();
    pids.dedup();
    pids
}

#[cfg(not(windows))]
pub fn find_war3_pids() -> Vec<u32> {
    Vec::new()
}

pub fn is_pid_alive(pid: u32) -> bool {
    find_war3_pids().contains(&pid)
}

#[cfg(windows)]
fn current_user_sid() -> Result<Vec<u8>> {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::Security::{
        GetLengthSid, GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    unsafe {
        let mut token = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            bail!("OpenProcessToken failed");
        }
        let mut needed: u32 = 0;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut needed);
        if needed == 0 {
            CloseHandle(token);
            bail!("GetTokenInformation size query failed");
        }
        let mut buf = vec![0u8; needed as usize];
        let ok = GetTokenInformation(
            token,
            TokenUser,
            buf.as_mut_ptr() as *mut _,
            needed,
            &mut needed,
        );
        CloseHandle(token);
        if ok == 0 {
            bail!("GetTokenInformation(TokenUser) failed");
        }
        let tu = &*(buf.as_ptr() as *const TOKEN_USER);
        let sid_len = GetLengthSid(tu.User.Sid) as usize;
        let mut sid = vec![0u8; sid_len];
        std::ptr::copy_nonoverlapping(tu.User.Sid as *const u8, sid.as_mut_ptr(), sid_len);
        Ok(sid)
    }
}

/// Rewrite War3 1.27a's deny-only process DACL (installed by Game.dll) so the
/// owning user can terminate orphaned war3.exe instances without admin rights.
#[cfg(windows)]
pub fn repair_process_dacl(pid: u32) -> Result<()> {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, LocalFree};
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSidToSidW, SetSecurityInfo, SE_KERNEL_OBJECT,
    };
    use windows_sys::Win32::Security::{
        AddAccessAllowedAceEx, InitializeAcl, ACL, ACL_REVISION, DACL_SECURITY_INFORMATION,
    };
    use windows_sys::Win32::System::Memory::{LocalAlloc, LPTR};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_ALL_ACCESS, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    const READ_CONTROL: u32 = 0x0002_0000;
    const WRITE_DAC: u32 = 0x0004_0000;
    let _ = PROCESS_QUERY_LIMITED_INFORMATION;

    let user_sid = current_user_sid()?;
    unsafe {
        let hproc = OpenProcess(READ_CONTROL | WRITE_DAC, 0, pid);
        if hproc.is_null() {
            bail!("OpenProcess(READ_CONTROL|WRITE_DAC) failed (err {})", GetLastError());
        }
        let mut sid_system = std::ptr::null_mut();
        let sys_str: Vec<u16> = "S-1-5-18\0".encode_utf16().collect();
        let mut p_acl = std::ptr::null_mut();
        let result = (|| -> Result<()> {
            if ConvertStringSidToSidW(sys_str.as_ptr(), &mut sid_system) == 0 {
                bail!("ConvertStringSidToSidW(SYSTEM) failed (err {})", GetLastError());
            }
            p_acl = LocalAlloc(LPTR, 1024);
            if p_acl.is_null() {
                bail!("LocalAlloc(ACL) failed");
            }
            if InitializeAcl(p_acl as *mut ACL, 1024, ACL_REVISION) == 0 {
                bail!("InitializeAcl failed (err {})", GetLastError());
            }
            if AddAccessAllowedAceEx(p_acl as *mut ACL, ACL_REVISION, 0, PROCESS_ALL_ACCESS, sid_system) == 0 {
                bail!("AddAccessAllowedAceEx(SYSTEM) failed (err {})", GetLastError());
            }
            if AddAccessAllowedAceEx(
                p_acl as *mut ACL,
                ACL_REVISION,
                0,
                PROCESS_ALL_ACCESS,
                user_sid.as_ptr() as *mut _,
            ) == 0
            {
                bail!("AddAccessAllowedAceEx(User) failed (err {})", GetLastError());
            }
            let rc = SetSecurityInfo(
                hproc,
                SE_KERNEL_OBJECT,
                DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                p_acl as *const ACL,
                std::ptr::null(),
            );
            if rc != 0 {
                bail!("SetSecurityInfo failed (err {})", rc);
            }
            Ok(())
        })();

        if !p_acl.is_null() {
            LocalFree(p_acl);
        }
        if !sid_system.is_null() {
            LocalFree(sid_system);
        }
        CloseHandle(hproc);
        result
    }
}

#[cfg(windows)]
pub fn stop_war3_pid(pid: u32, timeout: Duration) -> Result<&'static str> {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError};
    use windows_sys::Win32::System::Threading::{OpenProcess, TerminateProcess, PROCESS_TERMINATE};

    if !is_pid_alive(pid) {
        return Ok("already-exited");
    }

    let method = unsafe {
        let h = OpenProcess(PROCESS_TERMINATE, 0, pid);
        if !h.is_null() {
            let ok = TerminateProcess(h, 0);
            let err = GetLastError();
            CloseHandle(h);
            if ok != 0 {
                "direct-terminate"
            } else {
                repair_process_dacl(pid)
                    .with_context(|| format!("TerminateProcess err {}; DACL repair failed", err))?;
                let h2 = OpenProcess(PROCESS_TERMINATE, 0, pid);
                if h2.is_null() {
                    bail!("OpenProcess after DACL repair failed (err {})", GetLastError());
                }
                let ok2 = TerminateProcess(h2, 0);
                let err2 = GetLastError();
                CloseHandle(h2);
                if ok2 == 0 {
                    bail!("TerminateProcess after DACL repair failed (err {})", err2);
                }
                "dacl-repair+terminate"
            }
        } else {
            repair_process_dacl(pid)?;
            let h2 = OpenProcess(PROCESS_TERMINATE, 0, pid);
            if h2.is_null() {
                bail!("OpenProcess after DACL repair failed (err {})", GetLastError());
            }
            let ok2 = TerminateProcess(h2, 0);
            let err2 = GetLastError();
            CloseHandle(h2);
            if ok2 == 0 {
                bail!("TerminateProcess after DACL repair failed (err {})", err2);
            }
            "dacl-repair+terminate"
        }
    };

    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if !is_pid_alive(pid) {
            return Ok(method);
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    if !is_pid_alive(pid) {
        Ok(method)
    } else {
        bail!("war3.exe (pid {}) still alive after {}s", pid, timeout.as_secs())
    }
}

#[cfg(not(windows))]
pub fn stop_war3_pid(_pid: u32, _timeout: Duration) -> Result<&'static str> {
    Ok("noop")
}

#[cfg(windows)]
pub struct KillOnCloseJob {
    handle: windows_sys::Win32::Foundation::HANDLE,
}

#[cfg(windows)]
impl KillOnCloseJob {
    pub fn new() -> Result<Self> {
        use windows_sys::Win32::Foundation::{CloseHandle, GetLastError};
        use windows_sys::Win32::System::JobObjects::{
            CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        };

        unsafe {
            let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if handle.is_null() {
                bail!("CreateJobObjectW failed (err {})", GetLastError());
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let ok = SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const _,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            if ok == 0 {
                let err = GetLastError();
                CloseHandle(handle);
                bail!("SetInformationJobObject failed (err {})", err);
            }
            Ok(Self { handle })
        }
    }

    pub fn assign_process(&self, proc_handle: windows_sys::Win32::Foundation::HANDLE) -> Result<()> {
        use windows_sys::Win32::Foundation::GetLastError;
        use windows_sys::Win32::System::JobObjects::AssignProcessToJobObject;
        unsafe {
            if AssignProcessToJobObject(self.handle, proc_handle) == 0 {
                bail!("AssignProcessToJobObject failed (err {})", GetLastError());
            }
        }
        Ok(())
    }
}

#[cfg(windows)]
impl Drop for KillOnCloseJob {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe {
                windows_sys::Win32::Foundation::CloseHandle(self.handle);
            }
        }
    }
}

/// RAII guard for HKCU\Software\Blizzard Entertainment\Warcraft III\Gameplay\healthbars=1
#[cfg(windows)]
pub struct HealthBarsGuard {
    previous: Option<u32>,
    active: bool,
}

#[cfg(windows)]
impl HealthBarsGuard {
    pub fn enable() -> Result<Self> {
        use windows_sys::Win32::System::Registry::{
            RegCloseKey, RegCreateKeyExW, RegQueryValueExW, RegSetValueExW, HKEY_CURRENT_USER,
            KEY_READ, KEY_WRITE, REG_DWORD,
        };

        let subkey = to_wide(r"Software\Blizzard Entertainment\Warcraft III\Gameplay");
        let valname = to_wide("healthbars");
        let mut previous = None;
        unsafe {
            let mut hkey = std::ptr::null_mut();
            let rc = RegCreateKeyExW(
                HKEY_CURRENT_USER,
                subkey.as_ptr(),
                0,
                std::ptr::null_mut(),
                0,
                KEY_READ | KEY_WRITE,
                std::ptr::null(),
                &mut hkey,
                std::ptr::null_mut(),
            );
            if rc != 0 {
                bail!("RegCreateKeyExW(Gameplay) failed (err {})", rc);
            }
            let mut data: u32 = 0;
            let mut data_len: u32 = 4;
            let mut kind: u32 = 0;
            if RegQueryValueExW(
                hkey,
                valname.as_ptr(),
                std::ptr::null_mut(),
                &mut kind,
                &mut data as *mut u32 as *mut u8,
                &mut data_len,
            ) == 0
                && kind == REG_DWORD
            {
                previous = Some(data);
            }
            let one: u32 = 1;
            RegSetValueExW(
                hkey,
                valname.as_ptr(),
                0,
                REG_DWORD,
                &one as *const u32 as *const u8,
                4,
            );
            RegCloseKey(hkey);
        }
        println!("  Native health bars: on for this session (healthbars=1)");
        Ok(Self {
            previous,
            active: true,
        })
    }
}

#[cfg(windows)]
impl Drop for HealthBarsGuard {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        use windows_sys::Win32::System::Registry::{
            RegCloseKey, RegDeleteValueW, RegOpenKeyExW, RegSetValueExW, HKEY_CURRENT_USER,
            KEY_WRITE, REG_DWORD,
        };
        let subkey = to_wide(r"Software\Blizzard Entertainment\Warcraft III\Gameplay");
        let valname = to_wide("healthbars");
        unsafe {
            let mut hkey = std::ptr::null_mut();
            if RegOpenKeyExW(HKEY_CURRENT_USER, subkey.as_ptr(), 0, KEY_WRITE, &mut hkey) == 0 {
                if let Some(prev) = self.previous {
                    RegSetValueExW(
                        hkey,
                        valname.as_ptr(),
                        0,
                        REG_DWORD,
                        &prev as *const u32 as *const u8,
                        4,
                    );
                } else {
                    RegDeleteValueW(hkey, valname.as_ptr());
                }
                RegCloseKey(hkey);
                println!("  Native health bars: player setting restored");
            }
        }
    }
}

#[cfg(windows)]
pub fn is_module_loaded(pid: u32, expected_path: &Path) -> bool {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::ProcessStatus::{
        EnumProcessModulesEx, GetModuleFileNameExW, LIST_MODULES_ALL,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_INFORMATION, PROCESS_VM_READ,
    };

    let expected_lower = expected_path.to_string_lossy().to_ascii_lowercase();
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, 0, pid);
        if h.is_null() {
            return false;
        }
        let mut mods = vec![std::ptr::null_mut(); 512];
        let mut needed: u32 = 0;
        let ok = EnumProcessModulesEx(
            h,
            mods.as_mut_ptr(),
            (mods.len() * std::mem::size_of::<*mut std::ffi::c_void>()) as u32,
            &mut needed,
            LIST_MODULES_ALL,
        );
        let mut found = false;
        if ok != 0 {
            let count = (needed as usize / std::mem::size_of::<*mut std::ffi::c_void>()).min(mods.len());
            let mut buf = vec![0u16; 512];
            for &m in &mods[..count] {
                let len = GetModuleFileNameExW(h, m, buf.as_mut_ptr(), buf.len() as u32) as usize;
                if len > 0 {
                    let s = OsString::from_wide(&buf[..len])
                        .to_string_lossy()
                        .to_ascii_lowercase();
                    if s == expected_lower {
                        found = true;
                        break;
                    }
                }
            }
        }
        CloseHandle(h);
        found
    }
}

#[cfg(windows)]
fn to_wide(s: &str) -> Vec<u16> {
    std::ffi::OsStr::new(s)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

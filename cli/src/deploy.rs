use crate::config::{sha256_file_upper, JapiEnv, DEFAULT_LOG_FILE};
use crate::pack::{run_pack, PackArgs};
use crate::war3::{
    assert_d3d_proxy_contract, find_war3_pids, is_module_loaded, is_pid_alive, stop_war3_pid,
    HealthBarsGuard, KillOnCloseJob,
};
use anyhow::{bail, Context, Result};
use regex::Regex;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime};

#[derive(Debug, Clone)]
pub struct DeployArgs {
    pub pack: PackArgs,
    pub war3_dir: Option<PathBuf>,
    pub map_name: Option<String>,
    pub log_file: Option<PathBuf>,
    pub timeout_secs: Option<u64>,
    pub play: bool,
    pub no_kill: bool,
    pub hold: bool,
    pub job: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyAction {
    Verify,
    Install,
    Uninstall,
}

pub fn run_proxy(
    env: &JapiEnv,
    action: ProxyAction,
    war3_dir_explicit: Option<&Path>,
    proxy_explicit: Option<&Path>,
) -> Result<()> {
    let war3_dir = env
        .resolve_war3_dir(war3_dir_explicit, false)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "War3Dir is required. Pass --war3-dir, set WAR3_DIR, or configure japi.local.json."
            )
        })?;
    if !war3_dir.is_dir() {
        bail!("War3 directory not found: {}", war3_dir.display());
    }

    let proxy_target = war3_dir.join("d3d9.dll");
    let proxy_sidecar = war3_dir.join(".japi_d3d_proxy.sha256");
    let probe_target = war3_dir.join("japi_d3d_visual_probe.bmp");
    let probe_sidecar = war3_dir.join(".japi_d3d_probe.sha256");
    let d3dx_target = war3_dir.join("D3DX9_42.dll");

    match action {
        ProxyAction::Install => {
            assert_war3_stopped()?;
            let proxy_src = env.resolve_proxy(proxy_explicit);
            if !proxy_src.is_file() {
                bail!("D3D proxy binary not found: {}", proxy_src.display());
            }
            assert_d3d_proxy_contract(&proxy_src)?;
            let d3dx_ok = find_d3dx_for_war3(&war3_dir).is_some();
            if !d3dx_ok {
                bail!("D3DX9_42.dll is required in {} or Windows SysWOW64/System32", war3_dir.display());
            }
            install_owned_artifact(&proxy_src, &proxy_target, &proxy_sidecar, "D3D proxy")?;
            println!("D3D proxy status: Installed");
        }
        ProxyAction::Uninstall => {
            assert_war3_stopped()?;
            for (target, sidecar, label) in [
                (&proxy_target, &proxy_sidecar, "D3D proxy"),
                (&probe_target, &probe_sidecar, "D3D visual probe"),
            ] {
                if target.is_file() {
                    let target_hash = sha256_file_upper(target)?;
                    let owned_hash = fs::read_to_string(sidecar).unwrap_or_default().trim().to_ascii_uppercase();
                    if owned_hash != target_hash {
                        bail!(
                            "{} collision: refusing to remove unknown file {}",
                            label,
                            target.display()
                        );
                    }
                    fs::remove_file(target)?;
                    println!("  Removed {}: {}", label, target.display());
                }
                if sidecar.is_file() {
                    let _ = fs::remove_file(sidecar);
                }
            }
            println!("D3D proxy status: Uninstalled");
        }
        ProxyAction::Verify => {
            if !proxy_target.is_file() {
                println!("D3D proxy status: NotInstalled");
                return Ok(());
            }
            let target_hash = sha256_file_upper(&proxy_target)?;
            let owned_hash = fs::read_to_string(&proxy_sidecar)
                .unwrap_or_default()
                .trim()
                .to_ascii_uppercase();
            if owned_hash != target_hash {
                println!(
                    "D3D proxy status: ForeignOrModified (file={} sidecar={})",
                    target_hash,
                    if owned_hash.is_empty() { "missing" } else { &owned_hash }
                );
                bail!("d3d9.dll does not match .japi_d3d_proxy.sha256");
            }
            assert_d3d_proxy_contract(&proxy_target)?;
            if !d3dx_target.is_file() && find_d3dx_for_war3(&war3_dir).is_none() {
                bail!("D3DX9_42.dll missing");
            }
            println!("  D3D proxy: {} ({})", proxy_target.display(), target_hash);
            println!("D3D proxy status: InstalledAndVerified");
        }
    }
    Ok(())
}

pub fn run_deploy(env: &JapiEnv, args: &DeployArgs) -> Result<()> {
    let war3_dir = env
        .resolve_war3_dir(args.war3_dir.as_deref(), true)
        .unwrap();
    let war3_exe = war3_dir.join("war3.exe");
    if !war3_exe.is_file() {
        bail!(
            "War3 not found: {}\n  Pass --war3-dir, set WAR3_DIR, or configure japi.local.json",
            war3_exe.display()
        );
    }

    let log_file = args
        .log_file
        .clone()
        .unwrap_or_else(|| PathBuf::from(DEFAULT_LOG_FILE));
    if !log_file
        .to_string_lossy()
        .to_ascii_lowercase()
        .starts_with(r"c:\programdata\japi_debug")
    {
        println!(
            "  WARNING: --log-file {} is not where the DLL writes (C:\\ProgramData\\japi_debug.txt).",
            log_file.display()
        );
    }

    let needs_proxy = args.pack.interactive_d3d || args.pack.demo || args.pack.test_reboot;
    let proxy_src = env.resolve_proxy(args.pack.proxy_path.as_deref());
    if needs_proxy && !proxy_src.is_file() {
        bail!("D3D proxy not found: {}", proxy_src.display());
    }

    // Step 1: Pack
    println!("[1/4] Packing map...");
    let packed = run_pack(env, &args.pack)?;
    println!("  Map packed OK");

    // Step 2: Deploy
    println!("[2/4] Deploying to War3...");
    let map_name = args
        .map_name
        .clone()
        .or(packed.map_name_hint)
        .unwrap_or_else(|| "output.w3x".to_string());
    let test_map_rel = format!(r"Maps\Test\{}", map_name);
    let dest_map = war3_dir.join(&test_map_rel);
    if let Some(parent) = dest_map.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(&packed.out_file, &dest_map)
        .with_context(|| format!("Failed to copy {} -> {}", packed.out_file.display(), dest_map.display()))?;
    println!("  Deployed to {}", dest_map.display());

    let d3d_target = war3_dir.join("d3d9.dll");
    if needs_proxy {
        assert_d3d_proxy_contract(&proxy_src)?;
        install_owned_artifact(
            &proxy_src,
            &d3d_target,
            &war3_dir.join(".japi_d3d_proxy.sha256"),
            "D3D proxy",
        )?;
        if find_d3dx_for_war3(&war3_dir).is_none() {
            bail!("D3DX9_42.dll is required for D3D text (checked War3Dir, SysWOW64, System32)");
        }
    }

    if args.pack.interactive_d3d {
        let probe_src = env.root.join("build").join("d3d").join("japi_d3d_visual_probe.bmp");
        write_d3d_probe_bmp(&probe_src)?;
        install_owned_artifact(
            &probe_src,
            &war3_dir.join("japi_d3d_visual_probe.bmp"),
            &war3_dir.join(".japi_d3d_probe.sha256"),
            "D3D visual probe",
        )?;
    }

    // Step 3: Launch War3
    println!("[3/4] Launching War3...");
    let kill_file = env.root.join("build").join("war3.kill");
    let _ = fs::remove_file(&kill_file);
    let _ = fs::remove_file(&log_file);
    if log_file.exists() {
        println!(
            "  NOTE: {} is locked by a stale instance; per-pid log will be used by the DLL.",
            log_file.display()
        );
    }

    #[cfg(windows)]
    let _health_guard = if args.pack.demo && !args.play {
        Some(HealthBarsGuard::enable()?)
    } else {
        None
    };

    let mut child = Command::new(&war3_exe)
        .current_dir(&war3_dir)
        .arg("-window")
        .arg("-loadfile")
        .arg(&test_map_rel)
        .spawn()
        .with_context(|| format!("Failed to launch {}", war3_exe.display()))?;

    let pid = child.id();
    if args.play {
        println!(
            "  War3 launched for interactive play (pid {}, map: {})",
            pid, test_map_rel
        );
        println!("  Log: {}", log_file.display());
        return Ok(());
    }

    #[cfg(windows)]
    let _job = if args.job && !args.no_kill {
        use std::os::windows::io::AsRawHandle;
        match KillOnCloseJob::new() {
            Ok(j) => {
                if let Err(e) = j.assign_process(child.as_raw_handle() as _) {
                    println!("  WARNING: cannot put War3 into job ({}); unguarded.", e);
                    None
                } else {
                    println!("  War3 runs in a kill-on-close job.");
                    Some(j)
                }
            }
            Err(e) => {
                println!("  WARNING: cannot create kill-on-close job ({}); unguarded.", e);
                None
            }
        }
    } else {
        None
    };

    let launch_time = SystemTime::now();
    let alt_log = PathBuf::from(format!(r"C:\ProgramData\japi_debug_{}.txt", pid));
    let log_candidates = [alt_log, log_file.clone()];

    if args.pack.interactive_d3d || args.pack.test_reboot {
        let mut loaded = false;
        for _ in 0..40 {
            if child.try_wait()?.is_some() {
                bail!("War3 exited before D3D proxy verification: {}", d3d_target.display());
            }
            #[cfg(windows)]
            if is_module_loaded(pid, &d3d_target) {
                loaded = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        if loaded {
            println!("  Verified loaded module: {}", d3d_target.display());
        } else {
            println!("  WARNING: module enumeration could not prove proxy path; GetD3DStatus provides in-process proof");
        }
    }

    // Step 4: Wait for Results: line
    let timeout_secs = args.timeout_secs.unwrap_or_else(|| {
        if args.pack.interactive_point || args.pack.interactive_ui || args.pack.interactive_d3d {
            3660
        } else if args.pack.test_reboot {
            180
        } else {
            120
        }
    });
    println!("[4/4] Waiting for test results ({}s timeout)...", timeout_secs);

    let re_results = Regex::new(r"Results:\s*(\d+)\s+passed,\s*(\d+)\s+failed,\s*(\d+)\s+total").unwrap();
    let deadline = Instant::now() + Duration::from_secs(timeout_secs);
    let start = Instant::now();
    let mut active_log_path = log_file.clone();
    let mut last_log = String::new();
    let mut stop_reason = "timeout";
    let mut exit_code_str = "unknown".to_string();

    while Instant::now() < deadline {
        for cand in &log_candidates {
            if let Ok(meta) = fs::metadata(cand) {
                if let Ok(mtime) = meta.modified() {
                    let threshold = launch_time.checked_sub(Duration::from_secs(2)).unwrap_or(launch_time);
                    if mtime < threshold {
                        continue;
                    }
                }
                if let Ok(text) = read_log_snapshot(cand) {
                    if re_results.is_match(&text) {
                        active_log_path = cand.clone();
                        last_log = text;
                        stop_reason = "results";
                        break;
                    }
                }
            }
        }
        if stop_reason == "results" {
            break;
        }
        if kill_file.is_file() {
            println!("  build\\war3.kill appeared; closing War3.");
            let _ = fs::remove_file(&kill_file);
            stop_reason = "kill";
            break;
        }
        if let Some(status) = child.try_wait()? {
            exit_code_str = status
                .code()
                .map(|c| c.to_string())
                .unwrap_or_else(|| "unavailable".to_string());
            println!(
                "  War3 exited on its own after {}s (exit code {}) without reaching a Results line",
                start.elapsed().as_secs(),
                exit_code_str
            );
            stop_reason = "exit";
            break;
        }
        std::thread::sleep(Duration::from_secs(2));
    }

    if args.hold {
        let _ = fs::remove_file(&kill_file);
        println!("  Holding War3 session; touch {} to close it", kill_file.display());
        while child.try_wait()?.is_none() && !kill_file.is_file() {
            std::thread::sleep(Duration::from_secs(1));
        }
        let _ = fs::remove_file(&kill_file);
    }

    if !args.no_kill {
        if child.try_wait()?.is_some() || !is_pid_alive(pid) {
            println!(
                "  {}",
                if stop_reason == "exit" {
                    "War3 was already gone; nothing to close"
                } else {
                    "War3 terminated"
                }
            );
        } else if child.kill().is_ok() {
            let _ = child.wait();
            println!("  War3 terminated (creation-handle)");
        } else {
            match stop_war3_pid(pid, Duration::from_secs(20)) {
                Ok(method) => println!("  War3 terminated ({})", method),
                Err(e) => println!("  ERROR: War3 (pid {}) still running: {}", pid, e),
            }
        }
    } else {
        println!("  War3 left running (--no-kill)");
    }

    std::thread::sleep(Duration::from_secs(1));
    if let Ok(text) = read_log_snapshot(&active_log_path) {
        if !text.is_empty() {
            last_log = text;
        }
    }

    if !last_log.is_empty() {
        let lines: Vec<&str> = last_log.lines().collect();
        let start_idx = lines.len().saturating_sub(35);
        println!();
        for l in &lines[start_idx..] {
            println!("{}", l);
        }
        println!();
    } else {
        println!("  WARNING: No log content read (reason: {})", stop_reason);
    }

    if let Some(caps) = re_results.captures_iter(&last_log).last() {
        let failed: usize = caps[2].parse().unwrap_or(0);
        let total: usize = caps[3].parse().unwrap_or(0);
        if failed > 0 {
            bail!("FAILED: {} check(s) failed out of {}", failed, total);
        }
    }

    if stop_reason == "exit" {
        bail!(
            "FAILED: War3 exited before reporting a Results line (exit code {})",
            exit_code_str
        );
    }

    Ok(())
}

fn read_log_snapshot(path: &Path) -> Result<String> {
    let bytes = fs::read(path)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn assert_war3_stopped() -> Result<()> {
    let pids = find_war3_pids();
    if !pids.is_empty() {
        bail!(
            "war3.exe is currently running (PID: {:?}). Run `japi kill` first.",
            pids
        );
    }
    Ok(())
}

fn find_d3dx_for_war3(war3_dir: &Path) -> Option<PathBuf> {
    let windir = PathBuf::from(std::env::var("WINDIR").unwrap_or_else(|_| r"C:\Windows".to_string()));
    let cands = [
        war3_dir.join("D3DX9_42.dll"),
        windir.join("SysWOW64").join("D3DX9_42.dll"),
        windir.join("System32").join("D3DX9_42.dll"),
    ];
    cands.into_iter().find(|p| p.is_file())
}

fn install_owned_artifact(src: &Path, dst: &Path, sidecar: &Path, label: &str) -> Result<()> {
    let src_hash = sha256_file_upper(src)?;
    if dst.is_file() {
        let dst_hash = sha256_file_upper(dst)?;
        if dst_hash != src_hash {
            let owned = fs::read_to_string(sidecar)
                .unwrap_or_default()
                .trim()
                .to_ascii_uppercase();
            if owned != dst_hash {
                bail!(
                    "{} collision: refusing to overwrite unknown file {}\n  source={}\n  target={}",
                    label,
                    dst.display(),
                    src_hash,
                    dst_hash
                );
            }
        }
    }
    fs::copy(src, dst).with_context(|| format!("Failed to copy {} -> {}", src.display(), dst.display()))?;
    fs::write(sidecar, src_hash.as_bytes())?;
    println!("  {}: {} ({})", label, dst.display(), src_hash);
    Ok(())
}

fn write_d3d_probe_bmp(path: &Path) -> Result<()> {
    let w: u32 = 128;
    let h: u32 = 128;
    let stride = (w * 3) as usize;
    let pixel_bytes = stride * h as usize;
    let total_len = 54 + pixel_bytes;
    let mut bytes = vec![0u8; total_len];
    bytes[0] = b'B';
    bytes[1] = b'M';
    bytes[2..6].copy_from_slice(&(total_len as u32).to_le_bytes());
    bytes[10..14].copy_from_slice(&54u32.to_le_bytes());
    bytes[14..18].copy_from_slice(&40u32.to_le_bytes());
    bytes[18..22].copy_from_slice(&w.to_le_bytes());
    bytes[22..26].copy_from_slice(&h.to_le_bytes());
    bytes[26..28].copy_from_slice(&1u16.to_le_bytes());
    bytes[28..30].copy_from_slice(&24u16.to_le_bytes());
    bytes[34..38].copy_from_slice(&(pixel_bytes as u32).to_le_bytes());

    for y in 0..h {
        for x in 0..w {
            let border = x < 4 || y < 4 || x >= w - 4 || y >= h - 4;
            let even = ((x / 16) + (y / 16)) % 2 == 0;
            let (r, g, b) = if border {
                (255, 255, 0)
            } else if even {
                (255, 0, 255)
            } else {
                (0, 255, 255)
            };
            let off = 54 + (y as usize) * stride + (x as usize) * 3;
            bytes[off] = b;
            bytes[off + 1] = g;
            bytes[off + 2] = r;
        }
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, bytes)?;
    Ok(())
}

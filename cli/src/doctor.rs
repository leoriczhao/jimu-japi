use crate::config::{JapiEnv, LayoutKind};
use anyhow::{bail, Result};
use std::path::Path;

pub fn run_doctor(env: &JapiEnv, explicit_war3: Option<&Path>) -> Result<()> {
    let layout_str = match env.layout {
        LayoutKind::SdkBundle => "SDK bundle (bin/templates/vendor)",
        LayoutKind::SourceRepo => "Source repository (src/reference/tools)",
    };
    let war3_dir = env.resolve_war3_dir(explicit_war3, true).unwrap();
    let war3_exe = war3_dir.join("war3.exe");
    let dll = env.resolve_dll(None);
    let proxy = env.resolve_proxy(None);
    let d3dx = env.resolve_d3dx(None);
    let cb = env.resolve_callback();
    let pjass = env.resolve_pjass();
    let w2l = env.resolve_w3x2lni(None);
    let w2l_lua = w2l.join("bin").join("w3x2lni-lua.exe");
    let base_map = env.resolve_base_map(None);
    let manifest = env.resolve_natives_manifest();
    let ex_cpp = env
        .root
        .join("src")
        .join("src")
        .join("extensions")
        .join("ex_natives")
        .join("Initialize.cpp");

    println!();
    println!("=== map-inject doctor ===");
    println!("  Root      : {}", env.root.display());
    println!("  Layout    : {}", layout_str);
    match &env.local_config_path {
        Some(p) => println!("  Config    : {}", p.display()),
        None => println!("  Config    : (none - create japi.local.json or set WAR3_DIR)"),
    }
    println!();

    let mut failures = 0usize;
    let mut check = |label: &str, ok: bool, detail: String, required: bool| {
        if ok {
            println!("  [OK]   {:<16} {}", label, detail);
        } else if required {
            failures += 1;
            println!("  [MISS] {:<16} {}", label, detail);
        } else {
            println!("  [WARN] {:<16} {}", label, detail);
        }
    };

    check("War3 1.27a", war3_exe.is_file(), war3_dir.display().to_string(), false);
    check("yd_japi.dll", dll.is_file(), dll.display().to_string(), true);
    check("newD3d9.dll", proxy.is_file(), proxy.display().to_string(), false);
    check(
        "D3DX9_42.dll",
        d3dx.is_file(),
        if d3dx.is_file() {
            d3dx.display().to_string()
        } else {
            "embedded in yd_japi.dll (.rsrc)".to_string()
        },
        false,
    );
    check("callback", cb.is_file(), cb.display().to_string(), true);
    check("pjass.exe", pjass.is_file(), pjass.display().to_string(), true);
    check("w3x2lni", w2l_lua.is_file(), w2l.display().to_string(), true);
    check("base-map", base_map.exists(), base_map.display().to_string(), true);

    let (has_wrappers, wrapper_src) = if let Some(ref m) = manifest {
        (true, m.display().to_string())
    } else if ex_cpp.is_file() {
        (true, "src/src/* registries".to_string())
    } else {
        (false, "missing".to_string())
    };
    check("wrapper source", has_wrappers, wrapper_src, false);

    if war3_exe.is_file() {
        let installed = war3_dir.join("d3d9.dll");
        let sidecar = war3_dir.join(".japi_d3d_proxy.sha256");
        let state = if installed.is_file() && sidecar.is_file() {
            "installed (sidecar present)".to_string()
        } else if installed.is_file() {
            "d3d9.dll present (no sidecar)".to_string()
        } else {
            "not installed yet (auto-staged on first map launch, or run `japi proxy --install`)".to_string()
        };
        check("D3D proxy", installed.is_file(), state, false);
    }

    println!();
    if failures > 0 {
        bail!("Doctor found {} missing required component(s).", failures);
    }
    println!("All required packaging components are ready.");
    Ok(())
}

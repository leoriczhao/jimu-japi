use crate::config::{load_project_config, resolve_abs, JapiEnv};
use crate::jass_patcher::{patch_war3map_j, run_pjass_check, JassPatchOptions};
use crate::lua_bundler::{bundle_lua_dir_with_std, load_engine_modules, BundleFlags};
use crate::we_compat;
use anyhow::{bail, Context, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, Default)]
pub struct PackArgs {
    pub map_dir: Option<PathBuf>,
    pub base_map: Option<PathBuf>,
    pub out_file: Option<PathBuf>,
    pub work_dir: Option<PathBuf>,
    pub dll_path: Option<PathBuf>,
    #[allow(dead_code)]
    pub proxy_path: Option<PathBuf>,
    #[allow(dead_code)]
    pub d3dx_path: Option<PathBuf>,
    pub w3x2lni: Option<PathBuf>,
    pub manifest: Option<PathBuf>,
    pub with_jass_wrappers: Option<bool>,
    pub with_get_func_addr: Option<bool>,
    pub with_debugger: Option<bool>,
    pub strict_requires: Option<bool>,
    pub no_array_prealloc: Option<bool>,
    pub skip_jass_check: Option<bool>,
    pub require_report: bool,
    pub skip_repack: bool,
    // Internal regression flags (used by tools/dev suites)
    pub interactive_point: bool,
    pub interactive_ui: bool,
    pub interactive_d3d: bool,
    pub demo: bool,
    pub test_reboot: bool,
}

#[derive(Debug, Clone)]
pub struct PackOutcome {
    pub out_file: PathBuf,
    pub map_name_hint: Option<String>,
}

pub fn run_pack(env: &JapiEnv, args: &PackArgs) -> Result<PackOutcome> {
    let map_dir = match &args.map_dir {
        Some(p) => resolve_abs(p, None),
        None => env.root.join("map"),
    };
    if !map_dir.is_dir() {
        bail!("Map dir not found: {}", map_dir.display());
    }
    let main_lua = map_dir.join("war3map.lua");
    if !main_lua.is_file() {
        bail!("war3map.lua not found: {}", main_lua.display());
    }

    let project_cfg = load_project_config(&map_dir)?;

    let base_map_explicit = args
        .base_map
        .as_deref()
        .or_else(|| project_cfg.as_ref().and_then(|c| c.base_map.as_deref()));
    let base_map = env.resolve_base_map(base_map_explicit);

    let out_file = args
        .out_file
        .as_deref()
        .map(|p| resolve_abs(p, None))
        .or_else(|| project_cfg.as_ref().and_then(|c| c.out_file.clone()))
        .unwrap_or_else(|| env.root.join("build").join("output.w3x"));

    let work_dir = args
        .work_dir
        .as_deref()
        .map(|p| resolve_abs(p, None))
        .or_else(|| project_cfg.as_ref().and_then(|c| c.work_dir.clone()))
        .unwrap_or_else(|| env.root.join("build").join("work"));

    let with_jass_wrappers = args
        .with_jass_wrappers
        .or_else(|| project_cfg.as_ref().and_then(|c| c.raw.with_jass_wrappers))
        .unwrap_or(false);
    let with_get_func_addr = args
        .with_get_func_addr
        .or_else(|| project_cfg.as_ref().and_then(|c| c.raw.with_get_func_addr))
        .unwrap_or(false);
    let with_debugger = args
        .with_debugger
        .or_else(|| project_cfg.as_ref().and_then(|c| c.raw.with_debugger))
        .unwrap_or(false);
    let strict_requires = args
        .strict_requires
        .or_else(|| project_cfg.as_ref().and_then(|c| c.raw.strict_requires))
        .unwrap_or(false);
    let no_array_prealloc = args
        .no_array_prealloc
        .or_else(|| project_cfg.as_ref().and_then(|c| c.raw.no_array_prealloc))
        .unwrap_or(false);
    let skip_jass_check = args
        .skip_jass_check
        .or_else(|| project_cfg.as_ref().and_then(|c| c.raw.skip_jass_check))
        .unwrap_or(false);

    let dll_path = env.resolve_dll(args.dll_path.as_deref());
    let w3x2lni = env.resolve_w3x2lni(args.w3x2lni.as_deref());
    let lua_exe = w3x2lni.join("bin").join("w3x2lni-lua.exe");
    let cb_src = env.resolve_callback();
    let pjass_exe = env.resolve_pjass();

    if !base_map.exists() {
        bail!("Base map or source directory not found: {}", base_map.display());
    }
    if !dll_path.is_file() {
        bail!("DLL not found: {}\n  Build the engine DLLs first or pass --dll-path.", dll_path.display());
    }
    if !lua_exe.is_file() {
        bail!("w3x2lni not found: {}\n  Pass --w3x2lni or run `mise run setup`.", lua_exe.display());
    }
    if !cb_src.is_file() {
        bail!("callback not found: {}", cb_src.display());
    }

    if let Some(ref cfg) = project_cfg {
        println!("  Project:  {}", cfg.manifest_path.display());
    }
    println!("  Base map: {}", base_map.display());
    println!("  Map dir:  {}", map_dir.display());
    println!("  DLL:      {} (single-TGA payload: embedded D3D proxy + D3DX)", dll_path.display());
    println!("  Output:   {}", out_file.display());

    // 1. Clean and import base map
    if work_dir.exists() {
        fs::remove_dir_all(&work_dir)
            .with_context(|| format!("Failed to clean work dir {}", work_dir.display()))?;
    }
    fs::create_dir_all(&work_dir)?;
    if base_map.is_dir() {
        println!("  [1/5] Copy base-map source directory");
        copy_dir_recursive(&base_map, &work_dir)?;
    } else {
        println!("  [1/5] Unpack base map");
        run_w3x2lni(&w3x2lni, "unpack", &base_map, &work_dir)?;
    }

    // 1b. Compile war3map.w3u.ini if present
    let unit_ini = work_dir.join("war3map.w3u.ini");
    if unit_ini.is_file() {
        println!("  [1b] Compile unit object data");
        let obj_map = PathBuf::from(format!("{}-object.w3x", work_dir.display()));
        let obj_dir = PathBuf::from(format!("{}-object", work_dir.display()));
        let _ = fs::remove_file(&obj_map);
        let _ = fs::remove_dir_all(&obj_dir);
        run_w3x2lni(&w3x2lni, "obj", &work_dir, &obj_map)?;
        fs::create_dir_all(&obj_dir)?;
        run_w3x2lni(&w3x2lni, "unpack", &obj_map, &obj_dir)?;
        fs::remove_dir_all(&work_dir)?;
        fs::rename(&obj_dir, &work_dir)?;
        let _ = fs::remove_file(&obj_map);
    }

    // 1c. Compile project objects.lua if present
    let objects_lua = map_dir.join("objects.lua");
    if objects_lua.is_file() {
        println!("  [1c] Compile code-defined unit/ability data");
        let compiler = env.resolve_object_compiler();
        if !compiler.is_file() {
            bail!("Object compiler missing: {}", compiler.display());
        }
        let data_dir = w3x2lni.join("data").join("enUS-1.27.1");
        let status = Command::new(&lua_exe)
            .arg("-E")
            .arg(&compiler)
            .arg(&objects_lua)
            .arg(&work_dir)
            .arg(&data_dir)
            .status()
            .with_context(|| format!("Failed to run object compiler {}", compiler.display()))?;
        if !status.success() {
            bail!("Object declaration compilation failed");
        }
    }

    let jfile = work_dir.join("war3map.j");
    if !jfile.is_file() {
        fs::write(&jfile, b"// empty war3map.j\r\n")?;
        println!("  No war3map.j found, created empty");
    }

    // 2. Bundle Lua sources directly into script\war3map.lua
    println!("  [2/5] Bundle Lua");
    let script_dir = work_dir.join("script");
    fs::create_dir_all(&script_dir)?;
    let stale_root_lua = work_dir.join("war3map.lua");
    if stale_root_lua.is_file() {
        let _ = fs::remove_file(&stale_root_lua);
    }

    let engine_modules = load_engine_modules(&env.root);
    let flags = BundleFlags {
        interactive_point: args.interactive_point,
        interactive_ui: args.interactive_ui,
        interactive_d3d: args.interactive_d3d,
        demo: args.demo,
        test_reboot: args.test_reboot,
    };
    let std_dir = env.root.join("std");
    let std_opt = if std_dir.is_dir() {
        Some(std_dir.as_path())
    } else {
        None
    };
    let report = bundle_lua_dir_with_std(
        &map_dir,
        std_opt,
        "war3map",
        &engine_modules,
        &flags,
        args.require_report,
        strict_requires,
    )?;
    fs::write(script_dir.join("war3map.lua"), report.output_code.as_bytes())?;
    println!(
        "  Bundled {} Lua files into war3map.lua ({} preloaded module(s))",
        report.module_count, report.reachable_count
    );

    if args.test_reboot {
        println!("  [2b] Bundle reboot child script");
        let child = bundle_lua_dir_with_std(
            &map_dir,
            std_opt,
            "tests.reboot_child",
            &engine_modules,
            &BundleFlags::default(),
            false,
            false,
        )?;
        fs::write(script_dir.join("reboot_child.lua"), child.output_code.as_bytes())?;
    }

    // 3. Patch war3map.j + pjass syntax check
    println!("  [3/5] Patching war3map.j");
    let base_disp = base_map.display().to_string();
    let patch_opts = JassPatchOptions {
        root: &env.root,
        base_map_display: &base_disp,
        no_array_prealloc,
        with_jass_wrappers,
        with_get_func_addr,
        test_reboot: args.test_reboot,
        explicit_manifest: args.manifest.as_deref(),
    };
    patch_war3map_j(&jfile, &patch_opts)?;
    if !skip_jass_check {
        run_pjass_check(&pjass_exe, &w3x2lni, &jfile)?;
    }

    // 4. Inject single-TGA japi.tga + callback + WE trigger/import metadata
    // Mirrors builtin-japi: newD3d9.dll + D3DX9_42.dll are embedded in japi.tga's
    // PE .rsrc section, and all injected files are registered in war3map.imp (0x0D)
    // so World Editor / YDWE / KKWE preserves them when re-saving the map.
    println!("  [4/5] Inject single-TGA japi.tga + callback + war3map.imp");
    fs::copy(&dll_path, work_dir.join("japi.tga"))?;
    fs::copy(&cb_src, work_dir.join("callback"))?;
    // Remove legacy split-TGA files if repacking an older map
    for legacy in ["d3d9.tga", "d3d9.tga.sha256", "d3dx9_42.tga"] {
        let p = work_dir.join(legacy);
        if p.is_file() {
            let _ = fs::remove_file(p);
        }
    }

    let mut needed: Vec<String> = vec![
        "callback".into(),
        "japi.tga".into(),
        r"script\war3map.lua".into(),
    ];
    if args.test_reboot {
        needed.push(r"script\reboot_child.lua".into());
    }
    if args.interactive_d3d {
        needed.extend(write_interactive_d3d_fixtures(&work_dir)?);
    }

    if with_debugger {
        println!("  [4b] Inject debugger resources");
        let dbg_src = env.root.join("tools").join("debugger");
        let dbg_dst = work_dir.join("debugger");
        if !dbg_src.join("luadebug.dll").is_file() {
            bail!("debugger payload not found: {}", dbg_src.display());
        }
        fs::create_dir_all(&dbg_dst)?;
        copy_dir_recursive(&dbg_src.join("script"), &dbg_dst.join("script"))?;
        fs::copy(dbg_src.join("luadebug.dll"), dbg_dst.join("luadebug.dll"))?;
        fs::copy(dbg_src.join("LICENSE.lua-debug"), dbg_dst.join("LICENSE.lua-debug"))?;

        let mut dbg_entries = vec!["luadebug.dll".to_string(), "LICENSE.lua-debug".to_string()];
        collect_rel_files(&dbg_dst.join("script"), &dbg_dst, &mut dbg_entries)?;
        fs::write(dbg_dst.join("manifest.txt"), dbg_entries.join("\r\n").as_bytes())?;
        needed.push(r"debugger\manifest.txt".into());
        for e in dbg_entries {
            needed.push(format!(r"debugger\{}", e));
        }
    }

    let imp_added = we_compat::update_war3map_imp(&work_dir.join("war3map.imp"), &needed)?;
    println!("  war3map.imp: registered {} new custom-path import(s)", imp_added);

    if we_compat::inject_wtg_wct_bootstrap(&work_dir)? {
        println!("  war3map.wtg/wct: injected JapiBootstrap trigger (survives WE/YDWE/KKWE save)");
    }

    let mut listfile_needed = needed.clone();
    listfile_needed.push("war3map.imp".into());
    if work_dir.join("war3map.wct").is_file() {
        listfile_needed.push("war3map.wct".into());
    }
    update_listfile(&work_dir.join("(listfile)"), &listfile_needed)?;

    // 5. Repack
    if args.skip_repack {
        println!("  [5/5] Repack skipped (--skip-repack); no .w3x written");
        println!("  Work dir: {}", work_dir.display());
    } else {
        println!("  [5/5] Repack");
        if let Some(parent) = out_file.parent() {
            fs::create_dir_all(parent)?;
        }
        run_w3x2lni(&w3x2lni, "pack", &work_dir, &out_file)?;
        println!("  Done -> {}", out_file.display());
    }

    let map_name_hint = project_cfg
        .as_ref()
        .and_then(|c| c.raw.map_name.clone().or_else(|| c.raw.name.as_ref().map(|n| format!("{}.w3x", n))));

    Ok(PackOutcome {
        out_file,
        map_name_hint,
    })
}

pub fn run_w3x2lni(w3x2lni_dir: &Path, mode: &str, source: &Path, target: &Path) -> Result<()> {
    let bin_dir = w3x2lni_dir.join("bin");
    let script_dir = w3x2lni_dir.join("script");
    let lua_exe = bin_dir.join("w3x2lni-lua.exe");
    let cpath = bin_dir.join("?.dll").to_string_lossy().into_owned();
    let ppath = format!(
        "{};{}",
        script_dir.join("?.lua").to_string_lossy(),
        script_dir.join(r"?\init.lua").to_string_lossy()
    );
    let init_expr = format!(
        "_W2L_MODE='CLI';package.cpath=[[{}]];package.path=[[{}]]",
        cpath, ppath
    );
    let old_path = std::env::var("PATH").unwrap_or_default();
    let new_path = format!("{};{}", bin_dir.display(), old_path);

    let output = Command::new(&lua_exe)
        .current_dir(&script_dir)
        .env("PATH", new_path)
        .arg("-E")
        .arg("-e")
        .arg(init_expr)
        .arg("main.lua")
        .arg(mode)
        .arg(source)
        .arg(target)
        .output()
        .with_context(|| format!("Failed to invoke w3x2lni ({})", mode))?;
    if !output.status.success() {
        eprintln!("{}", String::from_utf8_lossy(&output.stdout));
        eprintln!("{}", String::from_utf8_lossy(&output.stderr));
        bail!("w3x2lni {} failed", mode);
    }
    Ok(())
}

pub fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src).with_context(|| format!("Failed to read {}", src.display()))? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let to = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_recursive(&entry.path(), &to)?;
        } else {
            fs::copy(entry.path(), to)?;
        }
    }
    Ok(())
}

fn collect_rel_files(dir: &Path, base: &Path, out: &mut Vec<String>) -> Result<()> {
    let mut entries: Vec<_> = fs::read_dir(dir)?.collect::<std::io::Result<_>>()?;
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let p = entry.path();
        if p.is_dir() {
            collect_rel_files(&p, base, out)?;
        } else {
            let rel = p.strip_prefix(base)?.to_string_lossy().replace('/', "\\");
            out.push(rel);
        }
    }
    Ok(())
}

fn update_listfile(listfile: &Path, needed: &[String]) -> Result<()> {
    let mut existing = if listfile.is_file() {
        fs::read_to_string(listfile).unwrap_or_default()
    } else {
        String::new()
    };
    let existing_lower: std::collections::HashSet<String> = existing
        .lines()
        .map(|l| l.trim().to_ascii_lowercase())
        .filter(|l| !l.is_empty())
        .collect();

    let mut to_add = Vec::new();
    for item in needed {
        if !existing_lower.contains(&item.to_ascii_lowercase()) {
            to_add.push(item.as_str());
        }
    }
    if !to_add.is_empty() {
        if !existing.is_empty() && !existing.ends_with('\n') {
            existing.push_str("\r\n");
        }
        for item in to_add {
            existing.push_str(item);
            existing.push_str("\r\n");
        }
        fs::write(listfile, existing.as_bytes())?;
    }
    Ok(())
}

// ── Internal regression D3D asset fixtures (--interactive-d3d) ───────────────

fn write_interactive_d3d_fixtures(work_dir: &Path) -> Result<Vec<String>> {
    // 16x16 valid PNG
    const PROBE_PNG: &[u8] = &[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
        0xF3, 0xFF, 0x61, 0x00, 0x00, 0x00, 0x01, 0x73, 0x52, 0x47, 0x42, 0x00, 0xAE, 0xCE, 0x1C,
        0xE9, 0x00, 0x00, 0x00, 0x04, 0x67, 0x41, 0x4D, 0x41, 0x00, 0x00, 0xB1, 0x8F, 0x0B, 0xFC,
        0x61, 0x05, 0x00, 0x00, 0x00, 0x09, 0x70, 0x48, 0x59, 0x73, 0x00, 0x00, 0x0E, 0xC3, 0x00,
        0x00, 0x0E, 0xC3, 0x01, 0xC7, 0x6F, 0xA8, 0x64, 0x00, 0x00, 0x00, 0x39, 0x49, 0x44, 0x41,
        0x54, 0x38, 0x4F, 0x63, 0x90, 0xDB, 0xF2, 0xFF, 0x3F, 0x32, 0xFE, 0x1F, 0x20, 0x87, 0x82,
        0x09, 0xC9, 0x33, 0x10, 0x52, 0x40, 0x48, 0x7E, 0x10, 0x18, 0x80, 0x2E, 0x40, 0x48, 0x03,
        0xBA, 0xFC, 0x70, 0x30, 0x00, 0x5D, 0x80, 0x90, 0x06, 0x74, 0xF9, 0xE1, 0x60, 0x00, 0xBA,
        0x00, 0x21, 0x0D, 0xE8, 0xF2, 0xC3, 0xC0, 0x00, 0x00, 0x94, 0xC0, 0x9E, 0x1F, 0x8D, 0xF2,
        0x9B, 0x65, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    fs::write(work_dir.join("d3d-sdk-probe.png"), PROBE_PNG)?;
    fs::write(work_dir.join("d3d-sdk-corrupt.png"), b"not-an-image")?;
    write_blp2_fixture(&work_dir.join("d3d-sdk-blp2-raw.blp"), "raw", 48, 32)?;
    write_blp2_fixture(&work_dir.join("d3d-sdk-blp2-palette.blp"), "palette", 64, 48)?;
    write_blp2_fixture(&work_dir.join("d3d-sdk-blp2-dxt1.blp"), "dxt1", 64, 32)?;
    write_blp2_fixture(&work_dir.join("d3d-sdk-blp2-bad.blp"), "bad", 16, 16)?;
    Ok(vec![
        "d3d-sdk-probe.png".into(),
        "d3d-sdk-corrupt.png".into(),
        "d3d-sdk-blp2-raw.blp".into(),
        "d3d-sdk-blp2-palette.blp".into(),
        "d3d-sdk-blp2-dxt1.blp".into(),
        "d3d-sdk-blp2-bad.blp".into(),
    ])
}

fn write_blp2_fixture(path: &Path, kind: &str, width: u32, height: u32) -> Result<()> {
    let pixels = (width * height) as usize;
    let mut payload: Vec<u8> = Vec::new();
    let (encoding, alpha_depth, palette_bytes, data_size): (u8, u8, u32, u32) = match kind {
        "raw" => {
            for y in 0..height {
                for x in 0..width {
                    let even = ((x / 8) + (y / 8)) % 2 == 0;
                    if even {
                        payload.extend_from_slice(&[40, 40, 220, 255]);
                    } else {
                        payload.extend_from_slice(&[220, 40, 40, 255]);
                    }
                }
            }
            (3, 0, 0, payload.len() as u32)
        }
        "palette" => {
            for i in 0..256u32 {
                payload.extend_from_slice(&[i as u8, (255 - i) as u8, ((i * 7) % 256) as u8, 255]);
            }
            for y in 0..height {
                for x in 0..width {
                    let even = ((x / 8) + (y / 8)) % 2 == 0;
                    payload.push(if even { 17 } else { 203 });
                }
            }
            payload.resize(payload.len() + pixels, 255);
            (1, 8, 1024, (pixels * 2) as u32)
        }
        "dxt1" => {
            let blocks = width.div_ceil(4) * height.div_ceil(4);
            for _ in 0..blocks {
                payload.extend_from_slice(&[0xFF, 0xFF, 0, 0, 0, 0, 0, 0]);
            }
            (2, 0, 0, payload.len() as u32)
        }
        _ => {
            payload.resize(pixels * 4, 0);
            (4, 0, 0, payload.len() as u32)
        }
    };

    let data_offset = 148 + palette_bytes;
    let mut out = Vec::with_capacity(148 + payload.len());
    out.extend_from_slice(b"BLP2");
    out.extend_from_slice(&0u32.to_le_bytes());
    out.push(encoding);
    out.push(alpha_depth);
    out.push(0);
    out.push(0);
    out.extend_from_slice(&width.to_le_bytes());
    out.extend_from_slice(&height.to_le_bytes());
    for i in 0..16 {
        out.extend_from_slice(&(if i == 0 { data_offset } else { 0 }).to_le_bytes());
    }
    for i in 0..16 {
        out.extend_from_slice(&(if i == 0 { data_size } else { 0 }).to_le_bytes());
    }
    out.extend_from_slice(&payload);
    fs::write(path, out)?;
    Ok(())
}

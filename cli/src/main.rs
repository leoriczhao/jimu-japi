mod config;
mod deploy;
mod doctor;
mod jass_patcher;
mod lua_bundler;
mod pack;
mod scaffold;
mod war3;
mod we_compat;
mod wrappers;

use anyhow::Result;
use clap::{Args, Parser, Subcommand};
use config::JapiEnv;
use deploy::{run_deploy, run_proxy, DeployArgs, ProxyAction};
use pack::{run_pack, PackArgs};
use std::path::PathBuf;
use std::time::Duration;

#[derive(Parser)]
#[command(
    name = "japi",
    version,
    about = "WAR3 1.27a map-inject SDK CLI (new, check, build, run, test, proxy, doctor, kill)"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Create a new map project scaffold (with japi.json + base-map)
    New {
        /// Project name (A-Z, a-z, 0-9, '_' and '-' only)
        name: String,
        /// Parent directory that receives the project directory
        #[arg(short, long, default_value = ".")]
        path: PathBuf,
        /// Custom base map directory or .w3m/.w3x file
        #[arg(short, long)]
        base: Option<PathBuf>,
        /// Overwrite scaffold files if target directory is non-empty
        #[arg(short, long)]
        force: bool,
    },

    /// Validate Lua requires, objects.lua and JASS syntax without writing .w3x
    Check {
        /// Project directory (defaults to map/)
        project: Option<PathBuf>,
        #[command(flatten)]
        opts: CommonBuildFlags,
    },

    /// Pack a map project into a playable .w3x archive (reads japi.json)
    Build {
        /// Project directory (defaults to map/)
        project: Option<PathBuf>,
        #[command(flatten)]
        opts: CommonBuildFlags,
        /// Stop after patching work dir without repacking .w3x
        #[arg(long)]
        skip_repack: bool,
    },

    /// Pack, deploy to Maps\Test and launch War3 for interactive play
    Run {
        /// Project directory (defaults to map/)
        project: Option<PathBuf>,
        /// War3 1.27a installation directory
        #[arg(long)]
        war3_dir: Option<PathBuf>,
        /// Deployed map filename under Maps\Test\
        #[arg(long)]
        map_name: Option<String>,
        #[command(flatten)]
        opts: CommonBuildFlags,
    },

    /// Pack, deploy, launch War3, wait for Results: line, and exit with verdict
    Test {
        /// Project directory (defaults to map/)
        project: Option<PathBuf>,
        /// War3 1.27a installation directory
        #[arg(long)]
        war3_dir: Option<PathBuf>,
        /// Deployed map filename under Maps\Test\
        #[arg(long)]
        map_name: Option<String>,
        /// Log file to poll (DLL always writes C:\ProgramData\japi_debug.txt)
        #[arg(long)]
        log_file: Option<PathBuf>,
        /// Timeout in seconds
        #[arg(long)]
        timeout: Option<u64>,
        /// Leave War3 running after results
        #[arg(long)]
        no_kill: bool,
        /// Keep session open until build\war3.kill appears
        #[arg(long)]
        hold: bool,
        /// Put War3 into a Windows kill-on-close Job Object
        #[arg(long)]
        job: bool,
        #[command(flatten)]
        opts: CommonBuildFlags,
    },

    /// Manage d3d9.dll proxy installation in the War3 directory
    Proxy {
        #[arg(long)]
        install: bool,
        #[arg(long)]
        verify: bool,
        #[arg(long)]
        uninstall: bool,
        #[arg(long)]
        war3_dir: Option<PathBuf>,
        #[arg(long)]
        proxy_path: Option<PathBuf>,
    },

    /// Check SDK binaries, tools, base map and War3 directory health
    Doctor {
        #[arg(long)]
        war3_dir: Option<PathBuf>,
    },

    /// Terminate any running or orphaned war3.exe (repairs 1.27a deny-only DACL)
    Kill {
        /// Optional specific PID to terminate
        #[arg(long)]
        pid: Option<u32>,
        /// Only report running war3.exe PIDs without terminating
        #[arg(long)]
        dry_run: bool,
    },

    /// Export natives-manifest.json from C++ registries (used when building SDK bundles)
    #[command(hide = true)]
    EmitManifest {
        /// Output JSON path
        #[arg(short, long)]
        out: PathBuf,
        /// Source repository root (optional)
        #[arg(long)]
        root: Option<PathBuf>,
    },
}

#[derive(Args, Debug, Clone, Default)]
struct CommonBuildFlags {
    #[arg(long)]
    base_map: Option<PathBuf>,
    #[arg(short, long)]
    out_file: Option<PathBuf>,
    #[arg(long)]
    work_dir: Option<PathBuf>,
    #[arg(long)]
    dll_path: Option<PathBuf>,
    #[arg(long)]
    proxy_path: Option<PathBuf>,
    #[arg(long)]
    d3dx_path: Option<PathBuf>,
    #[arg(long)]
    w3x2lni: Option<PathBuf>,
    #[arg(long)]
    manifest: Option<PathBuf>,
    #[arg(long)]
    with_jass_wrappers: bool,
    #[arg(long)]
    with_get_func_addr: bool,
    #[arg(long)]
    with_debugger: bool,
    #[arg(long)]
    require_report: bool,
    #[arg(long)]
    strict_requires: bool,
    #[arg(long)]
    no_array_prealloc: bool,
    #[arg(long)]
    skip_jass_check: bool,
    // Hidden internal regression flags for tools/dev suites
    #[arg(long, hide = true)]
    interactive_point: bool,
    #[arg(long, hide = true)]
    interactive_ui: bool,
    #[arg(long, hide = true)]
    interactive_d3d: bool,
    #[arg(long, hide = true)]
    demo: bool,
    #[arg(long, hide = true)]
    test_reboot: bool,
}

fn to_pack_args(project: Option<PathBuf>, f: CommonBuildFlags, skip_repack: bool, force_report: bool) -> PackArgs {
    PackArgs {
        map_dir: project,
        base_map: f.base_map,
        out_file: f.out_file,
        work_dir: f.work_dir,
        dll_path: f.dll_path,
        proxy_path: f.proxy_path,
        d3dx_path: f.d3dx_path,
        w3x2lni: f.w3x2lni,
        manifest: f.manifest,
        with_jass_wrappers: if f.with_jass_wrappers { Some(true) } else { None },
        with_get_func_addr: if f.with_get_func_addr { Some(true) } else { None },
        with_debugger: if f.with_debugger { Some(true) } else { None },
        strict_requires: if f.strict_requires { Some(true) } else { None },
        no_array_prealloc: if f.no_array_prealloc { Some(true) } else { None },
        skip_jass_check: if f.skip_jass_check { Some(true) } else { None },
        require_report: force_report || f.require_report,
        skip_repack,
        interactive_point: f.interactive_point,
        interactive_ui: f.interactive_ui,
        interactive_d3d: f.interactive_d3d,
        demo: f.demo,
        test_reboot: f.test_reboot,
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let env = JapiEnv::discover()?;

    match cli.command {
        Commands::New {
            name,
            path,
            base,
            force,
        } => scaffold::run_new_project(&env, &name, &path, base.as_deref(), force),

        Commands::Check { project, opts } => {
            let scratch = if opts.work_dir.is_none() {
                Some(env.root.join("build").join(format!("check-{}", std::process::id())))
            } else {
                None
            };
            let mut pack_args = to_pack_args(project, opts, true, true);
            if let Some(ref s) = scratch {
                pack_args.work_dir = Some(s.clone());
            }
            let res = run_pack(&env, &pack_args);
            if let Some(ref s) = scratch {
                let _ = std::fs::remove_dir_all(s);
            }
            res.map(|_| ())
        }

        Commands::Build {
            project,
            opts,
            skip_repack,
        } => {
            let pack_args = to_pack_args(project, opts, skip_repack, false);
            run_pack(&env, &pack_args).map(|_| ())
        }

        Commands::Run {
            project,
            war3_dir,
            map_name,
            opts,
        } => {
            let pack = to_pack_args(project, opts, false, false);
            let dargs = DeployArgs {
                pack,
                war3_dir,
                map_name,
                log_file: None,
                timeout_secs: None,
                play: true,
                no_kill: true,
                hold: false,
                job: false,
            };
            run_deploy(&env, &dargs)
        }

        Commands::Test {
            project,
            war3_dir,
            map_name,
            log_file,
            timeout,
            no_kill,
            hold,
            job,
            opts,
        } => {
            let pack = to_pack_args(project, opts, false, false);
            let dargs = DeployArgs {
                pack,
                war3_dir,
                map_name,
                log_file,
                timeout_secs: timeout,
                play: false,
                no_kill,
                hold,
                job,
            };
            run_deploy(&env, &dargs)
        }

        Commands::Proxy {
            install,
            verify,
            uninstall,
            war3_dir,
            proxy_path,
        } => {
            let count = (install as u8) + (verify as u8) + (uninstall as u8);
            if count > 1 {
                anyhow::bail!("Choose at most one action: --install, --verify, or --uninstall");
            }
            let action = if install {
                ProxyAction::Install
            } else if uninstall {
                ProxyAction::Uninstall
            } else {
                ProxyAction::Verify
            };
            run_proxy(&env, action, war3_dir.as_deref(), proxy_path.as_deref())
        }

        Commands::Doctor { war3_dir } => doctor::run_doctor(&env, war3_dir.as_deref()),

        Commands::Kill { pid, dry_run } => {
            let pids = match pid {
                Some(p) => {
                    if war3::is_pid_alive(p) {
                        vec![p]
                    } else {
                        Vec::new()
                    }
                }
                None => war3::find_war3_pids(),
            };
            if pids.is_empty() {
                println!("No running war3.exe found.");
                return Ok(());
            }
            if dry_run {
                println!("Running war3.exe PIDs: {:?}", pids);
                return Ok(());
            }
            for p in pids {
                let method = war3::stop_war3_pid(p, Duration::from_secs(20))?;
                println!("Terminated war3.exe (pid {}, {})", p, method);
            }
            Ok(())
        }

        Commands::EmitManifest { out, root } => {
            let r = root.unwrap_or_else(|| env.root.clone());
            let count = wrappers::emit_natives_manifest(&r, &out)?;
            println!("Natives manifest: {} entries -> {}", count, out.display());
            Ok(())
        }
    }
}

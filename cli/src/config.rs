use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

pub const DEFAULT_WAR3_DIR: &str = r"D:\Warcraft III Frozen Throne 1.27a publish";
pub const DEFAULT_LOG_FILE: &str = r"C:\ProgramData\japi_debug.txt";

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalConfig {
    pub war3_dir: Option<String>,
    pub dll_path: Option<String>,
    pub proxy_path: Option<String>,
    pub d3dx_path: Option<String>,
    pub base_map: Option<String>,
    pub w3x2lni: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectConfig {
    pub schema: Option<u32>,
    pub name: Option<String>,
    pub base_map: Option<String>,
    pub out_file: Option<String>,
    pub map_name: Option<String>,
    pub work_dir: Option<String>,
    pub with_jass_wrappers: Option<bool>,
    pub with_get_func_addr: Option<bool>,
    pub with_debugger: Option<bool>,
    pub strict_requires: Option<bool>,
    pub no_array_prealloc: Option<bool>,
    pub skip_jass_check: Option<bool>,
}

#[derive(Debug, Clone)]
pub struct LoadedProjectConfig {
    pub manifest_path: PathBuf,
    pub raw: ProjectConfig,
    pub base_map: Option<PathBuf>,
    pub out_file: Option<PathBuf>,
    pub work_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayoutKind {
    SdkBundle,
    SourceRepo,
}

#[derive(Debug, Clone)]
pub struct JapiEnv {
    pub root: PathBuf,
    pub layout: LayoutKind,
    pub local: LocalConfig,
    pub local_config_path: Option<PathBuf>,
}

impl JapiEnv {
    pub fn discover() -> Result<Self> {
        let root = detect_root()?;
        let layout = if root.join("bin").is_dir() && !root.join("src").join("CMakeLists.txt").is_file() {
            LayoutKind::SdkBundle
        } else {
            LayoutKind::SourceRepo
        };
        let (local, local_config_path) = load_local_config(&root);
        Ok(Self {
            root,
            layout,
            local,
            local_config_path,
        })
    }

    /// Precedence: explicit CLI > $WAR3_DIR > japi.local.json / config.local.ps1 > default.
    pub fn resolve_war3_dir(&self, explicit: Option<&Path>, allow_default: bool) -> Option<PathBuf> {
        if let Some(p) = explicit {
            return Some(resolve_abs(p, None));
        }
        if let Ok(env_dir) = std::env::var("WAR3_DIR") {
            let trimmed = env_dir.trim();
            if !trimmed.is_empty() {
                return Some(resolve_abs(Path::new(trimmed), None));
            }
        }
        if let Some(ref cfg_dir) = self.local.war3_dir {
            if !cfg_dir.trim().is_empty() {
                return Some(resolve_abs(Path::new(cfg_dir), Some(&self.root)));
            }
        }
        if allow_default {
            Some(PathBuf::from(DEFAULT_WAR3_DIR))
        } else {
            None
        }
    }

    pub fn resolve_dll(&self, explicit: Option<&Path>) -> PathBuf {
        self.resolve_asset(
            explicit,
            self.local.dll_path.as_deref(),
            &[
                self.root.join("bin").join("yd_japi.dll"),
                self.root.join("src").join("build").join("bin").join("Release").join("yd_japi.dll"),
            ],
        )
    }

    pub fn resolve_proxy(&self, explicit: Option<&Path>) -> PathBuf {
        self.resolve_asset(
            explicit,
            self.local.proxy_path.as_deref(),
            &[
                self.root.join("bin").join("newD3d9.dll"),
                self.root.join("src").join("build").join("bin").join("Release").join("newD3d9.dll"),
            ],
        )
    }

    pub fn resolve_d3dx(&self, explicit: Option<&Path>) -> PathBuf {
        let windir = std::env::var("WINDIR").unwrap_or_else(|_| r"C:\Windows".to_string());
        let windir_path = PathBuf::from(windir);
        self.resolve_asset(
            explicit,
            self.local.d3dx_path.as_deref(),
            &[
                self.root.join("bin").join("D3DX9_42.dll"),
                self.root.join("reference").join("builtin-japi").join("extracted").join("D3DX9_42.dll"),
                self.root.join("src").join("build").join("bin").join("Release").join("D3DX9_42.dll"),
                windir_path.join("SysWOW64").join("D3DX9_42.dll"),
                windir_path.join("System32").join("D3DX9_42.dll"),
            ],
        )
    }

    pub fn resolve_base_map(&self, explicit: Option<&Path>) -> PathBuf {
        self.resolve_asset(
            explicit,
            self.local.base_map.as_deref(),
            &[
                self.root.join("templates").join("empty-map"),
                self.root.join("reference").join("empty-map"),
            ],
        )
    }

    pub fn resolve_callback(&self) -> PathBuf {
        self.resolve_asset(
            None,
            None,
            &[
                self.root.join("bin").join("callback"),
                self.root.join("tools").join("callback"),
            ],
        )
    }

    pub fn resolve_pjass(&self) -> PathBuf {
        self.resolve_asset(
            None,
            None,
            &[
                self.root.join("bin").join("pjass.exe"),
                self.root.join("tools").join("pjass.exe"),
            ],
        )
    }

    pub fn resolve_w3x2lni(&self, explicit: Option<&Path>) -> PathBuf {
        self.resolve_asset(
            explicit,
            self.local.w3x2lni.as_deref(),
            &[
                self.root.join("vendor").join("w3x2lni"),
                self.root.join("tools").join("w3x2lni"),
            ],
        )
    }

    pub fn resolve_object_compiler(&self) -> PathBuf {
        self.resolve_asset(
            None,
            None,
            &[
                self.root.join("tools").join("object-data").join("build.lua"),
            ],
        )
    }

    pub fn resolve_natives_manifest(&self) -> Option<PathBuf> {
        let p = self.root.join("bin").join("natives-manifest.json");
        if p.is_file() {
            Some(p)
        } else {
            None
        }
    }

    fn resolve_asset(
        &self,
        explicit: Option<&Path>,
        local_override: Option<&str>,
        candidates: &[PathBuf],
    ) -> PathBuf {
        if let Some(p) = explicit {
            return resolve_abs(p, None);
        }
        if let Some(s) = local_override {
            if !s.trim().is_empty() {
                return resolve_abs(Path::new(s), Some(&self.root));
            }
        }
        for c in candidates {
            if c.exists() {
                return c.clone();
            }
        }
        if self.layout == LayoutKind::SdkBundle {
            candidates[0].clone()
        } else {
            candidates.last().cloned().unwrap_or_default()
        }
    }
}

/// Detect the SDK or source-repository root.
/// Priority:
///   1. JAPI_ROOT environment variable
///   2. Ancestors of current executable (works from <sdk>/japi.exe, <sdk>/bin/japi.exe,
///      or <repo>/cli/target/release/japi.exe)
///   3. Current working directory and its ancestors
fn detect_root() -> Result<PathBuf> {
    if let Ok(env_root) = std::env::var("JAPI_ROOT") {
        let p = PathBuf::from(env_root.trim());
        if p.is_dir() {
            return Ok(p);
        }
    }

    if let Ok(exe) = std::env::current_exe() {
        for ancestor in exe.ancestors().skip(1) {
            if looks_like_root(ancestor) {
                return Ok(ancestor.to_path_buf());
            }
        }
    }

    if let Ok(cwd) = std::env::current_dir() {
        for ancestor in cwd.ancestors() {
            if looks_like_root(ancestor) {
                return Ok(ancestor.to_path_buf());
            }
        }
        return Ok(cwd);
    }

    anyhow::bail!("Could not determine SDK or repository root; set JAPI_ROOT.")
}

fn looks_like_root(dir: &Path) -> bool {
    // Clean SDK layout
    if dir.join("bin").join("yd_japi.dll").is_file()
        || (dir.join("bin").is_dir() && dir.join("templates").join("empty-map").is_dir())
    {
        return true;
    }
    // Source repo layout
    if dir.join("src").join("CMakeLists.txt").is_file() && dir.join("tools").is_dir() {
        return true;
    }
    false
}

fn load_local_config(root: &Path) -> (LocalConfig, Option<PathBuf>) {
    // Primary: japi.local.json at root
    let json_path = root.join("japi.local.json");
    if json_path.is_file() {
        if let Ok(text) = fs::read_to_string(&json_path) {
            if let Ok(cfg) = serde_json::from_str::<LocalConfig>(&text) {
                return (cfg, Some(json_path));
            }
        }
    }

    // Legacy fallback: tools/config.local.ps1 ($War3Dir = "...")
    let ps_path = root.join("tools").join("config.local.ps1");
    if ps_path.is_file() {
        if let Ok(text) = fs::read_to_string(&ps_path) {
            let mut cfg = LocalConfig::default();
            for line in text.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with('#') || trimmed.is_empty() {
                    continue;
                }
                if let Some((k, v)) = parse_ps_assignment(trimmed) {
                    match k.to_ascii_lowercase().as_str() {
                        "war3dir" => cfg.war3_dir = Some(v),
                        "dllpath" => cfg.dll_path = Some(v),
                        "proxypath" => cfg.proxy_path = Some(v),
                        "d3dxpath" => cfg.d3dx_path = Some(v),
                        "basemap" => cfg.base_map = Some(v),
                        "w3x2lni" => cfg.w3x2lni = Some(v),
                        _ => {}
                    }
                }
            }
            return (cfg, Some(ps_path));
        }
    }

    (LocalConfig::default(), None)
}

fn parse_ps_assignment(line: &str) -> Option<(String, String)> {
    let rest = line.strip_prefix('$')?;
    let (key, rhs) = rest.split_once('=')?;
    let key = key.trim().to_string();
    let val = rhs.trim();
    let unquoted = if (val.starts_with('"') && val.ends_with('"'))
        || (val.starts_with('\'') && val.ends_with('\''))
    {
        &val[1..val.len() - 1]
    } else {
        val
    };
    if key.is_empty() || unquoted.is_empty() {
        None
    } else {
        Some((key, unquoted.to_string()))
    }
}

pub fn load_project_config(map_dir: &Path) -> Result<Option<LoadedProjectConfig>> {
    let manifest_path = map_dir.join("japi.json");
    if !manifest_path.is_file() {
        return Ok(None);
    }
    let text = fs::read_to_string(&manifest_path)
        .with_context(|| format!("Failed to read {}", manifest_path.display()))?;
    let raw: ProjectConfig = serde_json::from_str(&text)
        .with_context(|| format!("Failed to parse JSON in {}", manifest_path.display()))?;

    let base_map = raw
        .base_map
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .map(|s| resolve_abs(Path::new(s), Some(map_dir)));
    let out_file = raw
        .out_file
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .map(|s| resolve_abs(Path::new(s), Some(map_dir)));
    let work_dir = raw
        .work_dir
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .map(|s| resolve_abs(Path::new(s), Some(map_dir)));

    Ok(Some(LoadedProjectConfig {
        manifest_path,
        raw,
        base_map,
        out_file,
        work_dir,
    }))
}

pub fn resolve_abs(path: &Path, base_dir: Option<&Path>) -> PathBuf {
    let combined = if path.is_absolute() {
        path.to_path_buf()
    } else if let Some(base) = base_dir {
        base.join(path)
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };
    normalize_path(&combined)
}

pub fn normalize_path(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

pub fn sha256_file_upper(path: &Path) -> Result<String> {
    let bytes = fs::read(path).with_context(|| format!("Failed to hash {}", path.display()))?;
    Ok(sha256_bytes_upper(&bytes))
}

pub fn sha256_bytes_upper(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    let mut s = String::with_capacity(64);
    for b in digest {
        use std::fmt::Write;
        let _ = write!(&mut s, "{:02X}", b);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_legacy_ps_assignment() {
        assert_eq!(
            parse_ps_assignment(r#"$War3Dir = "D:\Warcraft III Frozen Throne 1.27a publish""#),
            Some((
                "War3Dir".to_string(),
                r"D:\Warcraft III Frozen Throne 1.27a publish".to_string()
            ))
        );
        assert_eq!(
            parse_ps_assignment(r#"$BaseMap = 'reference\empty-map'"#),
            Some(("BaseMap".to_string(), r"reference\empty-map".to_string()))
        );
    }

    #[test]
    fn normalizes_parent_components() {
        let p = normalize_path(Path::new(r"C:\a\b\..\c\.\d.w3x"));
        assert_eq!(p, PathBuf::from(r"C:\a\c\d.w3x"));
    }
}

use anyhow::{bail, Context, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::Path;

const BUILTIN_EXCLUSIONS: &[&str] = &[
    "LoadScript",
    "SimulateMapBoot",
    "open_code_run_logs",
    "SaveFunc",
    "func_bind_trigger_name",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeEntry {
    pub name: String,
    pub spec: String,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativesManifest {
    pub schema: u32,
    pub handlers: Vec<NativeEntry>,
}

#[derive(Debug, Deserialize)]
struct D3dHandlerManifest {
    handlers: Vec<D3dHandlerRow>,
}

#[derive(Debug, Deserialize)]
struct D3dHandlerRow {
    name: String,
    spec: String,
}

#[derive(Debug, Clone)]
struct ParsedSpec {
    params: Vec<String>,
    ret: String,
}

#[derive(Debug, Clone)]
pub struct WrapperGenResult {
    pub jass_text: String,
    pub total_generated: usize,
}

pub fn load_registry_entries(root: &Path, explicit_manifest: Option<&Path>) -> Result<Vec<NativeEntry>> {
    let ex_src = root
        .join("src")
        .join("src")
        .join("extensions")
        .join("ex_natives")
        .join("Initialize.cpp");
    let msg_src = root
        .join("src")
        .join("src")
        .join("lua_engine")
        .join("lua_engine")
        .join("libs_message.cpp");
    let d3d_manifest_path = root
        .join("src")
        .join("src")
        .join("d3d9")
        .join("handler_manifest.json");

    let manifest_to_read = if let Some(p) = explicit_manifest {
        Some(p.to_path_buf())
    } else {
        let bin_manifest = root.join("bin").join("natives-manifest.json");
        if bin_manifest.is_file() && !ex_src.is_file() {
            Some(bin_manifest)
        } else {
            None
        }
    };

    if let Some(mpath) = manifest_to_read {
        let raw = fs::read_to_string(&mpath)
            .with_context(|| format!("Failed to read natives manifest {}", mpath.display()))?;
        let parsed: NativesManifest = serde_json::from_str(&raw)
            .with_context(|| format!("Failed to parse natives manifest {}", mpath.display()))?;
        return Ok(parsed.handlers);
    }

    let mut rows = Vec::new();
    rows.extend(scan_cpp_registry(
        &ex_src,
        r#"register_cpp_handler\(\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*"([^"]+)""#,
        "ex-native",
    )?);
    rows.extend(scan_cpp_registry(
        &msg_src,
        r#"\breg\(\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*,\s*"([^"]+)""#,
        "message",
    )?);
    if d3d_manifest_path.is_file() {
        let raw = fs::read_to_string(&d3d_manifest_path)
            .with_context(|| format!("Failed to read {}", d3d_manifest_path.display()))?;
        let d3d: D3dHandlerManifest = serde_json::from_str(&raw)
            .with_context(|| format!("Failed to parse {}", d3d_manifest_path.display()))?;
        for h in d3d.handlers {
            rows.push(NativeEntry {
                name: h.name,
                spec: h.spec,
                source: "d3d".to_string(),
            });
        }
    }
    Ok(rows)
}

fn scan_cpp_registry(path: &Path, pattern: &str, source: &str) -> Result<Vec<NativeEntry>> {
    if !path.is_file() {
        bail!("handler registry not found: {}", path.display());
    }
    let text = fs::read_to_string(path)
        .with_context(|| format!("Failed to read {}", path.display()))?;
    let re = Regex::new(pattern).unwrap();
    let mut out = Vec::new();
    for caps in re.captures_iter(&text) {
        out.push(NativeEntry {
            name: caps[1].to_string(),
            spec: caps[2].to_string(),
            source: source.to_string(),
        });
    }
    Ok(out)
}

pub fn emit_natives_manifest(root: &Path, out_path: &Path) -> Result<usize> {
    let handlers = load_registry_entries(root, None)?;
    let count = handlers.len();
    let manifest = NativesManifest {
        schema: 1,
        handlers,
    };
    if let Some(parent) = out_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut json = serde_json::to_string_pretty(&manifest)?;
    json.push('\n');
    fs::write(out_path, json.as_bytes())
        .with_context(|| format!("Failed to write {}", out_path.display()))?;
    Ok(count)
}

fn parse_spec(spec: &str) -> Option<ParsedSpec> {
    let re_outer = Regex::new(r"^\(([^)]*)\)(.+)$").unwrap();
    let caps = re_outer.captures(spec)?;
    let params_str = &caps[1];
    let ret = caps[2].to_string();

    let re_tok = Regex::new(r"H[a-z]+;|[IRSBV]").unwrap();
    let params: Vec<String> = re_tok
        .find_iter(params_str)
        .map(|m| m.as_str().to_string())
        .collect();

    let re_ret = Regex::new(r"^(H[a-z]+;|[IRSBV])$").unwrap();
    if !re_ret.is_match(&ret) {
        return None;
    }
    Some(ParsedSpec { params, ret })
}

fn token_to_jass_and_save(token: &str) -> Result<(String, &'static str)> {
    match token {
        "I" => Ok(("integer".to_string(), "SaveInteger")),
        "R" => Ok(("real".to_string(), "SaveReal")),
        "S" => Ok(("string".to_string(), "SaveStr")),
        "B" => Ok(("boolean".to_string(), "SaveBoolean")),
        other => {
            if let Some(rest) = other.strip_prefix('H').and_then(|s| s.strip_suffix(';')) {
                let save = if rest == "rect" {
                    "SaveRectHandle"
                } else {
                    "SaveInteger"
                };
                Ok((rest.to_string(), save))
            } else {
                bail!("unsupported spec token: {}", token);
            }
        }
    }
}

pub fn generate_jass_wrappers(
    root: &Path,
    explicit_manifest: Option<&Path>,
    skip_names: &HashSet<String>,
) -> Result<WrapperGenResult> {
    let entries = load_registry_entries(root, explicit_manifest)?;
    let mut skip_set: HashSet<String> = BUILTIN_EXCLUSIONS.iter().map(|s| (*s).to_string()).collect();
    for s in skip_names {
        if !s.is_empty() {
            skip_set.insert(s.clone());
        }
    }

    let mut seen = HashSet::new();
    let mut source_order: Vec<String> = Vec::new();
    let mut by_source: BTreeMap<String, Vec<(String, String, ParsedSpec)>> = BTreeMap::new();

    for row in entries {
        if row.name.is_empty() || row.spec.is_empty() {
            continue;
        }
        if skip_set.contains(&row.name) {
            continue;
        }
        if !seen.insert(row.name.clone()) {
            continue;
        }
        let Some(parsed) = parse_spec(&row.spec) else {
            continue;
        };
        if parsed.ret.starts_with('H') && parsed.ret != "Hrect;" {
            continue;
        }
        if !by_source.contains_key(&row.source) {
            source_order.push(row.source.clone());
        }
        by_source
            .entry(row.source)
            .or_default()
            .push((row.name, row.spec, parsed));
    }

    let total: usize = by_source.values().map(|v| v.len()).sum();
    let mut lines: Vec<String> = Vec::new();
    lines.push("// ============================================================================".into());
    lines.push("// Auto-generated by japi - do not edit by hand.".into());
    lines.push(format!("// {} wrappers generated from the UnitId bridge registries.", total));
    lines.push("// ============================================================================".into());

    for src in &source_order {
        let Some(list) = by_source.get_mut(src) else { continue };
        list.sort_by(|a, b| a.0.cmp(&b.0));
        lines.push(String::new());
        lines.push(format!("// ---- {} handlers ----", src));
        for (name, spec, parsed) in list.iter() {
            lines.push(String::new());
            let mut param_sigs = Vec::new();
            for (idx, tok) in parsed.params.iter().enumerate() {
                let (jtype, _) = token_to_jass_and_save(tok)?;
                param_sigs.push(format!("{} arg{}", jtype, idx + 1));
            }
            let (ret_type, ret_line) = match parsed.ret.as_str() {
                "V" => ("nothing", String::new()),
                "I" => ("integer", "    return LoadInteger(japi_ht, japi__key, 0)".to_string()),
                "R" => ("real", "    return LoadReal(japi_ht, japi__key, 0)".to_string()),
                "S" => ("string", "    return LoadStr(japi_ht, japi__key, 0)".to_string()),
                "B" => ("boolean", "    return LoadBoolean(japi_ht, japi__key, 0)".to_string()),
                "Hrect;" => ("rect", "    return LoadRectHandle(japi_ht, japi__key, 0)".to_string()),
                other => bail!("unexpected return token: {}", other),
            };
            let takes = if param_sigs.is_empty() {
                "nothing".to_string()
            } else {
                param_sigs.join(", ")
            };
            lines.push(format!("function {} takes {} returns {}", name, takes, ret_type));
            lines.push(format!("    call SaveStr(japi_ht, japi__key, 0, \"{}\")", spec));
            for (idx, tok) in parsed.params.iter().enumerate() {
                let (_, save_call) = token_to_jass_and_save(tok)?;
                let mut arg = format!("arg{}", idx + 1);
                if tok.starts_with('H') && tok != "Hrect;" {
                    arg = format!("GetHandleId({})", arg);
                }
                lines.push(format!("    call {}(japi_ht, japi__key, {}, {})", save_call, idx + 1, arg));
            }
            lines.push(format!("    call UnitId(\"{}\")", name));
            if !ret_line.is_empty() {
                lines.push(ret_line);
            }
            lines.push("endfunction".into());
        }
    }

    let jass_text = lines.join("\r\n") + "\r\n";
    Ok(WrapperGenResult {
        jass_text,
        total_generated: total,
    })
}

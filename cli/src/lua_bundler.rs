use anyhow::{bail, Context, Result};
use regex::Regex;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

/// Built-in engine modules registered via `package.preload` in `open_lua_engine.cpp`.
const BUILTIN_ENGINE_MODULES: &[&str] = &[
    "jass.common",
    "jass.globals",
    "jass.japi",
    "jass.hook",
    "jass.runtime",
    "jass.debug",
    "jass.message",
    "jass.sleep",
    "jass.storm",
    "jass.slk",
    "jass.debugger",
    "jass.d3d",
    "jass.console",
    "jass.log",
    "jass.bignum",
    "jass.map_event",
    "jass.selector",
    "jass.ydwe",
    "jass.ai",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequireAction {
    Preloaded,
    Cached,
    Cycle,
    Engine,
    Missing,
}

impl RequireAction {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Preloaded => "preloaded",
            Self::Cached => "cached",
            Self::Cycle => "cycle",
            Self::Engine => "engine",
            Self::Missing => "missing",
        }
    }
}

#[derive(Debug, Clone)]
pub struct RequireRecord {
    pub source: String,
    pub line: usize,
    pub module: String,
    pub action: RequireAction,
    pub note: String,
}

#[derive(Debug, Clone, Default)]
pub struct BundleFlags {
    pub interactive_point: bool,
    pub interactive_ui: bool,
    pub interactive_d3d: bool,
    pub demo: bool,
    pub test_reboot: bool,
}

#[derive(Debug, Clone)]
pub struct BundleReport {
    pub module_count: usize,
    pub reachable_count: usize,
    pub output_code: String,
}

pub fn load_engine_modules(root: &Path) -> HashSet<String> {
    let mut set: HashSet<String> = BUILTIN_ENGINE_MODULES
        .iter()
        .map(|s| (*s).to_string())
        .collect();

    let open_cpp = root
        .join("src")
        .join("src")
        .join("lua_engine")
        .join("lua_engine")
        .join("open_lua_engine.cpp");
    if let Ok(text) = fs::read_to_string(&open_cpp) {
        let re = Regex::new(r#"register_preload_lib\s*\(\s*L\s*,\s*"([^"]+)""#).unwrap();
        for caps in re.captures_iter(&text) {
            set.insert(caps[1].to_string());
        }
    }
    set
}

/// Mask Lua comments (`--`, `--[=[...]=]`) and string literals (`"..."`, `'...'`, `[=[...]=]`)
/// with spaces while preserving byte length and newlines (`\r`/`\n`).
/// Used so static `require` discovery never mistakes strings or comments for real dependencies.
pub fn mask_lua_code(code: &str) -> String {
    let bytes = code.as_bytes();
    let mut out = bytes.to_vec();
    let n = bytes.len();
    let mut i = 0;

    while i < n {
        let start = i;
        let is_comment = i + 1 < n && bytes[i] == b'-' && bytes[i + 1] == b'-';
        let long_at = if is_comment { i + 2 } else { i };

        if let Some((eq_count, header_len)) = match_long_bracket(bytes, long_at) {
            let mut pos = long_at + header_len;
            let mut found_end = n;
            while pos < n {
                if bytes[pos] == b']' && match_long_close(bytes, pos, eq_count) {
                    found_end = pos + 2 + eq_count;
                    break;
                }
                pos += 1;
            }
            i = found_end;
        } else if is_comment {
            while i < n && bytes[i] != b'\n' {
                i += 1;
            }
        } else if bytes[i] == b'"' || bytes[i] == b'\'' {
            let quote = bytes[i];
            i += 1;
            while i < n {
                if bytes[i] == b'\\' {
                    i = (i + 2).min(n);
                    continue;
                }
                if bytes[i] == quote {
                    i += 1;
                    break;
                }
                i += 1;
            }
        } else {
            i += 1;
            continue;
        }

        for b in &mut out[start..i] {
            if *b != b'\r' && *b != b'\n' {
                *b = b' ';
            }
        }
    }

    // All replaced bytes were ASCII comments/strings; UTF-8 bytes outside comments/strings are untouched.
    String::from_utf8(out).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

fn match_long_bracket(bytes: &[u8], pos: usize) -> Option<(usize, usize)> {
    if pos >= bytes.len() || bytes[pos] != b'[' {
        return None;
    }
    let mut eq = 0;
    let mut p = pos + 1;
    while p < bytes.len() && bytes[p] == b'=' {
        eq += 1;
        p += 1;
    }
    if p < bytes.len() && bytes[p] == b'[' {
        Some((eq, 2 + eq))
    } else {
        None
    }
}

fn match_long_close(bytes: &[u8], pos: usize, eq_count: usize) -> bool {
    if pos + 2 + eq_count > bytes.len() || bytes[pos] != b']' {
        return false;
    }
    for k in 0..eq_count {
        if bytes[pos + 1 + k] != b'=' {
            return false;
        }
    }
    bytes[pos + 1 + eq_count] == b']'
}

fn line_number_at(code: &str, byte_index: usize) -> usize {
    1 + code[..byte_index.min(code.len())]
        .bytes()
        .filter(|&b| b == b'\n')
        .count()
}

/// Extract literal `require "mod"` / `require('mod')` / `require("mod")` calls
/// from real code (excluding comments and string literals).
fn find_static_requires(code: &str) -> Vec<(usize, String)> {
    let masked = mask_lua_code(code);
    let re = Regex::new(r#"(?m)(?:^|[^\w.:])require\s*(?:\(\s*)?["']([^"'\r\n]+)["']"#).unwrap();
    let mut results = Vec::new();
    for m in re.captures_iter(code) {
        let full = m.get(0).unwrap();
        let req_offset = full.as_str().find("require").unwrap_or(0);
        let req_pos = full.start() + req_offset;
        if masked.as_bytes().get(req_pos..req_pos + 7) == Some(b"require") {
            let line = line_number_at(code, req_pos);
            let target = m[1].to_string();
            results.push((line, target));
        }
    }
    results
}

fn collect_lua_files(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("Failed to read {}", dir.display()))? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            // Skip base-map / dist / .japi-work / build directories inside a project
            if let Some(name) = path.file_name().and_then(|s| s.to_str()) {
                let lower = name.to_ascii_lowercase();
                if matches!(lower.as_str(), "base-map" | "dist" | "build" | ".japi-work" | ".git") {
                    continue;
                }
            }
            collect_lua_files(&path, out)?;
        } else if path.extension().and_then(|s| s.to_str()).map(|s| s.eq_ignore_ascii_case("lua")).unwrap_or(false) {
            out.push(path);
        }
    }
    Ok(())
}

fn file_to_module_name(file: &Path, map_dir: &Path) -> Result<(String, String)> {
    let rel = file
        .strip_prefix(map_dir)
        .with_context(|| format!("{} is not under {}", file.display(), map_dir.display()))?;
    let rel_slash = rel.to_string_lossy().replace('\\', "/");
    let no_ext = rel_slash
        .strip_suffix(".lua")
        .or_else(|| rel_slash.strip_suffix(".LUA"))
        .unwrap_or(&rel_slash);
    let mod_name = no_ext.replace('/', ".");
    Ok((mod_name, rel_slash))
}

/// Bundle a Lua project directory into a single self-contained Lua chunk using
/// standard Lua `package.preload["module.name"] = function(...) ... end`.
///
/// Unlike legacy regex inlining:
/// - `require` works at ANY indentation, with parentheses, single quotes, inside
///   functions, `if` blocks, or `pcall(require, "...")`.
/// - Module source code is NEVER rewritten (comments/strings stay untouched).
/// - Standard Lua 5.4 `package.loaded` guarantees each module runs at most once.
pub fn bundle_lua_dir(
    map_dir: &Path,
    entry: &str,
    engine_modules: &HashSet<String>,
    flags: &BundleFlags,
    require_report: bool,
    strict_requires: bool,
) -> Result<BundleReport> {
    bundle_lua_dir_with_std(
        map_dir,
        None,
        entry,
        engine_modules,
        flags,
        require_report,
        strict_requires,
    )
}

pub fn bundle_lua_dir_with_std(
    map_dir: &Path,
    std_dir: Option<&Path>,
    entry: &str,
    engine_modules: &HashSet<String>,
    flags: &BundleFlags,
    require_report: bool,
    strict_requires: bool,
) -> Result<BundleReport> {
    let mut files = Vec::new();
    collect_lua_files(map_dir, &mut files)?;
    files.sort();

    let mut modules: BTreeMap<String, String> = BTreeMap::new();
    let mut module_files: BTreeMap<String, String> = BTreeMap::new();
    let mut std_modules: HashSet<String> = HashSet::new();

    for f in files {
        let (name, rel) = file_to_module_name(&f, map_dir)?;
        // Root objects.lua is a build-only declaration, never a runtime module.
        if name == "objects" {
            continue;
        }
        let raw = fs::read_to_string(&f)
            .with_context(|| format!("Failed to read Lua file {}", f.display()))?;
        // Strip UTF-8 BOM if present so embedded function bodies stay valid Lua.
        let clean = raw.strip_prefix('\u{FEFF}').unwrap_or(&raw).to_string();
        modules.insert(name.clone(), clean);
        module_files.insert(name, rel);
    }

    // Load SDK standard library (`std/*.lua`) as fallback modules so maps can
    // `require "std.timer"` / `require "std.unit"` / `require "std.ui"` with
    // zero copy-paste and automatic tree-shaking. Project-local files win on conflict.
    if let Some(sdir) = std_dir {
        if sdir.is_dir() {
            let mut sfiles = Vec::new();
            collect_lua_files(sdir, &mut sfiles)?;
            sfiles.sort();
            for f in sfiles {
                let (sub_name, sub_rel) = file_to_module_name(&f, sdir)?;
                let mod_name = if sub_name == "init" {
                    "std".to_string()
                } else {
                    format!("std.{}", sub_name)
                };
                if modules.contains_key(&mod_name) {
                    continue;
                }
                let raw = fs::read_to_string(&f)
                    .with_context(|| format!("Failed to read std Lua file {}", f.display()))?;
                let clean = raw.strip_prefix('\u{FEFF}').unwrap_or(&raw).to_string();
                modules.insert(mod_name.clone(), clean);
                module_files.insert(mod_name.clone(), format!("std/{}", sub_rel));
                std_modules.insert(mod_name);
            }
        }
    }

    if !modules.contains_key(entry) {
        bail!("{}.lua not found in {}", entry, map_dir.display());
    }

    let mut visited: BTreeSet<String> = BTreeSet::new();
    let mut active: HashSet<String> = HashSet::new();
    let mut preload_order: Vec<String> = Vec::new();
    let mut records: Vec<RequireRecord> = Vec::new();

    visited.insert(entry.to_string());
    active.insert(entry.to_string());

    #[allow(clippy::too_many_arguments)]
    fn visit(
        mod_name: &str,
        modules: &BTreeMap<String, String>,
        module_files: &BTreeMap<String, String>,
        engine_modules: &HashSet<String>,
        visited: &mut BTreeSet<String>,
        active: &mut HashSet<String>,
        preload_order: &mut Vec<String>,
        records: &mut Vec<RequireRecord>,
    ) {
        let code = &modules[mod_name];
        let src_file = &module_files[mod_name];
        for (line, target) in find_static_requires(code) {
            if modules.contains_key(&target) {
                if visited.contains(&target) {
                    if active.contains(&target) {
                        records.push(RequireRecord {
                            source: src_file.clone(),
                            line,
                            module: target,
                            action: RequireAction::Cycle,
                            note: "cyclic dependency detected".to_string(),
                        });
                    } else {
                        records.push(RequireRecord {
                            source: src_file.clone(),
                            line,
                            module: target,
                            action: RequireAction::Cached,
                            note: "served by package.loaded".to_string(),
                        });
                    }
                } else {
                    visited.insert(target.clone());
                    active.insert(target.clone());
                    visit(
                        &target,
                        modules,
                        module_files,
                        engine_modules,
                        visited,
                        active,
                        preload_order,
                        records,
                    );
                    active.remove(&target);
                    preload_order.push(target.clone());
                    records.push(RequireRecord {
                        source: src_file.clone(),
                        line,
                        module: target.clone(),
                        action: RequireAction::Preloaded,
                        note: module_files[&target].clone(),
                    });
                }
            } else if engine_modules.contains(&target) {
                records.push(RequireRecord {
                    source: src_file.clone(),
                    line,
                    module: target,
                    action: RequireAction::Engine,
                    note: "runtime module (engine package.preload)".to_string(),
                });
            } else {
                records.push(RequireRecord {
                    source: src_file.clone(),
                    line,
                    module: target,
                    action: RequireAction::Missing,
                    note: "no map file and no engine module".to_string(),
                });
            }
        }
    }

    visit(
        entry,
        &modules,
        &module_files,
        engine_modules,
        &mut visited,
        &mut active,
        &mut preload_order,
        &mut records,
    );
    active.remove(entry);

    let missing: Vec<&RequireRecord> = records
        .iter()
        .filter(|r| r.action == RequireAction::Missing)
        .collect();
    let cycles: Vec<&RequireRecord> = records
        .iter()
        .filter(|r| r.action == RequireAction::Cycle)
        .collect();
    let unused: Vec<String> = modules
        .keys()
        .filter(|k| !visited.contains(*k) && !std_modules.contains(*k))
        .cloned()
        .collect();
    let user_module_count = modules.len() - std_modules.len();

    if require_report {
        println!("  Require report ({}):", module_files[entry]);
        let mut sorted = records.clone();
        sorted.sort_by(|a, b| {
            a.source
                .cmp(&b.source)
                .then(a.line.cmp(&b.line))
                .then(a.module.cmp(&b.module))
        });
        for r in &sorted {
            println!(
                "    [{:<9}] {:<28} <- {}:{}",
                r.action.label(),
                r.module,
                r.source,
                r.line
            );
            if !r.note.is_empty()
                && !matches!(r.action, RequireAction::Preloaded | RequireAction::Cached)
            {
                println!("               {}", r.note);
            }
        }
        if !unused.is_empty() {
            println!(
                "  Unused Lua files (not reachable from {}): {}",
                entry,
                unused.join(", ")
            );
        }
        let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
        for r in &records {
            *counts.entry(r.action.label()).or_insert(0) += 1;
        }
        let summary_parts: Vec<String> = counts
            .iter()
            .map(|(k, v)| format!("{}={}", k, v))
            .collect();
        println!(
            "  Require summary: {} modules={} reachable={} unused={}",
            summary_parts.join(" "),
            user_module_count,
            visited.len().saturating_sub(1),
            unused.len()
        );
    } else if !missing.is_empty() || !cycles.is_empty() {
        println!(
            "  WARNING: {} missing and {} cyclic require(s); run with --require-report for detail",
            missing.len(),
            cycles.len()
        );
    }

    if strict_requires && (!missing.is_empty() || !cycles.is_empty()) {
        let mut bad: Vec<&RequireRecord> = missing.into_iter().chain(cycles).collect();
        bad.sort_by(|a, b| a.source.cmp(&b.source).then(a.line.cmp(&b.line)));
        for r in bad {
            println!("  [require] {}:{}: {} ({})", r.source, r.line, r.module, r.action.label());
        }
        bail!(
            "require validation failed: missing or cyclic dependencies; resolve them before bundling, or drop --strict-requires for runtime-managed modules"
        );
    }

    // Assemble standard package.preload bundle
    let mut out = String::new();
    let is_main = entry == "war3map";
    if is_main {
        if flags.test_reboot {
            out.push_str("_G.__JAPI_REBOOT_PARENT = true\r\n");
        }
        if flags.demo {
            out.push_str("_G.__JAPI_DEMO = true\r\n");
        }
        if flags.interactive_d3d {
            out.push_str("_G.__JAPI_TEST_INTERACTIVE_D3D = true\r\n");
        }
        if flags.interactive_ui {
            out.push_str("_G.__JAPI_TEST_INTERACTIVE_UI = true\r\n");
        }
        if flags.interactive_point {
            out.push_str("_G.__JAPI_TEST_INTERACTIVE_POINT = true\r\n");
        }
    }

    if !preload_order.is_empty() {
        out.push_str("-- Bundled modules (standard Lua package.preload)\r\n");
        for mod_name in &preload_order {
            let escaped = mod_name.replace('\\', "\\\\").replace('"', "\\\"");
            out.push_str(&format!(
                "package.preload[\"{}\"] = function(...)\r\n",
                escaped
            ));
            out.push_str(&modules[mod_name]);
            if !modules[mod_name].ends_with('\n') {
                out.push_str("\r\n");
            }
            out.push_str("end\r\n\r\n");
        }
    }

    out.push_str(&modules[entry]);

    Ok(BundleReport {
        module_count: modules.len(),
        reachable_count: visited.len().saturating_sub(1),
        output_code: out,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn masks_comments_and_long_strings() {
        let src = "--[==[\nrequire \"missing.comment\"\n]==]\nlocal t = [=[\nrequire \"lib.exists\"\n]=]\nlocal s = \"a\\\" require 'missing.str'\"\n-- require \"missing.line\"\nlocal a = require(\"lib.exists\")\n";
        let reqs = find_static_requires(src);
        assert_eq!(reqs.len(), 1);
        assert_eq!(reqs[0], (9, "lib.exists".to_string()));
    }

    #[test]
    fn supports_indented_and_parenthesized_requires() {
        let src = "if true then\n    local a = require('lib.a')\n    local b = require ( \"lib.b\" )\nend\n";
        let reqs = find_static_requires(src);
        assert_eq!(
            reqs,
            vec![(2, "lib.a".to_string()), (3, "lib.b".to_string())]
        );
    }

    #[test]
    fn detects_cycles_and_missing_in_strict_mode() {
        let tmp = std::env::temp_dir().join(format!("japi-bundler-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("lib")).unwrap();
        fs::write(tmp.join("war3map.lua"), "local a = require 'lib.a'\n").unwrap();
        fs::write(tmp.join("lib").join("a.lua"), "local b = require 'lib.b'\nreturn {}\n").unwrap();
        fs::write(tmp.join("lib").join("b.lua"), "local a = require 'lib.a'\nreturn {}\n").unwrap();

        let engine: HashSet<String> = BUILTIN_ENGINE_MODULES.iter().map(|s| s.to_string()).collect();
        let err = bundle_lua_dir(&tmp, "war3map", &engine, &BundleFlags::default(), false, true)
            .unwrap_err();
        assert!(err.to_string().contains("require validation failed"));
        let _ = fs::remove_dir_all(&tmp);
    }
}

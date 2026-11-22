use crate::wrappers;
use anyhow::{bail, Context, Result};
use encoding_rs::Encoding;
use regex::Regex;
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Copy)]
pub enum ScriptEncoding {
    Utf8Bom,
    Utf16LeBom,
    Utf8,
    Ansi(&'static Encoding),
}

impl ScriptEncoding {
    pub fn label(&self) -> String {
        match self {
            Self::Utf8Bom => "utf-8 (BOM preserved)".to_string(),
            Self::Utf16LeBom => "utf-16le (BOM preserved)".to_string(),
            Self::Utf8 => "utf-8".to_string(),
            Self::Ansi(enc) => enc.name().to_string(),
        }
    }
}

pub struct JassScript {
    pub text: String,
    pub encoding: ScriptEncoding,
}

fn system_ansi_encoding() -> &'static Encoding {
    #[cfg(windows)]
    {
        let cp = unsafe { windows_sys::Win32::Globalization::GetACP() };
        match cp {
            936 => encoding_rs::GBK,
            950 => encoding_rs::BIG5,
            932 => encoding_rs::SHIFT_JIS,
            949 => encoding_rs::EUC_KR,
            _ => encoding_rs::WINDOWS_1252,
        }
    }
    #[cfg(not(windows))]
    {
        encoding_rs::WINDOWS_1252
    }
}

pub fn read_jass_script(path: &Path) -> Result<JassScript> {
    let bytes = fs::read(path).with_context(|| format!("Failed to read {}", path.display()))?;
    if bytes.len() >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
        let text = String::from_utf8_lossy(&bytes[3..]).into_owned();
        return Ok(JassScript {
            text,
            encoding: ScriptEncoding::Utf8Bom,
        });
    }
    if bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
        let (cow, _, _) = encoding_rs::UTF_16LE.decode(&bytes[2..]);
        return Ok(JassScript {
            text: cow.into_owned(),
            encoding: ScriptEncoding::Utf16LeBom,
        });
    }
    if let Ok(text) = String::from_utf8(bytes.clone()) {
        return Ok(JassScript {
            text,
            encoding: ScriptEncoding::Utf8,
        });
    }
    let enc = system_ansi_encoding();
    let (cow, _, _) = enc.decode(&bytes);
    Ok(JassScript {
        text: cow.into_owned(),
        encoding: ScriptEncoding::Ansi(enc),
    })
}

pub fn write_jass_script(path: &Path, encoding: ScriptEncoding, text: &str) -> Result<()> {
    let bytes: Vec<u8> = match encoding {
        ScriptEncoding::Utf8Bom => {
            let mut v = vec![0xEF, 0xBB, 0xBF];
            v.extend_from_slice(text.as_bytes());
            v
        }
        ScriptEncoding::Utf16LeBom => {
            let mut v = vec![0xFF, 0xFE];
            for u in text.encode_utf16() {
                v.extend_from_slice(&u.to_le_bytes());
            }
            v
        }
        ScriptEncoding::Utf8 => text.as_bytes().to_vec(),
        ScriptEncoding::Ansi(enc) => {
            let (cow, _, _) = enc.encode(text);
            cow.into_owned()
        }
    };
    fs::write(path, bytes).with_context(|| format!("Failed to write {}", path.display()))
}

fn line_number_from_index(text: &str, byte_idx: usize) -> usize {
    1 + text[..byte_idx.min(text.len())]
        .bytes()
        .filter(|&b| b == b'\n')
        .count()
}

pub fn anchor_summary(content: &str) -> String {
    let fmt_one = |re: &str, name: &str| -> String {
        let r = Regex::new(re).unwrap();
        match r.find(content) {
            Some(m) => format!("{}@{}", name, line_number_from_index(content, m.start())),
            None => format!("{}=absent", name),
        }
    };
    let fmt_many = |re: &str, name: &str| -> String {
        let r = Regex::new(re).unwrap();
        let ms: Vec<_> = r.find_iter(content).collect();
        if ms.is_empty() {
            format!("{}=absent", name)
        } else {
            let line = line_number_from_index(content, ms[0].start());
            if ms.len() > 1 {
                format!("{}@{}(x{})", name, line, ms.len())
            } else {
                format!("{}@{}", name, line)
            }
        }
    };

    let mut parts = vec![
        fmt_one(r"(?m)^[ \t]*globals\b", "globals"),
        fmt_one(r"(?m)^[ \t]*endglobals\b", "endglobals"),
        fmt_one(r"(?m)^[ \t]*function[ \t]+main[ \t]+takes\b", "main"),
        fmt_one(
            r"(?m)^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+takes\b",
            "first-function",
        ),
        fmt_many(
            r"(?m)^[ \t]*call[ \t]+initializePlugin[ \t]*\([ \t]*\)",
            "initializePlugin",
        ),
        fmt_many(
            r#"(?m)^[ \t]*call[ \t]+UnitId[ \t]*\([ \t]*"LoadScript"[ \t]*\)"#,
            "loadScript",
        ),
        fmt_many(
            r"(?m)^[ \t]*native[ \t]+SetHeroLevels\b",
            "native:SetHeroLevels",
        ),
    ];

    let mut probes = Vec::new();
    if Regex::new(r"(?m)^[ \t]*function[ \t]+LuaBridgeProbeCall[ \t]+takes\b")
        .unwrap()
        .is_match(content)
    {
        probes.push("bridge");
    }
    if Regex::new(r"(?m)^[ \t]*integer[ \t]+udg_lua_wrapper_ready\b")
        .unwrap()
        .is_match(content)
    {
        probes.push("wrapper");
    }
    if Regex::new(r"(?m)^[ \t]*integer[ \t]+udg_lua_getfunc_ready\b")
        .unwrap()
        .is_match(content)
    {
        probes.push("getfunc");
    }
    if probes.is_empty() {
        parts.push("probes=absent".to_string());
    } else {
        parts.push(format!("probes={}", probes.join(",")));
    }
    parts.join(" ")
}

pub struct JassPatchOptions<'a> {
    pub root: &'a Path,
    pub base_map_display: &'a str,
    pub no_array_prealloc: bool,
    pub with_jass_wrappers: bool,
    pub with_get_func_addr: bool,
    pub test_reboot: bool,
    pub explicit_manifest: Option<&'a Path>,
}

pub fn patch_war3map_j(jfile: &Path, opts: &JassPatchOptions<'_>) -> Result<()> {
    let script = read_jass_script(jfile)?;
    let mut jcontent = script.text;
    let nl = "\r\n";

    println!("  JASS encoding: {}", script.encoding.label());
    println!("  JASS anchors: {}", anchor_summary(&jcontent));

    // 1. Collect declared array globals for JapiForceAllocArrays
    let mut array_globals: Vec<String> = Vec::new();
    if !opts.no_array_prealloc {
        let re_arr = Regex::new(
            r"(?m)^[ \t]*(?:constant[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]+array[ \t]+([A-Za-z_][A-Za-z0-9_]*)",
        )
        .unwrap();
        let mut seen = HashSet::new();
        for caps in re_arr.captures_iter(&jcontent) {
            let name = caps[1].to_string();
            if seen.insert(name.clone()) {
                array_globals.push(name);
            }
        }
    }
    let array_alloc_call = if !array_globals.is_empty() {
        println!("  Array prealloc: {} array globals", array_globals.len());
        format!("    call JapiForceAllocArrays(){}", nl)
    } else {
        String::new()
    };

    // 2. Optional JASS wrappers (-WithJassWrappers)
    let mut jass_wrapper_block = String::new();
    let mut wrapper_probe_call = String::new();
    if opts.with_jass_wrappers {
        let re_fn = Regex::new(r"(?m)^[ \t]*function[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]+takes").unwrap();
        let map_funcs: HashSet<String> = re_fn
            .captures_iter(&jcontent)
            .map(|c| c[1].to_string())
            .collect();
        let gen = wrappers::generate_jass_wrappers(opts.root, opts.explicit_manifest, &map_funcs)?;
        if gen.total_generated == 0 {
            println!(
                "  JASS wrappers: 0 generated ({} map functions already present)",
                map_funcs.len()
            );
        } else {
            println!(
                "  JASS wrappers: {} generated, {} map functions left as-is",
                gen.total_generated,
                map_funcs.len()
            );
            jass_wrapper_block = gen.jass_text;
        }

        let has_ready = Regex::new(r"(?m)^[ \t]*integer[ \t]+udg_lua_wrapper_ready\b")
            .unwrap()
            .is_match(&jcontent);
        let has_probe = Regex::new(r"(?m)^[ \t]*function[ \t]+JapiWrapperProbeActions\b")
            .unwrap()
            .is_match(&jcontent);
        if has_ready && !has_probe {
            wrapper_probe_call = format!(
                "{nl}    set udg_lua_wrapper_ready = 1{nl}    call TimerStart(CreateTimer(), 2.00, false, function JapiWrapperProbeActions)"
            );
            jass_wrapper_block.push_str(&format!(
                "{nl}function JapiWrapperProbeActions takes nothing returns nothing{nl}\
                 \x20   call DestroyTimer(GetExpiredTimer()){nl}\
                 \x20   set udg_lua_wrapper_int = GetGameVersion(){nl}\
                 \x20   set udg_lua_wrapper_hex = Hex(255){nl}\
                 \x20   set udg_lua_wrapper_text = GetPluginVersion(){nl}\
                 \x20   set udg_lua_wrapper_real_base = GetLittleMapX(){nl}\
                 \x20   call SetLittleMapX(udg_lua_wrapper_real_base + 0.01){nl}\
                 \x20   set udg_lua_wrapper_real = GetLittleMapX(){nl}\
                 \x20   call SetLittleMapX(udg_lua_wrapper_real_base){nl}\
                 \x20   set udg_lua_wrapper_bool = GetChatState(){nl}\
                 endfunction{nl}"
            ));
        }
    }

    // 3. Optional GetFuncAddr (-WithGetFuncAddr)
    let mut func_addr_decl = String::new();
    let mut func_addr_block = String::new();
    let mut func_addr_probe_call = String::new();
    if opts.with_get_func_addr {
        let re_nat = Regex::new(r"(?m)^[ \t]*native[ \t]+SetHeroLevels\b").unwrap();
        let nat_matches: Vec<_> = re_nat.find_iter(&jcontent).collect();
        if nat_matches.len() > 1 {
            let lines: Vec<String> = nat_matches
                .iter()
                .map(|m| line_number_from_index(&jcontent, m.start()).to_string())
                .collect();
            bail!(
                "war3map.j declares 'native SetHeroLevels' {} times (lines {}); duplicate declarations are invalid.\n  JASS anchors: {}\n  Base map: {}",
                nat_matches.len(),
                lines.join(", "),
                anchor_summary(&jcontent),
                opts.base_map_display
            );
        }
        let declared_native = !nat_matches.is_empty();
        if declared_native {
            let re_first_fn =
                Regex::new(r"(?m)^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+takes\b").unwrap();
            if let Some(first_fn) = re_first_fn.find(&jcontent) {
                if nat_matches[0].start() > first_fn.start() {
                    bail!(
                        "war3map.j declares 'native SetHeroLevels' at line {}, after the first function at line {}. Move the declaration above every function, or drop --with-get-func-addr.\n  JASS anchors: {}\n  Base map: {}",
                        line_number_from_index(&jcontent, nat_matches[0].start()),
                        line_number_from_index(&jcontent, first_fn.start()),
                        anchor_summary(&jcontent),
                        opts.base_map_display
                    );
                }
            }
        }
        let declared_func = Regex::new(r"(?m)^[ \t]*function[ \t]+GetFuncAddr[ \t]+takes\b")
            .unwrap()
            .is_match(&jcontent);

        if !declared_native {
            func_addr_decl = format!(
                "// japi: engine native that common.j omits; declared here so the map can take a code address.{nl}native SetHeroLevels takes code f returns nothing{nl}{nl}"
            );
        }
        if !declared_func {
            func_addr_block = format!(
                "{nl}function GetFuncAddr takes code f returns integer{nl}\
                 \x20   call SetHeroLevels(f){nl}\
                 \x20   return LoadInteger(japi_ht, japi__key, 0){nl}\
                 endfunction{nl}"
            );
        }
        let has_ready = Regex::new(r"(?m)^[ \t]*integer[ \t]+udg_lua_getfunc_ready\b")
            .unwrap()
            .is_match(&jcontent);
        let has_probe = Regex::new(r"(?m)^[ \t]*function[ \t]+JapiGetFuncAddrProbeActions\b")
            .unwrap()
            .is_match(&jcontent);
        if has_ready && !has_probe {
            func_addr_probe_call = format!(
                "{nl}    call TimerStart(CreateTimer(), 2.20, false, function JapiGetFuncAddrProbeActions)"
            );
            func_addr_block.push_str(&format!(
                "{nl}function JapiGetFuncAddrTarget takes nothing returns nothing{nl}\
                 \x20   set udg_lua_getfunc_hits = udg_lua_getfunc_hits + 1{nl}\
                 endfunction{nl}\
                 function JapiGetFuncAddrTarget2 takes nothing returns nothing{nl}\
                 endfunction{nl}\
                 function JapiGetFuncAddrProbeActions takes nothing returns nothing{nl}\
                 \x20   call DestroyTimer(GetExpiredTimer()){nl}\
                 \x20   if udg_lua_japi_alive != 1 then{nl}\
                 \x20       return{nl}\
                 \x20   endif{nl}\
                 \x20   set udg_lua_getfunc_addr = GetFuncAddr(function JapiGetFuncAddrTarget){nl}\
                 \x20   set udg_lua_getfunc_addr2 = GetFuncAddr(function JapiGetFuncAddrTarget2){nl}\
                 \x20   set udg_lua_getfunc_addr3 = GetFuncAddr(function JapiGetFuncAddrTarget){nl}\
                 \x20   call SaveStr(japi_ht, japi__key, 0, \"(IS)V\"){nl}\
                 \x20   call SaveInteger(japi_ht, japi__key, 1, udg_lua_getfunc_addr){nl}\
                 \x20   call SaveStr(japi_ht, japi__key, 2, \"jass-getfunc-target\"){nl}\
                 \x20   call UnitId(\"func_bind_trigger_name\"){nl}\
                 \x20   call SaveStr(japi_ht, japi__key, 0, \"(I)V\"){nl}\
                 \x20   call SaveInteger(japi_ht, japi__key, 1, udg_lua_getfunc_addr2){nl}\
                 \x20   call UnitId(\"SaveFunc\"){nl}\
                 \x20   set udg_lua_getfunc_ready = 1{nl}\
                 endfunction{nl}"
            ));
        }
        if declared_native && declared_func {
            println!("  GetFuncAddr: map already declares the native and helper, nothing injected");
        } else {
            println!("  GetFuncAddr: SetHeroLevels declaration + GetFuncAddr wrapper injected");
        }
    }

    // 4. Build LoadScript block (idempotent across repacking)
    let array_alloc_for_script = if !array_alloc_call.is_empty()
        && !Regex::new(r"(?m)^[ \t]*call[ \t]+JapiForceAllocArrays\b")
            .unwrap()
            .is_match(&jcontent)
    {
        array_alloc_call.clone()
    } else {
        String::new()
    };
    let wrapper_probe_for_script = if !wrapper_probe_call.is_empty()
        && !Regex::new(r"(?m)^[ \t]*function[ \t]+JapiWrapperProbeActions[ \t]+takes\b")
            .unwrap()
            .is_match(&jcontent)
    {
        wrapper_probe_call.clone()
    } else {
        String::new()
    };
    let getfunc_probe_for_script = if !func_addr_probe_call.is_empty()
        && !Regex::new(r"(?m)^[ \t]*function[ \t]+JapiGetFuncAddrProbeActions[ \t]+takes\b")
            .unwrap()
            .is_match(&jcontent)
    {
        func_addr_probe_call.clone()
    } else {
        String::new()
    };

    let mut load_script_lines = format!(
        "{}    call SaveStr(japi_ht, japi__key, 0, \"()V\"){nl}    call UnitId(\"LoadScript\"){}{}",
        array_alloc_for_script, wrapper_probe_for_script, getfunc_probe_for_script
    );
    if jcontent.contains("function LuaBridgeProbeCall") {
        load_script_lines.push_str(&format!(
            "{nl}    call LuaCallback1(){nl}\
             \x20   set udg_lua_bridge_result = LuaBridgeProbeCall(10, 32){nl}\
             \x20   set udg_lua_error_result = LuaErrorProbeCall(){nl}\
             \x20   set udg_lua_handle_result = LuaHandleProbeCall()"
        ));
    }

    // 5. Optional -TestReboot probe
    let mut reboot_probe_call = String::new();
    if opts.test_reboot {
        if !Regex::new(r"(?m)^[ \t]*call[ \t]+TimerStart[^\r\n]*function[ \t]+JapiRebootProbe\b")
            .unwrap()
            .is_match(&jcontent)
        {
            reboot_probe_call = format!(
                "{nl}    call TimerStart(CreateTimer(), 6.00, false, function JapiRebootProbe)"
            );
            load_script_lines.push_str(&reboot_probe_call);
        }
        let re_main = Regex::new(r"(?m)^[ \t]*function[ \t]+main[ \t]+takes\b").unwrap();
        let Some(main_m) = re_main.find(&jcontent) else {
            bail!(
                "war3map.j has no 'function main takes' for --test-reboot.\n  JASS anchors: {}\n  Base map: {}",
                anchor_summary(&jcontent),
                opts.base_map_display
            );
        };
        if !Regex::new(r"(?m)^[ \t]*function[ \t]+JapiRebootProbe\b")
            .unwrap()
            .is_match(&jcontent)
        {
            let probe_fn = format!(
                "function JapiRebootProbe takes nothing returns nothing{nl}\
                 \x20   call UnitId(\"SimulateMapBoot\"){nl}\
                 endfunction{nl}{nl}"
            );
            let idx = main_m.start();
            jcontent.insert_str(idx, &probe_fn);
        }
    }

    // 6. Inject bootstrap / LoadScript call
    let re_load = Regex::new(r#"(?m)^[ \t]*call[ \t]+UnitId[ \t]*\([ \t]*"LoadScript"[ \t]*\)"#).unwrap();
    let re_init = Regex::new(r"(?m)^[ \t]*call[ \t]+initializePlugin[ \t]*\([ \t]*\)").unwrap();

    let load_matches: Vec<(usize, usize, String)> = re_load
        .find_iter(&jcontent)
        .map(|m| (m.start(), m.end(), m.as_str().to_string()))
        .collect();
    let init_matches: Vec<(usize, usize)> = re_init
        .find_iter(&jcontent)
        .map(|m| (m.start(), m.end()))
        .collect();

    if !load_matches.is_empty() {
        if load_matches.len() > 1 {
            let lines: Vec<String> = load_matches
                .iter()
                .map(|(s, _, _)| line_number_from_index(&jcontent, *s).to_string())
                .collect();
            println!(
                "  WARNING: found {} LoadScript calls (lines {}); patching the first only",
                load_matches.len(),
                lines.join(", ")
            );
        }
        let (s, e, matched_text) = &load_matches[0];
        let before = &array_alloc_for_script;
        let after = format!(
            "{}{}{}",
            wrapper_probe_for_script, getfunc_probe_for_script, reboot_probe_call
        );
        if !before.is_empty() || !after.is_empty() {
            let replacement = format!("{}{}{}", before, matched_text, after);
            jcontent.replace_range(*s..*e, &replacement);
            println!("  Bootstrap: LoadScript anchor present; updated probes/prealloc");
        } else {
            println!("  Bootstrap: LoadScript anchor present, nothing to add");
        }
    } else if !init_matches.is_empty() {
        if init_matches.len() > 1 {
            let lines: Vec<String> = init_matches
                .iter()
                .map(|(s, _)| line_number_from_index(&jcontent, *s).to_string())
                .collect();
            println!(
                "  WARNING: found {} initializePlugin calls (lines {}); patching the first only",
                init_matches.len(),
                lines.join(", ")
            );
        }
        let end = init_matches[0].1;
        jcontent.insert_str(end, &format!("{}{}", nl, load_script_lines));
        println!("  Bootstrap: plugin marker map");
    } else {
        if Regex::new(r"UnitId\s*\(").unwrap().is_match(&jcontent) {
            println!(
                "  WARNING: map already uses UnitId() without LoadScript/initializePlugin; review injected bootstrap"
            );
        }
        jcontent = inject_foreign_bootstrap(&jcontent, &load_script_lines, nl, opts.base_map_display)?;
        println!("  Bootstrap: injected into map main() (foreign map)");
    }

    // 7. Verify JapiForceAllocArrays call exists if arrays exist, then insert helper
    if !array_globals.is_empty() {
        if !Regex::new(r"(?m)^[ \t]*call[ \t]+JapiForceAllocArrays\b")
            .unwrap()
            .is_match(&jcontent)
        {
            bail!(
                "war3map.j declares {} array global(s) but the patched script has no JapiForceAllocArrays() call.\n  JASS anchors: {}\n  Base map: {}",
                array_globals.len(),
                anchor_summary(&jcontent),
                opts.base_map_display
            );
        }
        let mut alloc_body = String::new();
        for arr in &array_globals {
            alloc_body.push_str(&format!("    set {}[8191] = {}[8191]{}", arr, arr, nl));
        }
        let alloc_func = format!(
            "// japi array preallocation injected by japi{nl}\
             function JapiForceAllocArrays takes nothing returns nothing{nl}\
             {}\
             endfunction{nl}{nl}",
            alloc_body
        );
        let re_existing = Regex::new(r"(?ms)^[ \t]*function[ \t]+JapiForceAllocArrays\b.*?^[ \t]*endfunction\b").unwrap();
        if let Some(m) = re_existing.find(&jcontent) {
            let range = m.start()..m.end();
            jcontent.replace_range(range, alloc_func.trim_end());
            println!("  Array prealloc: existing helper refreshed");
        } else {
            let end_g = find_endglobals(&jcontent, opts.base_map_display, "JapiForceAllocArrays")?;
            jcontent.insert_str(end_g, &format!("{nl}{nl}{alloc_func}"));
            println!("  Array prealloc: JapiForceAllocArrays injected");
        }
    }

    // 8. Insert wrapper block right after endglobals
    if !jass_wrapper_block.is_empty() {
        let end_g = find_endglobals(&jcontent, opts.base_map_display, "--with-jass-wrappers")?;
        jcontent.insert_str(end_g, &format!("{nl}{nl}{jass_wrapper_block}"));
        println!("  JASS wrappers: injected after endglobals");
    }

    // 9. Insert GetFuncAddr helper after endglobals
    if !func_addr_block.is_empty() {
        let end_g = find_endglobals(&jcontent, opts.base_map_display, "--with-get-func-addr")?;
        jcontent.insert_str(end_g, &func_addr_block);
        println!("  GetFuncAddr: helper injected after endglobals");
    }

    // 10. Prepend native SetHeroLevels declaration at top of file
    if !func_addr_decl.is_empty() {
        jcontent.insert_str(0, &func_addr_decl);
        println!("  GetFuncAddr: native SetHeroLevels declared at top of war3map.j");
    }

    write_jass_script(jfile, script.encoding, &jcontent)?;
    println!("  JASS anchors after patch: {}", anchor_summary(&jcontent));
    Ok(())
}

fn find_endglobals(content: &str, base_map_display: &str, purpose: &str) -> Result<usize> {
    let re = Regex::new(r"(?m)^[ \t]*endglobals\b").unwrap();
    match re.find(content) {
        Some(m) => Ok(m.end()),
        None => bail!(
            "war3map.j has no top-level 'endglobals' anchor for {}.\n  JASS anchors: {}\n  Base map: {}",
            purpose,
            anchor_summary(content),
            base_map_display
        ),
    }
}

fn inject_foreign_bootstrap(
    content: &str,
    load_script_block: &str,
    nl: &str,
    base_map_display: &str,
) -> Result<String> {
    let mut out = content.to_string();
    let bootstrap = format!(
        "// japi bootstrap injected by japi{nl}\
         function JapiBootstrap takes nothing returns nothing{nl}\
         \x20   call StartCampaignAI(Player(PLAYER_NEUTRAL_AGGRESSIVE), \"callback\"){nl}\
         \x20   call UnitId(I2S(GetHandleId(japi_ht))){nl}\
         {}{nl}\
         endfunction{nl}{nl}",
        load_script_block
    );

    let mut globals_decl = String::new();
    if !Regex::new(r"(?m)^[ \t]*hashtable[ \t]+japi_ht\b")
        .unwrap()
        .is_match(&out)
    {
        globals_decl.push_str(&format!("    hashtable japi_ht = InitHashtable(){}", nl));
    }
    if !Regex::new(r"(?m)^[ \t]*integer[ \t]+japi__key\b")
        .unwrap()
        .is_match(&out)
    {
        globals_decl.push_str(&format!("    integer japi__key = StringHash(\"jass\"){}", nl));
    }

    let re_main = Regex::new(r"(?m)^[ \t]*function[ \t]+main[ \t]+takes\b").unwrap();
    let Some(main_m) = re_main.find(&out) else {
        bail!(
            "war3map.j has no 'function main takes' to bootstrap.\n  JASS anchors: {}\n  Base map: {}",
            anchor_summary(&out),
            base_map_display
        );
    };
    let main_start = main_m.start();
    let re_endfunc = Regex::new(r"(?m)^[ \t]*endfunction\b").unwrap();
    let Some(end_m) = re_endfunc.find(&out[main_start..]) else {
        bail!(
            "war3map.j main() (line {}) has no matching 'endfunction'.\n  JASS anchors: {}\n  Base map: {}",
            line_number_from_index(&out, main_start),
            anchor_summary(&out),
            base_map_display
        );
    };
    let end_func_at = main_start + end_m.start();
    out.insert_str(end_func_at, &format!("    call JapiBootstrap(){}", nl));

    let main_start_2 = re_main.find(&out).unwrap().start();
    out.insert_str(main_start_2, &bootstrap);

    if globals_decl.is_empty() {
        return Ok(out);
    }
    let re_g = Regex::new(r"(?m)^[ \t]*globals\b").unwrap();
    let re_eg = Regex::new(r"(?m)^[ \t]*endglobals\b").unwrap();
    let g = re_g.find(&out);
    let eg = re_eg.find(&out);
    if let Some(gm) = g {
        if eg.is_none() {
            bail!(
                "war3map.j has a 'globals' block (line {}) but no 'endglobals'.\n  JASS anchors: {}\n  Base map: {}",
                line_number_from_index(&out, gm.start()),
                anchor_summary(&out),
                base_map_display
            );
        }
    }
    if let Some(egm) = eg {
        let at = egm.start();
        out.insert_str(at, &globals_decl);
        Ok(out)
    } else {
        Ok(format!("globals{nl}{globals_decl}endglobals{nl}{nl}{out}"))
    }
}

pub fn run_pjass_check(pjass_exe: &Path, w3x2lni_dir: &Path, jfile: &Path) -> Result<()> {
    let common_j = w3x2lni_dir
        .join("data")
        .join("enUS-1.27.1")
        .join("mpq")
        .join("Scripts")
        .join("Common.j");
    let blizzard_j = w3x2lni_dir
        .join("data")
        .join("enUS-1.27.1")
        .join("mpq")
        .join("Scripts")
        .join("Blizzard.j");
    if !pjass_exe.is_file() || !common_j.is_file() || !blizzard_j.is_file() {
        return Ok(());
    }
    let output = Command::new(pjass_exe)
        .arg(&common_j)
        .arg(&blizzard_j)
        .arg(jfile)
        .output()
        .with_context(|| format!("Failed to invoke {}", pjass_exe.display()))?;
    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let has_err = Regex::new(r"(?m)^\s*(Error|error)").unwrap().is_match(&combined);
    if !output.status.success() || has_err {
        let tail: Vec<&str> = combined.lines().rev().take(15).collect();
        for l in tail.into_iter().rev() {
            eprintln!("  {}", l);
        }
        bail!(
            "JASS syntax check failed: {} (pass --skip-jass-check to bypass)",
            jfile.display()
        );
    }
    println!("  JASS syntax check OK");
    Ok(())
}

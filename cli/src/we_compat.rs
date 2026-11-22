use anyhow::{bail, Context, Result};
use std::collections::HashSet;
use std::fs;
use std::path::Path;

/// Custom full-path flag in `war3map.imp` (matches builtin-japi's `war3map.imp`).
/// World Editor preserves files marked 0x0D verbatim without prepending `war3mapImported\`.
pub const IMP_FLAG_CUSTOM_PATH: u8 = 0x0D;

const JAPI_TRIGGER_NAME: &str = "JapiBootstrap";
const JAPI_TRIGGER_DESC: &str =
    "map-inject bootstrap (auto-injected by japi; keep enabled so KKWE/YDWE saves preserve Lua/JAPI)";

pub const JAPI_TRIGGER_SCRIPT: &str = concat!(
    "function Trig_JapiBootstrap_Actions takes nothing returns nothing\r\n",
    "    local hashtable ht = InitHashtable()\r\n",
    "    call StartCampaignAI(Player(PLAYER_NEUTRAL_AGGRESSIVE), \"callback\")\r\n",
    "    call UnitId(I2S(GetHandleId(ht)))\r\n",
    "    call SaveStr(ht, StringHash(\"jass\"), 0, \"()V\")\r\n",
    "    call UnitId(\"LoadScript\")\r\n",
    "endfunction\r\n",
    "\r\n",
    "function InitTrig_JapiBootstrap takes nothing returns nothing\r\n",
    "    set gg_trg_JapiBootstrap = CreateTrigger()\r\n",
    "    call TriggerAddAction(gg_trg_JapiBootstrap, function Trig_JapiBootstrap_Actions)\r\n",
    "endfunction\r\n",
);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImpEntry {
    pub flag: u8,
    pub path: String,
}

impl ImpEntry {
    pub fn effective_path(&self) -> String {
        if self.flag == 0x05 || self.flag == 0x08 {
            format!(r"war3mapImported\{}", self.path)
        } else {
            self.path.clone()
        }
    }
}

pub fn parse_war3map_imp(bytes: &[u8]) -> Result<Vec<ImpEntry>> {
    if bytes.len() < 8 {
        bail!("war3map.imp too short ({} bytes)", bytes.len());
    }
    let version = u32::from_le_bytes(bytes[0..4].try_into().unwrap());
    if version != 1 {
        bail!("Unsupported war3map.imp version {}", version);
    }
    let count = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
    let mut entries = Vec::with_capacity(count);
    let mut pos = 8usize;
    for idx in 0..count {
        if pos >= bytes.len() {
            bail!("Truncated war3map.imp at entry {}", idx);
        }
        let flag = bytes[pos];
        pos += 1;
        let nul = bytes[pos..]
            .iter()
            .position(|&b| b == 0)
            .with_context(|| format!("Unterminated path in war3map.imp entry {}", idx))?;
        let path = String::from_utf8_lossy(&bytes[pos..pos + nul]).into_owned();
        pos += nul + 1;
        entries.push(ImpEntry { flag, path });
    }
    Ok(entries)
}

pub fn serialize_war3map_imp(entries: &[ImpEntry]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + entries.len() * 32);
    out.extend_from_slice(&1u32.to_le_bytes());
    out.extend_from_slice(&(entries.len() as u32).to_le_bytes());
    for e in entries {
        out.push(e.flag);
        out.extend_from_slice(e.path.as_bytes());
        out.push(0);
    }
    out
}

/// Register injected MPQ files in `war3map.imp` (0x0D custom path, preserving all
/// pre-existing map imports) so World Editor / YDWE / KKWE keeps them on save.
/// Returns the number of newly added entries.
pub fn update_war3map_imp(imp_path: &Path, injected: &[String]) -> Result<usize> {
    let mut entries = if imp_path.is_file() {
        let raw = fs::read(imp_path)
            .with_context(|| format!("Failed to read {}", imp_path.display()))?;
        parse_war3map_imp(&raw)?
    } else {
        Vec::new()
    };

    let mut seen: HashSet<String> = entries
        .iter()
        .map(|e| e.effective_path().replace('/', "\\").to_ascii_lowercase())
        .collect();

    let mut added = 0usize;
    for raw_path in injected {
        let norm = raw_path.replace('/', "\\");
        let key = norm.to_ascii_lowercase();
        if seen.insert(key) {
            entries.push(ImpEntry {
                flag: IMP_FLAG_CUSTOM_PATH,
                path: norm,
            });
            added += 1;
        }
    }

    let bytes = serialize_war3map_imp(&entries);
    fs::write(imp_path, bytes)
        .with_context(|| format!("Failed to write {}", imp_path.display()))?;
    Ok(added)
}

fn read_u32(buf: &[u8], pos: &mut usize, ctx: &str) -> Result<u32> {
    if *pos + 4 > buf.len() {
        bail!("Unexpected EOF reading {} at offset {}", ctx, *pos);
    }
    let val = u32::from_le_bytes(buf[*pos..*pos + 4].try_into().unwrap());
    *pos += 4;
    Ok(val)
}

fn skip_cstr(buf: &[u8], pos: &mut usize, ctx: &str) -> Result<()> {
    let nul = buf[*pos..]
        .iter()
        .position(|&b| b == 0)
        .with_context(|| format!("Unterminated C string for {} at offset {}", ctx, *pos))?;
    *pos += nul + 1;
    Ok(())
}

fn contains_subslice(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() {
        return true;
    }
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// Inject a pure-JASS `JapiBootstrap` custom-script trigger into `war3map.wtg` +
/// `war3map.wct` so maps re-saved in World Editor / YDWE / KKWE retain JAPI boot.
///
/// Design:
/// - Preserves every existing trigger byte untouched (never parses YDWE/KKWE ECAs).
/// - Supports both RoC (`wtg` v4 / `wct` v0) and TFT/YDWE/KKWE (`wtg` v7 / `wct` v1).
/// - Idempotent: if `JapiBootstrap` is already present, leaves both files untouched.
/// - Skips cleanly (`Ok(false)`) when `war3map.wtg` does not exist (synthetic maps).
pub fn inject_wtg_wct_bootstrap(work_dir: &Path) -> Result<bool> {
    let wtg_path = work_dir.join("war3map.wtg");
    if !wtg_path.is_file() {
        return Ok(false);
    }
    let wct_path = work_dir.join("war3map.wct");

    let wtg = fs::read(&wtg_path)
        .with_context(|| format!("Failed to read {}", wtg_path.display()))?;
    let wct_existing = if wct_path.is_file() {
        Some(fs::read(&wct_path).with_context(|| format!("Failed to read {}", wct_path.display()))?)
    } else {
        None
    };

    if contains_subslice(&wtg, b"JapiBootstrap\0")
        || wct_existing
            .as_ref()
            .is_some_and(|w| contains_subslice(w, b"InitTrig_JapiBootstrap"))
    {
        return Ok(false);
    }

    if wtg.len() < 12 || &wtg[0..4] != b"WTG!" {
        bail!("Invalid war3map.wtg header in {}", wtg_path.display());
    }

    let mut pos = 4usize;
    let ver = read_u32(&wtg, &mut pos, "wtg version")?;
    if ver != 4 && ver != 7 {
        bail!("Unsupported war3map.wtg version {} (expected 4 or 7)", ver);
    }

    let ncat_off = pos;
    let ncat = read_u32(&wtg, &mut pos, "wtg category count")?;
    let mut first_cat: Option<u32> = None;
    for _ in 0..ncat {
        let cid = read_u32(&wtg, &mut pos, "wtg category id")?;
        skip_cstr(&wtg, &mut pos, "wtg category name")?;
        let is_comment = if ver >= 7 {
            read_u32(&wtg, &mut pos, "wtg category is_comment")?
        } else {
            0
        };
        if first_cat.is_none() && is_comment == 0 {
            first_cat = Some(cid);
        }
    }
    let cat_end = pos;

    let _unk = read_u32(&wtg, &mut pos, "wtg unknown")?;
    let nvar = read_u32(&wtg, &mut pos, "wtg variable count")?;
    for _ in 0..nvar {
        skip_cstr(&wtg, &mut pos, "wtg var name")?;
        skip_cstr(&wtg, &mut pos, "wtg var type")?;
        let _vunk = read_u32(&wtg, &mut pos, "wtg var unk")?;
        let _varr = read_u32(&wtg, &mut pos, "wtg var is_array")?;
        let _vsz = read_u32(&wtg, &mut pos, "wtg var array_size")?;
        let _vinit = read_u32(&wtg, &mut pos, "wtg var is_init")?;
        skip_cstr(&wtg, &mut pos, "wtg var initial_value")?;
    }

    let ntrig_off = pos;
    let old_ntrig = read_u32(&wtg, &mut pos, "wtg trigger count")?;

    // If the map has zero non-comment categories, insert a "JAPI" category (id 0).
    let (target_cat_id, insert_cat) = match first_cat {
        Some(cid) => (cid, false),
        None => (0u32, true),
    };

    // Build updated war3map.wtg
    let mut new_wtg = Vec::with_capacity(wtg.len() + 192);
    if insert_cat {
        new_wtg.extend_from_slice(&wtg[..ncat_off]);
        new_wtg.extend_from_slice(&(ncat + 1).to_le_bytes());
        new_wtg.extend_from_slice(&wtg[ncat_off + 4..cat_end]);
        new_wtg.extend_from_slice(&0u32.to_le_bytes());
        new_wtg.extend_from_slice(b"JAPI\0");
        if ver >= 7 {
            new_wtg.extend_from_slice(&0u32.to_le_bytes());
        }
        new_wtg.extend_from_slice(&wtg[cat_end..ntrig_off]);
    } else {
        new_wtg.extend_from_slice(&wtg[..ntrig_off]);
    }
    new_wtg.extend_from_slice(&(old_ntrig + 1).to_le_bytes());
    new_wtg.extend_from_slice(&wtg[ntrig_off + 4..]);

    // Append custom-script trigger record at EOF
    new_wtg.extend_from_slice(JAPI_TRIGGER_NAME.as_bytes());
    new_wtg.push(0);
    new_wtg.extend_from_slice(JAPI_TRIGGER_DESC.as_bytes());
    new_wtg.push(0);
    if ver >= 7 {
        new_wtg.extend_from_slice(&0u32.to_le_bytes()); // is_comment = 0
    }
    new_wtg.extend_from_slice(&1u32.to_le_bytes()); // is_enabled = 1
    new_wtg.extend_from_slice(&1u32.to_le_bytes()); // is_custom_script = 1
    new_wtg.extend_from_slice(&0u32.to_le_bytes()); // is_initially_off = 0
    new_wtg.extend_from_slice(&1u32.to_le_bytes()); // run_on_map_init = 1
    new_wtg.extend_from_slice(&target_cat_id.to_le_bytes()); // category_id
    new_wtg.extend_from_slice(&0u32.to_le_bytes()); // num_ecas = 0

    // Build updated war3map.wct
    let script_bytes = JAPI_TRIGGER_SCRIPT.as_bytes();
    let script_len_with_nul = (script_bytes.len() + 1) as u32;

    let new_wct = if let Some(wct) = wct_existing {
        let mut wpos = 0usize;
        let wver = read_u32(&wct, &mut wpos, "wct version")?;
        if wver == 1 {
            skip_cstr(&wct, &mut wpos, "wct header comment")?;
            let hsz = read_u32(&wct, &mut wpos, "wct header code size")? as usize;
            if wpos + hsz > wct.len() {
                bail!("Truncated war3map.wct header code");
            }
            wpos += hsz;
        } else if wver != 0 {
            bail!("Unsupported war3map.wct version {} (expected 0 or 1)", wver);
        }
        let wcnt_off = wpos;
        let wcnt = read_u32(&wct, &mut wpos, "wct trigger count")?;
        if wcnt != old_ntrig {
            bail!(
                "war3map.wtg trigger count ({}) != war3map.wct count ({}); refusing to corrupt triggers",
                old_ntrig,
                wcnt
            );
        }
        let mut out = Vec::with_capacity(wct.len() + script_bytes.len() + 8);
        out.extend_from_slice(&wct[..wcnt_off]);
        out.extend_from_slice(&(wcnt + 1).to_le_bytes());
        out.extend_from_slice(&wct[wcnt_off + 4..]);
        out.extend_from_slice(&script_len_with_nul.to_le_bytes());
        out.extend_from_slice(script_bytes);
        out.push(0);
        out
    } else {
        let mut out = Vec::with_capacity(64 + (old_ntrig as usize) * 4 + script_bytes.len());
        out.extend_from_slice(&1u32.to_le_bytes()); // TFT version 1
        out.push(0); // empty header comment
        out.extend_from_slice(&0u32.to_le_bytes()); // empty header code
        out.extend_from_slice(&(old_ntrig + 1).to_le_bytes());
        for _ in 0..old_ntrig {
            out.extend_from_slice(&0u32.to_le_bytes());
        }
        out.extend_from_slice(&script_len_with_nul.to_le_bytes());
        out.extend_from_slice(script_bytes);
        out.push(0);
        out
    };

    fs::write(&wtg_path, &new_wtg)
        .with_context(|| format!("Failed to write {}", wtg_path.display()))?;
    fs::write(&wct_path, &new_wct)
        .with_context(|| format!("Failed to write {}", wct_path.display()))?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imp_matches_builtin_japi_binary_format() {
        let bytes = serialize_war3map_imp(&[
            ImpEntry {
                flag: IMP_FLAG_CUSTOM_PATH,
                path: "callback".into(),
            },
            ImpEntry {
                flag: IMP_FLAG_CUSTOM_PATH,
                path: "wenhao_plugin.tga".into(),
            },
        ]);
        let expected: &[u8] = &[
            0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x0D, b'c', b'a', b'l', b'l', b'b',
            b'a', b'c', b'k', 0x00, 0x0D, b'w', b'e', b'n', b'h', b'a', b'o', b'_', b'p', b'l',
            b'u', b'g', b'i', b'n', b'.', b't', b'g', b'a', 0x00,
        ];
        assert_eq!(bytes, expected);
        let parsed = parse_war3map_imp(&bytes).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].path, "callback");
        assert_eq!(parsed[1].path, "wenhao_plugin.tga");
    }

    #[test]
    fn imp_merges_and_is_idempotent() {
        let dir = std::env::temp_dir().join(format!("japi-imp-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let imp = dir.join("war3map.imp");

        // Pre-existing standard WE import (0x05 -> war3mapImported\foo.blp)
        let pre = serialize_war3map_imp(&[ImpEntry {
            flag: 0x05,
            path: "foo.blp".into(),
        }]);
        fs::write(&imp, pre).unwrap();

        let needed = vec![
            "callback".to_string(),
            "japi.tga".to_string(),
            r"script\war3map.lua".to_string(),
        ];
        assert_eq!(update_war3map_imp(&imp, &needed).unwrap(), 3);
        assert_eq!(update_war3map_imp(&imp, &needed).unwrap(), 0);

        let entries = parse_war3map_imp(&fs::read(&imp).unwrap()).unwrap();
        assert_eq!(entries.len(), 4);
        assert_eq!(entries[0].flag, 0x05);
        assert_eq!(entries[0].path, "foo.blp");
        assert_eq!(entries[1].flag, IMP_FLAG_CUSTOM_PATH);
        assert_eq!(entries[1].path, "callback");
        assert_eq!(entries[3].path, r"script\war3map.lua");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn wtg_wct_v7_injection_is_exact_and_idempotent() {
        let dir = std::env::temp_dir().join(format!("japi-wtg-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        // Minimal v7 WTG with 1 category, 1 variable, 0 triggers
        let mut wtg = Vec::new();
        wtg.extend_from_slice(b"WTG!");
        wtg.extend_from_slice(&7u32.to_le_bytes());
        wtg.extend_from_slice(&1u32.to_le_bytes()); // ncat
        wtg.extend_from_slice(&0u32.to_le_bytes()); // cid
        wtg.extend_from_slice(b"Init\0");
        wtg.extend_from_slice(&0u32.to_le_bytes()); // is_comment
        wtg.extend_from_slice(&2u32.to_le_bytes()); // unk
        wtg.extend_from_slice(&1u32.to_le_bytes()); // nvar
        wtg.extend_from_slice(b"foo\0integer\0");
        wtg.extend_from_slice(&1u32.to_le_bytes()); // vunk
        wtg.extend_from_slice(&0u32.to_le_bytes()); // is_array
        wtg.extend_from_slice(&1u32.to_le_bytes()); // array_size
        wtg.extend_from_slice(&0u32.to_le_bytes()); // is_init
        wtg.extend_from_slice(b"\0");
        wtg.extend_from_slice(&0u32.to_le_bytes()); // ntrig = 0

        let mut wct = Vec::new();
        wct.extend_from_slice(&1u32.to_le_bytes()); // ver 1
        wct.push(0); // empty comment
        wct.extend_from_slice(&0u32.to_le_bytes()); // empty header code
        wct.extend_from_slice(&0u32.to_le_bytes()); // count = 0

        fs::write(dir.join("war3map.wtg"), &wtg).unwrap();
        fs::write(dir.join("war3map.wct"), &wct).unwrap();

        assert!(inject_wtg_wct_bootstrap(&dir).unwrap());
        assert!(!inject_wtg_wct_bootstrap(&dir).unwrap());

        let out_wtg = fs::read(dir.join("war3map.wtg")).unwrap();
        let out_wct = fs::read(dir.join("war3map.wct")).unwrap();
        assert!(contains_subslice(&out_wtg, b"JapiBootstrap\0"));
        assert!(contains_subslice(&out_wct, b"InitTrig_JapiBootstrap"));
        // wct count at offset 9 should be 1
        assert_eq!(u32::from_le_bytes(out_wct[9..13].try_into().unwrap()), 1);
        assert_eq!(*out_wct.last().unwrap(), 0);

        let _ = fs::remove_dir_all(&dir);
    }
}

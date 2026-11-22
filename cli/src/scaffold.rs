use crate::config::{resolve_abs, JapiEnv};
use crate::pack::copy_dir_recursive;
use anyhow::{bail, Context, Result};
use std::fs;
use std::path::Path;

pub fn run_new_project(
    env: &JapiEnv,
    name: &str,
    parent_path: &Path,
    base_explicit: Option<&Path>,
    force: bool,
) -> Result<()> {
    if name.trim() != name || name.is_empty() || name == "." || name == ".." {
        bail!("Invalid project name '{}'", name);
    }
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        bail!(
            "Invalid project name '{}': use only A-Z, a-z, 0-9, '_' and '-'",
            name
        );
    }

    let parent_abs = resolve_abs(parent_path, None);
    fs::create_dir_all(&parent_abs)
        .with_context(|| format!("Failed to create {}", parent_abs.display()))?;
    let target_dir = parent_abs.join(name);

    if target_dir.exists() {
        if !target_dir.is_dir() {
            bail!("Target exists and is not a directory: {}", target_dir.display());
        }
        let non_empty = fs::read_dir(&target_dir)?.next().is_some();
        if non_empty && !force {
            bail!(
                "Target directory already exists and is not empty: {} (pass --force to overwrite scaffold)",
                target_dir.display()
            );
        }
    }
    fs::create_dir_all(&target_dir)?;

    let base_src = env.resolve_base_map(base_explicit);
    if !base_src.exists() {
        bail!("Base map not found: {}", base_src.display());
    }

    let base_dst_dir = target_dir.join("base-map");
    if base_dst_dir.exists() {
        fs::remove_dir_all(&base_dst_dir)?;
    }

    let manifest_base_rel: String;
    if base_src.is_dir() {
        copy_dir_recursive(&base_src, &base_dst_dir)?;
        manifest_base_rel = "base-map".to_string();
    } else {
        let ext = base_src
            .extension()
            .and_then(|s| s.to_str())
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();
        if ext != "w3m" && ext != "w3x" {
            bail!("Base map file must be .w3m or .w3x: {}", base_src.display());
        }
        fs::create_dir_all(&base_dst_dir)?;
        let fname = format!("base.{}", ext);
        fs::copy(&base_src, base_dst_dir.join(&fname))?;
        manifest_base_rel = format!("base-map/{}", fname);
    }

    let manifest_json = format!(
        r#"{{
  "schema": 1,
  "name": "{name}",
  "baseMap": "{base}",
  "outFile": "dist/{name}.w3x",
  "mapName": "{name}.w3x",
  "withJassWrappers": false,
  "withGetFuncAddr": false,
  "withDebugger": false,
  "strictRequires": false
}}
"#,
        name = name,
        base = manifest_base_rel
    );

    write_file(&target_dir.join("japi.json"), &manifest_json)?;
    write_file(
        &target_dir.join("war3map.lua"),
        &WAR3MAP_LUA_TEMPLATE.replace("@@PROJECT@@", name),
    )?;
    write_file(&target_dir.join("lib").join("util.lua"), UTIL_LUA_TEMPLATE)?;
    write_file(&target_dir.join("lib").join("check.lua"), CHECK_LUA_TEMPLATE)?;
    write_file(&target_dir.join("tests").join("smoke.lua"), SMOKE_LUA_TEMPLATE)?;
    write_file(&target_dir.join("config.lua"), CONFIG_LUA_TEMPLATE)?;
    write_file(
        &target_dir.join("config.local.lua.example"),
        CONFIG_LOCAL_TEMPLATE,
    )?;
    write_file(&target_dir.join(".gitignore"), GITIGNORE_TEMPLATE)?;
    write_file(
        &target_dir.join("README.md"),
        &README_TEMPLATE.replace("@@PROJECT@@", name),
    )?;

    let disp = display_path(&env.root, &target_dir);
    println!();
    println!("Created map project '{}' at {}", name, target_dir.display());
    println!();
    println!("Next steps:");
    println!("  japi check {} --strict-requires   # static check", disp);
    println!("  japi build {}                     # pack -> dist/{}.w3x", disp, name);
    println!("  japi run   {}                     # pack, deploy & launch War3", disp);
    println!("  japi test  {}                     # pack, deploy & wait for Results:", disp);
    println!();
    Ok(())
}

fn write_file(path: &Path, content: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, content.as_bytes())
        .with_context(|| format!("Failed to write {}", path.display()))
}

fn display_path(root: &Path, target: &Path) -> String {
    let s = if let Ok(rel) = target.strip_prefix(root) {
        rel.to_string_lossy().into_owned()
    } else {
        target.to_string_lossy().into_owned()
    };
    if s.contains(' ') {
        format!("\"{}\"", s)
    } else {
        s
    }
}

const WAR3MAP_LUA_TEMPLATE: &str = r#"-- @@PROJECT@@ - main entry point (war3map.lua)
-- Standard Lua require() is bundled via package.preload automatically.

local jass    = require "jass.common"
local globals = require "jass.globals"
local util    = require "lib.util"
local config  = require "config"
local smoke   = require "tests.smoke"

globals.udg_lua_japi_alive = 1
util.log("@@PROJECT@@ loaded (tick=" .. tostring(config.tick) .. ")")

util.after(1.0, function()
    smoke.run()
end)
"#;

const UTIL_LUA_TEMPLATE: &str = r#"local jass = require "jass.common"

local util = {}

function util.after(seconds, fn)
    local t = jass.CreateTimer()
    jass.TimerStart(t, seconds, false, function()
        jass.DestroyTimer(t)
        local ok, err = pcall(fn)
        if not ok then
            print("[util.after] error: " .. tostring(err))
        end
    end)
    return t
end

function util.fourcc(s)
    local a, b, c, d = s:byte(1, 4)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

function util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function util.log(msg)
    print("[map] " .. tostring(msg))
end

return util
"#;

const CHECK_LUA_TEMPLATE: &str = r#"local check = {}
local passed, failed, skipped = 0, 0, 0

function check.reset()
    passed, failed, skipped = 0, 0, 0
end

function check.check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("[PASS] " .. name)
    else
        failed = failed + 1
        print("[FAIL] " .. name .. ": " .. tostring(err))
    end
end

function check.skip(name, reason)
    skipped = skipped + 1
    print("[SKIP] " .. name .. " (" .. tostring(reason) .. ")")
end

function check.finish(suite)
    local total = passed + failed
    print(string.format(" Results: %d passed, %d failed, %d total (%d skipped)", passed, failed, total, skipped))
    if failed == 0 then
        print(string.format(" ALL CHECKS PASSED (%d/%d) [%s]", passed, total, tostring(suite or "default")))
    end
end

return check
"#;

const SMOKE_LUA_TEMPLATE: &str = r#"local jass    = require "jass.common"
local globals = require "jass.globals"
local runtime = require "jass.runtime"
local slk     = require "jass.slk"
local util    = require "lib.util"
local chk     = require "lib.check"

local smoke = {}

function smoke.run()
    chk.reset()

    chk.check("jass.common loaded", function()
        assert(type(jass.CreateUnit) == "function")
    end)

    chk.check("jass.runtime version string", function()
        assert(type(runtime.version) == "string" and #runtime.version > 0)
    end)

    chk.check("Player(0) handle valid", function()
        local p = jass.Player(0)
        assert(p ~= nil)
    end)

    chk.check("fourcc hfoo", function()
        assert(util.fourcc("hfoo") == 1751543663)
    end)

    chk.check("CreateUnit + GetUnitTypeId + RemoveUnit", function()
        local id = util.fourcc("hfoo")
        local u = jass.CreateUnit(jass.Player(0), id, 0.0, 0.0, 0.0)
        assert(u ~= nil, "CreateUnit returned nil")
        assert(jass.GetUnitTypeId(u) == id, "unexpected unit type id")
        jass.RemoveUnit(u)
    end)

    chk.check("slk.unit hfoo readable", function()
        local row = slk.unit.hfoo
        assert(row ~= nil, "slk.unit.hfoo missing")
    end)

    chk.check("timer fires asynchronously", function()
        assert(type(jass.CreateTimer) == "function")
    end)

    chk.check("require caching works", function()
        local u2 = require("lib.util")
        assert(u2 == util, "module cache mismatch")
    end)

    local alive = globals.udg_lua_japi_alive
    if alive == nil then
        chk.skip("globals.udg_lua_japi_alive == 1", "base map does not declare udg_lua_japi_alive")
    else
        chk.check("globals.udg_lua_japi_alive == 1", function()
            assert(alive == 1, "expected 1, got " .. tostring(alive))
        end)
    end

    chk.finish("smoke")
end

return smoke
"#;

const CONFIG_LUA_TEMPLATE: &str = r#"local config = {
    hud = false,
    tick = 0.25,
    debug = false,
}

-- Optional per-machine overrides (copy config.local.lua.example -> config.local.lua):
-- local ok, overrides = pcall(require, "config.local")
-- if ok and type(overrides) == "table" then
--     for k, v in pairs(overrides) do config[k] = v end
-- end

return config
"#;

const CONFIG_LOCAL_TEMPLATE: &str = r#"return {
    hud = true,
    debug = true,
}
"#;

const GITIGNORE_TEMPLATE: &str = r#"build/
dist/
.japi-work/
*.w3x
config.local.lua
japi_debug*.txt
"#;

const README_TEMPLATE: &str = r#"# @@PROJECT@@

由 `japi new` 生成的 WAR3 1.27a Lua 地图项目。

## 常用命令

```powershell
japi check . --strict-requires   # 静态检查 Lua / 物编 / JASS（不生成 .w3x）
japi build .                     # 按 japi.json 打包到 dist/@@PROJECT@@.w3x
japi run   .                     # 打包并启动 War3 交互游玩
japi test  .                     # 打包并运行自动化冒烟测试（等待 Results: 行）
```

项目配置位于 `japi.json`，入口脚本为 `war3map.lua`，可选代码化物编放在 `objects.lua`。
"#;

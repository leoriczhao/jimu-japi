-- ============================================================
-- 示例 07 · 查游戏数据表（jass.slk）
-- 编号      : 07-slk
-- 用途      : 用 jass.slk 惰性表查 ability / unit / item / buff / upgrade /
--             destructable / doodad 的 SLK 行，替代手写一堆 if 判断。
--             典型用法：按技能 id 查代码、按单位 id 查种族/生命值。
-- 需要的开关: 无
-- 前置条件  : 空地图（SLK 数据来自游戏本体，不需要地图里有对应对象）
-- 预期日志  : 若干 [PASS] 行，末尾一行 Results 行且 failed 为 0（本示例 5 项）
-- 验证状态  : 2026-11-16 静态 + 打包验证通过（tools\verify-examples.ps1）
-- ============================================================

-- ============ 以下这段可以粘进自己的 war3map.lua ============

local jass = require "jass.common"
local slk = require "jass.slk"

-- slk.<表名>[<4 字符 id>] 返回一行（table），字段名与 SLK 列名一致（小写）。
-- 表是惰性的：第一次访问某张表时才解析并缓存，之后 rawget(slk, "表名") 就是缓存。
local function describe_ability(ability_id)
    local row = slk.ability[ability_id]
    if row == nil then
        return nil
    end
    print(string.format("[example 07] ability %s: code=%s, name=%s",
        ability_id, tostring(row.code), tostring(row.name)))
    return row
end

local function unit_race(unit_id)
    local row = slk.unit[unit_id]
    return row and row.race or nil
end

describe_ability("AHbz")          -- 暴风雪（Archmage）
print("[example 07] hpea race = " .. tostring(unit_race("hpea")))

-- ============ 以下为示例自检，粘到自己地图时可以删掉 ============

-- 自检 harness：输出约定与 map/game/demo.lua 一致（[PASS]/[FAIL] + 一行 Results）。
local pass, fail = 0, 0

local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("  [PASS] " .. name)
    else
        fail = fail + 1
        print("  [FAIL] " .. name .. " : " .. tostring(err))
    end
end

local function finish()
    print("")
    print("========================================")
    print(string.format(" Results: %d passed, %d failed, %d total", pass, fail, pass + fail))
    print("========================================")
end

local ROW_MIN = 10

local function count_rows(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

check("七张 SLK 表都能取到", function()
    for _, name in ipairs({ "ability", "unit", "item", "buff", "upgrade", "destructable", "doodad" }) do
        assert(type(slk[name]) == "table", name .. " 不是 table")
    end
end)

check("ability 行数足够（>=" .. ROW_MIN .. "）", function()
    local n = count_rows(slk.ability)
    assert(n >= ROW_MIN, "行数 " .. tostring(n))
end)

check("按 id 取技能行，字段 code 可读", function()
    local row = slk.ability["AHbz"]
    assert(type(row) == "table", "AHbz 行缺失")
    assert(row.code == "AHbz", "code = " .. tostring(row.code))
end)

check("按 id 取单位行，字段 race 可读", function()
    local row = slk.unit["hpea"]
    assert(type(row) == "table", "hpea 行缺失")
    assert(row.race == "human", "race = " .. tostring(row.race))
end)

check("第二次访问命中缓存（rawget 可见）", function()
    local cached = rawget(slk, "ability")
    assert(type(cached) == "table", "rawget(slk, 'ability') 为 nil，说明没有缓存")
    assert(cached == slk.ability, "缓存表与 slk.ability 不是同一个 table")
end)

local finish_timer = jass.CreateTimer()
jass.TimerStart(finish_timer, 3.8, false, function()
    jass.DestroyTimer(finish_timer)
    finish()
end)

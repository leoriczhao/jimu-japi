# 一致性测试台（conformance suite）

一个**独立的最小地图**：不依赖 `map\` 的 demo，也不用任何移植层 shim，只用引擎本身。
它把「引擎到底实现了什么」变成**一张会失败的表格** —— 改一处引擎、跑一局、看断言，
而不是改一处、进游戏、靠人眼看画面。

- 每行一个断言：`[PASS]` / `[FAIL]` / `[SKIP]`；已知缺口显式 `[SKIP]` 并写原因，绝不静默跳过；
- 末尾两行机器可读：

```
 Conformance: 199 passed, 0 failed, 4 skipped
 Results: 199 passed, 0 failed, 199 total      <- tools\deploy.ps1 用这一行判定
```

## 当前结果（2026-11-17）

```
 Conformance: 199 passed, 0 failed, 4 skipped
 Results: 199 passed, 0 failed, 199 total
 deploy exit: 0
```

被测 DLL：`src\build\bin\Release\yd_japi.dll`，640000 B，
SHA256 `F2C6EB0849D07FF6ACAA97FEAB854BB58AD950014F7DC7BD0B83EA662B7EE9E4`（cmake Win32 Release 构建）。

4 条 `[SKIP]` 都需要本测试台给不了的东西（D3D 代理才能拿到的地图坐标、夹具物品、`EXPauseUnit` 的游戏侧相关性），
每条都打印原因；断言名和原因一起进日志，所以「为什么跳过」不会随时间丢失。

## 它抓到的引擎缺陷

| 缺陷 | 症状 | 根因 | 处置 |
|---|---|---|---|
| bridge 字符串返回 ABI | 所有 EX* 字符串 getter 返回垃圾：读 `AHbz` 的提示得到 `playerevent` / `unitevent`，`EXSetAbilityDataString` 写进去再读回是别的字符串 | `jass::create_string()` 返回的是 **JASS 字符串句柄索引**（实测 `create_string("Blizzard") == 0x30`），必须 `vm->string_table->get(idx)` 拿到节点再 `jass::from_string()`；原实现按「`>=0x10000` 当句柄、否则当脚本 string id」猜，小值全走错 | `src/src/lua_engine/lua_engine/bridge_dispatch.cpp` 新增 `resolve_string_result()`（句柄表优先、脚本 string id 回落且检查 `reverse_table::size`），D6 两条转 `[PASS]` |
| 39 个声明 native 是死代码 | `jass.japi.EXGetUnitAbility` 等全是 `nil`，`EXGet/SetAbilityData*`、`EXDisplayChat` 一类接口在游戏里根本不存在 | `initialize_ex_natives()` 只 `register_cpp_handler`，从没调用各模块的 `Initialize*()`，里面那些 `jass::japi_add` 从未执行 | 新增 `register_real_ex_natives()` 让 39 个 `jass::japi_add` 名字注册为**真 JASS native**（同时 `jass.japi` 保留 `push_cpp_handler` 回落，`-WithJassWrappers` 仍 125/125 没撞名） |

顺带把两个假警报钉死，避免以后重复排查：

- **不是** `EXGetUnitAbility` 的字节序问题：`EXGetAbilityId` 返回的大端 fourcc 与 JASS 一致；当时失败是夹具往步兵加 `AInv`（物品栏技能）返回 false 没加上。
- **不是** `ability_ui` 布局问题：`ability_ptr+0x54 → ability_data=ui_+0x28` 定位到的就是游戏读的表，`[PASS]` 之后仍保留两行 `[PROBE]` 信息输出（`203=暴风雪 / 204=…\BTNBlizzard.blp / 215=暴风雪(|cffffcc00B|r) - [|cffffcc00等级 1|r] / 218=召唤出6次的冰片…`）。

## 运行

```powershell
# 语法校验 -> 独占 war3 -> 打包部署 -> 打印断言与两行汇总（约 2-4 分钟）
powershell -NoProfile -ExecutionPolicy Bypass -File tests\conformance\run.ps1

# 慢机器 / 自己管进程
... -Timeout 300
... -NoKill
```

只看包不含游戏（静态）：

```powershell
node tests\conformance\gen-manifest.mjs                     # 刷新 manifest.lua
tools\w3x2lni\bin\w3x2lni-lua.exe tests\conformance\check-syntax.lua tests\conformance\war3map.lua
tools\pack.ps1 -MapDir tests\conformance -WorkDir build\scratch\conf -OutFile build\conformance.w3x
```

## 目录

| 文件 | 作用 |
|---|---|
| `war3map.lua` | 测试本体：夹具（步兵 `hfoo` + 英雄技能 `AHbz`）+ 分组断言 + 收尾打印 |
| `manifest.lua` | **生成物**：`gen-manifest.mjs` 从 `src/` 抽出的注册表快照（`bridge` = 可被 Lua 调用的 handler，`declared` = `jass::japi_add` 声明的 native） |
| `gen-manifest.mjs` | 生成器：扫 `register_cpp_handler("Name","(spec)")`、`libs_message.cpp` 的 `reg("Name","(spec)")` 与 `jass::japi_add(..., "Name", "(spec)")`；D3D proxy 的条件注册有意排除 |
| `check-syntax.lua` | `w3x2lni-lua` 的通用 `loadfile` 校验 |
| `run.ps1` | 校验 + 部署 + 过滤断言输出 |

## 断言分组

| 组 | 内容 | 失败意味着什么 |
|---|---|---|
| A | 15 个 `jass.*` 模块可 `require`（含 2026-11-17 补成真实现的 `jass.console` / `jass.log` / `jass.bignum`） | 引擎 `package.preload` 少注册了模块 |
| B | `jass.common` 基础 native 与 JASS 常量回落 | 基础调用通道坏了（外部脚本全靠它） |
| C | `manifest.bridge` 里每个 handler 在 `jass.japi` 上可调用（一条一行） | `push_cpp_handler` 回落通道漏了某个名字 |
| D | 按 spec 的 ret 字符校验返回类型（`R` 数字 / `S` 字符串 / `B` 布尔） | bridge ABI 把字符串/实数推错了 |
| E | Set→Get 往返：`EXSetUnitState`、`EXSetUnitFacing`、`EXPauseUnit`、`EXSetAbilityDataInteger/Real/String`、`EXSetAbilityString`、`EXGetAbilityId`、`EXGetUnitAbilityByIndex` | 写进去了读不回来 |
| J | 真 JASS native 注册（`EXGetUnitAbility` / `EXGetAbilityDataReal` / `EXSetAbilityDataString` / `EXDisplayChat` / `Hex` / `GetMapName`）、`jass.japi` 仍走 bridge、JASS 级派发（`EXGetUnitAbility -> EXGetAbilityId`、字符串返回 `Hex`） | `register_real_ex_natives()` 没生效，或真 native 与 bridge 抢了同一个名字 |
| K | `jass.console`（`enable` 读写回环、`write` 多参数）与 `jass.log`（`path` 自动补尾部分隔符、`info`/`error` 真写文件、保留 builtin-japi 的 `warnning` 拼写） | 两个模块退化成空壳，日志不再落盘 |
| L | `jass.bignum`：`modpow` 小案例 + 256 位模数（2^255-19）、`bin`、`sha1` 标准向量（`"abc"` / 空串）、`sha1 -> bin -> new -> tostring` 往返 | 大数/哈希实现与标准不符 |
| M | setter 的谓词语义：`EXSetAbilityString` / `EXSetUnitState` / `EXPauseUnit` 返回 `true` | bridge 的 `V` 声明把返回值吞了，Lua 侧拿到 `nil` |
| N | `jass.japi.info/counts` 的活注册表诊断（三张表归属、routes、effective spec、运行时 Lua handler、未知名字/参数校验、manifest 逐条一致、D3D 条件表面不虚报、诊断保留名）与显式清理（`hook.unhook` 返回值 / `hook[name]=nil`、texture event 回调按 owner 释放、`texture_destroy` 计数、执行中的 hook 不可卸载、卸载后 orig 安全报错） | 诊断与真实注册表漂移，或移除事件/hook 后回调仍被强引用 |
| F | slk 各表 + `slk.unit["hfoo"]` + `slk.destructable[整数 rawcode]` + `slk.misc` | 外部地图物编查不到（`libs_slk` 的整表加载/回退坏了） |
| G | `jass.message` 的 8 个成员存在 + `hook` 的读写回环 | 输入/命令链路的表结构变了 |
| H | `storm.has` / `storm.load` 读 `war3map.w3e` | MPQ 只读通道坏了 |
| I | 外部 YDWE 谱系图的 16 个 EX 使用点最小复现（只断言可调用不抛异常） | 上游某个使用点在引擎上直接报错 |

## 加一个用例

1. 需要调用新的 handler？先 `node tests\conformance\gen-manifest.mjs`，C 组会自动多一行；
2. 需要新的语义断言？在 `war3map.lua` 对应分组里加 `check("名字", function() ... end)`；
   已知缺口用 `skip("名字", "原因")`，原因里写清楚缺什么夹具；
3. 改完先跑 `check-syntax.lua`，再跑 `run.ps1`。

## 打包诊断回归（不启动游戏）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/tools/pack-diagnostics.ps1
```

验证实际输出与 Lua 执行结果，共 13 项，测试目录在结束时自动删除。动态 `require` 或自定义加载器不属于完整静态解析范围。

## 边界

- 只验证**接口与数据语义**，不验证「玩家看得见的效果」（蓝量、伤害、特效计数）—— 那需要用真实地图驱动实机输入；
- 只在本机 1.27a + 本地构建的 `yd_japi.dll` 上验证；
- `manifest.lua` 是生成物，改引擎后必须重新生成，否则 C 组会与真实注册表漂移。

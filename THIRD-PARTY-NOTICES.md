# Third-Party Notices & Open-Source License Compliance

本文件梳理 `map-inject` 仓库及所构建的开发者 SDK 包中引用、提取、内嵌或随包分发的全部第三方开源组件与非开源依赖，明确其上游来源、许可证类型及对外开源分发时的合规义务。

---

## 1. 核心合规提示（对外公开分发前必读）

1. **`yd_japi.dll`（及打包进地图的 `japi.tga`）包含源自 YDWE（GNU GPL v3.0）的衍生代码**：
   - `src/src/yd_core/`、`src/src/base/`、`src/src/slk/`、`src/src/lua_engine/`、`src/src/extensions/ex_natives/` 中的部分源码，以及 `src/src/image/pas_button_data.h`（复制自 `YDWE/Development/Plugin/Warcraft3/yd_jass_api/PasButton.h`），均提取或改编自 **YDWE**（许可证：**GNU General Public License v3.0**）。
   - 根据 **GPL-3.0 §5 & §6**：只要对外公开分发 `yd_japi.dll` / `japi.tga` 的源码或二进制，该 DLL 整体及其对应源码（Corresponding Source）必须遵循 **GPL-3.0** 协议公开，并保留版权声明、修改说明与 GPL-3.0 文本。
   - 独立进程/独立作品（例如纯原创的 Rust CLI `japi.exe`、纯 Lua 编写的 `std/` 标准库、`docs/` 文档）在 GPL-3.0 §5 下属于聚合（aggregate）中的独立部分，可单独采用宽松协议（如 MIT），不因与 `yd_japi.dll` 同包存放而改变其自身许可。
2. **`vendor/w3x2lni/`（GNU GPL v3.0）**：
   - `w3x2lni` 作为独立命令行子进程被 `japi.exe` 调用，不与 `japi.exe` 静态或动态链接。
   - 若 SDK 发行包随附 `vendor/w3x2lni/` 二进制（默认开启；可用 `--no-vendor` 排除），须保留其 `LICENSE.txt`（GPL-3.0），并向接收者指明对应上游源码位置（`https://github.com/sumneko/w3x2lni`，当前锁定版本 `2.7.4`）。
3. **Microsoft `D3DX9_42.dll`（专有闭源运行时，非开源软件）**：
   - `src/CMakeLists.txt` 支持在本地构建时通过 `-DJAPI_D3DX9_42_DLL=<path>` 将微软 `D3DX9_42.dll` 嵌入 `japi.tga` 的 PE `.rsrc` 节以实现零配置内联加载。
   - `D3DX9_42.dll` 属于 Microsoft DirectX 9 End-User Runtime 专有二进制文件，**不可按 GPL-3.0 或 MIT 再许可**。若面向公众做开源发行，建议：
     - **不要**在开源仓库或公开发行的 `japi.tga` 中硬嵌入 `D3DX9_42.dll`（构建时不传 `-DJAPI_D3DX9_42_DLL`）；
     - 由最终用户自行安装官方 DirectX End-User Runtimes (June 2010)（大多数 Windows 系统 `SysWOW64` 已内置，`newD3d9.dll` 会自动按系统路径加载）。

---

## 2. Copyleft（GPL-3.0）第三方组件清单

| 组件 | 仓库路径 | 上游项目 / 版权 | 许可证 | 使用方式 |
|------|----------|------------------|--------|----------|
| **YDWE**（核心提取模块） | `src/src/base/`<br>`src/src/yd_core/`<br>`src/src/slk/`<br>`src/src/lua_engine/`<br>`src/src/extensions/ex_natives/`<br>`src/src/image/pas_button_data.h` | [actboy168/YDWE](https://github.com/actboy168/YDWE)<br>`reference/YDWE/LICENSE` | **GNU GPL v3.0** | 提取并面向 War3 1.27a callback 模式改编后静态编译进 `yd_japi.dll` |
| **w3x2lni** | `tools/w3x2lni/`（SDK 中位于 `vendor/w3x2lni/`） | [sumneko/w3x2lni](https://github.com/sumneko/w3x2lni) (v2.7.4)<br>`tools/w3x2lni/LICENSE.txt` | **GNU GPL v3.0** | 作为独立 CLI 工具（`w2l.exe` / `w3x2lni-lua.exe`）由 `japi.exe` 与测试脚本调用 |

---

## 3. 宽松开源协议（MIT / BSD / Apache-2.0）组件清单

### 3.1 C / C++ 与调试工具

| 组件 | 仓库路径 | 版权与来源 | 许可证 |
|------|----------|------------|--------|
| **Lua 5.4** | `src/vendor/lua-5.4/` | Copyright (C) 1994–2024 Lua.org, PUC-Rio (`src/vendor/lua-5.4/src/lua.h`) | **MIT** |
| **bee.lua** | `src/vendor/bee-lua/`、`src/src/bee/` | Copyright (c) 2018 actboy168 (`src/vendor/bee-lua/LICENSE`) | **MIT** |
| **lua-debug** | `tools/debugger/luadebug.dll`、`tools/debugger/script/` | Copyright (c) 2016–present actboy168 (`tools/debugger/LICENSE.lua-debug`) | **MIT** |
| **udis86** | `src/src/yd_core/warcraft3/udis86/` | Copyright (c) 2002–2009 Vivek Thampi (`udis86.h`) | **BSD-2-Clause** |
| **pjass** | `tools/pjass.exe`、`tools/pjass-src/` | pjass contributors (`tools/pjass-src/LICENSE`) | **BSD-2-Clause** |

> 注：`src/src/fmt/format.h` 为本仓库编写的极简 `snprintf` 兼容垫片，不引入外部 `{fmt}` 代码。

### 3.2 Rust 开发者 CLI（`cli/Cargo.toml` → `japi.exe`）

| Crate | 用途 | 许可证 |
|-------|------|--------|
| `anyhow` | 错误上下文处理 | MIT OR Apache-2.0 |
| `clap` | 命令行参数解析 | MIT OR Apache-2.0 |
| `encoding_rs` | UTF-8 / GBK / ANSI 编码转换 | Apache-2.0 OR MIT |
| `regex` | 静态 `require` 与文本解析 | MIT OR Apache-2.0 |
| `serde` / `serde_json` | 配置与清单 JSON 序列化 | MIT OR Apache-2.0 |
| `sha2` | SHA-256 校验计算 | MIT OR Apache-2.0 |
| `windows-sys` | Win32 进程/Job Object/DACL 绑定 | MIT OR Apache-2.0 |

---

## 4. 仅作研究参考的文件与商标声明

- `reference/` 目录（含 `builtin-japi`、`ujapi`、`YDWE` 完整源码快照等）仅用于本仓库内技术研究与离线比对，**不随开发者 SDK 包分发**。
- `tools/callback` 为 War3 1.27a `StartCampaignAI` 引导脚本，参考社区公开的内置 JAPI 加载机制编写。
- *Warcraft III* 与 *Battle.net* 是 Blizzard Entertainment, Inc. 的注册商标。本项目为非官方社区技术工具，与 Blizzard Entertainment 或 KK 对战平台无任何官方隶属关系。

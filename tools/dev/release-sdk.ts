import fs from 'node:fs';
import path from 'node:path';
import {
  copyDirRecursive,
  findCargoCmd,
  formatMB,
  JAPI_EXE,
  ROOT,
  runCapture,
  runChecked,
  sha256File,
  walkFiles,
} from './common.ts';

export interface ReleaseOptions {
  commit?: string;
  version?: string;
  outDir?: string;
  noBuild?: boolean;
  keep?: boolean;
  sdkBundle?: boolean;
  noVendor?: boolean;
}

function git(args: string[], cwd: string = ROOT): string {
  const r = runCapture('git', ['-C', cwd, ...args]);
  if (r.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${r.combined.trim()}`);
  }
  return r.stdout.trim();
}

function findVcvars32(): string {
  const defaultPath = String.raw`D:\vs2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat`;
  if (fs.existsSync(defaultPath)) return defaultPath;
  const pf86 = process.env['ProgramFiles(x86)'] ?? String.raw`C:\Program Files (x86)`;
  const vswhere = path.join(pf86, 'Microsoft Visual Studio', 'Installer', 'vswhere.exe');
  if (fs.existsSync(vswhere)) {
    const r = runCapture(vswhere, [
      '-latest',
      '-products',
      '*',
      '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '-property',
      'installationPath',
    ]);
    const install = r.stdout.trim().split(/\r?\n/)[0]?.trim();
    if (install) {
      const cand = path.join(install, 'VC', 'Auxiliary', 'Build', 'vcvars32.bat');
      if (fs.existsSync(cand)) return cand;
    }
  }
  throw new Error('vcvars32.bat not found. Install Visual Studio C++ Build Tools (x86).');
}

function writeTreeChecksums(dir: string, outName: string): { path: string; count: number } {
  const outPath = path.join(dir, outName);
  const files = walkFiles(dir)
    .filter((f) => path.resolve(f) !== path.resolve(outPath))
    .sort((a, b) => a.localeCompare(b));
  const lines = files.map((f) => {
    const rel = path.relative(dir, f).replace(/\\/g, '/');
    return `${sha256File(f)}  ${rel}`;
  });
  fs.writeFileSync(outPath, lines.join('\n') + '\n', 'ascii');
  return { path: outPath, count: files.length };
}

function treeStats(dir: string): { files: number; bytes: number } {
  const files = walkFiles(dir);
  let bytes = 0;
  for (const f of files) bytes += fs.statSync(f).size;
  return { files: files.length, bytes };
}

export function runReleaseSdk(opts: ReleaseOptions = {}): void {
  const commitRef = opts.commit ?? 'HEAD';
  console.log('\n== 0. Resolve commit and SDK version');
  const commitSha = git(['rev-parse', `${commitRef}^{commit}`]);
  const sha7 = git(['rev-parse', '--short', commitSha]);
  const commitDate = git(['show', '-s', '--format=%aI', commitSha]);
  const commitSubject = git(['show', '-s', '--format=%s', commitSha]);

  const d3dBlob = git(['--no-pager', 'show', `${commitSha}:src/src/lua_engine/lua_engine/libs_d3d.cpp`]);
  const verMatch = d3dBlob.match(/constexpr\s+const\s+char\s*\*\s*kVersion\s*=\s*"([^"]+)"/);
  if (!verMatch) {
    throw new Error(`kVersion not found in libs_d3d.cpp at ${sha7}`);
  }
  const version = opts.version ?? verMatch[1];
  console.log(`  commit : ${commitSha} (${sha7})`);
  console.log(`  version: ${version}`);

  console.log('\n== 1. Prepare output directory');
  const buildRoot = path.resolve(ROOT, 'build');
  const outDir = path.resolve(opts.outDir ?? path.join(buildRoot, 'sdk', `${version}-${sha7}`));
  if (!outDir.toLowerCase().startsWith((buildRoot + path.sep).toLowerCase())) {
    throw new Error(`Refusing to write release outside ${buildRoot}: ${outDir}`);
  }
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  console.log(`  output : ${outDir}`);

  console.log('\n== 2. Create detached clean worktree');
  const workPath = path.join(buildRoot, `clean-${sha7}`);
  let createdWorktree = false;
  if (!fs.existsSync(workPath)) {
    git(['worktree', 'add', '--detach', workPath, commitSha]);
    createdWorktree = true;
  }
  const status = git(['status', '--porcelain'], workPath);
  if (status.length > 0) {
    throw new Error(`Clean worktree is dirty: ${workPath}`);
  }

  try {
    // Only ship production runtime binaries in the developer SDK — never internal C++ test executables.
    const runtimeDlls = ['yd_japi.dll', 'newD3d9.dll'];
    let binSourceDir: string;
    let japiExeSource: string;

    if (opts.noBuild) {
      console.log('\n== 3. Skipping build (--no-build; using local artifacts)');
      binSourceDir = path.join(ROOT, 'src', 'build', 'bin', 'Release');
      japiExeSource = JAPI_EXE;
    } else {
      console.log('\n== 3. Build C++ DLLs (Win32 Release) + Rust japi.exe (Release)');
      const vcvars = findVcvars32();
      const cmakeBuildDir = path.join(buildRoot, `cmake-${sha7}`);
      const d3dxCandidates = [
        path.join(ROOT, 'reference', 'builtin-japi', 'extracted', 'D3DX9_42.dll'),
        path.join(process.env.WINDIR ?? String.raw`C:\Windows`, 'SysWOW64', 'D3DX9_42.dll'),
        path.join(process.env.WINDIR ?? String.raw`C:\Windows`, 'System32', 'D3DX9_42.dll'),
      ];
      const d3dxPath = d3dxCandidates.find((p) => fs.existsSync(p));
      const d3dxArg = d3dxPath ? ` -DJAPI_D3DX9_42_DLL="${d3dxPath}"` : '';
      const buildBat = path.join(buildRoot, `build-cmake-${sha7}.cmd`);
      fs.writeFileSync(
        buildBat,
        [
          '@echo off',
          `call "${vcvars}" >nul || exit /b 1`,
          `cmake -S "${path.join(workPath, 'src')}" -B "${cmakeBuildDir}" -G "Visual Studio 17 2022" -A Win32${d3dxArg} || exit /b 1`,
          `cmake --build "${cmakeBuildDir}" --config Release || exit /b 1`,
        ].join('\r\n') + '\r\n',
        'ascii',
      );
      try {
        runChecked('cmd.exe', ['/c', buildBat]);
      } finally {
        fs.rmSync(buildBat, { force: true });
      }
      binSourceDir = path.join(cmakeBuildDir, 'bin', 'Release');

      const cargo = findCargoCmd();
      const cargoTargetDir = path.join(buildRoot, `cargo-${sha7}`);
      runChecked(cargo.cmd, [
        ...cargo.prefixArgs,
        'build',
        '--release',
        '--manifest-path',
        path.join(workPath, 'cli', 'Cargo.toml'),
        '--target-dir',
        cargoTargetDir,
      ]);
      japiExeSource = path.join(cargoTargetDir, 'release', 'japi.exe');
    }

    console.log('\n== 4. Collect release binaries');
    const artifacts: Array<{ name: string; bytes: number; sha256: string }> = [];
    for (const name of runtimeDlls) {
      const src = path.join(binSourceDir, name);
      const dst = path.join(outDir, name);
      fs.copyFileSync(src, dst);
      artifacts.push({ name, bytes: fs.statSync(dst).size, sha256: sha256File(dst) });
    }
    if (fs.existsSync(japiExeSource)) {
      const dst = path.join(outDir, 'japi.exe');
      fs.copyFileSync(japiExeSource, dst);
      artifacts.push({ name: 'japi.exe', bytes: fs.statSync(dst).size, sha256: sha256File(dst) });
    }

    let bundleInfo: Record<string, unknown> | null = null;
    if (opts.sdkBundle) {
      console.log('\n== 5. Assemble clean developer SDK bundle (sdk\\)');
      const sdkDir = path.join(outDir, 'sdk');
      fs.mkdirSync(path.join(sdkDir, 'bin'), { recursive: true });

      // Root CLI
      fs.copyFileSync(path.join(outDir, 'japi.exe'), path.join(sdkDir, 'japi.exe'));

      // bin/ (runtime & packing binaries only — zero test executables)
      for (const name of runtimeDlls) {
        fs.copyFileSync(path.join(outDir, name), path.join(sdkDir, 'bin', name));
      }
      fs.copyFileSync(path.join(workPath, 'tools', 'callback'), path.join(sdkDir, 'bin', 'callback'));
      fs.copyFileSync(path.join(workPath, 'tools', 'pjass.exe'), path.join(sdkDir, 'bin', 'pjass.exe'));

      // Pure-JSON natives manifest (zero C++ files in SDK!)
      const manifestOut = path.join(sdkDir, 'bin', 'natives-manifest.json');
      runChecked(path.join(sdkDir, 'japi.exe'), ['emit-manifest', '--out', manifestOut, '--root', workPath]);

      // templates/empty-map/
      copyDirRecursive(path.join(workPath, 'reference', 'empty-map'), path.join(sdkDir, 'templates', 'empty-map'));

      // std/ (developer Lua standard library: timer, event, unit, player, group, effect, statbar, tween, ui)
      const stdSrc = path.join(workPath, 'std');
      if (fs.existsSync(stdSrc)) {
        copyDirRecursive(stdSrc, path.join(sdkDir, 'std'));
      }

      // tools/object-data/ (needed for objects.lua compilation)
      copyDirRecursive(path.join(workPath, 'tools', 'object-data'), path.join(sdkDir, 'tools', 'object-data'));

      // examples/ (clean map-author examples — omit internal manifest.json)
      copyDirRecursive(path.join(workPath, 'examples'), path.join(sdkDir, 'examples'));
      fs.rmSync(path.join(sdkDir, 'examples', 'manifest.json'), { force: true });

      // docs/ (map-author guides + CHANGELOG only — no internal STATUS/RELEASE/planning docs)
      copyDirRecursive(path.join(workPath, 'docs', 'guide'), path.join(sdkDir, 'docs', 'guide'));
      fs.copyFileSync(path.join(workPath, 'CHANGELOG.md'), path.join(sdkDir, 'CHANGELOG.md'));

      // vendor/w3x2lni/
      let vendorStatus = '**未包含**（`--no-vendor`）';
      if (!opts.noVendor) {
        const vendorDst = path.join(sdkDir, 'vendor', 'w3x2lni');
        copyDirRecursive(path.join(workPath, 'tools', 'w3x2lni'), vendorDst);
        // Overlay gitignored runtime DLLs from local checkout
        const localW2l = path.join(ROOT, 'tools', 'w3x2lni');
        let overlaid = 0;
        if (fs.existsSync(localW2l)) {
          for (const f of walkFiles(localW2l)) {
            const rel = path.relative(localW2l, f);
            if (rel.startsWith('log' + path.sep)) continue;
            const dst = path.join(vendorDst, rel);
            if (!fs.existsSync(dst)) {
              fs.mkdirSync(path.dirname(dst), { recursive: true });
              fs.copyFileSync(f, dst);
              overlaid++;
            }
          }
        }
        const vs = treeStats(vendorDst);
        vendorStatus = `\`w3x2lni\` 运行时（${vs.files} 文件 / ${formatMB(vs.bytes)} MB，含 ${overlaid} 个本地 runtime DLL）`;
      }

      // sdk/README.md
      const builtAtUtc = new Date().toISOString();
      const artifactRows = artifacts
        .map((a) => `| \`${a.name}\` | ${a.bytes} | \`${a.sha256}\` |`)
        .join('\n');
      const readmeText = `# WAR3 map-inject 地图作者 SDK ${version}

零依赖单文件 CLI（\`japi.exe\`）+ 运行时二进制 + 示例 + 文档，解压即可开发 WAR3 1.27a Lua 地图。

- 版本：\`${version}\`
- 提交：\`${sha7}\`（\`${commitSha}\`，${commitDate}）
- 打包时间：${builtAtUtc}${opts.noBuild ? '\n\n> **警告：本包由 `--no-build` 复用本地产物生成，仅供内部验证，不得对外分发。**' : ''}

## 目录结构

| 路径 | 用途 |
|---|---|
| \`japi.exe\` | 地图作者主命令行工具（静态单文件，零依赖） |
| \`bin/\` | \`yd_japi.dll\`、\`newD3d9.dll\`、\`callback\`、\`pjass.exe\`、\`natives-manifest.json\` |
| \`templates/empty-map/\` | 空白基座地图 |
| \`std/\` | 地图开发 Lua 标准库（\`std.signal\` / \`std.frame\` / \`std.ui\` / \`std.timer\` / \`std.event\` / \`std.unit\` 等，自动按需 Tree-Shaking） |
| \`vendor/w3x2lni/\` | ${vendorStatus} |
| \`tools/object-data/\` | \`objects.lua\` 代码化物编编译器 |
| \`examples/\` | 12 个独立可打包示例工程 |
| \`docs/guide/\` | 地图作者阶梯指南 |

## 快速开始

\`\`\`powershell
.\\japi.exe doctor
.\\japi.exe new MyMap --path D:\\maps
.\\japi.exe check D:\\maps\\MyMap --strict-requires
.\\japi.exe build D:\\maps\\MyMap
.\\japi.exe run   D:\\maps\\MyMap
\`\`\`

如需指定 War3 1.27a 目录，传 \`--war3-dir\`、设置环境变量 \`WAR3_DIR\`，或在 SDK 根目录新建 \`japi.local.json\`：

\`\`\`json
{
  "war3Dir": "D:\\\\Warcraft III Frozen Throne 1.27a publish"
}
\`\`\`

## 发行二进制

| 文件 | 字节 | SHA-256 |
|---|---|---|
${artifactRows}
`;
      fs.writeFileSync(path.join(sdkDir, 'README.md'), readmeText, 'utf8');
      const sdkSums = writeTreeChecksums(sdkDir, 'SHA256SUMS.txt');
      const stats = treeStats(sdkDir);

      // Package a clean, ready-to-share zip archive of sdk/
      const zipName = `map-inject-sdk-${version}.zip`;
      const zipPath = path.join(outDir, zipName);
      fs.rmSync(zipPath, { force: true });
      runChecked('powershell.exe', [
        '-NoProfile',
        '-Command',
        `Compress-Archive -Path '${sdkDir}\\*' -DestinationPath '${zipPath}' -CompressionLevel Optimal`,
      ]);
      const zipBytes = fs.statSync(zipPath).size;
      const zipSha = sha256File(zipPath);

      bundleInfo = {
        path: 'sdk',
        zip: zipName,
        zip_bytes: zipBytes,
        zip_sha256: zipSha,
        files: stats.files,
        bytes: stats.bytes,
        hashed_files: sdkSums.count,
        layout: 'clean zero-dependency developer SDK: japi.exe + bin/ + templates/ + vendor/ + tools/object-data/ + examples/ + docs/guide/',
      };
      console.log(`  bundle : ${stats.files} files / ${formatMB(stats.bytes)} MB`);
      console.log(`  archive: ${zipPath} (${formatMB(zipBytes)} MB, sha256=${zipSha.slice(0, 12)}...)`);
    }

    const manifest = {
      schema: 2,
      version,
      commit: commitSha,
      commit_short: sha7,
      commit_date: commitDate,
      commit_subject: commitSubject,
      built: !opts.noBuild,
      artifacts,
      sdk_bundle: bundleInfo,
    };
    fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n', 'utf8');
    const topSums = writeTreeChecksums(outDir, 'SHA256SUMS.txt');
    console.log(`\nRelease ready: ${outDir} (${topSums.count} files hashed)`);
  } finally {
    if (createdWorktree && !opts.keep) {
      git(['worktree', 'remove', '--force', workPath]);
      git(['worktree', 'prune']);
    }
  }
}

import path from 'node:path';
import { ensureJapiExe, findCargoCmd, ROOT, runChecked } from './common.ts';
import { runPackDiagnostics } from './pack-diagnostics.ts';
import { runReleaseSdk } from './release-sdk.ts';
import { runSetup } from './setup.ts';
import {
  cleanBuildDir,
  makeForeignMap,
  runConformanceLive,
  runD3dContractSuite,
  runObjectDataSuite,
  runSelectorOfflineSuite,
  runStdOfflineSuite,
  runUiOfflineSuite,
  runYdweCompatSuite,
} from './suites.ts';
import { runVerifyExamples } from './verify-examples.ts';

function showUsage(): void {
  console.log(`
WAR3 map-inject Engine Maintainer CLI (Node 24 native TS: node tools/dev/cli.ts / mise run <task>)

Commands:
  setup [--force] [--ref <sha>]             Bootstrap pinned dependencies (w3x2lni scripts/data + checks)
  build [all | dll | cli]                   Compile C++ DLLs (src/build.bat) and/or Rust japi.exe
  test  [suite]                             Run engine & toolchain test suites:
          all          (default) cli + pack + object-data + selector + ui + std + ydwe-compat + d3d-contract + examples
          cli          cargo test (Rust unit tests)
          pack         pack-diagnostics (single-TGA, war3map.imp, wtg/wct, japi.json, manifest, SDK layout)
          object-data  objects.lua compiler + w3x2lni roundtrip + pack integration
          selector     offline jass.selector Lua tests
          ui           offline UI library & example contract tests
          std          offline std.* standard library & reactive DzFrame UI tests
          ydwe-compat  Python + Lua + C++ + CLI YDWE compat offline suite
          d3d-contract D3D handler manifest vs C++ registrations & test_d3d.lua coverage
          examples     verify all 12 examples (--filter, --skip-pack, --live, --war3-dir)
          live         main engine regression in War3 (japi test)
          demo         wave-defense demo regression in War3 (japi test --demo)
          conformance  conformance suite in War3
  release [--commit HEAD] [--sdk-bundle] [--no-build] [--no-vendor] [--keep]
  foreign-map [outDir]                      Generate build/foreign-map fixture
  clean                                     Prune worktrees under build/ and clear build/
`);
}

function parseFlagVal(args: string[], flag: string): string | undefined {
  const idx = args.indexOf(flag);
  if (idx >= 0 && idx + 1 < args.length) return args[idx + 1];
  return undefined;
}

function buildDll(): void {
  console.log('\n== [build] C++ DLLs (src/build.bat)');
  runChecked('cmd.exe', ['/c', path.join(ROOT, 'src', 'build.bat')]);
}

function buildCli(): void {
  console.log('\n== [build] Rust japi.exe (cli/Cargo.toml --release)');
  const cargo = findCargoCmd();
  runChecked(cargo.cmd, [
    ...cargo.prefixArgs,
    'build',
    '--release',
    '--manifest-path',
    path.join(ROOT, 'cli', 'Cargo.toml'),
  ]);
}

function testCli(): void {
  console.log('\n== [test] Rust CLI unit tests (cargo test)');
  const cargo = findCargoCmd();
  runChecked(cargo.cmd, [
    ...cargo.prefixArgs,
    'test',
    '--manifest-path',
    path.join(ROOT, 'cli', 'Cargo.toml'),
  ]);
}

const [, , cmd = 'help', ...rest] = process.argv;

switch (cmd.toLowerCase()) {
  case 'help':
  case '-h':
  case '--help':
    showUsage();
    break;

  case 'setup':
    await runSetup({
      ref: parseFlagVal(rest, '--ref'),
      url: parseFlagVal(rest, '--url'),
      dest: parseFlagVal(rest, '--dest'),
      force: rest.includes('--force'),
    });
    break;

  case 'build': {
    const target = (rest[0] ?? 'all').toLowerCase();
    if (target === 'dll') buildDll();
    else if (target === 'cli') buildCli();
    else if (target === 'all') {
      buildDll();
      buildCli();
    } else {
      throw new Error(`Unknown build target '${target}'. Expected: all, dll, cli`);
    }
    break;
  }

  case 'test': {
    const suite = (rest[0] && !rest[0].startsWith('-') ? rest[0] : 'all').toLowerCase();
    const extra = rest[0] && !rest[0].startsWith('-') ? rest.slice(1) : rest;

    switch (suite) {
      case 'cli':
        testCli();
        break;
      case 'pack':
        runPackDiagnostics();
        break;
      case 'object-data':
        runObjectDataSuite();
        break;
      case 'selector':
        runSelectorOfflineSuite();
        break;
      case 'ui':
        runUiOfflineSuite();
        break;
      case 'std':
        runStdOfflineSuite();
        break;
      case 'ydwe-compat':
        runYdweCompatSuite();
        break;
      case 'd3d-contract':
        runD3dContractSuite();
        break;
      case 'examples':
        runVerifyExamples({
          filter: parseFlagVal(extra, '--filter'),
          skipPack: extra.includes('--skip-pack'),
          live: extra.includes('--live'),
          timeout: parseFlagVal(extra, '--timeout') ? Number(parseFlagVal(extra, '--timeout')) : undefined,
          war3Dir: parseFlagVal(extra, '--war3-dir'),
          keepWork: extra.includes('--keep-work'),
        });
        break;
      case 'live': {
        const japi = ensureJapiExe();
        runChecked(japi, ['test', ...extra]);
        break;
      }
      case 'demo': {
        const japi = ensureJapiExe();
        runChecked(japi, ['test', '--demo', ...extra]);
        break;
      }
      case 'conformance':
        runConformanceLive(extra);
        break;
      case 'all':
        testCli();
        console.log('\n== [test] pack-diagnostics');
        runPackDiagnostics();
        console.log('\n== [test] object-data');
        runObjectDataSuite();
        console.log('\n== [test] selector-offline');
        runSelectorOfflineSuite();
        console.log('\n== [test] ui-offline');
        runUiOfflineSuite();
        console.log('\n== [test] std-offline');
        runStdOfflineSuite();
        console.log('\n== [test] ydwe-compat');
        runYdweCompatSuite();
        console.log('\n== [test] d3d-contract');
        runD3dContractSuite();
        console.log('\n== [test] examples (static + pack)');
        runVerifyExamples();
        console.log('\nAll offline engine & CLI suites passed.');
        break;
      default:
        throw new Error(`Unknown test suite '${suite}'.`);
    }
    break;
  }

  case 'release':
    runReleaseSdk({
      commit: parseFlagVal(rest, '--commit'),
      version: parseFlagVal(rest, '--version'),
      outDir: parseFlagVal(rest, '--out-dir'),
      noBuild: rest.includes('--no-build'),
      keep: rest.includes('--keep'),
      sdkBundle: rest.includes('--sdk-bundle'),
      noVendor: rest.includes('--no-vendor'),
    });
    break;

  case 'foreign-map':
    makeForeignMap(rest[0]);
    break;

  case 'clean':
    cleanBuildDir();
    break;

  default:
    console.error(`Unknown command: ${cmd}`);
    showUsage();
    process.exit(1);
}

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  copyDirRecursive,
  ensureJapiExe,
  ROOT,
  runCapture,
  runChecked,
  W2L_LUA,
  W3X2LNI_DIR,
} from './common.ts';

function runW2lConvert(mode: string, source: string, target: string): void {
  const binDir = path.join(W3X2LNI_DIR, 'bin');
  const scriptDir = path.join(W3X2LNI_DIR, 'script');
  const cpath = path.join(binDir, '?.dll');
  const ppath = `${path.join(scriptDir, '?.lua')};${path.join(scriptDir, '?\\init.lua')}`;
  const expr = `_W2L_MODE='CLI';package.cpath=[[${cpath}]];package.path=[[${ppath}]]`;
  runChecked(W2L_LUA, ['-E', '-e', expr, 'main.lua', mode, source, target], {
    cwd: scriptDir,
    env: { ...process.env, PATH: `${binDir};${process.env.PATH ?? ''}` },
  });
}

export function runObjectDataSuite(): void {
  const japiExe = ensureJapiExe();
  const scratch = path.join(ROOT, 'build', `object-data-test-${crypto.randomUUID().slice(0, 8)}`);
  try {
    const source = path.join(scratch, 'source');
    fs.mkdirSync(source, { recursive: true });
    runChecked(W2L_LUA, ['-E', path.join(ROOT, 'tests', 'object-data', 'test.lua'), ROOT, source]);

    copyDirRecursive(path.join(ROOT, 'reference', 'empty-map'), source);
    fs.rmSync(path.join(source, 'war3map.w3u.ini'), { force: true });
    const archive = path.join(scratch, 'objects.w3x');
    const lni = path.join(scratch, 'lni');
    runW2lConvert('pack', source, archive);
    runW2lConvert('lni', archive, lni);
    runChecked(W2L_LUA, ['-E', path.join(ROOT, 'tests', 'object-data', 'roundtrip.lua'), lni]);

    const work = path.join(scratch, 'packed');
    runChecked(japiExe, [
      'build',
      path.join(ROOT, 'examples', '11-object-data'),
      '--work-dir',
      work,
      '--skip-repack',
      '--strict-requires',
    ]);
    if (!fs.existsSync(path.join(work, 'war3map.w3a'))) {
      throw new Error('Pack did not emit ability object data');
    }
    const bundle = fs.readFileSync(path.join(work, 'script', 'war3map.lua'), 'utf8');
    if (/unit\s*\{|ability\s*\{|Build only:/.test(bundle)) {
      throw new Error('Build declaration leaked into runtime bundle');
    }

    const legacy = path.join(scratch, 'legacy-project');
    fs.mkdirSync(legacy, { recursive: true });
    fs.writeFileSync(path.join(legacy, 'war3map.lua'), 'print("legacy project")\n', 'utf8');
    const legacyWork = path.join(scratch, 'legacy-work');
    runChecked(japiExe, ['build', legacy, '--work-dir', legacyWork, '--skip-repack', '--strict-requires']);
    if (fs.existsSync(path.join(legacyWork, 'war3map.w3a'))) {
      throw new Error('Legacy project unexpectedly gained ability objects');
    }
    runChecked(W2L_LUA, [
      '-E',
      path.join(ROOT, 'tests', 'object-data', 'integration.lua'),
      ROOT,
      legacyWork,
      work,
    ]);
    console.log('Results: object-data compiler, converter roundtrip and pack integration passed');
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

export function runUiOfflineSuite(): void {
  runChecked(W2L_LUA, ['-E', path.join(ROOT, 'tests', 'ui', 'run_suite.lua'), ROOT]);
}

export function runStdOfflineSuite(): void {
  runChecked(W2L_LUA, ['-E', path.join(ROOT, 'tests', 'std', 'run.lua'), ROOT]);
}

export function runSelectorOfflineSuite(): void {
  runChecked(W2L_LUA, ['-E', path.join(ROOT, 'tests', 'selector', 'run.lua')], { cwd: ROOT });
  console.log('SELECTOR OFFLINE: passed; no War3 process, map loader or pack step was started.');
}

export function runD3dContractSuite(): void {
  const d3dDir = path.join(ROOT, 'src', 'src', 'd3d9');
  const manifestPath = path.join(d3dDir, 'handler_manifest.json');
  const apiPath = path.join(d3dDir, 'api.cpp');
  const messagePath = path.join(ROOT, 'src', 'src', 'lua_engine', 'lua_engine', 'libs_message.cpp');
  const exPath = path.join(ROOT, 'src', 'src', 'extensions', 'ex_natives', 'Initialize.cpp');
  const testPath = path.join(ROOT, 'map', 'tests', 'test_d3d.lua');

  interface HandlerEntry {
    name: string;
    spec: string;
    owner: 'd3d_proxy' | 'message' | 'ex_game_ui';
    test_id?: string | null;
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as {
    handler_count: number;
    legacy_handler_count: number;
    handlers: HandlerEntry[];
  };
  const handlers = manifest.handlers;
  if (handlers.length !== manifest.handler_count) {
    throw new Error(`manifest handler_count=${manifest.handler_count}, actual=${handlers.length}`);
  }
  if (manifest.legacy_handler_count !== handlers.length - 1) {
    throw new Error('legacy_handler_count must be the surface count before GetTextureSrcRect was restored');
  }
  const seenNames = new Set<string>();
  for (const h of handlers) {
    if (seenNames.has(h.name)) throw new Error(`duplicate manifest name: ${h.name}`);
    seenNames.add(h.name);
  }

  const readRegs = (filePath: string, re: RegExp): Array<{ name: string; spec: string }> => {
    const text = fs.readFileSync(filePath, 'utf8');
    return [...text.matchAll(re)].map((m) => ({ name: m[1], spec: m[2] }));
  };
  const apiRegs = readRegs(apiPath, /reg\s*\(\s*"([^"]+)"\s*,\s*"([^"]+)"/g);
  const messageRegs = readRegs(messagePath, /reg\s*\(\s*"([^"]+)"\s*,\s*"([^"]+)"/g);
  const exRegs = readRegs(exPath, /register_cpp_handler\s*\(\s*"([^"]+)"\s*,\s*"([^"]+)"/g);

  for (const entry of handlers) {
    const src = entry.owner === 'd3d_proxy' ? apiRegs : entry.owner === 'message' ? messageRegs : exRegs;
    const matches = src.filter((r) => r.name === entry.name);
    if (matches.length !== 1) {
      throw new Error(`${entry.name}: expected one ${entry.owner} registration, found ${matches.length}`);
    }
    if (matches[0].spec !== entry.spec) {
      throw new Error(`${entry.name}: manifest spec ${entry.spec}, source spec ${matches[0].spec}`);
    }
  }

  const canonical = ['GetMouseVectorX', 'GetMouseVectorY', 'ShowConsole', 'ShowFpsText', 'SetKeyboard'];
  for (const name of canonical) {
    if (apiRegs.some((r) => r.name === name)) {
      throw new Error(`D3D proxy must not register canonical handler ${name}`);
    }
  }

  const testText = fs.readFileSync(testPath, 'utf8');
  const fixtureNames = new Set<string>([
    ...[...testText.matchAll(/call\s*\(\s*"([^"]+)"/g)].map((m) => m[1]),
    ...[...testText.matchAll(/jass\.UnitId\s*\(\s*"([^"]+)"/g)].map((m) => m[1]),
  ]);
  const covered = handlers.filter((h) => fixtureNames.has(h.name)).map((h) => h.name).sort();
  const declared = handlers.filter((h) => h.test_id != null).map((h) => h.name).sort();
  if (JSON.stringify(covered) !== JSON.stringify(declared)) {
    throw new Error(`manifest fixture coverage differs from test_d3d.lua:\n  covered=${covered.join(',')}\n  declared=${declared.join(',')}`);
  }

  console.log(
    `D3D contract PASS: surface=${handlers.length}, proxy=${apiRegs.length}, canonical=${canonical.length}, fixture=${covered.length}/${handlers.length}, untested=${handlers.length - covered.length}`,
  );
}

export function runYdweCompatSuite(): void {
  const iconTest = path.join(ROOT, 'src', 'build', 'bin', 'Release', 'button_icon_test.exe');
  const iconTool = path.join(ROOT, 'src', 'build', 'bin', 'Release', 'ydwe_button_icon.exe');
  const suiteDir = path.join(ROOT, 'tests', 'ydwe-compat');

  console.log('=== [1/4] unit-state migration tests ===');
  runChecked('python', ['-m', 'unittest', 'discover', '-s', suiteDir, '-p', 'test_unit_state_migrate.py', '-v']);

  console.log('=== [2/4] jass.ydwe Lua module tests ===');
  runChecked(W2L_LUA, ['-E', path.join(suiteDir, 'run_lua.lua'), ROOT]);

  console.log('=== [3/4] C++ image module tests ===');
  if (!fs.existsSync(iconTest)) throw new Error(`Missing ${iconTest}; build C++ DLLs first.`);
  runChecked(iconTest, [ROOT]);

  console.log('=== [4/4] end-to-end icon tool tests ===');
  if (!fs.existsSync(iconTool)) throw new Error(`Missing ${iconTool}; build C++ DLLs first.`);
  runChecked('python', ['-m', 'unittest', 'discover', '-s', suiteDir, '-p', 'test_button_icons.py', '-v']);

  console.log('YDWE compat offline: 4 step(s) passed');
}

export function runConformanceLive(extraArgs: string[] = []): void {
  const japiExe = ensureJapiExe();
  const confDir = path.join(ROOT, 'tests', 'conformance');
  runChecked(W2L_LUA, [path.join(confDir, 'check-syntax.lua'), path.join(confDir, 'war3map.lua')]);

  if (!extraArgs.includes('--no-kill')) {
    runCapture(japiExe, ['kill']);
  }

  const r = runCapture(japiExe, [
    'test',
    confDir,
    '--map-name',
    'conformance.w3x',
    '--timeout',
    '200',
    ...extraArgs,
  ]);
  const logOut = path.join(ROOT, 'build', 'conformance-run.log');
  fs.mkdirSync(path.dirname(logOut), { recursive: true });
  fs.writeFileSync(logOut, r.combined, 'utf8');
  process.stdout.write(r.combined);

  const cMatch = [...r.combined.matchAll(/Conformance:\s*(\d+) passed,\s*(\d+) failed,\s*(\d+) skipped/g)].at(-1);
  const rMatch = [...r.combined.matchAll(/Results:\s*(\d+) passed,\s*(\d+) failed,\s*(\d+) total/g)].at(-1);
  if (
    r.status !== 0 ||
    !cMatch ||
    !rMatch ||
    cMatch[2] !== '0' ||
    rMatch[2] !== '0' ||
    cMatch[1] !== rMatch[1] ||
    rMatch[1] !== rMatch[3]
  ) {
    process.exit(1);
  }
}

export function makeForeignMap(outDir?: string): void {
  const dst = path.resolve(outDir ?? path.join(ROOT, 'build', 'foreign-map'));
  const src = path.join(ROOT, 'reference', 'empty-map');
  const fixture = path.join(ROOT, 'tools', 'fixtures', 'foreign-war3map.j');
  fs.rmSync(dst, { recursive: true, force: true });
  copyDirRecursive(src, dst);
  fs.copyFileSync(fixture, path.join(dst, 'war3map.j'));
  console.log(`Foreign map fixture ready: ${dst}`);
}

export function cleanBuildDir(): void {
  const buildDir = path.join(ROOT, 'build');
  // Remove any git worktrees registered under build/
  const wt = runCapture('git', ['-C', ROOT, 'worktree', 'list', '--porcelain']);
  for (const line of wt.stdout.split(/\r?\n/)) {
    const m = line.match(/^worktree\s+(.+)$/);
    if (m) {
      const wtPath = path.resolve(m[1].trim());
      if (wtPath.toLowerCase().startsWith((buildDir + path.sep).toLowerCase())) {
        runCapture('git', ['-C', ROOT, 'worktree', 'remove', '--force', wtPath]);
      }
    }
  }
  runCapture('git', ['-C', ROOT, 'worktree', 'prune']);
  if (fs.existsSync(buildDir)) {
    for (const entry of fs.readdirSync(buildDir)) {
      fs.rmSync(path.join(buildDir, entry), { recursive: true, force: true });
    }
  }
  console.log(`Cleaned ${buildDir}`);
}

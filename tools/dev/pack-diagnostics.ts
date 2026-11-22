import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  copyDirRecursive,
  ensureJapiExe,
  ROOT,
  runCapture,
  W2L_LUA,
  W3X2LNI_DIR,
} from './common.ts';

const DEFAULT_JASS = `globals
endglobals
function config takes nothing returns nothing
endfunction
function main takes nothing returns nothing
endfunction
`;

function putFile(filePath: string, text: string): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, text, 'utf8');
}

export function runPackDiagnostics(): void {
  const japiExe = ensureJapiExe();
  const scratch = path.join(ROOT, 'build', `pack-diag-${crypto.randomUUID().slice(0, 8)}`);
  fs.mkdirSync(scratch, { recursive: true });

  let passed = 0;
  let failed = 0;

  function testCase(name: string, fn: () => void): void {
    try {
      fn();
      passed++;
      console.log(`[PASS] ${name}`);
    } catch (err) {
      failed++;
      console.log(`[FAIL] ${name}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  function packCase(
    name: string,
    files: Record<string, string>,
    opts: { jass?: string; extraArgs?: string[]; base?: string } = {},
  ) {
    const dir = path.join(scratch, name);
    const mapDir = path.join(dir, 'map');
    const workDir = path.join(dir, 'work');
    const outFile = path.join(dir, 'output.w3x');
    for (const [rel, content] of Object.entries(files)) {
      putFile(path.join(mapDir, rel), content);
    }
    const base = opts.base ?? path.join(dir, 'base');
    if (!opts.base) {
      putFile(path.join(base, 'war3map.j'), opts.jass ?? DEFAULT_JASS);
    }
    const res = runCapture(japiExe, [
      'build',
      mapDir,
      '--base-map',
      base,
      '--work-dir',
      workDir,
      '--out-file',
      outFile,
      '--skip-repack',
      '--require-report',
      ...(opts.extraArgs ?? []),
    ]);
    return { ...res, workDir, outFile };
  }

  try {
    testCase('missing dependency includes source and line', () => {
      const r = packCase(
        'missing',
        { 'war3map.lua': '-- comment\nrequire "lib.absent"\n' },
        { extraArgs: ['--strict-requires'] },
      );
      assert.notEqual(r.status, 0, r.combined);
      assert.match(r.combined, /war3map\.lua:2: lib\.absent/);
    });

    testCase('default mode warns without blocking external runtime loaders', () => {
      const r = packCase('permissive', { 'war3map.lua': 'require "external"\n' });
      assert.equal(r.status, 0, r.combined);
      assert.match(r.combined, /\[missing/);
    });

    testCase('known engine modules remain runtime dependencies', () => {
      const r = packCase(
        'engine',
        { 'war3map.lua': 'local j = require "jass.common"\nlocal k = require(\'jass.japi\')\n' },
        { extraArgs: ['--strict-requires'] },
      );
      assert.equal(r.status, 0, r.combined);
      assert.match(r.combined, /\[engine/);
      assert.equal(fs.existsSync(r.outFile), false, '--skip-repack wrote an archive');
    });

    testCase('block comments and long strings are not dependencies or rewritten', () => {
      const source = `--[==[
require "missing.comment"
]==]
local text = [=[
require "lib.exists"
]=]
local escaped = "a\\" require 'missing.string'"
-- require "missing.line"
local actual = require "lib.exists"
assert(actual.value == 42)
assert(text:find('require "lib.exists"', 1, true))
`;
      const r = packCase(
        'quoted',
        { 'war3map.lua': source, 'lib/exists.lua': 'return {value = 42}\n' },
        { extraArgs: ['--strict-requires'] },
      );
      assert.equal(r.status, 0, r.combined);
      const luaRun = runCapture(W2L_LUA, [path.join(r.workDir, 'script', 'war3map.lua')]);
      assert.equal(luaRun.status, 0, luaRun.combined);
    });

    testCase('indented, parenthesized and conditional requires work via package.preload', () => {
      const source = `if true then
    local a = require("lib.a")
    local b = require('lib.b')
    assert(a.v + b.v == 30)
end
`;
      const r = packCase(
        'indented',
        {
          'war3map.lua': source,
          'lib/a.lua': 'return { v = 10 }\n',
          'lib/b.lua': 'return { v = 20 }\n',
        },
        { extraArgs: ['--strict-requires'] },
      );
      assert.equal(r.status, 0, r.combined);
      const luaRun = runCapture(W2L_LUA, [path.join(r.workDir, 'script', 'war3map.lua')]);
      assert.equal(luaRun.status, 0, luaRun.combined);
    });

    testCase('cyclic dependencies are rejected in strict mode', () => {
      const r = packCase(
        'cycle',
        {
          'war3map.lua': 'local a = require "lib.a"\n',
          'lib/a.lua': 'local b = require "lib.b"\nreturn {}\n',
          'lib/b.lua': 'local a = require "lib.a"\nreturn {}\n',
        },
        { extraArgs: ['--strict-requires'] },
      );
      assert.notEqual(r.status, 0, r.combined);
      assert.match(r.combined, /lib\/b\.lua:1: lib\.a \(cycle\)/);
    });

    testCase('repeated bare require compiles and initializes only once', () => {
      const r = packCase(
        'repeated',
        {
          'war3map.lua': 'require "lib.a"\nrequire "lib.a"\nassert(_G.loads == 1)\n',
          'lib/a.lua': '_G.loads = (_G.loads or 0) + 1; return {}\n',
        },
        { extraArgs: ['--strict-requires'] },
      );
      assert.equal(r.status, 0, r.combined);
      const luaRun = runCapture(W2L_LUA, [path.join(r.workDir, 'script', 'war3map.lua')]);
      assert.equal(luaRun.status, 0, luaRun.combined);
    });

    testCase('missing main reports JASS anchors', () => {
      const r = packCase('anchor', { 'war3map.lua': 'return {}\n' }, { jass: 'globals\nendglobals\n' });
      assert.notEqual(r.status, 0, r.combined);
      assert.match(r.combined, /main=absent/);
      assert.match(r.combined, /JASS anchors/);
    });

    testCase('native declarations after functions are rejected with position', () => {
      const r = packCase(
        'native',
        { 'war3map.lua': 'return {}\n' },
        {
          jass: DEFAULT_JASS + '\nnative SetHeroLevels takes code f returns nothing\n',
          extraArgs: ['--with-get-func-addr'],
        },
      );
      assert.notEqual(r.status, 0, r.combined);
      assert.match(r.combined, /after the first function/);
    });

    testCase('repatch retains one allocator and one load call', () => {
      const jass = DEFAULT_JASS.replace('globals\n', 'globals\n    integer array values\n');
      const r = packCase('arrays', { 'war3map.lua': 'return {}\n' }, { jass });
      assert.equal(r.status, 0, r.combined);
      const r2 = packCase('arrays_again', { 'war3map.lua': 'return {}\n' }, { base: r.workDir });
      assert.equal(r2.status, 0, r2.combined);
      const out = fs.readFileSync(path.join(r2.workDir, 'war3map.j'), 'utf8');
      assert.equal((out.match(/^function JapiForceAllocArrays\b/gm) ?? []).length, 1);
      assert.equal((out.match(/call UnitId\("LoadScript"\)/g) ?? []).length, 1);
    });

    testCase('wrapper and GetFuncAddr probes are not duplicated by repacking', () => {
      const extra = ['--with-jass-wrappers', '--with-get-func-addr'];
      const r = packCase(
        'probes',
        { 'war3map.lua': 'return {}\n' },
        { base: path.join(ROOT, 'reference', 'empty-map'), extraArgs: extra },
      );
      assert.equal(r.status, 0, r.combined);
      const r2 = packCase(
        'probes_again',
        { 'war3map.lua': 'return {}\n' },
        { base: r.workDir, extraArgs: extra },
      );
      assert.equal(r2.status, 0, r2.combined);
      const out = fs.readFileSync(path.join(r2.workDir, 'war3map.j'), 'utf8');
      for (const fn of ['JapiWrapperProbeActions', 'JapiGetFuncAddrProbeActions', 'GetFuncAddr']) {
        assert.equal((out.match(new RegExp(`^function ${fn}\\b`, 'gm')) ?? []).length, 1, `${fn} duplicated`);
      }
      assert.match(out, /function CreateTexture takes/);
      assert.match(out, /function GetGameVersion takes/);
    });

    testCase('reboot probe survives repatching without duplicate functions/timers', () => {
      const files = { 'war3map.lua': 'return {}\n', 'tests/reboot_child.lua': 'return {}\n' };
      const r = packCase('reboot', files, { extraArgs: ['--test-reboot'] });
      assert.equal(r.status, 0, r.combined);
      const r2 = packCase('reboot_again', files, { base: r.workDir, extraArgs: ['--test-reboot'] });
      assert.equal(r2.status, 0, r2.combined);
      const out = fs.readFileSync(path.join(r2.workDir, 'war3map.j'), 'utf8');
      assert.equal((out.match(/^function JapiRebootProbe\b/gm) ?? []).length, 1);
      assert.equal(
        (out.match(/call TimerStart\(CreateTimer\(\), 6\.00, false, function JapiRebootProbe\)/g) ?? []).length,
        1,
      );
    });

    testCase('japi.json manifest drives build defaults (baseMap, strictRequires, withGetFuncAddr)', () => {
      const dir = path.join(scratch, 'manifest-case');
      putFile(path.join(dir, 'base', 'war3map.j'), DEFAULT_JASS);
      putFile(path.join(dir, 'war3map.lua'), 'require "lib.missing"\n');
      putFile(
        path.join(dir, 'japi.json'),
        JSON.stringify({
          schema: 1,
          name: 'ManifestTest',
          baseMap: 'base',
          strictRequires: true,
          withGetFuncAddr: true,
        }),
      );
      const r1 = runCapture(japiExe, ['build', dir, '--work-dir', path.join(dir, 'work'), '--skip-repack']);
      assert.notEqual(r1.status, 0, r1.combined);
      assert.match(r1.combined, /require validation failed/);

      putFile(path.join(dir, 'war3map.lua'), 'return {}\n');
      const r2 = runCapture(japiExe, ['build', dir, '--work-dir', path.join(dir, 'work'), '--skip-repack']);
      assert.equal(r2.status, 0, r2.combined);
      const jassOut = fs.readFileSync(path.join(dir, 'work', 'war3map.j'), 'utf8');
      assert.match(jassOut, /function GetFuncAddr takes code f returns integer/);
    });

    testCase('emit-manifest + --manifest generates identical wrappers (EX + message + D3D)', () => {
      const mPath = path.join(scratch, 'natives-manifest.json');
      const emit = runCapture(japiExe, ['emit-manifest', '--out', mPath]);
      assert.equal(emit.status, 0, emit.combined);
      const manifest = JSON.parse(fs.readFileSync(mPath, 'utf8')) as { handlers: Array<{ source: string }> };
      assert.ok(manifest.handlers.length >= 120, `expected >= 120 handlers, got ${manifest.handlers.length}`);
      assert.ok(manifest.handlers.some((h) => h.source === 'd3d'));
      assert.ok(manifest.handlers.some((h) => h.source === 'ex-native'));
      assert.ok(manifest.handlers.some((h) => h.source === 'message'));

      const base = path.join(ROOT, 'reference', 'empty-map');
      const rCpp = packCase('wrap-cpp', { 'war3map.lua': 'return {}\n' }, { base, extraArgs: ['--with-jass-wrappers'] });
      const rJson = packCase(
        'wrap-json',
        { 'war3map.lua': 'return {}\n' },
        { base, extraArgs: ['--with-jass-wrappers', '--manifest', mPath] },
      );
      assert.equal(rCpp.status, 0, rCpp.combined);
      assert.equal(rJson.status, 0, rJson.combined);
      const norm = (p: string) =>
        fs.readFileSync(p, 'utf8').replace(/^\/\/W3x2lni Data:.*$/gm, '//W3x2lni Data: <ts>');
      assert.equal(
        norm(path.join(rCpp.workDir, 'war3map.j')),
        norm(path.join(rJson.workDir, 'war3map.j')),
        'manifest wrappers drifted from C++ registry wrappers',
      );
    });

    testCase('japi new + check + build + doctor end-to-end', () => {
      const projParent = path.join(scratch, 'projects');
      const projDir = path.join(projParent, 'DemoProj');
      const rNew = runCapture(japiExe, ['new', 'DemoProj', '--path', projParent]);
      assert.equal(rNew.status, 0, rNew.combined);
      assert.ok(fs.existsSync(path.join(projDir, 'japi.json')));

      const rChk = runCapture(japiExe, ['check', projDir, '--strict-requires']);
      assert.equal(rChk.status, 0, rChk.combined);

      const rBld = runCapture(japiExe, ['build', projDir, '--work-dir', path.join(scratch, 'demo-work')]);
      assert.equal(rBld.status, 0, rBld.combined);
      assert.ok(fs.existsSync(path.join(projDir, 'dist', 'DemoProj.w3x')));

      const rDoc = runCapture(japiExe, ['doctor']);
      assert.equal(rDoc.status, 0, rDoc.combined);
      assert.match(rDoc.combined, /All required packaging components are ready/);
    });

    testCase('standalone SDK bundle layout (no src/ or reference/) works end-to-end', () => {
      const sdk = path.join(scratch, 'sdk-sim');
      fs.mkdirSync(path.join(sdk, 'bin'), { recursive: true });
      fs.mkdirSync(path.join(sdk, 'tools'), { recursive: true });
      fs.copyFileSync(japiExe, path.join(sdk, 'japi.exe'));
      fs.copyFileSync(path.join(ROOT, 'src', 'build', 'bin', 'Release', 'yd_japi.dll'), path.join(sdk, 'bin', 'yd_japi.dll'));
      fs.copyFileSync(path.join(ROOT, 'src', 'build', 'bin', 'Release', 'newD3d9.dll'), path.join(sdk, 'bin', 'newD3d9.dll'));
      fs.copyFileSync(path.join(ROOT, 'tools', 'callback'), path.join(sdk, 'bin', 'callback'));
      fs.copyFileSync(path.join(ROOT, 'tools', 'pjass.exe'), path.join(sdk, 'bin', 'pjass.exe'));
      const emit = runCapture(japiExe, ['emit-manifest', '--out', path.join(sdk, 'bin', 'natives-manifest.json')]);
      assert.equal(emit.status, 0, emit.combined);
      copyDirRecursive(path.join(ROOT, 'reference', 'empty-map'), path.join(sdk, 'templates', 'empty-map'));
      copyDirRecursive(W3X2LNI_DIR, path.join(sdk, 'vendor', 'w3x2lni'));
      copyDirRecursive(path.join(ROOT, 'tools', 'object-data'), path.join(sdk, 'tools', 'object-data'));

      const sdkExe = path.join(sdk, 'japi.exe');
      const rDoc = runCapture(sdkExe, ['doctor'], { cwd: sdk });
      assert.equal(rDoc.status, 0, rDoc.combined);
      assert.match(rDoc.combined, /SDK bundle \(bin\/templates\/vendor\)/);

      const rNew = runCapture(sdkExe, ['new', 'SdkMap', '--path', path.join(sdk, 'maps')], { cwd: sdk });
      assert.equal(rNew.status, 0, rNew.combined);

      const rBld = runCapture(
        sdkExe,
        ['build', path.join(sdk, 'maps', 'SdkMap'), '--with-jass-wrappers', '--strict-requires'],
        { cwd: sdk },
      );
      assert.equal(rBld.status, 0, rBld.combined);
      assert.ok(fs.existsSync(path.join(sdk, 'maps', 'SdkMap', 'dist', 'SdkMap.w3x')));
    });

    testCase('single-TGA layout + war3map.imp (0x0D) + war3map.wtg/wct JapiBootstrap are emitted and idempotent', () => {
      const base = path.join(ROOT, 'reference', 'empty-map');
      const r1 = packCase('we-compat-1', { 'war3map.lua': 'return {}\n' }, { base });
      assert.equal(r1.status, 0, r1.combined);
      // Single-TGA: japi.tga + callback present, legacy split TGA files absent
      assert.ok(fs.existsSync(path.join(r1.workDir, 'japi.tga')));
      assert.ok(fs.existsSync(path.join(r1.workDir, 'callback')));
      assert.equal(fs.existsSync(path.join(r1.workDir, 'd3d9.tga')), false);
      assert.equal(fs.existsSync(path.join(r1.workDir, 'd3d9.tga.sha256')), false);
      assert.equal(fs.existsSync(path.join(r1.workDir, 'd3dx9_42.tga')), false);
      // war3map.imp registers callback, japi.tga, script\war3map.lua with 0x0D custom path
      const imp = fs.readFileSync(path.join(r1.workDir, 'war3map.imp'));
      assert.equal(imp.readUInt32LE(0), 1);
      assert.equal(imp.readUInt32LE(4), 3);
      const impAscii = imp.toString('latin1');
      assert.ok(impAscii.includes('\x0dcallback\0'));
      assert.ok(impAscii.includes('\x0djapi.tga\0'));
      assert.ok(impAscii.includes('\x0dscript\\war3map.lua\0'));
      // war3map.wtg + war3map.wct contain JapiBootstrap custom-script trigger
      const wtg1 = fs.readFileSync(path.join(r1.workDir, 'war3map.wtg'));
      const wct1 = fs.readFileSync(path.join(r1.workDir, 'war3map.wct'));
      assert.ok(wtg1.includes(Buffer.from('JapiBootstrap\0')));
      assert.ok(wct1.includes(Buffer.from('InitTrig_JapiBootstrap')));

      // Repacking an already-injected map must be idempotent (no duplicate imp/wtg/wct entries)
      const r2 = packCase('we-compat-2', { 'war3map.lua': 'return {}\n' }, { base: r1.workDir });
      assert.equal(r2.status, 0, r2.combined);
      const imp2 = fs.readFileSync(path.join(r2.workDir, 'war3map.imp'));
      assert.equal(imp2.readUInt32LE(4), 3);
      const wtg2 = fs.readFileSync(path.join(r2.workDir, 'war3map.wtg'));
      const wct2 = fs.readFileSync(path.join(r2.workDir, 'war3map.wct'));
      assert.equal(wtg2.length, wtg1.length, 'wtg grew on repack');
      assert.equal(wct2.length, wct1.length, 'wct grew on repack');
    });

    testCase('unexpanded YDTrigger #include directives produce actionable diagnostic', () => {
      const ydJass = `#define USE_BJ_ANTI_LEAK
#include <YDTrigger/Import.h>
${DEFAULT_JASS}`;
      const r = packCase('ydtrigger-raw', { 'war3map.lua': 'return {}\n' }, { jass: ydJass });
      assert.notEqual(r.status, 0, r.combined);
      assert.match(r.combined, /unexpanded YDWE\/KKWE preprocessor directives/);
    });
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }

  console.log(`Pack diagnostics: ${passed} passed, ${failed} failed`);
  if (failed > 0) {
    process.exit(1);
  }
}

if (import.meta.url === `file:///${process.argv[1].replace(/\\/g, '/')}`) {
  runPackDiagnostics();
}

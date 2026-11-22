import fs from 'node:fs';
import path from 'node:path';
import { ensureJapiExe, ROOT, runCapture } from './common.ts';

interface ExampleEntry {
  id: string;
  dir: string;
  title: string;
  d3d?: boolean;
  pack?: string[];
  interactive?: string;
}

interface ExampleManifest {
  examples: ExampleEntry[];
}

const FLAG_MAP: Record<string, string> = {
  WithJassWrappers: '--with-jass-wrappers',
  WithGetFuncAddr: '--with-get-func-addr',
  WithDebugger: '--with-debugger',
  NoArrayPrealloc: '--no-array-prealloc',
  SkipJassCheck: '--skip-jass-check',
};

export interface VerifyExamplesOptions {
  filter?: string;
  skipPack?: boolean;
  live?: boolean;
  timeout?: number;
  war3Dir?: string;
  keepWork?: boolean;
}

export function runVerifyExamples(opts: VerifyExamplesOptions = {}): void {
  const japiExe = ensureJapiExe();
  const examplesDir = path.join(ROOT, 'examples');
  const manifestPath = path.join(examplesDir, 'manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as ExampleManifest;

  const filterRe = opts.filter ? new RegExp(opts.filter, 'i') : null;
  const selected = manifest.examples.filter((e) => !filterRe || filterRe.test(e.id) || filterRe.test(e.dir));
  if (selected.length === 0) {
    throw new Error(`No examples matched filter '${opts.filter}'`);
  }

  const mode = opts.live ? 'static+pack+live' : opts.skipPack ? 'static' : 'static+pack';
  console.log(`verify-examples  mode=${mode}  examples=${selected.length}/${manifest.examples.length}`);

  const scratchRoot = path.join(ROOT, 'build', 'scratch');
  fs.mkdirSync(scratchRoot, { recursive: true });

  let passed = 0;
  let failed = 0;

  for (const ex of selected) {
    const dir = path.join(examplesDir, ex.dir);
    const luaPath = path.join(dir, 'war3map.lua');
    const readmePath = path.join(dir, 'README.md');
    const errors: string[] = [];

    if (!fs.existsSync(luaPath)) errors.push('missing war3map.lua');
    if (!fs.existsSync(readmePath)) errors.push('missing README.md');

    const extraFlags: string[] = [];
    for (const sw of ex.pack ?? []) {
      const mapped = FLAG_MAP[sw];
      if (!mapped) {
        errors.push(`unknown pack switch in manifest: ${sw}`);
      } else {
        extraFlags.push(mapped);
      }
    }

    let packOk = true;
    let mapSize = 0;
    const exScratch = path.join(scratchRoot, `ex-${ex.id}`);
    const outW3x = path.join(exScratch, 'out.w3x');
    const workDir = path.join(exScratch, 'work');

    if (errors.length === 0 && !opts.skipPack) {
      const r = runCapture(japiExe, [
        'build',
        dir,
        '--work-dir',
        workDir,
        '--out-file',
        outW3x,
        ...extraFlags,
      ]);
      if (r.status !== 0 || !fs.existsSync(outW3x)) {
        packOk = false;
        errors.push(`pack failed:\n${r.combined.trim()}`);
      } else {
        const stat = fs.statSync(outW3x);
        mapSize = stat.size;
        const fd = fs.openSync(outW3x, 'r');
        const magic = Buffer.alloc(4);
        fs.readSync(fd, magic, 0, 4, 0);
        fs.closeSync(fd);
        if (magic.toString('ascii') !== 'HM3W' || mapSize < 131072) {
          packOk = false;
          errors.push(`invalid .w3x output (magic=${magic.toString('ascii')}, size=${mapSize})`);
        }
      }
    }

    let liveOk = true;
    if (errors.length === 0 && packOk && opts.live) {
      const testArgs = [
        'test',
        dir,
        '--map-name',
        `vx-${ex.id}.w3x`,
        '--timeout',
        String(opts.timeout ?? 120),
        ...extraFlags,
      ];
      if (opts.war3Dir) {
        testArgs.push('--war3-dir', opts.war3Dir);
      }
      const r = runCapture(japiExe, testArgs);
      const m = r.combined.match(/Results:\s*(\d+)\s+passed,\s*(\d+)\s+failed,\s*(\d+)\s+total/);
      if (r.status !== 0 || !m || Number(m[2]) > 0 || Number(m[3]) < 3) {
        liveOk = false;
        errors.push(`live failed:\n${r.combined.slice(-1000)}`);
      }
    }

    const ok = errors.length === 0 && packOk && liveOk;
    if (ok) {
      passed++;
      const sizeStr = opts.skipPack ? 'skip-pack' : `${mapSize} bytes`;
      console.log(`  [PASS] ${ex.dir.padEnd(22)} (${sizeStr})`);
      if (!opts.keepWork) {
        fs.rmSync(exScratch, { recursive: true, force: true });
      }
    } else {
      failed++;
      console.log(`  [FAIL] ${ex.dir.padEnd(22)} ${errors.join(' | ')}`);
    }
  }

  console.log(`\nExamples: ${passed} passed, ${failed} failed, ${selected.length} total`);
  if (failed > 0) {
    process.exit(1);
  }
}

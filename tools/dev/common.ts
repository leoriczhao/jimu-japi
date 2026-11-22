import { spawnSync, type SpawnSyncOptions } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(__dirname, '..', '..');
export const JAPI_EXE = path.join(ROOT, 'cli', 'target', 'release', 'japi.exe');
export const W3X2LNI_DIR = path.join(ROOT, 'tools', 'w3x2lni');
export const W2L_LUA = path.join(W3X2LNI_DIR, 'bin', 'w3x2lni-lua.exe');

export interface RunResult {
  status: number;
  stdout: string;
  stderr: string;
  combined: string;
}

export function runCapture(
  cmd: string,
  args: string[],
  opts: SpawnSyncOptions = {},
): RunResult {
  const res = spawnSync(cmd, args, {
    encoding: 'utf8',
    windowsHide: true,
    ...opts,
  });
  if (res.error) {
    throw res.error;
  }
  const stdout = String(res.stdout ?? '');
  const stderr = String(res.stderr ?? '');
  return {
    status: res.status ?? 1,
    stdout,
    stderr,
    combined: stdout + (stderr ? (stdout.endsWith('\n') ? '' : '\n') + stderr : ''),
  };
}

export function runInherit(
  cmd: string,
  args: string[],
  opts: SpawnSyncOptions = {},
): number {
  const res = spawnSync(cmd, args, {
    stdio: 'inherit',
    ...opts,
  });
  if (res.error) {
    throw res.error;
  }
  return res.status ?? 1;
}

export function runChecked(
  cmd: string,
  args: string[],
  opts: SpawnSyncOptions = {},
): void {
  const code = runInherit(cmd, args, opts);
  if (code !== 0) {
    throw new Error(`Command failed (exit ${code}): ${cmd} ${args.join(' ')}`);
  }
}

export function ensureJapiExe(): string {
  if (!fs.existsSync(JAPI_EXE)) {
    throw new Error(
      `japi.exe not built yet (${JAPI_EXE}). Run: node tools/dev/cli.ts build cli`,
    );
  }
  return JAPI_EXE;
}

export function sha256File(filePath: string): string {
  const buf = fs.readFileSync(filePath);
  return createHash('sha256').update(buf).digest('hex').toUpperCase();
}

export function copyDirRecursive(src: string, dst: string): void {
  fs.mkdirSync(dst, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dst, entry.name);
    if (entry.isDirectory()) {
      copyDirRecursive(s, d);
    } else {
      fs.copyFileSync(s, d);
    }
  }
}

export function walkFiles(dir: string, out: string[] = []): string[] {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkFiles(full, out);
    } else {
      out.push(full);
    }
  }
  return out;
}

export function formatMB(bytes: number): string {
  return (bytes / (1024 * 1024)).toFixed(1);
}

export function findCargoCmd(): { cmd: string; prefixArgs: string[] } {
  // Prefer cargo directly if on PATH, otherwise fall back to `mise exec -- cargo`.
  const probe = spawnSync('cargo', ['--version'], { encoding: 'utf8', windowsHide: true });
  if (!probe.error && probe.status === 0) {
    return { cmd: 'cargo', prefixArgs: [] };
  }
  return { cmd: 'mise', prefixArgs: ['exec', '--', 'cargo'] };
}

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { ROOT, W3X2LNI_DIR } from './common.ts';

const DEFAULT_W3X2LNI_REF = '82916514a12b7edb15252d42225cd8cc8ce61cfd';
const WANTED_TOP = new Set(['script', 'data', 'template', 'config.ini', 'LICENSE.txt', 'README.md']);

export interface SetupOptions {
  ref?: string;
  url?: string;
  dest?: string;
  force?: boolean;
}

interface ZipEntry {
  name: string;
  compressionMethod: number;
  compressedSize: number;
  localHeaderOffset: number;
}

/** Minimal zero-dependency ZIP central-directory reader (handles UTF-8 entries cleanly). */
function parseZipEntries(buf: Buffer): ZipEntry[] {
  // Locate End of Central Directory (EOCD) signature 0x06054b50
  let eocd = -1;
  const minOff = Math.max(0, buf.length - 65557);
  for (let i = buf.length - 22; i >= minOff; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('Invalid ZIP archive: EOCD signature not found');

  const totalEntries = buf.readUInt16LE(eocd + 10);
  const cdOffset = buf.readUInt32LE(eocd + 16);
  const entries: ZipEntry[] = [];
  let pos = cdOffset;

  for (let i = 0; i < totalEntries; i++) {
    if (buf.readUInt32LE(pos) !== 0x02014b50) {
      throw new Error(`Invalid ZIP central directory entry at offset ${pos}`);
    }
    const compressionMethod = buf.readUInt16LE(pos + 10);
    const compressedSize = buf.readUInt32LE(pos + 20);
    const nameLen = buf.readUInt16LE(pos + 28);
    const extraLen = buf.readUInt16LE(pos + 30);
    const commentLen = buf.readUInt16LE(pos + 32);
    const localHeaderOffset = buf.readUInt32LE(pos + 42);
    const name = buf.subarray(pos + 46, pos + 46 + nameLen).toString('utf8');
    entries.push({ name, compressionMethod, compressedSize, localHeaderOffset });
    pos += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

function extractEntryData(buf: Buffer, entry: ZipEntry): Buffer {
  const off = entry.localHeaderOffset;
  if (buf.readUInt32LE(off) !== 0x04034b50) {
    throw new Error(`Invalid ZIP local file header for ${entry.name}`);
  }
  const nameLen = buf.readUInt16LE(off + 26);
  const extraLen = buf.readUInt16LE(off + 28);
  const dataStart = off + 30 + nameLen + extraLen;
  const raw = buf.subarray(dataStart, dataStart + entry.compressedSize);
  if (entry.compressionMethod === 0) return raw;
  if (entry.compressionMethod === 8) return zlib.inflateRawSync(raw);
  throw new Error(`Unsupported ZIP compression method ${entry.compressionMethod} for ${entry.name}`);
}

export async function runSetup(opts: SetupOptions = {}): Promise<void> {
  const ref = opts.ref ?? DEFAULT_W3X2LNI_REF;
  const dest = path.resolve(opts.dest ?? W3X2LNI_DIR);
  const url = opts.url ?? `https://codeload.github.com/sumneko/w3x2lni/zip/${ref}`;

  const readyMarker = path.join(dest, 'script', 'main.lua');
  const dataMarker = path.join(dest, 'data', 'enUS-1.27.1', 'prebuilt', 'metadata.ini');
  if (!opts.force && fs.existsSync(readyMarker) && fs.existsSync(dataMarker)) {
    console.log(`[setup] w3x2lni already populated at ${dest} (pass --force to re-fetch)`);
  } else {
    console.log(`[setup] downloading w3x2lni (${ref.slice(0, 12)}) from ${url}`);
    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`Failed to download ${url}: HTTP ${res.status} ${res.statusText}`);
    }
    const zipBuf = Buffer.from(await res.arrayBuffer());
    console.log(`[setup] downloaded ${(zipBuf.length / (1024 * 1024)).toFixed(1)} MB`);

    const entries = parseZipEntries(zipBuf);
    if (entries.length === 0) throw new Error('Downloaded w3x2lni archive is empty');
    const prefix = entries[0].name.split('/')[0];

    const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'w3x2lni-stage-'));
    try {
      let written = 0;
      for (const entry of entries) {
        const rel = entry.name.slice(prefix.length).replace(/^\/+/, '');
        if (!rel) continue;
        const top = rel.split('/')[0];
        if (!WANTED_TOP.has(top)) continue;
        const target = path.join(stage, ...rel.split('/'));
        if (entry.name.endsWith('/')) {
          fs.mkdirSync(target, { recursive: true });
        } else {
          fs.mkdirSync(path.dirname(target), { recursive: true });
          fs.writeFileSync(target, extractEntryData(zipBuf, entry));
          written++;
        }
      }
      console.log(`[setup] extracted ${written} files from ${prefix}`);

      fs.mkdirSync(dest, { recursive: true });
      for (const item of WANTED_TOP) {
        const from = path.join(stage, item);
        if (!fs.existsSync(from)) continue;
        const to = path.join(dest, item);
        fs.rmSync(to, { recursive: true, force: true });
        fs.cpSync(from, to, { recursive: true });
        console.log(`[setup]   ok: ${item}`);
      }
    } finally {
      fs.rmSync(stage, { recursive: true, force: true });
    }
  }

  // Verify tracked runtime & optional embedded D3DX redistributable
  const runtimeExe = path.join(dest, 'bin', 'w3x2lni-lua.exe');
  if (!fs.existsSync(runtimeExe)) {
    throw new Error(`w3x2lni runtime missing: ${runtimeExe}`);
  }
  const d3dxCandidates = [
    path.join(ROOT, 'reference', 'builtin-japi', 'extracted', 'D3DX9_42.dll'),
    path.join(process.env.WINDIR ?? String.raw`C:\Windows`, 'SysWOW64', 'D3DX9_42.dll'),
    path.join(process.env.WINDIR ?? String.raw`C:\Windows`, 'System32', 'D3DX9_42.dll'),
  ];
  const d3dx = d3dxCandidates.find((p) => fs.existsSync(p));
  console.log(`[setup] w3x2lni runtime : ${runtimeExe}`);
  console.log(`[setup] D3DX9_42.dll    : ${d3dx ?? '(not found - single-TGA will embed newD3d9.dll only)'}`);
  console.log('[setup] Ready. Next: `mise run build` then `mise run test`.');
}

// Agent-Prompts: history (<userData>/prompts/, one .md file per prompt). Port of APStore.swift.
//
// Each file: a header (--- … ---) with id/date/app/source, then the prompt, then after the marker the original dictation.
// Writes are always atomic (temporary file in the same folder + rename), mode 0600, folder 0700. At most 50.
// Broken files are never deleted on load: they move to prompts/defekt/ (and are skipped). Leftover temp files are removed.
import { randomUUID } from 'node:crypto';
import { chmodSync, closeSync, existsSync, fsyncSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync, writeSync } from 'node:fs';
import path from 'node:path';
import { gistOf, type Gist } from './core';

/** a stored prompt – always with the original dictation */
export interface APRecord {
  id: string;
  /** ISO date */
  created: string;
  prompt: string;
  original: string;
  appName: string;
  windowTitle: string;
  /** „claude/sonnet/low“, „regeln“ – and why (e.g. „Claude nicht erreichbar“) */
  source: string;
  note: string;
  /** „zuruf“ (spoken) or „vorschlag“ (card) */
  trigger: string;
  buildMs: number;
}

export const MAX_PROMPTS = 50;
export const ORIGINAL_MARK = '<!-- flow:original -->';

export const byRules = (r: Pick<APRecord, 'source'>): boolean => r.source.startsWith('regeln');
export const recordGist = (r: Pick<APRecord, 'prompt'>): Gist => gistOf(r.prompt);
export const recordTitle = (r: Pick<APRecord, 'prompt'>): string => gistOf(r.prompt).goal || 'Agent-Prompt';

export const newRecordId = (): string => randomUUID();

const oneLine = (s: string) => s.replace(/[\r\n]/gu, ' ');

export function serialize(r: APRecord): string {
  let s = '---\n';
  s += `id: ${oneLine(r.id)}\n`;
  s += `created: ${new Date(r.created).toISOString()}\n`;
  s += `app: ${oneLine(r.appName)}\n`;
  s += `window: ${oneLine(r.windowTitle)}\n`;
  s += `source: ${oneLine(r.source)}\n`;
  s += `note: ${oneLine(r.note)}\n`;
  s += `trigger: ${oneLine(r.trigger)}\n`;
  s += `build_ms: ${Math.round(r.buildMs) || 0}\n`;
  s += '---\n\n';
  s += r.prompt.trim();
  s += `\n\n${ORIGINAL_MARK}\n\n`;
  s += r.original.trim();
  s += '\n';
  return s;
}

export function parse(raw: string): APRecord | null {
  const s = raw.replace(/\r\n/gu, '\n');
  if (!s.startsWith('---\n')) return null;
  const body = s.slice(4);
  const end = body.indexOf('\n---\n');
  if (end < 0) return null;
  const meta = new Map<string, string>();
  for (const line of body.slice(0, end).split('\n').filter((l) => l.length > 0)) {
    const c = line.indexOf(':');
    if (c < 0) return null;
    meta.set(line.slice(0, c).trim(), line.slice(c + 1).trim());
  }
  const rest = body.slice(end + 5);
  const id = meta.get('id') ?? '';
  const created = meta.get('created') ?? '';
  if (!id || !created || Number.isNaN(Date.parse(created))) return null;
  let at = rest.indexOf(`\n${ORIGINAL_MARK}\n`);
  let markLen = ORIGINAL_MARK.length + 2;
  if (at < 0) { at = rest.indexOf(ORIGINAL_MARK); markLen = ORIGINAL_MARK.length; }
  if (at < 0) return null;
  const prompt = rest.slice(0, at).trim();
  const original = rest.slice(at + markLen).trim();
  if (!prompt) return null;
  return {
    id, created: new Date(created).toISOString(), prompt, original, appName: meta.get('app') ?? '', windowTitle: meta.get('window') ?? '',
    source: meta.get('source') ?? '', note: meta.get('note') ?? '', trigger: meta.get('trigger') || 'zuruf', buildMs: Number(meta.get('build_ms')) || 0,
  };
}

const pad = (n: number, w = 2) => String(n).padStart(w, '0');

function sleepSync(ms: number) {
  try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch { /* */ }
}

/** Windows: a virus scanner or the indexer may hold the target for a moment (EPERM/EBUSY) – retry a few times */
function renameWithRetry(from: string, to: string) {
  for (let attempt = 0; ; attempt++) {
    try { renameSync(from, to); return; } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      if (attempt >= 5 || (code !== 'EPERM' && code !== 'EBUSY' && code !== 'EACCES')) throw e;
      sleepSync(15 * (attempt + 1));
    }
  }
}

export class APStore {
  records: APRecord[] = [];
  /** broken files moved away on the last load (tests/log) */
  quarantined = 0;
  onChange: () => void = () => {};

  constructor(readonly dir: string, private log: (line: string) => void = () => {}, load = true) {
    if (load) this.reload();
  }

  private ensureDir() {
    mkdirSync(this.dir, { recursive: true, mode: 0o700 });
  }

  reload(): void {
    try { this.ensureDir(); } catch { /* read-only? then empty */ }
    const out: APRecord[] = [];
    let bad = 0;
    let names: string[] = [];
    try { names = readdirSync(this.dir); } catch { names = []; }
    for (const f of names) {
      if (!f.endsWith('.md') || f.startsWith('.')) continue;
      const file = path.join(this.dir, f);
      let r: APRecord | null = null;
      try { r = parse(readFileSync(file, 'utf8')); } catch { r = null; }
      if (r) out.push(r); else { bad++; this.quarantine(file); }
    }
    // leftovers of a crash in the middle of writing
    for (const f of names) if (f.startsWith('.tmp-')) { try { rmSync(path.join(this.dir, f), { force: true }); } catch { /* */ } }
    this.quarantined = bad;
    if (bad > 0) this.log(`Agent-Prompts: ${bad} kaputte Datei(en) nach prompts/defekt/ verschoben`);
    this.records = out.sort((a, b) => Date.parse(b.created) - Date.parse(a.created));
  }

  record(id: string | null | undefined): APRecord | null { return this.records.find((r) => r.id === id) ?? null; }

  private quarantine(file: string) {
    try {
      const d = path.join(this.dir, 'defekt');
      mkdirSync(d, { recursive: true, mode: 0o700 });
      renameSync(file, path.join(d, `${path.basename(file)}-${Math.floor(Date.now() / 1000)}`));
    } catch { /* stays where it is, skipped again next time */ }
  }

  add(r: APRecord): APRecord {
    const old = this.record(r.id);
    this.write(r);
    if (old && this.fileName(old) !== this.fileName(r)) { try { rmSync(this.filePath(old), { force: true }); } catch { /* */ } }
    this.records = [r, ...this.records.filter((x) => x.id !== r.id)];
    this.trim();
    this.onChange();
    return r;
  }

  delete(id: string): void {
    const r = this.record(id);
    if (r) { try { rmSync(this.filePath(r), { force: true }); } catch { /* */ } }
    this.records = this.records.filter((x) => x.id !== id);
    this.onChange();
  }

  private trim() {
    if (this.records.length <= MAX_PROMPTS) return;
    for (const r of this.records.slice(MAX_PROMPTS)) { try { rmSync(this.filePath(r), { force: true }); } catch { /* */ } }
    this.records = this.records.slice(0, MAX_PROMPTS);
  }

  fileName(r: APRecord): string {
    const d = new Date(r.created);
    const stamp = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}_${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}`;
    return `${stamp}_${r.id.replace(/[^A-Za-z0-9-]/gu, '').slice(0, 8) || 'prompt'}.md`;
  }

  filePath(r: APRecord): string { return path.join(this.dir, this.fileName(r)); }

  /** atomic: write a temporary file in the same folder, then rename over the target (never half a file) */
  write(r: APRecord): void {
    this.ensureDir();
    const final = this.filePath(r);
    const tmp = path.join(this.dir, `.tmp-${randomUUID()}.md`);
    try {
      const fd = openSync(tmp, 'w', 0o600);
      try { writeSync(fd, Buffer.from(serialize(r), 'utf8')); fsyncSync(fd); } finally { closeSync(fd); }
      try { chmodSync(tmp, 0o600); } catch { /* Windows: ACLs of the profile folder apply */ }
      renameWithRetry(tmp, final);
    } catch (e) {
      try { if (existsSync(tmp)) rmSync(tmp, { force: true }); } catch { /* */ }
      this.log(`Agent-Prompt speichern fehlgeschlagen: ${(e as NodeJS.ErrnoException).code ?? 'Fehler'}`);
    }
  }
}

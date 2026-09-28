// Client for the UI Automation helper (flow-uia.ps1): one long-lived powershell.exe, started on demand, one JSON
// request per line on stdin, one JSON reply per line on stdout.
//
// Why a PowerShell helper and not koffi → IUIAutomation (COM) in the main process:
//   • UIA calls block until the target app answers (hundreds of ms, a hung app: seconds). In the Electron main process
//     that would freeze the pill, the hotkey and the paste. In a child process a stuck call is simply killed.
//   • Microsoft advises against UIA client calls on a UI thread (re-entrancy/deadlocks with the app's own windows).
//   • System.Windows.Automation (UIAutomationClient, part of .NET Framework on every Windows 10/11) is a complete,
//     tested UIA client – vtable-level COM with VARIANT/SAFEARRAY marshalling through koffi would be a lot of fragile
//     code nobody can verify without a Windows PC.
//   • no compiled binary to sign/ship: the helper is a ~250-line text file (asarUnpack'ed).
// Cost: ~0.5–1.5 s start-up once (the process then stays; it is stopped after 5 minutes without use), ~40 MB RAM.
// If PowerShell is blocked (Constrained Language Mode, AppLocker) the helper fails to start → `available` becomes
// false and both features fall back to what works without UI Automation.
import type { Point, UiaNode } from '../../core/mouseTarget';
import type { UiaElement, UiaPort, UiaRead } from './types';

export interface LineProcess {
  write(line: string): void;
  onLine(cb: (line: string) => void): void;
  onExit(cb: (code: number | null) => void): void;
  kill(): void;
}
export type Spawner = () => LineProcess;

interface Pending { resolve: (v: Record<string, unknown> | null) => void; timer: ReturnType<typeof setTimeout> }

export interface UiaClientOptions {
  spawn: Spawner;
  log?: (...a: unknown[]) => void;
  startTimeoutMs?: number;
  idleMs?: number;
  /** after this many failed starts/timeouts in a row the helper is given up for this session */
  maxFailures?: number;
  timers?: { setTimeout: typeof setTimeout; clearTimeout: typeof clearTimeout };
}

export class UiaClient implements UiaPort {
  private proc: LineProcess | null = null;
  private ready: Promise<boolean> | null = null;
  private pending = new Map<number, Pending>();
  private seq = 0;
  private failures = 0;
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private gaveUp = false;
  dpiAware = false;
  private readonly t: { setTimeout: typeof setTimeout; clearTimeout: typeof clearTimeout };

  constructor(private o: UiaClientOptions) {
    this.t = o.timers ?? { setTimeout, clearTimeout };
  }

  get available(): boolean { return !this.gaveUp; }

  private log(...a: unknown[]) { this.o.log?.('[uia]', ...a); }

  private start(): Promise<boolean> {
    if (this.ready) return this.ready;
    this.ready = new Promise<boolean>((resolve) => {
      let settled = false;
      const done = (ok: boolean) => { if (settled) return; settled = true; this.t.clearTimeout(timer); resolve(ok); };
      let proc: LineProcess;
      try {
        proc = this.o.spawn();
      } catch (e) {
        this.log('start failed', e);
        this.fail();
        done(false);
        return;
      }
      this.proc = proc;
      const timer = this.t.setTimeout(() => { this.log('start timeout'); this.fail(); this.kill(); done(false); }, this.o.startTimeoutMs ?? 8000);
      proc.onLine((line) => {
        let msg: Record<string, unknown>;
        try { msg = JSON.parse(line) as Record<string, unknown>; } catch { return; }
        if (msg.ready === true) {
          this.dpiAware = msg.dpi === true;
          this.failures = 0;
          this.log(`helper ready (v${String(msg.v ?? '?')}, dpi ${this.dpiAware ? 'per monitor' : 'unaware – coordinate commands off'})`);
          done(true);
          return;
        }
        const id = Number(msg.id);
        const p = this.pending.get(id);
        if (!p) return;
        this.pending.delete(id);
        this.t.clearTimeout(p.timer);
        p.resolve(msg.ok === true ? msg : null);
      });
      proc.onExit((code) => {
        if (this.proc === proc) { this.proc = null; this.ready = null; }
        for (const [, p] of this.pending) { this.t.clearTimeout(p.timer); p.resolve(null); }
        this.pending.clear();
        if (!settled) { this.log('helper exited during start', code); this.fail(); }
        done(false);
      });
    });
    return this.ready;
  }

  private fail() {
    this.failures++;
    if (this.failures >= (this.o.maxFailures ?? 3) && !this.gaveUp) { this.gaveUp = true; this.log('helper given up for this session'); }
  }

  private kill() {
    const p = this.proc;
    this.proc = null;
    this.ready = null;
    try { p?.kill(); } catch { /* */ }
  }

  private touch() {
    if (this.idleTimer) this.t.clearTimeout(this.idleTimer);
    this.idleTimer = this.t.setTimeout(() => { this.idleTimer = null; if (this.pending.size === 0) { this.log('idle – helper stopped'); this.kill(); } }, this.o.idleMs ?? 5 * 60_000);
  }

  /** one request; null on error/timeout (a timed-out helper is killed – it is probably stuck in a hung app) */
  async request(cmd: string, args: Record<string, unknown> = {}, timeoutMs = 1200): Promise<Record<string, unknown> | null> {
    if (this.gaveUp) return null;
    if (!(await this.start())) return null;
    const proc = this.proc;
    if (!proc) return null;
    this.touch();
    const id = ++this.seq;
    return new Promise((resolve) => {
      const timer = this.t.setTimeout(() => {
        if (!this.pending.has(id)) return;
        this.pending.delete(id);
        this.log(`${cmd}: timeout after ${timeoutMs} ms – helper restarted on next use`);
        this.fail();
        this.kill();
        resolve(null);
      }, timeoutMs);
      this.pending.set(id, { resolve, timer });
      try { proc.write(JSON.stringify({ id, cmd, ...args }) + '\n'); } catch { this.pending.delete(id); this.t.clearTimeout(timer); resolve(null); }
    });
  }

  /** start the helper in the background (e.g. when the setting is switched on), so the first dictation does not wait */
  warm(): void { if (!this.gaveUp) void this.start(); }

  async at(p: Point): Promise<UiaElement | null> {
    const r = await this.request('at', { x: Math.round(p.x), y: Math.round(p.y) }, 900);
    // a DPI-unaware helper would see scaled coordinates on 125 %/150 % monitors → its answer is not trusted
    return r && this.dpiAware ? toElement(r.el) : null;
  }
  async focused(opts: { value?: boolean } = {}): Promise<UiaElement | null> {
    const r = await this.request('focused', { value: !!opts.value }, 900);
    return r ? toElement(r.el) : null;
  }
  async setFocusAt(p: Point): Promise<boolean> {
    if (!this.dpiAware) return false;
    const r = await this.request('setFocusAt', { x: Math.round(p.x), y: Math.round(p.y) }, 900);
    return r?.focused === true;
  }
  async read(): Promise<UiaRead | null> { return toRead(await this.request('read', {}, 2500)); }
  async reread(): Promise<UiaRead | null> { return toRead(await this.request('reread', {}, 2500)); }

  dispose(): void {
    if (this.idleTimer) this.t.clearTimeout(this.idleTimer);
    try { this.proc?.write(JSON.stringify({ id: 0, cmd: 'quit' }) + '\n'); } catch { /* */ }
    this.kill();
  }
}

// ── response normalisation (PowerShell's ConvertTo-Json: numbers may be strings, single values not arrays) ──

const str = (v: unknown) => (typeof v === 'string' ? v : v === null || v === undefined ? '' : String(v));
const num = (v: unknown) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : v === null || v === undefined ? [] : [v]);

export function toNode(v: unknown): UiaNode {
  const o = (v && typeof v === 'object' ? v : {}) as Record<string, unknown>;
  const n: UiaNode = { ct: str(o.ct).replace(/^ControlType\./u, ''), cls: str(o.cls).slice(0, 200) };
  if (o.pwd === true) n.pwd = true;
  if (o.ed === true || o.editable === true) n.editable = true;
  return n;
}

export function toElement(v: unknown): UiaElement | null {
  if (!v || typeof v !== 'object') return null;
  const o = v as Record<string, unknown>;
  const chain = arr(o.chain).map(toNode);
  if (!chain.length) return null;
  const el: UiaElement = { chain, root: num(o.root), pid: num(o.pid), pwd: o.pwd === true || chain[0]!.pwd === true, editable: o.ed === true || chain[0]!.editable === true };
  if (typeof o.value === 'string' && !el.pwd) el.value = o.value;
  return el;
}

export function toRead(r: Record<string, unknown> | null): UiaRead | null {
  if (!r) return null;
  const kind = str(r.kind);
  const out: UiaRead = { kind: kind === 'field' || kind === 'terminal' || kind === 'xterm' ? kind : 'none', pid: num(r.pid), root: num(r.root) };
  if (r.pwd === true) { out.pwd = true; out.kind = 'none'; return out; }
  if (out.kind === 'field' && typeof r.text === 'string') out.text = r.text;
  if (out.kind === 'terminal' || out.kind === 'xterm') out.rows = arr(r.rows).map(str);
  return out;
}

/** real process (Windows only): powershell.exe with the helper script, hidden window, UTF-8 pipes */
export function powershellSpawner(scriptPath: string): Spawner {
  return () => {
    const { spawn } = require('node:child_process') as typeof import('node:child_process');
    // A script *file* would be subject to the execution policy (GPO can override -ExecutionPolicy Bypass); a command
    // string is not. So the file is read and run as a script block.
    const lit = scriptPath.replace(/'/gu, "''");
    const cmd = `& ([scriptblock]::Create([IO.File]::ReadAllText('${lit}', [Text.Encoding]::UTF8)))`;
    const child = spawn('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', cmd], {
      windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'],
    });
    let buf = '';
    const lineCbs: ((l: string) => void)[] = [];
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (d: string) => {
      buf += d;
      let i: number;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).replace(/\r$/u, '');
        buf = buf.slice(i + 1);
        if (line) for (const cb of lineCbs) cb(line);
      }
    });
    child.stdin.on('error', () => { /* helper gone */ });
    return {
      write: (l) => { child.stdin.write(l, 'utf8'); },
      onLine: (cb) => { lineCbs.push(cb); },
      onExit: (cb) => { child.on('exit', (code) => cb(code)); child.on('error', () => cb(null)); },
      kill: () => { try { child.kill(); } catch { /* */ } },
    };
  };
}

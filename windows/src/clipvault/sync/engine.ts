// ClipVault sync client for Windows – talks to the SAME Cloudflare Worker as the Mac (clipvault/sync-worker),
// wire-compatible with clipvault/sync.swift. Off by default; the user enters their own worker URL (no default).
//
//   HTTP  /v/<vault>/{init,invite,join,info,since,items/<id>,items/<id>/{begin,parts/<n>,commit}}
//   WS    /v/<vault>/ws?device=<id>  – auth via Sec-WebSocket-Protocol "cvsync.v1, auth.<token>"
//         "ping" -> "pong" (answered by the runtime), {"type":"item",…}, {"type":"peer","event":"joined"}
//   Heartbeat: ping every 30 s (+0–3 s jitter); no pong within 10 s -> reconnect, backoff 1 -> 30 s (+jitter).
//   Catch-up via /since on connect, every 60 s, after resume / network change and when HTTP works again.
//   Outbox: sync-queue.json (ids) survives restarts and offline periods.
//   Secrets (vault key + token) never touch sync.json: sync-secrets.bin, protected by the SecretBox
//   (DPAPI on Windows). Content and keys are never logged.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';
import { writeFileAtomic, readFileOrNull } from '../core/atomic';
import type { SharedVault } from './vault';
import {
  seal, open, itemAAD, partAAD, encodeItem, encodeVocab, decodeAny, encodePairCode, decodePairCode, isBig, isUuid,
  expectedPartLen, PART_SIZE, AUTO_DOWNLOAD_MAX, vocabIdKey, vocabId, type SharedItem, type VocabEntry, type Opened,
} from './wire';

export interface SecretBox {
  protect(plain: Buffer): Buffer;
  unprotect(blob: Buffer): Buffer;
}

export interface WsLike {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  onopen: ((ev: unknown) => void) | null;
  onmessage: ((ev: { data: unknown }) => void) | null;
  onclose: ((ev: { code?: number; reason?: string }) => void) | null;
  onerror: ((ev: unknown) => void) | null;
}
export type WsFactory = (url: string, protocols: string[]) => WsLike;
export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body?: Uint8Array | string }) => Promise<{
  status: number; ok: boolean; arrayBuffer(): Promise<ArrayBuffer>;
}>;

export interface SyncConfig {
  url?: string;
  vaultId?: string;
  deviceId?: string;
  cursor?: number;
  partnerJoined?: boolean;
  proto?: number;
}

export type SyncState = 'off' | 'unconfigured' | 'unpaired' | 'pairing' | 'waiting' | 'connecting' | 'connected' | 'offline';

export interface SyncSnapshot {
  state: SyncState;
  reason: string;
  paired: boolean;
  partnerJoined: boolean;
  queue: number;
  pairingCode: string | null;
  pairingExpires: number | null;
  lastLatencyMs: number | null;
  host: string;
  vault: string;
  used?: number;
  quota?: number;
  transfers: Record<string, { dir: 'up' | 'down'; done: number; total: number }>;
}

export class SyncError extends Error {
  constructor(message: string, public status = 0, public network = false) { super(message); }
}

export interface EngineDeps {
  dir: string;
  vault: SharedVault;
  secrets: SecretBox;
  fetch: FetchLike;
  ws: WsFactory;
  me: () => string;
  log?: (...a: unknown[]) => void;
  now?: () => number;
  onSnapshot?: (s: SyncSnapshot) => void;
  onReceived?: (items: SharedItem[], live: boolean) => void;
  /** timings (tests shorten them) */
  pingEveryMs?: number;
  pongTimeoutMs?: number;
  periodicMs?: number;
  random?: () => number;
}

const FILES = { config: 'sync.json', queue: 'sync-queue.json', secrets: 'sync-secrets.bin', vocab: 'vocab.json' };

export class SyncEngine {
  private cfg: SyncConfig = {};
  private key: Buffer | null = null;
  private token: string | null = null;
  private queue: string[] = [];
  private state: SyncState = 'unconfigured';
  private reason = '';
  private pairingCode: string | null = null;
  private pairingExpires: number | null = null;
  private pairingBaseline = 1;
  private ws: WsLike | null = null;
  private gen = 0;
  private lastPong = 0;
  private backoff = 1;
  private flushing = false;
  private flushRetryAt = 0;
  private catching = false;
  private catchAgain = false;
  private lastLatencyMs: number | null = null;
  private timers = new Set<ReturnType<typeof setTimeout>>();
  private periodicTimer: ReturnType<typeof setInterval> | null = null;
  private tick = 0;
  private stopped = false;
  private uploads = new Map<string, Promise<void>>();
  private downloads = new Map<string, { cancel: boolean }>();
  private transfers: SyncSnapshot['transfers'] = {};
  private vocab: VocabEntry[] = [];
  private storage: { used: number; quota: number } | null = null;
  private readonly now: () => number;
  private readonly rnd: () => number;

  constructor(private d: EngineDeps) {
    this.now = d.now ?? (() => Date.now());
    this.rnd = d.random ?? Math.random;
  }

  private p(f: string) { return path.join(this.d.dir, f); }
  private log(msg: string) { this.d.log?.('[clipvault] Sync: ' + msg); }
  private get paired() { return !!(this.cfg.vaultId && this.key && this.token && this.cfg.url); }
  private get device() { return this.cfg.deviceId ?? 'unknown'; }

  // ------------------------------------------------------------------ persistence
  private saveConfig() { writeFileAtomic(this.p(FILES.config), JSON.stringify(this.cfg, null, 1)); }
  private saveQueue() { writeFileAtomic(this.p(FILES.queue), JSON.stringify(this.queue)); }
  private saveSecrets() {
    if (!this.key || !this.token) { try { fs.rmSync(this.p(FILES.secrets), { force: true }); } catch { /* ignore */ } return; }
    const plain = Buffer.from(JSON.stringify({ key: this.key.toString('hex'), token: this.token }), 'utf8');
    writeFileAtomic(this.p(FILES.secrets), this.d.secrets.protect(plain));
  }
  private loadSecrets() {
    const raw = readFileOrNull(this.p(FILES.secrets));
    this.key = null; this.token = null;
    if (!raw) return;
    try {
      const o = JSON.parse(this.d.secrets.unprotect(raw).toString('utf8'));
      if (typeof o.key === 'string' && o.key.length === 64) this.key = Buffer.from(o.key, 'hex');
      if (typeof o.token === 'string' && /^[0-9a-f]{64}$/.test(o.token)) this.token = o.token;
    } catch {
      this.log('secrets unreadable (other user/machine?) – pair again');
    }
  }
  private loadVocab() {
    try { this.vocab = JSON.parse(readFileOrNull(this.p(FILES.vocab))?.toString('utf8') ?? '{"items":[]}').items ?? []; } catch { this.vocab = []; }
  }
  private saveVocab() { writeFileAtomic(this.p(FILES.vocab), JSON.stringify({ version: 1, items: this.vocab.slice(-2000) })); }

  // ------------------------------------------------------------------ lifecycle
  start(): void {
    this.stopped = false;
    try { this.cfg = JSON.parse(readFileOrNull(this.p(FILES.config))?.toString('utf8') ?? '{}'); } catch { this.cfg = {}; }
    if (!this.cfg.deviceId) { this.cfg.deviceId = randomUUID(); this.saveConfig(); }
    if ((this.cfg.proto ?? 0) < 3) { this.cfg.cursor = 0; this.cfg.proto = 3; this.saveConfig(); }
    try { const q = JSON.parse(readFileOrNull(this.p(FILES.queue))?.toString('utf8') ?? '[]'); this.queue = Array.isArray(q) ? q : []; } catch { this.queue = []; }
    this.loadSecrets();
    this.loadVocab();
    if (this.paired) { this.state = 'connecting'; this.connect(); } else this.state = this.cfg.url ? 'unpaired' : 'unconfigured';
    this.periodicTimer = setInterval(() => void this.periodic(), this.d.periodicMs ?? 5000);
    this.emit();
  }

  stop(): void {
    this.stopped = true;
    this.gen++;
    try { this.ws?.close(1000, 'bye'); } catch { /* ignore */ }
    this.ws = null;
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    if (this.periodicTimer) clearInterval(this.periodicTimer);
    this.periodicTimer = null;
    for (const dl of this.downloads.values()) dl.cancel = true;
  }

  private later(ms: number, fn: () => void) {
    if (this.stopped) return;
    const t = setTimeout(() => { this.timers.delete(t); if (!this.stopped) fn(); }, ms);
    this.timers.add(t);
  }

  snapshot(): SyncSnapshot {
    if (this.pairingExpires && this.pairingExpires < this.now()) this.endPairing();
    const st: SyncState = this.pairingCode ? 'pairing' : this.paired && !this.cfg.partnerJoined && this.state === 'connected' ? 'waiting' : this.state;
    let host = '';
    try { host = this.cfg.url ? new URL(this.cfg.url).host : ''; } catch { /* ignore */ }
    return {
      state: st, reason: this.reason, paired: this.paired, partnerJoined: !!this.cfg.partnerJoined, queue: this.queue.length,
      pairingCode: this.pairingCode, pairingExpires: this.pairingExpires, lastLatencyMs: this.lastLatencyMs, host,
      vault: (this.cfg.vaultId ?? '').slice(0, 8), transfers: { ...this.transfers },
      ...(this.storage ? { used: this.storage.used, quota: this.storage.quota } : {}),
    };
  }
  private emit() { this.d.onSnapshot?.(this.snapshot()); }
  private setState(s: SyncState, why = '') {
    if (s === this.state && why === this.reason) return;
    this.state = s; this.reason = why; this.emit();
  }

  private async periodic() {
    this.tick++;
    if (this.pairingCode) await this.pollPairing();
    if (this.pairingExpires && this.pairingExpires < this.now()) { this.endPairing(); this.emit(); }
    if (this.tick % 12 === 0 && this.paired) { await this.catchUp(); await this.flush(); }
    if (this.tick % 60 === 3 && this.paired) await this.refreshInfo();
    if (this.flushRetryAt && this.flushRetryAt < this.now() && this.queue.length) { this.flushRetryAt = 0; await this.flush(); }
  }

  // ------------------------------------------------------------------ HTTP
  private base(): string {
    const u = (this.cfg.url ?? '').replace(/[/\s]+$/, '');
    if (!u) throw new SyncError('Sync ist nicht eingerichtet (Worker-URL fehlt)');
    return u;
  }
  private vaultPath(): string {
    if (!this.cfg.vaultId) throw new SyncError('nicht gekoppelt');
    return this.base() + '/v/' + this.cfg.vaultId;
  }
  private async request(method: string, url: string, body?: Buffer | string, auth?: string | null, headers: Record<string, string> = {}): Promise<Buffer> {
    const h: Record<string, string> = { 'X-CV-Device': this.device, ...headers };
    if (auth) h.Authorization = 'Bearer ' + auth;
    let res: Awaited<ReturnType<FetchLike>>;
    try {
      res = await this.d.fetch(url, { method, headers: h, body: typeof body === 'string' ? body : body ? new Uint8Array(body) : undefined });
    } catch {
      throw new SyncError('keine Verbindung', 0, true);
    }
    const data = Buffer.from(await res.arrayBuffer());
    if (res.status < 500 && !this.ws && this.state === 'offline' && this.paired) { this.backoff = 1; this.connect(); }
    if (!res.ok) {
      let msg = `HTTP ${res.status}`;
      try { const o = JSON.parse(data.toString('utf8')); if (typeof o.error === 'string') msg = o.error.slice(0, 160); } catch { /* not json */ }
      throw new SyncError(msg, res.status, res.status >= 500);
    }
    return data;
  }
  private json(d: Buffer): Record<string, unknown> {
    try { const o = JSON.parse(d.toString('utf8')); return o && typeof o === 'object' ? o : {}; } catch { return {}; }
  }

  // ------------------------------------------------------------------ setup + pairing
  setup(url: string): { url: string } {
    const u = url.trim().replace(/\/+$/, '');
    let p: URL;
    try { p = new URL(u); } catch { throw new SyncError('URL muss https:// sein (http nur für localhost)'); }
    const localHttp = p.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(p.hostname);
    if (p.protocol !== 'https:' && !localHttp) throw new SyncError('URL muss https:// sein (http nur für localhost)');
    if (this.paired && this.cfg.url !== u) throw new SyncError('Schon gekoppelt – erst trennen');
    this.cfg.url = u; this.saveConfig();
    if (!this.paired) this.state = 'unpaired';
    this.emit();
    return { url: u };
  }

  async pairCreate(): Promise<{ code: string; expiresAt: number }> {
    const b = this.base();
    if (!this.paired) {
      const vault = randomUUID().toLowerCase();
      const tok = randomBytes(32).toString('hex');
      const k = randomBytes(32);
      await this.request('POST', `${b}/v/${vault}/init`, undefined, tok);
      this.key = k; this.token = tok; this.saveSecrets();
      Object.assign(this.cfg, { vaultId: vault, cursor: 0, partnerJoined: false }); this.saveConfig();
      this.log(`new vault ${vault.slice(0, 8)}`);
      this.connect();
    }
    const secret = randomBytes(16).toString('hex');
    const d = await this.request('POST', this.vaultPath() + '/invite', JSON.stringify({ secret }), this.token, { 'Content-Type': 'application/json' });
    const expMs = Number(this.json(d).expiresAt) || this.now() + 15 * 60_000;
    const code = encodePairCode({ url: b, vaultId: this.cfg.vaultId!, secret, key: this.key! });
    try { this.pairingBaseline = Number((await this.info()).devices) || 1; } catch { this.pairingBaseline = 1; }
    this.pairingCode = code; this.pairingExpires = expMs;
    this.emit();
    return { code, expiresAt: expMs / 1000 };
  }

  private async info(): Promise<Record<string, unknown>> {
    return this.json(await this.request('GET', this.vaultPath() + '/info', undefined, this.token));
  }
  private async pollPairing() {
    try {
      const i = await this.info();
      if (Number(i.devices) > this.pairingBaseline && i.invite === false) this.partnerDidJoin();
    } catch { /* try again next tick */ }
  }
  private partnerDidJoin() {
    const was = !!this.pairingCode;
    this.cfg.partnerJoined = true; this.saveConfig();
    this.endPairing();
    if (was) this.log('partner joined');
    this.emit();
  }
  private endPairing() { this.pairingCode = null; this.pairingExpires = null; }
  async pairCancel() {
    if (this.token && this.cfg.vaultId) { try { await this.request('DELETE', this.vaultPath() + '/invite', undefined, this.token); } catch { /* ignore */ } }
    this.endPairing(); this.emit();
  }

  async pairJoin(raw: string): Promise<{ vault: string; already?: boolean }> {
    const p = decodePairCode(raw);
    if (!p) throw new SyncError('Code nicht erkannt (beginnt mit cvpair1.)');
    if (this.paired) {
      if (this.cfg.vaultId === p.vaultId) return { vault: p.vaultId.slice(0, 8), already: true };
      throw new SyncError('Schon mit einem anderen Tresor gekoppelt – erst trennen');
    }
    const u = p.url.replace(/\/+$/, '');
    const d = await this.request('POST', `${u}/v/${p.vaultId}/join`, JSON.stringify({ secret: p.secret, device: this.device }), null, { 'Content-Type': 'application/json' });
    const tok = this.json(d).token;
    if (typeof tok !== 'string' || tok.length !== 64) throw new SyncError('Server lieferte keinen Zugang');
    this.key = p.key; this.token = tok; this.saveSecrets();
    Object.assign(this.cfg, { url: u, vaultId: p.vaultId, cursor: 0, partnerJoined: true }); this.saveConfig();
    this.log(`joined vault ${p.vaultId.slice(0, 8)}`);
    this.backoff = 1;
    this.connect();
    void this.catchUp().then(() => this.flush());
    this.emit();
    return { vault: p.vaultId.slice(0, 8) };
  }

  unpair(): void {
    this.gen++;
    try { this.ws?.close(1000, 'unpair'); } catch { /* ignore */ }
    this.ws = null;
    for (const dl of this.downloads.values()) dl.cancel = true;
    this.key = null; this.token = null; this.saveSecrets();
    delete this.cfg.vaultId; delete this.cfg.cursor; delete this.cfg.partnerJoined; this.saveConfig();
    this.queue = []; this.saveQueue();
    this.endPairing();
    this.storage = null;
    this.state = this.cfg.url ? 'unpaired' : 'unconfigured'; this.reason = '';
    this.log('unpaired');
    this.emit();
  }

  // ------------------------------------------------------------------ outbox
  async enqueue(id: string): Promise<void> {
    if (!this.queue.includes(id)) { this.queue.push(id); this.saveQueue(); }
    this.emit();
    await this.flush();
  }
  private dropFromQueue(id: string) {
    const n = this.queue.length;
    this.queue = this.queue.filter((q) => q !== id);
    if (n !== this.queue.length) this.saveQueue();
  }
  private retryLater(e: SyncError) {
    this.flushRetryAt = this.now() + (e.status === 429 ? 15_000 : Math.min(this.backoff * 2, 30) * 1000);
    if (e.network && this.state === 'connected') this.setState('offline', 'keine Verbindung');
  }

  async flush(): Promise<void> {
    if (this.flushing || !this.paired) return;
    this.flushing = true;
    const k = this.key!, tok = this.token!, vault = this.cfg.vaultId!;
    try {
      let i = 0;
      while (i < this.queue.length) {
        const id = this.queue[i]!;
        const it = this.d.vault.item(id);
        if (!it) {
          const v = this.vocab.find((x) => x.id.toLowerCase() === id.toLowerCase());
          if (v) {
            try {
              await this.request('PUT', `${this.vaultPath()}/items/${v.id.toLowerCase()}`, seal(encodeVocab(v), k, itemAAD(vault, v.id)), tok, {
                'Content-Type': 'application/octet-stream', 'X-CV-Updated-At': v.updatedAt.toFixed(6), 'X-CV-Deleted': '0' });
            } catch (e) {
              if (e instanceof SyncError && !(e.status === 400 || e.status === 413 || e.status === 507)) { this.retryLater(e); return; }
            }
          }
          this.dropFromQueue(id);
          continue;
        }
        if (!isUuid(id)) { this.dropFromQueue(id); continue; }
        if (isBig(it) && !it.deleted) {
          if (it.uploadError) { this.dropFromQueue(id); continue; }
          if (!this.uploads.has(id) && this.uploads.size < 2) this.startUpload(id);
          i++;
          continue;
        }
        let sealed: Buffer;
        try {
          const body = it.kind === 'image' || it.kind === 'file' ? (it.deleted ? null : this.d.vault.body(it)) : null;
          sealed = seal(encodeItem({ ...it, body }), k, itemAAD(vault, id));
        } catch (e) {
          this.log('not uploaded: ' + (e as Error).message);
          this.dropFromQueue(id);
          this.d.vault.markUploadFailed(id, (e as Error).message);
          continue;
        }
        const sentAt = it.updatedAt;
        try {
          const d = await this.request('PUT', `${this.vaultPath()}/items/${id.toLowerCase()}`, sealed, tok, {
            'Content-Type': 'application/octet-stream', 'X-CV-Updated-At': it.updatedAt.toFixed(6), 'X-CV-Deleted': it.deleted ? '1' : '0' });
          this.dropFromQueue(id);
          if (this.d.vault.item(id)?.updatedAt === sentAt) this.d.vault.markSynced([id]);
          else if (!this.queue.includes(id)) { this.queue.push(id); this.saveQueue(); }
          if (this.json(d).applied === false) void this.catchUp();
        } catch (e) {
          if (!(e instanceof SyncError)) return;
          if (e.status === 401 || e.status === 404) { this.setState('offline', 'Zugang abgelehnt – neu koppeln'); return; }
          if (e.status === 413 || e.status === 507 || e.status === 400) {
            const msg = e.status === 507 ? 'Geteilter Speicher voll' : e.status === 413 ? 'Zu groß zum Teilen' : `Server lehnte Eintrag ab (${e.message})`;
            this.dropFromQueue(id);
            this.d.vault.markUploadFailed(id, msg);
            continue;
          }
          this.retryLater(e);
          return;
        }
      }
    } finally {
      this.flushing = false;
      this.emit();
    }
  }

  // ------------------------------------------------------------------ big items (v2): upload in parts
  private setTransfer(id: string, t: { dir: 'up' | 'down'; done: number; total: number } | null) {
    if (t) this.transfers[id] = t; else delete this.transfers[id];
    this.emit();
  }
  private startUpload(id: string) {
    const p = this.runUpload(id).finally(() => {
      this.uploads.delete(id);
      this.emit();
      if (this.queue.length && !this.stopped) void this.flush();
    });
    this.uploads.set(id, p);
  }
  /** wait for running uploads (tests / dispose) */
  async idle(): Promise<void> {
    while (this.uploads.size) await Promise.all([...this.uploads.values()]);
  }

  private async runUpload(id: string): Promise<void> {
    const k = this.key, tok = this.token, vault = this.cfg.vaultId;
    const it = this.d.vault.item(id);
    if (!k || !tok || !vault || !it || !isBig(it) || it.deleted || !it.parts || !it.content || !it.size) { this.dropFromQueue(id); return; }
    const file = this.d.vault.localPath(it);
    let fd: number;
    try {
      if (!file || fs.statSync(file).size !== it.size) throw new Error('size');
      fd = fs.openSync(file, 'r');
    } catch {
      this.dropFromQueue(id);
      this.d.vault.markUploadFailed(id, 'Datei fehlt auf der Platte');
      return;
    }
    const parts = it.parts, content = it.content, size = it.size;
    const total = size + parts * 28;
    const itemPath = `${this.vaultPath()}/items/${id.toLowerCase()}`;
    const headers = { 'Content-Type': 'application/octet-stream', 'X-CV-Updated-At': it.updatedAt.toFixed(6), 'X-CV-Parts': String(parts),
      'X-CV-Total': String(total), 'X-CV-Content': content, 'X-CV-Keep': it.pinned ? '1' : '0' };
    try {
      const manifest = seal(encodeItem(it), k, itemAAD(vault, id));
      let bo = this.json(await this.request('POST', itemPath + '/begin', manifest, tok, headers));
      if (bo.applied === false) {
        this.dropFromQueue(id);
        this.d.vault.markSynced([id]);
        void this.catchUp();
        return;
      }
      if (typeof bo.used === 'number' && typeof bo.quota === 'number') this.storage = { used: bo.used, quota: bo.quota };
      for (let round = 0; round < 3; round++) {
        const have = new Set<number>((Array.isArray(bo.have) ? bo.have : []).map(Number));
        let done = [...have].reduce((s, i) => s + expectedPartLen(i, parts, size), 0);
        const missing = [...Array(parts).keys()].filter((i) => !have.has(i));
        this.setTransfer(id, { dir: 'up', done, total: size });
        let next = 0;
        const worker = async () => {
          while (next < missing.length) {
            const idx = missing[next++]!;
            const len = expectedPartLen(idx, parts, size);
            const buf = Buffer.alloc(len);
            fs.readSync(fd, buf, 0, len, idx * PART_SIZE);
            const sealedPart = seal(buf, k, partAAD(vault, id, content, idx, parts));
            await this.withRetry(() => this.request('PUT', `${itemPath}/parts/${idx}`, sealedPart, tok, { 'Content-Type': 'application/octet-stream', 'X-CV-Content': content }));
            done += len;
            this.setTransfer(id, { dir: 'up', done, total: size });
          }
        };
        await Promise.all([worker(), worker(), worker()]);
        try {
          const cd = this.json(await this.request('POST', itemPath + '/commit', undefined, tok));
          const exp = typeof cd.expires_at === 'number' ? cd.expires_at / 1000 : null;
          this.d.vault.setServerMeta(id, false, exp);
          break;
        } catch (e) {
          if (!(e instanceof SyncError) || e.status !== 409 || round === 2) throw e;
          bo = this.json(await this.request('POST', itemPath + '/begin', manifest, tok, headers));
        }
      }
      this.dropFromQueue(id);
      if (this.d.vault.item(id)?.updatedAt === it.updatedAt) this.d.vault.markSynced([id]);
      else if (!this.queue.includes(id)) { this.queue.push(id); this.saveQueue(); }
      this.log(`uploaded big item (${Math.round(size / 1e6)} MB)`);
    } catch (e) {
      if (e instanceof SyncError) {
        if (e.status === 507 || e.status === 413 || e.status === 400) {
          this.dropFromQueue(id);
          this.d.vault.markUploadFailed(id, e.status === 507 ? 'Geteilter Speicher voll' : e.status === 413 ? 'Zu groß zum Teilen (max. 200 MB)' : 'Server lehnte die Datei ab');
        } else if (e.status === 401 || e.status === 404) this.setState('offline', 'Zugang abgelehnt – neu koppeln');
        else this.retryLater(e);
      } else {
        this.dropFromQueue(id);
        this.d.vault.markUploadFailed(id, 'Datei nicht lesbar');
      }
    } finally {
      try { fs.closeSync(fd); } catch { /* ignore */ }
      this.setTransfer(id, null);
    }
  }

  private async withRetry<T>(fn: () => Promise<T>): Promise<T> {
    for (let attempt = 0; ; attempt++) {
      try { return await fn(); } catch (e) {
        const se = e instanceof SyncError ? e : null;
        if (!se || !(se.status === 429 || se.status >= 500 || se.network) || attempt >= 4) throw e;
        await new Promise((r) => setTimeout(r, (attempt + 1) * (se.status === 429 ? 3000 : 1500)));
      }
    }
  }

  // ------------------------------------------------------------------ big items: download on demand
  download(id: string): Promise<void> {
    if (!this.paired || this.downloads.has(id)) return Promise.resolve();
    const h = { cancel: false };
    this.downloads.set(id, h);
    return this.runDownload(id, h).finally(() => { this.downloads.delete(id); this.emit(); });
  }
  cancelTransfer(id: string) {
    const d = this.downloads.get(id);
    if (d) d.cancel = true;
  }

  private async runDownload(id: string, h: { cancel: boolean }): Promise<void> {
    const k = this.key!, tok = this.token!, vault = this.cfg.vaultId!;
    const it = this.d.vault.item(id);
    if (!it || !isBig(it) || it.deleted || it.serverGone || this.d.vault.isLocal(it) || !it.parts || !it.content || !it.size) return;
    const dest = this.d.vault.localPath(it);
    if (!dest) return;
    const parts = it.parts, content = it.content, size = it.size;
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const tmp = path.join(path.dirname(dest), `.laden-${content}.part`);
    const fd = fs.openSync(tmp, 'w', 0o600);
    let ok = false;
    try {
      fs.ftruncateSync(fd, size);
      const itemPath = `${this.vaultPath()}/items/${id.toLowerCase()}`;
      let next = 0, done = 0;
      this.setTransfer(id, { dir: 'down', done: 0, total: size });
      const worker = async () => {
        while (next < parts) {
          if (h.cancel) throw new SyncError('abgebrochen', -2);
          const idx = next++;
          const box = await this.withRetry(() => this.request('GET', `${itemPath}/parts/${idx}`, undefined, tok));
          let plain: Buffer;
          try { plain = open(box, k, partAAD(vault, id, content, idx, parts)); } catch { throw new SyncError(`Teil ${idx + 1} beschädigt oder manipuliert – Laden abgebrochen`, -3); }
          if (plain.length !== expectedPartLen(idx, parts, size)) throw new SyncError(`Teil ${idx + 1} hat die falsche Länge`, -3);
          fs.writeSync(fd, plain, 0, plain.length, idx * PART_SIZE);
          done += plain.length;
          this.setTransfer(id, { dir: 'down', done, total: size });
        }
      };
      await Promise.all([worker(), worker(), worker()]);
      fs.fsyncSync(fd);
      ok = true;
    } catch (e) {
      if (e instanceof SyncError && e.status === 410) this.d.vault.setServerMeta(id, true, null);
      else if (!(e instanceof SyncError && e.status === -2)) this.log('download failed: ' + (e as Error).message);
    } finally {
      fs.closeSync(fd);
      this.setTransfer(id, null);
      if (ok) this.d.vault.placeDownloaded(it, tmp);
      else { try { fs.rmSync(tmp, { force: true }); } catch { /* ignore */ } }
    }
  }

  private async autoDownloads() {
    for (const s of this.d.vault.items) {
      if (isBig(s) && !s.deleted && !s.serverGone && (s.size ?? Infinity) <= AUTO_DOWNLOAD_MAX && !this.d.vault.isLocal(s) && !this.uploads.has(s.id)) {
        await this.download(s.id);
      }
    }
  }

  async refreshInfo() {
    try {
      const i = await this.info();
      if (typeof i.quota === 'number' && i.quota > 0) { this.storage = { used: Number(i.used) || 0, quota: i.quota }; this.emit(); }
    } catch { /* ignore */ }
  }

  // ------------------------------------------------------------------ catch-up
  private openBlob(id: string, blob: Buffer): Opened | null {
    if (!this.key || !this.cfg.vaultId) return null;
    try {
      const o = decodeAny(open(blob, this.key, itemAAD(this.cfg.vaultId, id)));
      const oid = o.type === 'item' ? o.item.id : o.vocab.id;
      if (oid.toLowerCase() !== id.toLowerCase()) { this.log('entry dropped (id mismatch)'); return null; }
      return o;
    } catch {
      this.log('entry could not be decrypted – dropped');
      return null;
    }
  }

  private applyMeta(rows: Record<string, unknown>[]) {
    for (const r of rows) {
      if (typeof r.id !== 'string' || !(Number(r.parts) > 0) || r.deleted === true) continue;
      this.d.vault.setServerMeta(r.id, r.gone === true, typeof r.expires_at === 'number' ? r.expires_at / 1000 : null);
    }
  }

  private applyItems(items: SharedItem[], live: boolean) {
    if (!items.length) return;
    if (live) this.lastLatencyMs = Math.max(0, Math.round(this.now() - Math.max(...items.map((i) => i.updatedAt)) * 1000));
    this.d.vault.applyRemote(items);
    this.d.onReceived?.(items, live);
    this.emit();
  }

  private applyVocab(list: VocabEntry[]) {
    if (!this.key) return;
    const ik = vocabIdKey(this.key);
    for (const v of list) {
      if (vocabId(v.word, ik).toLowerCase() !== v.id.toLowerCase()) { this.log('vocab dropped (id does not match word)'); continue; }
      const i = this.vocab.findIndex((x) => x.id.toLowerCase() === v.id.toLowerCase());
      if (i >= 0) { if (this.vocab[i]!.updatedAt < v.updatedAt) this.vocab[i] = v; } else this.vocab.push(v);
    }
    this.saveVocab();
  }

  async catchUp(): Promise<void> {
    if (!this.paired) return;
    if (this.catching) { this.catchAgain = true; return; }
    this.catching = true;
    try {
      do {
        this.catchAgain = false;
        let cursor = this.cfg.cursor ?? 0;
        let more = true;
        while (more) {
          let o: Record<string, unknown>;
          try { o = this.json(await this.request('GET', `${this.vaultPath()}/since?t=${cursor}`, undefined, this.token)); } catch { return; }
          const rows = (Array.isArray(o.items) ? o.items : []) as Record<string, unknown>[];
          more = o.more === true;
          const next = typeof o.next === 'number' ? o.next : cursor;
          const got: SharedItem[] = [], names: VocabEntry[] = [];
          for (const r of rows) {
            const id = typeof r.id === 'string' ? r.id.toLowerCase() : null;
            if (!id) continue;
            const upd = Number(r.updated_at) || 0;
            const localShared = this.d.vault.item(id);
            const local = localShared ?? this.vocab.find((v) => v.id.toLowerCase() === id);
            const rowBig = Number(r.parts) > 0;
            // a big entry that an older client only knew as a hint text must be fetched again
            const localIsBigOrDeleted = localShared ? isBig(localShared) || localShared.deleted : !!local;
            if (local && local.updatedAt >= upd - 0.0005 && !(rowBig && !localIsBigOrDeleted)) continue;
            if (!local && r.deleted === true) continue;
            let blob: Buffer | null = typeof r.blob === 'string' ? Buffer.from(r.blob, 'base64') : null;
            if (!blob) { try { blob = await this.request('GET', `${this.vaultPath()}/items/${id}`, undefined, this.token); } catch { blob = null; } }
            const op = blob ? this.openBlob(id, blob) : null;
            if (op?.type === 'item') got.push(op.item);
            else if (op?.type === 'vocab') names.push(op.vocab);
          }
          this.applyItems(got, false);
          if (names.length) this.applyVocab(names);
          this.applyMeta(rows);
          if (next !== cursor) { cursor = next; this.cfg.cursor = cursor; this.saveConfig(); }
        }
      } while (this.catchAgain);
    } finally {
      this.catching = false;
    }
    await this.autoDownloads();
  }

  // ------------------------------------------------------------------ WebSocket
  private wsURL(): string | null {
    try {
      let s = `${this.vaultPath()}/ws?device=${this.device}`;
      s = s.replace(/^https:\/\//, 'wss://').replace(/^http:\/\//, 'ws://');
      return s;
    } catch { return null; }
  }

  private connect() {
    const u = this.wsURL();
    if (!this.paired || !u || this.stopped) return;
    const g = ++this.gen;
    try { this.ws?.close(1000, 'reconnect'); } catch { /* ignore */ }
    let ws: WsLike;
    try { ws = this.d.ws(u, ['cvsync.v1', 'auth.' + this.token]); } catch { void this.failed(g, 'WebSocket nicht verfügbar'); return; }
    this.ws = ws;
    this.lastPong = 0;
    if (this.state !== 'connected') this.setState('connecting');
    ws.onopen = () => { if (g === this.gen) this.pingLoop(g); };
    ws.onmessage = (ev) => { if (g === this.gen) void this.handle(typeof ev.data === 'string' ? ev.data : Buffer.from(ev.data as ArrayBuffer).toString('utf8'), g); };
    ws.onclose = (ev) => { void this.failed(g, `Verbindung getrennt (${ev?.code ?? '?'})`); };
    ws.onerror = () => { void this.failed(g, 'Verbindungsfehler'); };
  }

  private jitter(maxMs: number) { return Math.round(this.rnd() * maxMs); }

  private pingLoop(g: number) {
    if (g !== this.gen || !this.ws) return;
    const sent = this.now();
    try { this.ws.send('ping'); } catch { void this.failed(g, 'Senden fehlgeschlagen'); return; }
    this.later(this.d.pongTimeoutMs ?? 10_000, () => {
      if (g !== this.gen) return;
      if (this.lastPong < sent) { void this.failed(g, 'keine Antwort vom Server'); return; }
      this.later((this.d.pingEveryMs ?? 30_000) - (this.d.pongTimeoutMs ?? 10_000) + this.jitter(3000), () => this.pingLoop(g));
    });
  }

  private async handle(s: string, g: number) {
    if (s === 'pong') {
      this.lastPong = this.now();
      if (this.state !== 'connected') {
        this.backoff = 1;
        this.setState('connected');
        this.log('connected (live)');
        void (async () => { await this.catchUp(); await this.flush(); await this.refreshInfo(); })();
      }
      return;
    }
    let o: Record<string, unknown>;
    try { o = JSON.parse(s); } catch { return; }
    if (o.type === 'item' && typeof o.id === 'string') {
      const id = o.id.toLowerCase();
      this.applyMeta([o]);
      if (typeof o.device === 'string' && o.device.toLowerCase() === this.device) return; // own echo
      const local = this.d.vault.item(id);
      if (Number(o.parts) > 0 && local && Number(o.updated_at) <= local.updatedAt + 0.0005) return; // metadata only
      let blob: Buffer | null = typeof o.blob === 'string' ? Buffer.from(o.blob, 'base64') : null;
      if (!blob) { try { blob = await this.request('GET', `${this.vaultPath()}/items/${id}`, undefined, this.token); } catch { return; } }
      if (g !== this.gen || !blob) return;
      const op = this.openBlob(id, blob);
      if (op?.type === 'item') { this.applyItems([op.item], true); this.applyMeta([o]); await this.autoDownloads(); }
      else if (op?.type === 'vocab') this.applyVocab([op.vocab]);
    } else if (o.type === 'peer' && o.event === 'joined') this.partnerDidJoin();
  }

  private async failed(g: number, why: string) {
    if (g !== this.gen) return;
    this.gen++;
    try { this.ws?.close(1000, 'retry'); } catch { /* ignore */ }
    this.ws = null;
    if (!this.paired || this.stopped) return;
    const was = this.state === 'connected';
    this.setState('offline', why);
    const wait = this.backoff * 1000 + this.jitter(500);
    if (was || this.backoff >= 30) this.log(`disconnected: ${why} – retry in ${Math.round(wait / 1000)} s`);
    this.backoff = Math.min(this.backoff * 2, 30);
    const mine = this.gen;
    this.later(wait, () => { if (mine === this.gen && !this.ws && this.paired) this.connect(); });
  }

  /** resume from sleep / network change: reconnect now or probe the old socket */
  kick() {
    if (!this.paired || this.stopped) return;
    if (this.state !== 'connected' || !this.ws) { this.backoff = 1; this.connect(); return; }
    const g = this.gen, sent = this.now();
    try { this.ws.send('ping'); } catch { void this.failed(g, 'Senden fehlgeschlagen'); return; }
    this.later(5000, () => { if (g === this.gen && this.lastPong < sent) void this.failed(g, 'keine Antwort nach Aufwachen/Netzwechsel'); });
    void this.catchUp().then(() => this.flush());
  }

  status() {
    return { ...this.snapshot(), url: this.cfg.url ?? null, device: this.device.slice(0, 8) };
  }
}

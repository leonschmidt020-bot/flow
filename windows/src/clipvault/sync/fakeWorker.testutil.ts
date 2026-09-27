// In-memory stand-in for clipvault/sync-worker (same routes + semantics that the clients rely on).
// Test helper only – no network.
import { createHash, createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import type { FetchLike, WsLike } from './engine';

interface Row { id: string; blob: Buffer; updated_at: number; deleted: boolean; device: string; synced_at: number; size: number;
  parts: number; total: number; content: string | null; complete: boolean; keep: boolean; gone: boolean }
interface Vault { tokenHash: string; items: Map<string, Row>; parts: Map<string, Map<number, Buffer>>; invite: { hash: string; wrapped: Buffer; exp: number } | null; devices: Set<string>; last: number }

const sha = (s: string) => createHash('sha256').update(s).digest('hex');
const wrapKey = (secret: string) => createHash('sha256').update('clipvault-invite-wrap|' + secret).digest();

export class FakeWs implements WsLike {
  readyState = 0;
  onopen: WsLike['onopen'] = null;
  onmessage: WsLike['onmessage'] = null;
  onclose: WsLike['onclose'] = null;
  onerror: WsLike['onerror'] = null;
  answerPings = true;
  constructor(public vault: string, public device: string, private srv: FakeWorker) {
    setTimeout(() => { this.readyState = 1; this.onopen?.({}); }, 0);
  }
  send(data: string) {
    if (this.readyState !== 1) throw new Error('not open');
    if (data === 'ping' && this.answerPings) setTimeout(() => this.deliver('pong'), 0);
  }
  deliver(s: string) { if (this.readyState === 1) this.onmessage?.({ data: s }); }
  close(code = 1000) {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.srv.sockets = this.srv.sockets.filter((s) => s !== this);
    setTimeout(() => this.onclose?.({ code }), 0);
  }
  /** simulate a dead link: server side drops without close frame */
  kill() { this.answerPings = false; }
}

export class FakeWorker {
  vaults = new Map<string, Vault>();
  sockets: FakeWs[] = [];
  requests: string[] = [];
  offline = false;

  private v(id: string) { return this.vaults.get(id); }

  ws = (url: string, protocols: string[]): WsLike => {
    const u = new URL(url);
    const m = u.pathname.match(/^\/v\/([0-9a-f-]{36})\/ws$/);
    const tok = protocols.find((p) => p.startsWith('auth.'))?.slice(5) ?? '';
    const s = new FakeWs(m?.[1] ?? '', (u.searchParams.get('device') ?? '').toLowerCase(), this);
    const vault = m ? this.v(m[1]!) : undefined;
    if (this.offline || !vault || sha(tok) !== vault.tokenHash) {
      setTimeout(() => { s.readyState = 3; s.onerror?.({}); }, 0);
      return s;
    }
    this.sockets.push(s);
    return s;
  };

  private broadcast(vault: string, msg: string, except?: string) {
    for (const s of this.sockets) if (s.vault === vault && s.device !== except) setTimeout(() => s.deliver(msg), 0);
  }
  private meta(r: Row) {
    const m: Record<string, unknown> = { id: r.id, updated_at: r.updated_at, deleted: r.deleted, device: r.device, synced_at: r.synced_at, size: r.size };
    if (r.parts > 0) Object.assign(m, { parts: r.parts, total: r.total, content: r.content, gone: r.gone });
    return m;
  }

  fetch: FetchLike = async (url, init) => {
    const res = (status: number, body: unknown) => {
      const buf = Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body));
      return { status, ok: status >= 200 && status < 300, arrayBuffer: async () => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length) as ArrayBuffer };
    };
    if (this.offline) throw new TypeError('fetch failed');
    const hdr = (k: string): string => init.headers[k] ?? '';
    const u = new URL(url);
    this.requests.push(`${init.method} ${u.pathname}`);
    const m = u.pathname.match(/^\/v\/([0-9a-f-]{36})\/(.+)$/);
    if (!m) return res(404, { error: 'not found' });
    const vid = m[1]!, route = m[2]!;
    const auth = hdr('Authorization').replace(/^Bearer /, '');
    const device = (hdr('X-CV-Device') || 'unknown').toLowerCase();
    const body = init.body === undefined ? Buffer.alloc(0) : Buffer.from(init.body as Uint8Array | string);
    let vault = this.v(vid);
    if (route === 'init' && init.method === 'POST') {
      if (vault) return vault.tokenHash === sha(auth) ? res(200, { ok: true, created: false }) : res(409, { error: 'vault exists' });
      vault = { tokenHash: sha(auth), items: new Map(), parts: new Map(), invite: null, devices: new Set([device]), last: 0 };
      this.vaults.set(vid, vault);
      return res(201, { ok: true, created: true });
    }
    if (route === 'join' && init.method === 'POST') {
      const o = JSON.parse(body.toString());
      if (!vault?.invite || vault.invite.exp < Date.now() || vault.invite.hash !== sha(o.secret)) return res(403, { error: 'code invalid or expired' });
      const w = vault.invite.wrapped;
      const d = createDecipheriv('aes-256-gcm', wrapKey(o.secret), w.subarray(0, 12));
      d.setAuthTag(w.subarray(w.length - 16));
      const token = Buffer.concat([d.update(w.subarray(12, w.length - 16)), d.final()]).toString();
      vault.invite = null;
      vault.devices.add(o.device);
      this.broadcast(vid, JSON.stringify({ type: 'peer', event: 'joined' }));
      return res(200, { token });
    }
    if (!vault) return res(404, { error: 'vault not found' });
    if (sha(auth) !== vault.tokenHash) return res(401, { error: 'unauthorized' });
    vault.devices.add(device);
    const next = () => (vault!.last = Math.max(Date.now(), vault!.last + 1));
    if (route === 'invite' && init.method === 'POST') {
      const { secret } = JSON.parse(body.toString());
      const iv = randomBytes(12);
      const c = createCipheriv('aes-256-gcm', wrapKey(secret), iv);
      const ct = Buffer.concat([c.update(auth), c.final(), c.getAuthTag()]);
      vault.invite = { hash: sha(secret), wrapped: Buffer.concat([iv, ct]), exp: Date.now() + 15 * 60_000 };
      return res(200, { ok: true, expiresAt: vault.invite.exp });
    }
    if (route === 'invite' && init.method === 'DELETE') { vault.invite = null; return res(200, { ok: true }); }
    if (route === 'info') return res(200, { devices: vault.devices.size, invite: !!vault.invite, items: vault.items.size, used: 0, quota: 3e9 });
    if (route === 'since') {
      const t = Number(u.searchParams.get('t') ?? 0);
      const rows = [...vault.items.values()].filter((r) => r.synced_at > t && r.complete).sort((a, b) => a.synced_at - b.synced_at);
      let n = t;
      const out = rows.map((r) => { n = r.synced_at; const o = this.meta(r); if (r.size <= 256 * 1024 && r.parts === 0) o.blob = r.blob.toString('base64'); return o; });
      return res(200, { items: out, next: n, more: false });
    }
    const pm = route.match(/^items\/([0-9a-f-]{36})\/(begin|commit|parts\/(\d+))$/);
    if (pm) {
      const id = pm[1]!;
      if (pm[2]! === 'begin') {
        const upd = Number(hdr('X-CV-Updated-At'));
        const cur = vault.items.get(id);
        if (cur && cur.updated_at > upd) return res(200, { applied: false });
        const content = hdr('X-CV-Content');
        const sameContent = cur?.content === content;
        if (!sameContent) vault.parts.set(id, new Map());
        const row: Row = { id, blob: body, updated_at: upd, deleted: false, device, synced_at: cur?.synced_at ?? 0, size: body.length,
          parts: Number(hdr('X-CV-Parts')), total: Number(hdr('X-CV-Total')), content, complete: sameContent && !!cur?.complete, keep: hdr('X-CV-Keep') === '1', gone: false };
        vault.items.set(id, row);
        return res(200, { applied: true, have: [...(vault.parts.get(id)?.keys() ?? [])], used: 0, quota: 3e9 });
      }
      if (pm[2]! === 'commit') {
        const r = vault.items.get(id)!;
        const have = vault.parts.get(id) ?? new Map();
        const missing = [...Array(r.parts).keys()].filter((i) => !have.has(i));
        if (missing.length) return res(409, { error: 'missing parts', missing });
        r.complete = true; r.synced_at = next();
        this.broadcast(vid, JSON.stringify({ type: 'item', ...this.meta(r), blob: r.blob.toString('base64') }), device);
        return res(200, { ok: true });
      }
      const idx = Number(pm[3]!);
      if (init.method === 'PUT') { vault.parts.get(id)!.set(idx, body); return res(200, { ok: true }); }
      const p = vault.parts.get(id)?.get(idx);
      return p ? res(200, p) : res(404, { error: 'not found' });
    }
    const im = route.match(/^items\/([0-9a-f-]{36})$/);
    if (im) {
      const id = im[1]!;
      if (init.method === 'GET') { const r = vault.items.get(id); return r?.complete ? res(200, r.blob) : res(404, { error: 'not found' }); }
      const upd = Number(hdr('X-CV-Updated-At'));
      const cur = vault.items.get(id);
      if (cur && cur.updated_at > upd) return res(200, { applied: false, synced_at: cur.synced_at });
      const deleted = hdr('X-CV-Deleted') === '1';
      if (cur && cur.parts > 0 && !deleted) return res(200, { applied: false });
      const r: Row = { id, blob: body, updated_at: upd, deleted, device, synced_at: next(), size: body.length, parts: 0, total: 0, content: null, complete: true, keep: false, gone: false };
      vault.items.set(id, r);
      this.broadcast(vid, JSON.stringify({ type: 'item', ...this.meta(r), ...(r.size <= 256 * 1024 ? { blob: r.blob.toString('base64') } : {}) }), device);
      return res(200, { applied: true, synced_at: r.synced_at });
    }
    return res(404, { error: 'not found' });
  };
}

// ClipVault Sync — verschluesselter Speicher + Echtzeit-Verteiler fuer den geteilten Tresor (du + ein Freund/Partner)
//
// Ein SQLite-Durable-Object pro Tresor. Der Server sieht NIE Inhalte: jeder Eintrag ist ein
// AES-GCM-Chiffrat, dessen Schluessel nur in den Schluesselbunden der Macs liegt.
//
// Zugang: pro Tresor ein zufaelliges 256-bit-`vaultToken`. Das DO speichert nur SHA-256(token).
// Jedes Geraet schickt es als `Authorization: Bearer <hex>` (oder beim WebSocket alternativ im
// Header `Sec-WebSocket-Protocol: cvsync.v1, auth.<hex>`).
// Kopplung: Einladung mit Beitritts-Geheimnis (15 Minuten gueltig, nur gehasht gespeichert). Das
// Token wird dafuer mit einem aus dem Geheimnis abgeleiteten Schluessel verpackt abgelegt und beim
// Beitritt EINMAL zurueckgegeben, danach ist die Einladung weg.
//
// Endpunkte (alle unter /v/<vault-uuid>/…):
//   POST   init              Tresor anlegen (Bearer = neues Token, Header X-CV-Init-Secret = INIT_SECRET) -> 201 | 200 | 409
//                            403 = falsches Geheimnis · 503 = INIT_SECRET auf dem Server nicht gesetzt (wrangler secret put INIT_SECRET)
//   POST   invite            Einladung anlegen, Body {"secret":"<hex>"}       -> {expiresAt}
//   DELETE invite            Einladung zurueckziehen
//   POST   join              Beitreten, Body {"secret":"<hex>","device":"…"}   -> {token}   (ohne Bearer)
//   GET    info              {devices, invite, items}
//   GET    since?t=<ms>      Nachholen: Eintraege mit synced_at > t (kleine Blobs inline, base64)
//   GET    items/<id>        ein Eintrag, Rohbytes (Metadaten in X-CV-*-Headern)
//   PUT    items/<id>        Eintrag schreiben (Rohbytes; X-CV-Updated-At, X-CV-Deleted, X-CV-Device)
//   POST   wipe              Tresor komplett loeschen (alle Eintraege, Einladungen, Token) — nur mit Token
//   GET    ws                WebSocket (Hibernation). Server -> Client: {"type":"item",…} / {"type":"peer",…}
//                            Client -> Server: "ping" -> "pong" (automatisch, weckt das DO nicht)
//
// Grosse Eintraege (Protokoll v2, seit 26.09.2026 — Dateien jeder Art bis 200 MB):
//   POST   items/<id>/begin        Kopf (verschluesseltes Manifest) + X-CV-Parts/-Total/-Content/-Keep  -> {applied, have:[idx…]}
//   PUT    items/<id>/parts/<n>    ein Teil (je ein eigenes AES-GCM-Chiffrat, <= 1 MiB + Tag)
//   POST   items/<id>/commit       alle Teile da -> sichtbar + an die anderen Geraete verteilt   (409 {missing})
//   GET    items/<id>/parts/<n>    ein Teil laden
//   POST   items/<id>/evict        Teile vom Server loeschen, Eintrag bleibt ("gone"; lokale Kopien bleiben)
// Solange ein grosser Eintrag nicht committed ist, taucht er in since/ws nicht auf.
// Gleiche Content-id beim erneuten begin = Teile bleiben (Fortsetzen nach Abbruch, Anheften ohne Neu-Upload).
// Kontingent pro Tresor (QUOTA_BYTES, Standard 3 GB) -> 507 {error:"vault full", used, quota}.
// Grosse Eintraege (> 20 MB), nicht angeheftet (X-CV-Keep), verlieren ihre Teile nach 7 Tagen (Alarm).
// Aeltere Clients (nur v1) sehen das Manifest als normalen Eintrag (Text mit Hinweis) — ihr v1-PUT kann
// einen grossen Eintrag nicht ueberschreiben (nur loeschen).

import { DurableObject } from "cloudflare:workers";

export interface Env {
  VAULT: DurableObjectNamespace<VaultDO>;
  /** Server-Geheimnis fuer `init` (neue Tresore anlegen). PFLICHT: `npx wrangler secret put INIT_SECRET`.
   *  Ohne es koennte jeder, der die Worker-URL kennt, auf deinem Konto Tresore anlegen und Speicher belegen.
   *  Beitreten (join) braucht es nicht – dafuer gibt es die Einladung mit eigenem Geheimnis. */
  INIT_SECRET?: string;
  /** nur fuer Tests (wrangler dev --var INVITE_TTL_SECONDS:3); nie laenger als 15 Minuten */
  INVITE_TTL_SECONDS?: string;
  /** Kontingent pro Tresor in Bytes (Standard 3 GB; Free-Plan: 5 GB fuer das ganze Konto) */
  QUOTA_BYTES?: string;
  /** Ablauf grosser, nicht angehefteter Eintraege in Sekunden (Standard 7 Tage) — Tests: wenige Sekunden */
  BIG_TTL_SECONDS?: string;
}

const MAX_BLOB = 8 * 1024 * 1024 + 64 * 1024;   // 8 MB Nutzlast + Kopf/Nonce/Tag
const CHUNK = 1024 * 1024;                       // SQLite-Zeilen im DO duerfen hoechstens 2 MB sein
const INLINE_MAX = 256 * 1024;                   // bis zu dieser Groesse Blob direkt mitschicken (WS / since)
const PAGE_INLINE_BUDGET = 4 * 1024 * 1024;      // so viele Inline-Bytes pro since-Seite
const INVITE_TTL_MAX_MS = 15 * 60 * 1000;
// v2 (grosse Eintraege in Teilen)
const PART_MAX = 1024 * 1024 + 1024;             // 1 MiB Klartext + Nonce/Tag (DO-Zeile max. 2 MB)
const MAX_PARTS = 256;
const MAX_TOTAL = 200 * 1024 * 1024 + MAX_PARTS * 64; // 200 MB Nutzlast pro Eintrag
const MANIFEST_MAX = 64 * 1024;
const DEFAULT_QUOTA = 3_000_000_000;              // 3 GB (Free-Plan: 5 GB DO-Speicher fuers ganze Konto)
const BIG_BYTES = 20 * 1024 * 1024;              // ab hier laeuft ein Eintrag nach BIG_TTL ab (ausser angeheftet)
const DEFAULT_BIG_TTL_S = 7 * 24 * 3600;
const STALE_UPLOAD_MS = 3 * 24 * 3600 * 1000;    // angefangene, nie beendete Uploads nach 3 Tagen wegraeumen
const HEX32_CONTENT = /^[0-9a-f]{32}$/;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HEX64_RE = /^[0-9a-f]{64}$/;
const HEX32_RE = /^[0-9a-f]{32}$/;

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}
const err = (status: number, message: string, headers: Record<string, string> = {}) => json({ error: message }, status, headers);

// ------------------------------------------------------------------------------------------------
// Worker: nur Weiterleiten an das DO des Tresors
// ------------------------------------------------------------------------------------------------
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") return json({ ok: true, service: "clipvault-sync" });
    const m = url.pathname.match(/^\/v\/([0-9a-fA-F-]{36})\/(.+)$/);
    if (!m) return err(404, "not found");
    const vault = m[1].toLowerCase();
    if (!UUID_RE.test(vault)) return err(400, "bad vault id");
    const len = Number(request.headers.get("content-length") ?? "0");
    if (len > MAX_BLOB + 4096) return err(413, "item too large (max 8 MB)");
    // Audit #16: Tresore anlegen nur mit dem Server-Geheimnis (sonst kann jeder mit der URL Speicher belegen)
    if (m[2] === "init" && request.method === "POST") {
      const want = env.INIT_SECRET ?? "";
      if (want.length < 16) return err(503, "INIT_SECRET not configured on server (npx wrangler secret put INIT_SECRET)");
      const got = request.headers.get("x-cv-init-secret") ?? "";
      if (!sameHex(await sha256Hex(got), await sha256Hex(want))) return err(403, "init secret wrong");
    }
    const stub = env.VAULT.get(env.VAULT.idFromName(vault));
    return stub.fetch(request);
  },
} satisfies ExportedHandler<Env>;

// ------------------------------------------------------------------------------------------------
// Hilfen
// ------------------------------------------------------------------------------------------------
const enc = new TextEncoder();

async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", enc.encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function sameHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
async function wrapKey(secret: string): Promise<CryptoKey> {
  const raw = await crypto.subtle.digest("SHA-256", enc.encode("clipvault-invite-wrap|" + secret));
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}
function toBase64(buf: Uint8Array): string {
  let s = "";
  for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  return btoa(s);
}
function bearer(req: Request): string | null {
  const a = req.headers.get("authorization");
  if (a?.startsWith("Bearer ")) return a.slice(7).trim().toLowerCase();
  // WebSocket-Variante: Sec-WebSocket-Protocol: cvsync.v1, auth.<hex>
  const p = req.headers.get("sec-websocket-protocol");
  if (p) for (const part of p.split(",").map((x) => x.trim())) if (part.startsWith("auth.")) return part.slice(5).toLowerCase();
  return null;
}
function deviceOf(req: Request, url: URL): string {
  const d = (req.headers.get("x-cv-device") ?? url.searchParams.get("device") ?? "").toLowerCase();
  return UUID_RE.test(d) ? d : "unknown";
}

// Einfacher Token-Eimer (pro Tresor, im Speicher des DO)
class Bucket {
  private tokens: number;
  private last = Date.now();
  constructor(private capacity: number, private perMinute: number) { this.tokens = capacity; }
  take(n = 1): boolean {
    const now = Date.now();
    this.tokens = Math.min(this.capacity, this.tokens + ((now - this.last) / 60000) * this.perMinute);
    this.last = now;
    if (this.tokens < n) return false;
    this.tokens -= n;
    return true;
  }
}

type ItemRow = {
  id: string; blob: ArrayBuffer | null; updated_at: number; deleted: number; device: string; synced_at: number; size: number; chunks: number;
  parts: number; total: number; content: string | null; complete: number; keep: number; gone: number; expires_at: number | null; began_at: number | null;
};

// ------------------------------------------------------------------------------------------------
// Durable Object: ein Tresor
// ------------------------------------------------------------------------------------------------
export class VaultDO extends DurableObject<Env> {
  private sql: SqlStorage;
  private lastSynced = 0;
  private writes = new Bucket(120, 240);      // 120 sofort, dann 240/min
  private reads = new Bucket(300, 600);
  private joins = new Bucket(10, 2);          // Beitrittsversuche
  private uploadBytes = new Bucket(200 * 1024 * 1024, 300 * 1024 * 1024); // 200 MB sofort, dann 300 MB/min
  private partWrites = new Bucket(600, 1200);  // Teile grosser Eintraege
  private partReads = new Bucket(600, 1200);

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.ensureSchema();
    // "ping" beantwortet die Laufzeit selbst -> das DO wird dafuer nicht aus dem Schlaf geholt
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  private ensureSchema() {
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY, blob BLOB, updated_at REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
        device TEXT NOT NULL, synced_at INTEGER NOT NULL, size INTEGER NOT NULL, chunks INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS items_synced ON items (synced_at);
      CREATE TABLE IF NOT EXISTS chunks (id TEXT NOT NULL, idx INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY (id, idx));
      CREATE TABLE IF NOT EXISTS invites (secret_hash TEXT PRIMARY KEY, wrapped BLOB NOT NULL, expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS devices (device TEXT PRIMARY KEY, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS parts (id TEXT NOT NULL, idx INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY (id, idx));
    `);
    // v2-Spalten nachruesten (bestehende Tresore behalten ihre Daten)
    const cols = new Set(this.sql.exec<{ name: string }>("PRAGMA table_info(items)").toArray().map((r) => r.name));
    const add = (c: string, def: string) => { if (!cols.has(c)) this.sql.exec(`ALTER TABLE items ADD COLUMN ${c} ${def}`); };
    add("parts", "INTEGER NOT NULL DEFAULT 0");
    add("total", "INTEGER NOT NULL DEFAULT 0");
    add("content", "TEXT");
    add("complete", "INTEGER NOT NULL DEFAULT 1");
    add("keep", "INTEGER NOT NULL DEFAULT 0");
    add("gone", "INTEGER NOT NULL DEFAULT 0");
    add("expires_at", "INTEGER");
    add("began_at", "INTEGER");
    const r = this.sql.exec<{ m: number | null }>("SELECT MAX(synced_at) AS m FROM items").one();
    this.lastSynced = r.m ?? 0;
  }

  private tokenHash(): string | null {
    const r = this.sql.exec<{ v: string }>("SELECT v FROM meta WHERE k = 'token_hash'").toArray();
    return r.length ? r[0].v : null;
  }
  private async authorized(req: Request): Promise<boolean> {
    const t = bearer(req);
    const h = this.tokenHash();
    if (!t || !h || !HEX64_RE.test(t)) return false;
    return sameHex(await sha256Hex(t), h);
  }
  private seen(device: string) {
    if (device === "unknown") return;
    const now = Date.now();
    this.sql.exec("INSERT INTO devices (device, first_seen, last_seen) VALUES (?, ?, ?) ON CONFLICT(device) DO UPDATE SET last_seen = excluded.last_seen", device, now, now);
  }
  private nextSynced(): number {
    this.lastSynced = Math.max(Date.now(), this.lastSynced + 1);   // streng steigend -> Cursor ohne Luecken
    return this.lastSynced;
  }
  private readBlob(row: ItemRow): Uint8Array {
    if (row.chunks === 0) return row.blob ? new Uint8Array(row.blob) : new Uint8Array(0);
    const out = new Uint8Array(row.size);
    let off = 0;
    for (const c of this.sql.exec<{ data: ArrayBuffer }>("SELECT data FROM chunks WHERE id = ? ORDER BY idx", row.id)) {
      const b = new Uint8Array(c.data);
      out.set(b, off);
      off += b.length;
    }
    return out;
  }
  private meta(row: ItemRow) {
    const m: Record<string, unknown> = { id: row.id, updated_at: row.updated_at, deleted: row.deleted === 1, device: row.device, synced_at: row.synced_at, size: row.size };
    if (row.parts > 0) {   // v2: nur fuer neue Clients interessant, alte ignorieren unbekannte Felder
      m.parts = row.parts; m.total = row.total; m.content = row.content; m.gone = row.gone === 1;
      if (row.expires_at) m.expires_at = row.expires_at;
    }
    return m;
  }
  private quota(): number { return Math.max(1, Number(this.env.QUOTA_BYTES) || DEFAULT_QUOTA); }
  /** belegter Platz: Manifeste/v1-Blobs + (nicht abgelaufene) Teile, auch halb hochgeladene (reserviert) */
  private used(exceptId?: string): number {
    const r = this.sql.exec<{ u: number | null }>(
      "SELECT SUM(size + CASE WHEN gone = 0 THEN total ELSE 0 END) AS u FROM items WHERE id != ?", exceptId ?? "").one();
    return r.u ?? 0;
  }
  private bigTtlMs(): number { return Math.max(1, Number(this.env.BIG_TTL_SECONDS) || DEFAULT_BIG_TTL_S) * 1000; }
  private itemMsg(r: ItemRow): string {
    const msg: Record<string, unknown> = { type: "item", ...this.meta(r) };
    if (r.size <= INLINE_MAX && r.chunks === 0 && r.blob) msg.blob = toBase64(new Uint8Array(r.blob));
    return JSON.stringify(msg);
  }
  private row(id: string): ItemRow | null {
    const rows = this.sql.exec<ItemRow>("SELECT * FROM items WHERE id = ?", id).toArray();
    return rows.length ? rows[0] : null;
  }
  private broadcast(msg: string, exceptDevice?: string) {
    for (const ws of this.ctx.getWebSockets()) {
      if (exceptDevice && this.ctx.getTags(ws).includes("dev:" + exceptDevice)) continue;
      try { ws.send(msg); } catch { /* Socket schon zu */ }
    }
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const m = url.pathname.match(/^\/v\/[0-9a-fA-F-]{36}\/(.+)$/);
    const route = m ? m[1] : "";
    const device = deviceOf(req, url);

    // ---- ohne Token ----
    if (route === "join" && req.method === "POST") return this.join(req);
    if (route === "init" && req.method === "POST") return this.init(req, device);

    // ---- ab hier nur mit Token ----
    if (!this.tokenHash()) return err(404, "vault not found");
    if (!(await this.authorized(req))) return err(401, "unauthorized");
    this.seen(device);

    if (route === "ws") return this.upgrade(req, device);
    if (route === "info" && req.method === "GET") {
      const devices = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM devices").one().n;
      const invite = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM invites WHERE expires_at > ?", Date.now()).one().n > 0;
      const items = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM items").one().n;
      const big = this.sql.exec<{ n: number; b: number | null }>(
        "SELECT COUNT(*) AS n, SUM(total) AS b FROM items WHERE parts > 0 AND gone = 0 AND deleted = 0 AND total > ?", BIG_BYTES).one();
      return json({ devices, invite, items, used: this.used(), quota: this.quota(), bigItems: big.n, bigBytes: big.b ?? 0,
                    v: 2, maxItem: MAX_TOTAL - MAX_PARTS * 64, bigAfter: BIG_BYTES, bigTtl: this.bigTtlMs() });
    }
    if (route === "wipe" && req.method === "POST") {
      for (const ws of this.ctx.getWebSockets()) { try { ws.close(4000, "vault wiped"); } catch { /* zu */ } }
      await this.ctx.storage.deleteAlarm();
      await this.ctx.storage.deleteAll();
      this.ensureSchema();
      return json({ ok: true, wiped: true });
    }
    if (route === "invite" && req.method === "POST") return this.invite(req);
    if (route === "invite" && req.method === "DELETE") { this.sql.exec("DELETE FROM invites"); return json({ ok: true }); }
    if (route === "since" && req.method === "GET") return this.since(url, device);
    const pm = route.match(/^items\/([0-9a-fA-F-]{36})\/(begin|commit|evict|parts\/(\d{1,4}))$/);
    if (pm) {
      const id = pm[1].toLowerCase();
      if (!UUID_RE.test(id)) return err(400, "bad item id");
      if (pm[2] === "begin" && req.method === "POST") return this.begin(req, id, device);
      if (pm[2] === "commit" && req.method === "POST") return this.commit(id, device);
      if (pm[2] === "evict" && req.method === "POST") return this.evictRoute(id);
      if (pm[3] !== undefined) {
        const idx = Number(pm[3]);
        if (req.method === "PUT") return this.putPart(req, id, idx);
        if (req.method === "GET") return this.getPart(id, idx);
      }
      return err(404, "not found");
    }
    const im = route.match(/^items\/([0-9a-fA-F-]{36})$/);
    if (im) {
      const id = im[1].toLowerCase();
      if (!UUID_RE.test(id)) return err(400, "bad item id");
      if (req.method === "PUT") return this.put(req, id, device);
      if (req.method === "GET") return this.getItem(id);
    }
    return err(404, "not found");
  }

  private async init(req: Request, device: string): Promise<Response> {
    const t = bearer(req);
    if (!t || !HEX64_RE.test(t)) return err(400, "token must be 64 hex chars");
    const h = await sha256Hex(t);
    const existing = this.tokenHash();
    if (existing) return sameHex(existing, h) ? json({ ok: true, created: false }) : err(409, "vault exists");
    this.sql.exec("INSERT INTO meta (k, v) VALUES ('token_hash', ?), ('created_at', ?)", h, String(Date.now()));
    this.seen(device);
    return json({ ok: true, created: true }, 201);
  }

  private async invite(req: Request): Promise<Response> {
    const body = (await req.json().catch(() => null)) as { secret?: string } | null;
    const secret = body?.secret?.toLowerCase() ?? "";
    if (!HEX32_RE.test(secret) && !HEX64_RE.test(secret)) return err(400, "secret must be 32 or 64 hex chars");
    const token = bearer(req)!;
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await wrapKey(secret), enc.encode(token)));
    const wrapped = new Uint8Array(iv.length + ct.length);
    wrapped.set(iv); wrapped.set(ct, iv.length);
    const ttl = Math.min(INVITE_TTL_MAX_MS, (Number(this.env.INVITE_TTL_SECONDS) || 900) * 1000);
    const expiresAt = Date.now() + ttl;
    this.sql.exec("DELETE FROM invites");                               // immer nur EINE offene Einladung
    this.sql.exec("INSERT INTO invites (secret_hash, wrapped, expires_at) VALUES (?, ?, ?)", await sha256Hex(secret), wrapped, expiresAt);
    return json({ ok: true, expiresAt });
  }

  private async join(req: Request): Promise<Response> {
    if (!this.joins.take()) return err(429, "too many attempts", { "retry-after": "60" });
    const body = (await req.json().catch(() => null)) as { secret?: string; device?: string } | null;
    const secret = body?.secret?.toLowerCase() ?? "";
    if (!HEX32_RE.test(secret) && !HEX64_RE.test(secret)) return err(400, "bad secret");
    this.sql.exec("DELETE FROM invites WHERE expires_at <= ?", Date.now());
    const rows = this.sql.exec<{ wrapped: ArrayBuffer }>("SELECT wrapped FROM invites WHERE secret_hash = ?", await sha256Hex(secret)).toArray();
    if (!rows.length) return err(403, "code invalid or expired");
    const w = new Uint8Array(rows[0].wrapped);
    let token: string;
    try {
      token = new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: w.subarray(0, 12) }, await wrapKey(secret), w.subarray(12)));
    } catch {
      return err(403, "code invalid or expired");
    }
    this.sql.exec("DELETE FROM invites");                               // einmalig
    const device = (body?.device ?? "").toLowerCase();
    if (UUID_RE.test(device)) this.seen(device);
    this.broadcast(JSON.stringify({ type: "peer", event: "joined" }));
    return json({ token });
  }

  private upgrade(req: Request, device: string): Response {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return err(426, "expected websocket");
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, ["dev:" + device]);
    const headers: Record<string, string> = {};
    if (req.headers.get("sec-websocket-protocol")?.includes("cvsync.v1")) headers["sec-websocket-protocol"] = "cvsync.v1";
    return new Response(null, { status: 101, webSocket: client, headers });
  }

  private since(url: URL, device: string): Response {
    if (!this.reads.take()) return err(429, "rate limited", { "retry-after": "10" });
    const t = Number(url.searchParams.get("t") ?? "0") || 0;
    const skipOwn = url.searchParams.get("skipOwn") === "1";
    const rows = this.sql.exec<ItemRow>(
      "SELECT id, CASE WHEN size <= ? THEN blob ELSE NULL END AS blob, updated_at, deleted, device, synced_at, size, chunks, parts, total, content, complete, keep, gone, expires_at, began_at FROM items WHERE synced_at > ? AND complete = 1 ORDER BY synced_at LIMIT 500",
      INLINE_MAX, t).toArray();
    const out: unknown[] = [];
    let budget = PAGE_INLINE_BUDGET;
    let next = t;
    let more = rows.length === 500;
    for (const r of rows) {
      const inline = r.size <= INLINE_MAX && r.chunks === 0 && r.blob !== null;
      if (inline && r.size > budget && out.length > 0) { more = true; break; }
      next = r.synced_at;
      if (skipOwn && r.device === device) continue;
      const o: Record<string, unknown> = this.meta(r);
      if (inline) { o.blob = toBase64(new Uint8Array(r.blob!)); budget -= r.size; }
      out.push(o);
    }
    return json({ items: out, next, more });
  }

  private getItem(id: string): Response {
    if (!this.reads.take()) return err(429, "rate limited", { "retry-after": "10" });
    const r = this.row(id);
    if (!r || r.complete !== 1) return err(404, "not found");
    return new Response(this.readBlob(r), {
      headers: {
        "content-type": "application/octet-stream",
        "x-cv-updated-at": String(r.updated_at),
        "x-cv-deleted": r.deleted ? "1" : "0",
        "x-cv-device": r.device,
        "x-cv-synced-at": String(r.synced_at),
      },
    });
  }

  private async put(req: Request, id: string, device: string): Promise<Response> {
    if (!this.writes.take()) return err(429, "rate limited", { "retry-after": "10" });
    const updatedAt = Number(req.headers.get("x-cv-updated-at"));
    if (!Number.isFinite(updatedAt) || updatedAt <= 0) return err(400, "X-CV-Updated-At missing");
    const deleted = req.headers.get("x-cv-deleted") === "1" ? 1 : 0;
    const body = new Uint8Array(await req.arrayBuffer());
    if (body.length === 0) return err(400, "empty blob");
    if (body.length > MAX_BLOB) return err(413, "item too large (max 8 MB)");
    if (!this.uploadBytes.take(body.length)) return err(429, "rate limited", { "retry-after": "30" });

    // Letzter Schreiber gewinnt (Zeit des Geraets). Aelteres wird still verworfen.
    const cur = this.row(id);
    if (cur && cur.updated_at > updatedAt) return json({ applied: false, synced_at: cur.synced_at });
    // Ein grosser Eintrag (v2) laesst sich mit v1 nur LOESCHEN — ein aelterer Client, der ihn nur als Hinweis-Text
    // kennt, soll ihn beim Anheften nicht ueberschreiben (er holt sich dann den Stand vom Server).
    if (cur && cur.parts > 0 && !deleted) return json({ applied: false, synced_at: cur.synced_at });
    if (!deleted && this.used(id) + body.length > this.quota()) return this.full(body.length);

    const synced = this.nextSynced();
    const chunked = body.length > CHUNK;
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM chunks WHERE id = ?", id);
      this.sql.exec("DELETE FROM parts WHERE id = ?", id);
      if (chunked) {
        let i = 0;
        for (let off = 0; off < body.length; off += CHUNK, i++) this.sql.exec("INSERT INTO chunks (id, idx, data) VALUES (?, ?, ?)", id, i, body.subarray(off, off + CHUNK));
      }
      this.sql.exec(
        `INSERT INTO items (id, blob, updated_at, deleted, device, synced_at, size, chunks, parts, total, content, complete, keep, gone, expires_at, began_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, NULL, 1, 0, 0, NULL, NULL)
         ON CONFLICT(id) DO UPDATE SET blob = excluded.blob, updated_at = excluded.updated_at, deleted = excluded.deleted,
           device = excluded.device, synced_at = excluded.synced_at, size = excluded.size, chunks = excluded.chunks,
           parts = 0, total = 0, content = NULL, complete = 1, keep = 0, gone = 0, expires_at = NULL, began_at = NULL`,
        id, chunked ? null : body, updatedAt, deleted, device, synced, body.length, chunked ? Math.ceil(body.length / CHUNK) : 0);
    });
    const msg: Record<string, unknown> = { type: "item", id, updated_at: updatedAt, deleted: deleted === 1, device, synced_at: synced, size: body.length };
    if (body.length <= INLINE_MAX) msg.blob = toBase64(body);
    this.broadcast(JSON.stringify(msg), device);
    await this.scheduleAlarm();
    return json({ applied: true, synced_at: synced });
  }

  private full(extra: number): Response {
    return json({ error: "vault full", used: this.used(), quota: this.quota(), need: extra }, 507);
  }

  // ---------------- v2: grosse Eintraege in Teilen ----------------
  private async begin(req: Request, id: string, device: string): Promise<Response> {
    if (!this.writes.take()) return err(429, "rate limited", { "retry-after": "10" });
    const h = (k: string) => req.headers.get(k) ?? "";
    const updatedAt = Number(h("x-cv-updated-at"));
    const parts = Number(h("x-cv-parts"));
    const total = Number(h("x-cv-total"));
    const content = h("x-cv-content").toLowerCase();
    const keep = h("x-cv-keep") === "1" ? 1 : 0;
    if (!Number.isFinite(updatedAt) || updatedAt <= 0) return err(400, "X-CV-Updated-At missing");
    if (!Number.isInteger(parts) || parts < 1 || parts > MAX_PARTS) return err(400, "bad X-CV-Parts");
    if (!Number.isInteger(total) || total < parts || total > MAX_TOTAL || total > parts * PART_MAX) return err(413, "item too large (max 200 MB)");
    if (!HEX32_CONTENT.test(content)) return err(400, "bad X-CV-Content");
    const manifest = new Uint8Array(await req.arrayBuffer());
    if (manifest.length === 0 || manifest.length > MANIFEST_MAX) return err(400, "bad manifest");

    const cur = this.row(id);
    if (cur && cur.updated_at > updatedAt) return json({ applied: false, synced_at: cur.synced_at });
    if (this.used(id) + manifest.length + total > this.quota()) return this.full(total);
    const same = !!cur && cur.content === content && cur.parts === parts && cur.total === total;
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM chunks WHERE id = ?", id);
      if (!same) this.sql.exec("DELETE FROM parts WHERE id = ?", id);
      this.sql.exec(
        `INSERT INTO items (id, blob, updated_at, deleted, device, synced_at, size, chunks, parts, total, content, complete, keep, gone, expires_at, began_at)
         VALUES (?, ?, ?, 0, ?, 0, ?, 0, ?, ?, ?, 0, ?, 0, NULL, ?)
         ON CONFLICT(id) DO UPDATE SET blob = excluded.blob, updated_at = excluded.updated_at, deleted = 0, device = excluded.device,
           size = excluded.size, chunks = 0, parts = excluded.parts, total = excluded.total, content = excluded.content,
           complete = 0, keep = excluded.keep, began_at = excluded.began_at`,
        id, manifest, updatedAt, device, manifest.length, parts, total, content, keep, Date.now());
    });
    const have = this.sql.exec<{ idx: number }>("SELECT idx FROM parts WHERE id = ? ORDER BY idx", id).toArray().map((r) => r.idx);
    await this.scheduleAlarm();
    return json({ applied: true, have, used: this.used(), quota: this.quota() });
  }

  private async putPart(req: Request, id: string, idx: number): Promise<Response> {
    if (!this.partWrites.take()) return err(429, "rate limited", { "retry-after": "5" });
    const r = this.row(id);
    if (!r || r.parts === 0 || r.deleted) return err(404, "no upload for this item");
    if (r.content !== (req.headers.get("x-cv-content") ?? "").toLowerCase()) return err(409, "content changed");
    if (!Number.isInteger(idx) || idx < 0 || idx >= r.parts) return err(400, "bad part index");
    const body = new Uint8Array(await req.arrayBuffer());
    if (body.length === 0 || body.length > PART_MAX) return err(413, "bad part size");
    if (!this.uploadBytes.take(body.length)) return err(429, "rate limited", { "retry-after": "10" });
    this.sql.exec("INSERT INTO parts (id, idx, data) VALUES (?, ?, ?) ON CONFLICT(id, idx) DO UPDATE SET data = excluded.data", id, idx, body);
    return json({ ok: true });
  }

  private async commit(id: string, device: string): Promise<Response> {
    if (!this.writes.take()) return err(429, "rate limited", { "retry-after": "10" });
    const r = this.row(id);
    if (!r || r.parts === 0 || r.deleted) return err(404, "no upload for this item");
    const got = this.sql.exec<{ idx: number; n: number }>("SELECT idx, LENGTH(data) AS n FROM parts WHERE id = ? ORDER BY idx", id).toArray();
    const have = new Set(got.map((g) => g.idx));
    const missing: number[] = [];
    for (let i = 0; i < r.parts; i++) if (!have.has(i)) missing.push(i);
    const bytes = got.reduce((a, g) => a + g.n, 0);
    if (missing.length || bytes !== r.total) return json({ error: "parts missing", missing, bytes, total: r.total }, 409);
    if (r.complete === 1 && r.gone === 0) return json({ applied: true, synced_at: r.synced_at });   // schon fertig
    const synced = this.nextSynced();
    const exp = r.total > BIG_BYTES && r.keep === 0 ? Date.now() + this.bigTtlMs() : null;
    this.sql.exec("UPDATE items SET complete = 1, gone = 0, synced_at = ?, expires_at = ?, began_at = NULL WHERE id = ?", synced, exp, id);
    this.broadcast(this.itemMsg(this.row(id)!), device);
    await this.scheduleAlarm();
    return json({ applied: true, synced_at: synced, expires_at: exp });
  }

  private getPart(id: string, idx: number): Response {
    if (!this.partReads.take()) return err(429, "rate limited", { "retry-after": "5" });
    const r = this.row(id);
    if (!r || r.parts === 0 || r.deleted) return err(404, "not found");
    if (r.gone) return err(410, "expired on server");
    const rows = this.sql.exec<{ data: ArrayBuffer }>("SELECT data FROM parts WHERE id = ? AND idx = ?", id, idx).toArray();
    if (!rows.length) return err(404, "part not found");
    return new Response(rows[0].data, { headers: { "content-type": "application/octet-stream", "x-cv-content": r.content ?? "" } });
  }

  /** Teile eines grossen Eintrags loeschen (Ablauf oder „Grosse Dateien aufraeumen"). Der Eintrag bleibt als „gone". */
  private evict(id: string): boolean {
    const r = this.row(id);
    if (!r || r.parts === 0 || r.gone === 1 || r.complete === 0) return false;
    const synced = this.nextSynced();
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM parts WHERE id = ?", id);
      this.sql.exec("UPDATE items SET gone = 1, complete = 1, expires_at = NULL, began_at = NULL, synced_at = ? WHERE id = ?", synced, id);
    });
    this.broadcast(this.itemMsg(this.row(id)!));
    return true;
  }
  private async evictRoute(id: string): Promise<Response> {
    if (!this.writes.take()) return err(429, "rate limited", { "retry-after": "10" });
    const ok = this.evict(id);
    await this.scheduleAlarm();
    return ok ? json({ ok: true, used: this.used(), quota: this.quota() }) : err(404, "nothing to evict");
  }

  /** naechster Weckzeitpunkt: fruehester Ablauf oder Aufraeumen haengengebliebener Uploads */
  private async scheduleAlarm() {
    const e = this.sql.exec<{ t: number | null }>("SELECT MIN(expires_at) AS t FROM items WHERE gone = 0 AND expires_at IS NOT NULL").one().t;
    const b = this.sql.exec<{ t: number | null }>("SELECT MIN(began_at) AS t FROM items WHERE complete = 0 AND began_at IS NOT NULL").one().t;
    const next = Math.min(e ?? Infinity, b !== null && b !== undefined ? b + STALE_UPLOAD_MS : Infinity);
    if (next === Infinity) { await this.ctx.storage.deleteAlarm(); return; }
    const cur = await this.ctx.storage.getAlarm();
    if (cur === null || cur !== next) await this.ctx.storage.setAlarm(Math.max(Date.now() + 1000, next));
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    for (const r of this.sql.exec<{ id: string }>("SELECT id FROM items WHERE gone = 0 AND expires_at IS NOT NULL AND expires_at <= ?", now).toArray()) this.evict(r.id);
    // nie beendete Uploads: Teile + Zeile weg (Empfaenger kannten sie nie)
    for (const r of this.sql.exec<{ id: string }>("SELECT id FROM items WHERE complete = 0 AND began_at IS NOT NULL AND began_at <= ?", now - STALE_UPLOAD_MS).toArray()) {
      this.ctx.storage.transactionSync(() => {
        this.sql.exec("DELETE FROM parts WHERE id = ?", r.id);
        this.sql.exec("DELETE FROM items WHERE id = ?", r.id);
      });
    }
    await this.scheduleAlarm();
  }

  // Hibernation-Handler
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (message === "ping") ws.send("pong");   // falls die Auto-Antwort nicht griff
  }
  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try { ws.close(code === 1005 || code === 1006 ? 1000 : code, reason); } catch { /* schon zu */ }
  }
  async webSocketError(ws: WebSocket): Promise<void> {
    try { ws.close(1011, "error"); } catch { /* schon zu */ }
  }
}

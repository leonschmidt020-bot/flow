// ClipVault UI – one view class for both the quick panel ("panel") and the Hub page ("hub").
// Vanilla DOM (no framework), everything inside the given root (ShadowRoot in the Hub).
import type { ItemView, TypeFilter } from '../core/types';
import type { ListResult } from '../core/view';
import { CSS } from './styles';
import { icon, COLLECTION_ICONS } from './icons';
import { tr, type StringKey } from './i18n';

export interface UiApi {
  invoke<T = unknown>(name: string, ...args: unknown[]): Promise<T>;
  on(name: string, cb: (payload: unknown) => void): () => void;
  locale: 'de' | 'en';
}

type Mode = 'panel' | 'hub';
type CollectionId = string | null; // null = history, '__shared__' = shared vault
const SHARED = '__shared__';
const TYPES: TypeFilter[] = ['all', 'text', 'links', 'images', 'files'];

interface SettingsView {
  encryptAtRest: boolean; skipPasswordLike: boolean; ignoredApps: string[]; maxAgeDays: number; maxItems: number; quotaMB: number;
  hotkey: string; pasteOnEnter: boolean; paused: boolean; sync: { enabled: boolean; name: string };
  dpapiAvailable: boolean; platform: string; readOnly: boolean; recovery: string;
}
interface SyncView { state: string; reason?: string; paired?: boolean; queue?: number; pairingCode?: string | null; url?: string | null; host?: string; lastLatencyMs?: number | null }

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

export class ClipVaultView {
  private el: HTMLElement;
  private q = '';
  private type: TypeFilter = 'all';
  private col: CollectionId = null;
  private data: ListResult | null = null;
  private flat: ItemView[] = [];
  private sel: string | null = null;
  private detail: ItemView | null = null;
  private page: 'list' | 'settings' = 'list';
  private settings: SettingsView | null = null;
  private sync: SyncView | null = null;
  private viewer: { ids: string[]; idx: number; zoom: number; fit: number; x: number; y: number; w: number; h: number } | null = null;
  private offs: (() => void)[] = [];
  private reqSeq = 0;
  private revealed = new Set<string>();
  private menuEl: HTMLElement | null = null;
  private viewerResize: ResizeObserver | null = null;
  private pairInput = '';
  private urlInput = '';

  constructor(root: ShadowRoot | HTMLElement, private api: UiApi, private mode: Mode, material = 'solid') {
    const style = document.createElement('style');
    style.textContent = CSS;
    this.el = document.createElement('div');
    this.el.className = `cv ${mode} m-${material}`;
    this.el.tabIndex = -1;
    root.appendChild(style);
    root.appendChild(this.el);
    this.el.addEventListener('click', (e) => this.onClick(e));
    this.el.addEventListener('dblclick', (e) => this.onDblClick(e));
    this.el.addEventListener('input', (e) => this.onInput(e));
    this.el.addEventListener('change', (e) => this.onChange(e));
    this.el.addEventListener('keydown', (e) => this.onKey(e));
    this.el.addEventListener('contextmenu', (e) => this.onContext(e));
    this.el.addEventListener('dragstart', (e) => this.onDragStart(e));
    this.el.addEventListener('dragover', (e) => this.onDragOver(e));
    this.el.addEventListener('dragleave', (e) => (e.target as HTMLElement).closest?.('[data-drop]')?.classList.remove('drop'));
    this.el.addEventListener('drop', (e) => this.onDrop(e));
    this.offs.push(api.on('changed', () => void this.refresh()));
    this.offs.push(api.on('settings', (s) => { this.settings = s as SettingsView; this.render(); }));
    this.offs.push(api.on('sync', (s) => { this.sync = (s as SyncView) ?? { state: 'off' }; if (this.page === 'settings' || this.col === SHARED) this.render(); }));
    this.offs.push(api.on('panel:shown', (p) => this.onShown(p as { view?: string | null })));
    this.renderShell();
    void this.boot();
  }

  destroy() {
    for (const o of this.offs) o();
    this.offs = [];
    this.el.remove();
  }

  private t(k: StringKey, ...a: (string | number)[]) { return tr(this.api.locale, k, ...a); }
  private $(sel: string) { return this.el.querySelector(sel) as HTMLElement | null; }

  private async boot() {
    try { this.settings = await this.api.invoke<SettingsView>('settings'); } catch { /* older main */ }
    try { this.sync = await this.api.invoke<SyncView>('syncStatus'); } catch { this.sync = { state: 'off' }; }
    await this.refresh();
    this.focusSearch();
  }

  private onShown(p: { view?: string | null }) {
    this.closeViewer();
    this.closeMenu();
    this.q = '';
    const s = this.$('input.q') as HTMLInputElement | null;
    if (s) s.value = '';
    if (p?.view !== undefined && p.view !== null) this.col = p.view;
    this.sel = null;
    void this.refresh().then(() => this.focusSearch());
  }

  private focusSearch() {
    const s = this.$('input.q') as HTMLInputElement | null;
    s?.focus();
  }

  // ------------------------------------------------------------------ data
  async refresh() {
    const seq = ++this.reqSeq;
    let data: ListResult;
    try {
      data = await this.api.invoke<ListResult>('list', { query: this.q, type: this.type, collection: this.col });
    } catch {
      return;
    }
    if (seq !== this.reqSeq) return;
    this.data = data;
    this.flat = data.sections.flatMap((s) => s.items);
    if (!this.sel || !this.flat.some((i) => i.id === this.sel)) this.sel = this.flat[0]?.id ?? null;
    this.render();
    await this.loadDetail();
  }

  private async loadDetail() {
    const id = this.sel;
    if (!id) { this.detail = null; this.renderPreview(); return; }
    const cached = this.flat.find((i) => i.id === id) ?? null;
    this.detail = cached;
    this.renderPreview();
    try {
      const full = await this.api.invoke<ItemView | null>('item', id, this.revealed.has(id));
      if (this.sel === id && full) { this.detail = full; this.renderPreview(); }
    } catch { /* keep cached */ }
  }

  private select(id: string | null, scroll = true) {
    if (!id || id === this.sel) return;
    this.sel = id;
    for (const r of this.el.querySelectorAll('.row')) r.classList.toggle('sel', (r as HTMLElement).dataset.id === id);
    if (scroll) (this.el.querySelector(`.row[data-id="${CSS_escape(id)}"]`) as HTMLElement | null)?.scrollIntoView({ block: 'nearest' });
    void this.loadDetail();
  }

  // ------------------------------------------------------------------ render
  private renderShell() {
    if (this.mode === 'panel') {
      this.el.innerHTML = `
        <div class="top">
          <label class="search">${icon('search', 16)}<input class="q" type="text" spellcheck="false" autocomplete="off" placeholder="${esc(this.t('searchPlaceholder'))}"></label>
          <button class="iconbtn" data-act="openHub" title="${esc(this.t('openHub'))}">${icon('external', 16)}</button>
        </div>
        <div class="chips"></div>
        <div class="filters"></div>
        <div class="banners"></div>
        <div class="body"><div class="list" tabindex="-1"></div><div class="prev"></div></div>
        <div class="foot"></div>`;
    } else {
      this.el.innerHTML = `
        <aside class="side"></aside>
        <section class="main">
          <div class="top"><label class="search">${icon('search', 16)}<input class="q" type="text" spellcheck="false" autocomplete="off" placeholder="${esc(this.t('searchPlaceholder'))}"><kbd>Strg F</kbd></label></div>
          <div class="filters"></div>
          <div class="banners"></div>
          <div class="body"><div class="list" tabindex="-1"></div><div class="prev"></div></div>
          <div class="settings" hidden></div>
        </section>`;
    }
  }

  private render() {
    if (this.mode === 'panel') this.renderChips(); else this.renderSide();
    const inSettings = this.page === 'settings';
    for (const sel of ['.filters', '.body', '.top', '.banners']) { const n = this.$(sel); if (n && this.mode === 'hub') n.hidden = inSettings; }
    const st = this.$('.settings');
    if (st) st.hidden = !inSettings;
    if (inSettings) { this.renderSettings(); return; }
    this.renderFilters();
    this.renderBanners();
    this.renderList();
    this.renderPreview();
    this.renderFoot();
  }

  private colIcon(symbol: string, secret: boolean) {
    return icon(secret ? 'lock' : COLLECTION_ICONS.includes(symbol) ? symbol : 'folder', 14);
  }

  private renderChips() {
    const c = this.$('.chips');
    if (!c || !this.data) return;
    const syncOn = !!this.settings?.sync.enabled;
    c.innerHTML = [
      `<button class="chip ${this.col === null ? 'on' : ''}" data-col="" data-drop="">${icon('text', 14)}${esc(this.t('history'))}<span class="n">${this.data.historyCount}</span></button>`,
      ...this.data.collections.map((k) => `<button class="chip ${this.col === k.id ? 'on' : ''}" data-col="${esc(k.id)}" data-drop="${esc(k.id)}">${this.colIcon(k.symbol, k.secret)}${esc(k.name)}<span class="n">${k.count || ''}</span></button>`),
      syncOn ? `<button class="chip ${this.col === SHARED ? 'on' : ''}" data-col="${SHARED}">${icon('cloud', 14)}${esc(this.t('shared'))}</button>` : '',
      `<button class="chip" data-act="newCollection" title="${esc(this.t('newCollection'))}">${icon('plus', 14)}</button>`,
    ].join('');
  }

  private renderSide() {
    const s = this.$('.side');
    if (!s) return;
    const d = this.data;
    const syncOn = !!this.settings?.sync.enabled;
    const on = (c: CollectionId) => (this.page === 'list' && this.col === c ? 'on' : '');
    s.innerHTML = `
      <h2>${esc(this.t('hubTitle'))}</h2><div class="subt">${esc(this.t('hubSubtitle'))}</div>
      <button class="nav ${on(null)}" data-col="" data-drop="">${icon('text', 16)}${esc(this.t('history'))}<span class="n">${d?.historyCount ?? ''}</span></button>
      ${syncOn ? `<button class="nav ${on(SHARED)}" data-col="${SHARED}">${icon('cloud', 16)}${esc(this.t('shared'))}</button>` : ''}
      <div class="lbl">${esc(this.api.locale === 'de' ? 'Bereiche' : 'Collections')}</div>
      ${(d?.collections ?? []).map((k) => `<button class="nav ${on(k.id)}" data-col="${esc(k.id)}" data-drop="${esc(k.id)}" data-colmenu="${esc(k.id)}">${this.colIcon(k.symbol, k.secret)}${esc(k.name)}<span class="n">${k.count || ''}</span></button>`).join('')}
      <button class="nav" data-act="newCollection">${icon('plus', 16)}${esc(this.t('newCollection'))}</button>
      <div class="grow"></div>
      <button class="nav ${this.page === 'settings' ? 'on' : ''}" data-act="settingsPage">${icon('settings', 16)}${esc(this.t('settings'))}</button>`;
  }

  private renderFilters() {
    const f = this.$('.filters');
    if (!f || !this.data) return;
    const n = this.data.counts;
    const shared = this.col === SHARED;
    f.innerHTML = (shared ? [] : TYPES).map((ty) => `<button class="seg ${this.type === ty ? 'on' : ''}" data-type="${ty}">${esc(this.t(ty as StringKey))}${ty !== 'all' && n[ty] ? `<span class="n">${n[ty]}</span>` : ''}</button>`).join('')
      + `<span class="count">${esc(this.flat.length === 1 ? this.t('entry') : this.t('entries', this.flat.length))}</span>`;
  }

  private renderBanners() {
    const b = this.$('.banners');
    if (!b) return;
    const s = this.settings;
    b.innerHTML = s?.readOnly ? `<div class="banner">${esc(this.t('readOnly'))}</div>` : s?.recovery === 'backup' ? `<div class="banner">${esc(this.t('recovery'))}</div>` : '';
  }

  private fmtTime(ts: number) {
    const d = new Date(ts * 1000), now = new Date();
    const loc = this.api.locale === 'de' ? 'de-DE' : 'en-US';
    const sameDay = d.toDateString() === now.toDateString();
    return sameDay ? d.toLocaleTimeString(loc, { hour: '2-digit', minute: '2-digit' }) : d.toLocaleDateString(loc, { day: '2-digit', month: 'short' }) + ' ' + d.toLocaleTimeString(loc, { hour: '2-digit', minute: '2-digit' });
  }

  private tileFor(it: ItemView): string {
    if (it.masked) return `<div class="tile t-lock">${icon('lock', 18)}</div>`;
    if (it.color) return `<div class="tile" style="background:${esc(it.color)}"></div>`;
    if (it.kind === 'image' && it.thumbUrl) return `<div class="tile"><img loading="lazy" data-fallback="${esc(it.id)}" src="${esc(it.thumbUrl)}" alt=""></div>`;
    if (it.kind === 'image') return `<div class="tile">${icon('image', 18)}</div>`;
    if (it.kind === 'file') return `<div class="tile t-file">${icon('file', 18)}</div>`;
    if (it.source === 'Diktat' || it.source === 'Meeting') return `<div class="tile t-mic">${icon('mic', 18)}</div>`;
    if (it.source === 'KI') return `<div class="tile t-ai">${icon('sparkles', 18)}</div>`;
    if (it.isLink) return `<div class="tile t-link">${icon('globe', 18)}</div>`;
    const smart = it.badges.find((b) => b === 'code' || b === 'email' || b === 'phone');
    if (smart) return `<div class="tile t-${smart}">${icon(smart === 'email' ? 'mail' : smart, 18)}</div>`;
    return `<div class="tile">${icon('text', 18)}</div>`;
  }

  private rowHTML(it: ItemView, quick: number | null): string {
    const tags: string[] = [];
    if (it.masked || it.expiresInH !== null && it.expiresInH !== undefined) {
      tags.push(`<span class="tag secret">${esc(it.masked ? this.t('hidden') : this.t('reveal'))}</span>`);
      if (it.expiresInH !== null && it.expiresInH !== undefined) tags.push(`<span>${esc(this.t('expiresIn', it.expiresInH))} ·</span>`);
    } else {
      for (const b of it.badges.slice(0, 2)) if (!(b === 'link' && it.isLink)) tags.push(`<span class="tag ${esc(b)}">${esc(b === 'link' ? 'Link' : b === 'code' ? 'Code' : b === 'email' ? 'E-Mail' : b === 'phone' ? (this.api.locale === 'de' ? 'Telefon' : 'Phone') : b === 'color' ? (this.api.locale === 'de' ? 'Farbe' : 'Color') : b)}</span>`);
      if (it.shared && it.collection !== SHARED) tags.push(`<span class="tag shared">${esc(this.t('shared'))}</span>`);
    }
    const sub = [it.subtitle, this.fmtTime(it.ts)].filter(Boolean).join(' · ');
    const acts = this.mode === 'hub'
      ? `<button class="iconbtn" data-act="copy" data-id="${esc(it.id)}" title="${esc(this.t('copy'))}">${icon('copy', 15)}</button>`
      : '';
    return `<div class="row ${it.id === this.sel ? 'sel' : ''}" data-id="${esc(it.id)}" draggable="${it.collection === SHARED ? 'false' : 'true'}">
      ${this.tileFor(it)}
      <div class="meta"><div class="title">${esc(it.title)}</div><div class="sub">${tags.join('')}<span>${esc(sub)}</span></div></div>
      ${it.pinned ? `<span class="pinmark">${icon('pinFill', 13)}</span>` : ''}
      ${quick ? `<span class="quick">Strg ${quick}</span>` : ''}
      <div class="rowacts">${acts}
        <button class="iconbtn ${it.pinned ? 'on' : ''}" data-act="pin" data-id="${esc(it.id)}" title="${esc(it.pinned ? this.t('unpin') : this.t('pin'))}">${icon(it.pinned ? 'pinFill' : 'pin', 15)}</button>
        <button class="iconbtn danger" data-act="delete" data-id="${esc(it.id)}" title="${esc(this.t('delete'))}">${icon('trash', 15)}</button>
      </div>
    </div>`;
  }

  private renderList() {
    const l = this.$('.list');
    if (!l || !this.data) return;
    this.$('.body')?.classList.toggle('noprev', !this.flat.length);
    if (!this.flat.length) {
      const searching = !!this.q.trim() || this.type !== 'all';
      l.innerHTML = `<div class="empty"><div><div class="ring">${icon(searching ? 'search' : 'copy', 22)}</div><h3>${esc(searching ? this.t('noResults') : this.t('empty'))}</h3><p>${esc(searching ? this.t('noResultsHint') : this.t('emptyHint'))}</p></div></div>`;
      return;
    }
    let n = 0;
    const secTitle = (k: string) => (k === 'pinned' ? this.t('pinned') : k === 'today' ? this.t('today') : k === 'yesterday' ? this.t('yesterday') : k === 'collection' || k === 'shared' ? '' : new Date(k + 'T12:00:00').toLocaleDateString(this.api.locale === 'de' ? 'de-DE' : 'en-US', { weekday: 'long', day: 'numeric', month: 'long' }));
    l.innerHTML = this.data.sections.map((s) => {
      const title = secTitle(s.key);
      return (title ? `<div class="sec ${s.key === 'pinned' ? 'pinned' : ''}">${s.key === 'pinned' ? icon('pinFill', 11) : ''}${esc(title)}</div>` : '')
        + s.items.map((it) => { n++; return this.rowHTML(it, n <= 9 ? n : null); }).join('');
    }).join('');
    for (const img of l.querySelectorAll('img[data-fallback]')) {
      img.addEventListener('error', () => void this.fallbackImage(img as HTMLImageElement), { once: true });
    }
  }

  private async fallbackImage(img: HTMLImageElement) {
    const id = img.dataset.fallback!;
    try {
      const r = await this.api.invoke<{ url: string } | null>('image', id);
      if (r?.url) img.src = r.url;
    } catch { /* leave empty */ }
  }

  private renderPreview() {
    const p = this.$('.prev');
    if (!p) return;
    const it = this.detail;
    if (!it || !this.flat.length) { p.innerHTML = ''; return; }
    const inShared = it.collection === SHARED;
    const cols = this.data?.collections ?? [];
    const colName = it.collection && !inShared ? cols.find((c) => c.id === it.collection)?.name : null;
    const meta = [it.kind === 'image' && it.w ? `${it.w}×${it.h}` : '', colName ?? '', this.fmtTime(it.ts)].filter(Boolean).join(' · ');
    const primary = this.mode === 'panel' && this.settings?.pasteOnEnter !== false
      ? `<button class="btn primary" data-act="paste">${icon('paste', 15)}${esc(this.t('paste'))}<span class="k">↵</span></button><button class="btn" data-act="copy">${icon('copy', 15)}${esc(this.t('copy'))}</button>`
      : `<button class="btn primary" data-act="copy">${icon('copy', 15)}${esc(this.t('copy'))}</button>`;
    const acts = [
      primary,
      it.kind === 'image' ? `<button class="btn" data-act="viewer">${icon('fit', 15)}${esc(this.t('openViewer'))}</button>` : '',
      it.isLink && !it.masked ? `<button class="btn" data-act="openLink">${icon('external', 15)}${esc(this.t('openLink'))}</button>` : '',
      `<button class="btn" data-act="more">${icon('more', 15)}${esc(this.t('more'))}</button>`,
    ].join('');
    let body: string;
    if (it.masked && !this.revealed.has(it.id)) {
      body = `<div class="pbody"><div class="masked"><div>${icon('lock', 26)}<div style="margin:8px 0 10px">${esc(this.t('hidden'))}</div><button class="btn" data-act="reveal">${icon('eye', 15)}${esc(this.t('reveal'))}</button></div></div></div>`;
    } else if (it.kind === 'image') {
      const src = it.imageUrl ?? it.thumbUrl ?? '';
      body = `<div class="pbody img" data-act="viewer"><img data-fallback="${esc(it.id)}" src="${esc(src)}" alt=""></div>${it.text ? `<div class="ocr">${esc(it.text)}</div>` : ''}`;
    } else if (it.kind === 'file') {
      body = `<div class="pbody"><div class="files">${(it.fileNames ?? []).map((f) => `<div class="frow">${icon('file', 18)}<span>${esc(f)}</span></div>`).join('')}</div></div>`;
    } else {
      const code = it.badges.includes('code');
      body = `<div class="pbody">${it.color ? `<div class="swatch" style="background:${esc(it.color)}"></div>` : ''}${code ? `<pre>${esc(it.text ?? '')}</pre>` : `<div class="prose">${esc(it.text ?? '')}</div>`}</div>`;
    }
    p.innerHTML = `
      <div class="phead"><div class="meta"><div class="title">${esc(it.masked && !this.revealed.has(it.id) ? '••••••••••••' : it.title)}</div><div class="sub">${esc(meta)}</div></div>
        <button class="iconbtn ${it.pinned ? 'on' : ''}" data-act="pin" title="${esc(it.pinned ? this.t('unpin') : this.t('pin'))}">${icon(it.pinned ? 'pinFill' : 'pin', 16)}</button>
      </div>
      <div class="pacts">${acts}</div>
      ${body}`;
    for (const img of p.querySelectorAll('img[data-fallback]')) img.addEventListener('error', () => void this.fallbackImage(img as HTMLImageElement), { once: true });
  }

  private renderFoot() {
    const f = this.$('.foot');
    if (!f) return;
    const k = (s: string) => { const [a, ...b] = s.split(' '); return `<span><b>${esc(a)}</b> ${esc(b.join(' '))}</span>`; };
    f.innerHTML = [this.t('hintNav'), this.settings?.pasteOnEnter === false ? '↵ ' + this.t('copy') : this.t('hintPaste'), this.t('hintCopy'), this.t('hintPin'), this.t('hintDel'), this.t('hintView'), this.t('hintEsc')].map(k).join('');
  }

  // ------------------------------------------------------------------ settings (hub)
  private renderSettings() {
    const el = this.$('.settings');
    const s = this.settings;
    if (!el || !s) return;
    const sw = (key: string, on: boolean, disabled = false) => `<button class="switch ${on ? 'on' : ''}" data-set="${key}" ${disabled ? 'disabled' : ''} role="switch" aria-checked="${on}"></button>`;
    const opt = (title: string, hint: string, ctl: string) => `<div class="opt"><div class="ot"><div>${esc(title)}</div>${hint ? `<div>${esc(hint)}</div>` : ''}</div>${ctl}</div>`;
    const sy = this.sync ?? { state: 'off' };
    const dotCls = sy.state === 'connected' ? 'ok' : sy.state === 'offline' ? 'bad' : sy.state === 'off' ? '' : 'warn';
    const stKey = ('st_' + (s.sync.enabled ? sy.state : 'off')) as StringKey;
    const syncCard = !s.sync.enabled
      ? `<div class="card">${opt(this.t('syncEnable'), this.t('syncOffHint'), sw('sync.enabled', false))}</div>`
      : `<div class="card">
          ${opt(this.t('syncEnable'), '', sw('sync.enabled', true))}
          <div class="opt"><div class="ot"><div class="status"><span class="dot ${dotCls}"></span>${esc(this.t(stKey))}${sy.reason ? ' – ' + esc(sy.reason) : ''}${sy.queue ? ' · ' + esc(this.t('queue', sy.queue)) : ''}</div></div></div>
          <div class="opt"><div class="ot"><div>${esc(this.t('syncName'))}</div></div><input class="field" data-field="sync.name" value="${esc(s.sync.name)}" placeholder="${esc(this.api.locale === 'de' ? 'z. B. Lena' : 'e.g. Lena')}"></div>
          ${sy.paired ? '' : `<div class="opt"><div class="ot"><div>${esc(this.t('syncUrl'))}</div></div><input class="field" style="width:320px" data-field="syncUrl" value="${esc(this.urlInput || sy.url || '')}" placeholder="${esc(this.t('syncUrlPh'))}"><button class="btn" data-act="syncSetup">${esc(this.t('syncSave'))}</button></div>`}
          ${sy.pairingCode ? `<div class="opt"><div class="ot"><div class="paircode">${esc(sy.pairingCode)}</div><div>${esc(this.t('syncCodeHint'))}</div></div><div style="display:flex;flex-direction:column;gap:6px"><button class="btn" data-act="copyCode">${icon('copy', 15)}${esc(this.t('copy'))}</button><button class="btn" data-act="syncPairCancel">${esc(this.t('syncCancel'))}</button></div></div>` : ''}
          ${sy.paired
            ? `<div class="opt"><div class="ot"><div>${esc(this.t('syncPaired'))}</div><div>${esc(sy.host ?? '')}</div></div><button class="btn" data-act="syncPairCreate">${esc(this.t('syncPairCreate'))}</button><button class="btn danger" data-act="syncUnpair">${esc(this.t('syncUnpair'))}</button></div>`
            : `<div class="opt"><div class="ot"><div>${esc(this.t('syncPairJoin'))}</div></div><input class="field" style="width:260px" data-field="pairCode" value="${esc(this.pairInput)}" placeholder="${esc(this.t('syncCodePh'))}"><button class="btn" data-act="syncPairJoin">${esc(this.t('syncPairJoin'))}</button></div>
               ${sy.state === 'unpaired' ? `<div class="opt"><div class="ot"><div>${esc(this.t('syncNewVault'))}</div></div><button class="btn" data-act="syncPairCreate">${esc(this.t('syncPairCreate'))}</button></div>` : ''}`}
        </div>`;
    el.innerHTML = `
      <h3>${esc(this.t('settings'))}</h3>
      <div class="card">
        ${opt(this.t('sPause'), '', sw('paused', s.paused))}
        ${opt(this.t('sPaste'), this.t('sPasteHint'), sw('pasteOnEnter', s.pasteOnEnter))}
        ${opt(this.t('sPasswords'), this.t('sPasswordsHint'), sw('skipPasswordLike', s.skipPasswordLike))}
        ${opt(this.t('sEncrypt'), s.dpapiAvailable ? this.t('sEncryptHint') : this.t('sEncryptNA'), sw('encryptAtRest', s.encryptAtRest && s.dpapiAvailable, !s.dpapiAvailable))}
        ${opt(this.t('sHotkey'), '', `<input class="field" data-field="hotkey" value="${esc(s.hotkey)}" style="width:170px">`)}
      </div>
      <h3>${esc(this.t('sRetention'))}</h3>
      <div class="card">
        ${opt(this.t('sDays'), '', `<input class="field num" type="number" min="1" max="30" data-field="maxAgeDays" value="${s.maxAgeDays}">`)}
        ${opt(this.t('sMax'), '', `<input class="field num" type="number" min="20" max="2000" data-field="maxItems" value="${s.maxItems}">`)}
        ${opt(this.t('sQuota'), '', `<input class="field num" type="number" min="50" max="20000" data-field="quotaMB" value="${s.quotaMB}">`)}
        <div class="opt"><div class="ot"><div>${esc(this.t('sIgnored'))}</div><textarea class="field" data-field="ignoredApps" spellcheck="false">${esc(s.ignoredApps.join('\n'))}</textarea></div></div>
        ${opt(this.t('sClear'), '', `<button class="btn danger" data-act="clearHistory">${icon('trash', 15)}${esc(this.t('sClear'))}</button>`)}
      </div>
      <h3>${esc(this.t('sync'))}</h3>
      ${syncCard}`;
  }

  private async setSetting(patch: Record<string, unknown>) {
    try { this.settings = await this.api.invoke<SettingsView>('setSettings', patch); } catch { /* ignore */ }
    this.render();
  }

  // ------------------------------------------------------------------ actions
  private current(): ItemView | null {
    return this.flat.find((i) => i.id === this.sel) ?? null;
  }

  private async act(name: string, id: string | null = this.sel, target?: HTMLElement) {
    const it = id ? this.flat.find((i) => i.id === id) ?? null : null;
    switch (name) {
      case 'paste': if (id) await this.api.invoke('paste', id); break;
      case 'copy': if (id) await this.api.invoke('copy', id); break;
      case 'pin': if (id && it) { await this.api.invoke('pin', id, !it.pinned); } break;
      case 'delete': if (id) { const i = this.flat.findIndex((x) => x.id === id); this.sel = this.flat[i + 1]?.id ?? this.flat[i - 1]?.id ?? null; await this.api.invoke('delete', id); } break;
      case 'viewer': if (id) this.openViewer(id); break;
      case 'reveal': if (id) { this.revealed.add(id); await this.loadDetail(); } break;
      case 'openLink': if (id) await this.api.invoke('openLink', id); break;
      case 'reveal-file': if (id) await this.api.invoke('reveal', id); break;
      case 'saveAs': if (id) await this.api.invoke('saveAs', id); break;
      case 'share': if (id) await this.api.invoke('share', id); break;
      case 'unshare': if (id) await this.api.invoke('unshare', id); break;
      case 'download': if (id) await this.api.invoke('download', id); break;
      case 'more': if (id) this.openItemMenu(id, target ?? null); break;
      case 'openHub': await this.api.invoke('openHub'); break;
      case 'newCollection': await this.promptCollection(); break;
      case 'settingsPage': this.page = 'settings'; this.render(); break;
      case 'clearHistory': if (confirm(this.t('sClearConfirm'))) await this.api.invoke('clearHistory'); break;
      case 'syncSetup': await this.syncCall('syncSetup', this.urlInput); break;
      case 'syncPairCreate': await this.syncCall('syncPairCreate'); break;
      case 'syncPairJoin': await this.syncCall('syncPairJoin', this.pairInput); this.pairInput = ''; break;
      case 'syncPairCancel': await this.syncCall('syncPairCancel'); break;
      case 'syncUnpair': await this.syncCall('syncUnpair'); break;
      case 'copyCode': if (this.sync?.pairingCode) await navigator.clipboard?.writeText(this.sync.pairingCode).catch(() => {}); break;
    }
  }

  private async syncCall(name: string, ...args: unknown[]) {
    try { await this.api.invoke(name, ...args); } catch (e) { alert(String((e as Error).message ?? e).replace(/^Error invoking remote method '[^']+': (Error: )?/, '')); }
    try { this.sync = await this.api.invoke<SyncView>('syncStatus'); } catch { /* ignore */ }
    this.render();
  }

  private openItemMenu(id: string, anchor: HTMLElement | null) {
    this.closeMenu();
    const it = this.flat.find((i) => i.id === id);
    if (!it) return;
    const inShared = it.collection === SHARED;
    const cols = this.data?.collections ?? [];
    const hasFile = it.kind === 'file' || it.kind === 'image';
    const syncOn = !!this.settings?.sync.enabled;
    const m = document.createElement('div');
    m.className = 'menu';
    m.innerHTML = [
      !inShared ? cols.filter((c) => c.id !== it.collection).map((c) => `<button data-move="${esc(c.id)}">${this.colIcon(c.symbol, c.secret)}${esc(this.t('moveTo'))}: ${esc(c.name)}</button>`).join('') : '',
      !inShared && it.collection ? `<button data-move="">${icon('text', 15)}${esc(this.t('removeFrom'))}</button>` : '',
      !inShared ? '<hr>' : '',
      hasFile ? `<button data-mact="reveal-file">${icon('folderOpen', 15)}${esc(this.t('showInExplorer'))}</button>` : '',
      `<button data-mact="saveAs">${icon('save', 15)}${esc(this.t('saveAs'))}</button>`,
      syncOn && !inShared ? `<button data-mact="${it.shared ? 'unshare' : 'share'}">${icon('share', 15)}${esc(it.shared ? this.t('unshare') : this.t('share'))}</button>` : '',
      inShared && hasFile ? `<button data-mact="download">${icon('save', 15)}${esc(this.t('download'))}</button>` : '',
      '<hr>',
      `<button data-mact="delete">${icon('trash', 15)}${esc(this.t('delete'))}</button>`,
    ].join('');
    this.el.appendChild(m);
    const host = this.el.getBoundingClientRect();
    const r = (anchor ?? this.$('.prev') ?? this.el).getBoundingClientRect();
    const mw = 230;
    m.style.left = `${Math.max(8, Math.min(host.width - mw - 8, r.left - host.left))}px`;
    const top = r.bottom - host.top + 4;
    m.style.top = `${Math.min(top, host.height - m.offsetHeight - 8)}px`;
    m.style.minWidth = mw + 'px';
    m.addEventListener('click', async (e) => {
      const b = (e.target as HTMLElement).closest('button');
      if (!b) return;
      e.stopPropagation();
      this.closeMenu();
      if (b.dataset.move !== undefined) await this.api.invoke('setCollection', id, b.dataset.move || null);
      else if (b.dataset.mact) await this.act(b.dataset.mact, id);
    });
    this.menuEl = m;
  }

  private closeMenu() { this.menuEl?.remove(); this.menuEl = null; }

  /** small inline dialog (Electron has no window.prompt) */
  private askText(title: string, value = ''): Promise<string | null> {
    this.closeMenu();
    return new Promise((resolve) => {
      const m = document.createElement('div');
      m.className = 'menu ask';
      m.style.left = '50%'; m.style.top = '96px'; m.style.transform = 'translateX(-50%)'; m.style.width = '300px'; m.style.padding = '12px';
      m.innerHTML = `<div style="font-size:12.5px;margin:0 2px 8px;color:var(--cv-dim)">${esc(title)}</div>
        <input class="field" style="width:100%" value="${esc(value)}">
        <div style="display:flex;gap:6px;justify-content:flex-end;margin-top:10px"><button class="btn" data-ask="0">Esc</button><button class="btn primary" data-ask="1">OK ↵</button></div>`;
      this.el.appendChild(m);
      const inp = m.querySelector('input') as HTMLInputElement;
      const done = (v: string | null) => { m.remove(); this.menuEl = null; resolve(v && v.trim() ? v.trim() : null); this.focusSearch(); };
      inp.addEventListener('keydown', (e) => { e.stopPropagation(); if (e.key === 'Enter') done(inp.value); if (e.key === 'Escape') done(null); });
      m.addEventListener('click', (e) => { e.stopPropagation(); const b = (e.target as HTMLElement).closest('[data-ask]') as HTMLElement | null; if (b) done(b.dataset.ask === '1' ? inp.value : null); });
      this.menuEl = m;
      setTimeout(() => { inp.focus(); inp.select(); }, 0);
    });
  }

  private async promptCollection() {
    const name = await this.askText(this.t('collectionName'));
    if (name) await this.api.invoke('createCollection', name, /passw|kennw|geheim|secret/i.test(name));
  }

  private openCollectionMenu(id: string, anchor: HTMLElement) {
    this.closeMenu();
    const c = this.data?.collections.find((x) => x.id === id);
    if (!c) return;
    const m = document.createElement('div');
    m.className = 'menu';
    m.innerHTML = `<button data-c="rename">${icon('text', 15)}${esc(this.t('rename'))}</button>
      <button data-c="icon">${icon(c.symbol, 15)}${esc(this.api.locale === 'de' ? 'Symbol wechseln' : 'Change icon')}</button><hr>
      <button data-c="delete">${icon('trash', 15)}${esc(this.t('deleteCollection'))}</button>`;
    this.el.appendChild(m);
    const host = this.el.getBoundingClientRect(), r = anchor.getBoundingClientRect();
    m.style.left = `${r.left - host.left + 8}px`;
    m.style.top = `${r.bottom - host.top + 2}px`;
    m.addEventListener('click', async (e) => {
      const b = (e.target as HTMLElement).closest('[data-c]') as HTMLElement | null;
      if (!b) return;
      e.stopPropagation();
      this.closeMenu();
      if (b.dataset.c === 'rename') { const n = await this.askText(this.t('collectionName'), c.name); if (n) await this.api.invoke('renameCollection', id, n); }
      else if (b.dataset.c === 'icon') { const i = COLLECTION_ICONS.indexOf(c.symbol); await this.api.invoke('renameCollection', id, c.name, COLLECTION_ICONS[(i + 1) % COLLECTION_ICONS.length]); }
      else if (confirm(`${this.t('deleteCollection')}: ${c.name}?`)) { if (this.col === id) this.col = null; await this.api.invoke('deleteCollection', id); }
    });
    this.menuEl = m;
  }

  // ------------------------------------------------------------------ viewer
  private imageIds() { return this.flat.filter((i) => i.kind === 'image' && !i.masked).map((i) => i.id); }

  private openViewer(id: string) {
    const ids = this.imageIds();
    const idx = ids.indexOf(id);
    if (idx < 0) return;
    this.viewer = { ids, idx, zoom: 1, fit: 1, x: 0, y: 0, w: 0, h: 0 };
    if (this.mode === 'panel') void this.api.invoke('viewer', true);
    this.renderViewer();
  }

  private closeViewer() {
    if (!this.viewer) return;
    this.viewer = null;
    this.viewerResize?.disconnect();
    this.viewerResize = null;
    this.$('.viewer')?.remove();
    if (this.mode === 'panel') void this.api.invoke('viewer', false);
    this.el.focus();
  }

  private renderViewer() {
    const v = this.viewer;
    if (!v) return;
    let el = this.$('.viewer');
    if (!el) {
      el = document.createElement('div');
      el.className = 'viewer';
      this.el.appendChild(el);
      this.bindViewer(el);
      // the panel window grows for the viewer -> refit while the user hasn't zoomed yet
      this.viewerResize = new ResizeObserver(() => { const v = this.viewer; if (v && Math.abs(v.zoom - v.fit) < 1e-3) this.fitViewer(); });
      this.viewerResize.observe(el);
    }
    const id = v.ids[v.idx];
    const it = this.flat.find((i) => i.id === id);
    el.innerHTML = `
      <div class="vbar"><div class="vt">${esc(it?.title ?? '')}</div>
        <span class="muted">${v.idx + 1} / ${v.ids.length}</span>
        <button class="iconbtn" data-v="out" title="${esc(this.t('zoomOut'))}">${icon('zoomOut', 16)}</button>
        <span class="vzoom">${Math.round(v.zoom * 100)}%</span>
        <button class="iconbtn" data-v="in" title="${esc(this.t('zoomIn'))}">${icon('zoomIn', 16)}</button>
        <button class="iconbtn" data-v="fit" title="${esc(this.t('fit'))}">${icon('fit', 16)}</button>
        <button class="iconbtn" data-v="copy" title="${esc(this.t('copy'))}">${icon('copy', 16)}</button>
        <button class="iconbtn" data-v="close" title="${esc(this.t('close'))} (Esc)">${icon('x', 16)}</button>
      </div>
      <div class="vstage"><img alt="" draggable="false">
        <button class="vnav l" data-v="prev" ${v.idx === 0 ? 'disabled' : ''}>${icon('left', 18)}</button>
        <button class="vnav r" data-v="next" ${v.idx >= v.ids.length - 1 ? 'disabled' : ''}>${icon('right', 18)}</button>
      </div>`;
    const img = el.querySelector('img') as HTMLImageElement;
    img.addEventListener('load', () => {
      if (!this.viewer) return;
      this.viewer.w = img.naturalWidth; this.viewer.h = img.naturalHeight;
      this.fitViewer();
    });
    img.addEventListener('error', async () => {
      const r = await this.api.invoke<{ url: string } | null>('image', id).catch(() => null);
      if (r?.url && img.src !== r.url) img.src = r.url;
    }, { once: true });
    img.src = it?.imageUrl ?? it?.thumbUrl ?? '';
  }

  private fitViewer() {
    const v = this.viewer;
    const st = this.$('.vstage');
    if (!v || !st || !v.w) return;
    const r = st.getBoundingClientRect();
    v.fit = Math.min(1, (r.width - 40) / v.w, (r.height - 40) / v.h);
    v.zoom = v.fit;
    v.x = (r.width - v.w * v.zoom) / 2;
    v.y = (r.height - v.h * v.zoom) / 2;
    this.applyViewer();
  }

  private applyViewer() {
    const v = this.viewer;
    const img = this.$('.vstage img') as HTMLImageElement | null;
    if (!v || !img) return;
    img.style.transform = `translate(${v.x}px, ${v.y}px) scale(${v.zoom})`;
    const z = this.$('.vzoom');
    if (z) z.textContent = `${Math.round(v.zoom * 100)}%`;
  }

  private zoomAt(factor: number, cx?: number, cy?: number) {
    const v = this.viewer;
    const st = this.$('.vstage');
    if (!v || !st) return;
    const r = st.getBoundingClientRect();
    const px = cx ?? r.width / 2, py = cy ?? r.height / 2;
    const nz = Math.min(8, Math.max(Math.min(v.fit, 0.1), v.zoom * factor));
    v.x = px - ((px - v.x) * nz) / v.zoom;
    v.y = py - ((py - v.y) * nz) / v.zoom;
    v.zoom = nz;
    this.applyViewer();
  }

  private stepViewer(d: number) {
    const v = this.viewer;
    if (!v) return;
    const n = v.idx + d;
    if (n < 0 || n >= v.ids.length) return;
    v.idx = n;
    this.select(v.ids[n] ?? null);
    this.renderViewer();
  }

  private bindViewer(el: HTMLElement) {
    el.addEventListener('click', (e) => {
      const b = (e.target as HTMLElement).closest('[data-v]') as HTMLElement | null;
      if (!b) return;
      e.stopPropagation();
      const a = b.dataset.v;
      if (a === 'close') this.closeViewer();
      else if (a === 'in') this.zoomAt(1.25);
      else if (a === 'out') this.zoomAt(0.8);
      else if (a === 'fit') this.fitViewer();
      else if (a === 'prev') this.stepViewer(-1);
      else if (a === 'next') this.stepViewer(1);
      else if (a === 'copy' && this.viewer) void this.api.invoke('copy', this.viewer.ids[this.viewer.idx]);
    });
    el.addEventListener('wheel', (e) => {
      const st = this.$('.vstage');
      if (!st) return;
      e.preventDefault();
      const r = st.getBoundingClientRect();
      this.zoomAt(e.deltaY < 0 ? 1.12 : 1 / 1.12, e.clientX - r.left, e.clientY - r.top);
    }, { passive: false });
    let drag: { x: number; y: number; vx: number; vy: number } | null = null;
    el.addEventListener('pointerdown', (e) => {
      if (!(e.target as HTMLElement).closest('.vstage') || (e.target as HTMLElement).closest('.vnav') || !this.viewer) return;
      drag = { x: e.clientX, y: e.clientY, vx: this.viewer.x, vy: this.viewer.y };
      this.$('.vstage')?.classList.add('drag');
      (e.target as HTMLElement).setPointerCapture?.(e.pointerId);
    });
    el.addEventListener('pointermove', (e) => {
      if (!drag || !this.viewer) return;
      this.viewer.x = drag.vx + e.clientX - drag.x;
      this.viewer.y = drag.vy + e.clientY - drag.y;
      this.applyViewer();
    });
    el.addEventListener('pointerup', () => { drag = null; this.$('.vstage')?.classList.remove('drag'); });
    el.addEventListener('dblclick', (e) => {
      if (!this.viewer || !(e.target as HTMLElement).closest('.vstage')) return;
      const st = this.$('.vstage')!.getBoundingClientRect();
      if (Math.abs(this.viewer.zoom - 1) < 0.01) this.fitViewer(); else this.zoomAt(1 / this.viewer.zoom, e.clientX - st.left, e.clientY - st.top);
    });
  }

  // ------------------------------------------------------------------ events
  private onClick(e: MouseEvent) {
    const t = e.target as HTMLElement;
    if (this.menuEl && !t.closest('.menu')) this.closeMenu();
    const actEl = t.closest('[data-act]') as HTMLElement | null;
    if (actEl) {
      e.stopPropagation();
      void this.act(actEl.dataset.act!, actEl.dataset.id ?? this.sel, actEl);
      return;
    }
    const setEl = t.closest('[data-set]') as HTMLElement | null;
    if (setEl && this.settings) {
      const k = setEl.dataset.set!;
      if (k === 'sync.enabled') void this.setSetting({ sync: { enabled: !this.settings.sync.enabled } });
      else void this.setSetting({ [k]: !(this.settings as unknown as Record<string, boolean>)[k] });
      return;
    }
    const colEl = t.closest('[data-col]') as HTMLElement | null;
    if (colEl) {
      this.col = colEl.dataset.col || null;
      this.page = 'list';
      this.type = 'all';
      this.sel = null;
      void this.refresh();
      return;
    }
    const typeEl = t.closest('[data-type]') as HTMLElement | null;
    if (typeEl) { this.type = typeEl.dataset.type as TypeFilter; this.sel = null; void this.refresh(); return; }
    const row = t.closest('.row') as HTMLElement | null;
    if (row?.dataset.id) this.select(row.dataset.id, false);
  }

  private onDblClick(e: MouseEvent) {
    const row = (e.target as HTMLElement).closest('.row') as HTMLElement | null;
    if (!row?.dataset.id || (e.target as HTMLElement).closest('[data-act]')) return;
    void this.act(this.mode === 'panel' ? 'paste' : 'copy', row.dataset.id);
  }

  private onContext(e: MouseEvent) {
    const colEl = (e.target as HTMLElement).closest('[data-col]') as HTMLElement | null;
    if (colEl?.dataset.col && colEl.dataset.col !== SHARED) { e.preventDefault(); this.openCollectionMenu(colEl.dataset.col, colEl); return; }
    const row = (e.target as HTMLElement).closest('.row') as HTMLElement | null;
    if (!row?.dataset.id) return;
    e.preventDefault();
    this.select(row.dataset.id, false);
    this.openItemMenu(row.dataset.id, row);
  }

  private inputTimer: ReturnType<typeof setTimeout> | null = null;
  private onInput(e: Event) {
    const t = e.target as HTMLInputElement;
    if (t.classList.contains('q')) {
      this.q = t.value;
      if (this.inputTimer) clearTimeout(this.inputTimer);
      this.inputTimer = setTimeout(() => { this.sel = null; void this.refresh(); }, 60);
    } else if (t.dataset.field === 'pairCode') this.pairInput = t.value;
    else if (t.dataset.field === 'syncUrl') this.urlInput = t.value;
  }

  private onChange(e: Event) {
    const t = e.target as HTMLInputElement;
    const f = t.dataset.field;
    if (!f || f === 'pairCode' || f === 'syncUrl') return;
    if (f === 'sync.name') void this.setSetting({ sync: { name: t.value } });
    else if (f === 'ignoredApps') void this.setSetting({ ignoredApps: t.value.split(/\r?\n/).map((x) => x.trim()).filter(Boolean) });
    else if (f === 'hotkey') void this.setSetting({ hotkey: t.value.trim() });
    else void this.setSetting({ [f]: Number(t.value) });
  }

  private onKey(e: KeyboardEvent) {
    const target = e.target as HTMLElement;
    const inSearch = target.classList?.contains('q');
    const inField = !inSearch && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA');
    if (inField || this.page === 'settings') return;
    const ctrl = e.ctrlKey || e.metaKey;
    if (this.viewer) {
      if (e.key === 'Escape') { this.closeViewer(); e.preventDefault(); }
      else if (e.key === 'ArrowLeft') { this.stepViewer(-1); e.preventDefault(); }
      else if (e.key === 'ArrowRight') { this.stepViewer(1); e.preventDefault(); }
      else if (e.key === '+' || e.key === '=') { this.zoomAt(1.25); e.preventDefault(); }
      else if (e.key === '-') { this.zoomAt(0.8); e.preventDefault(); }
      else if (e.key === '0') { this.fitViewer(); e.preventDefault(); }
      else if (e.key === ' ') { this.closeViewer(); e.preventDefault(); }
      else if (ctrl && e.key.toLowerCase() === 'c') { void this.api.invoke('copy', this.viewer.ids[this.viewer.idx]); e.preventDefault(); }
      return;
    }
    const idx = this.flat.findIndex((i) => i.id === this.sel);
    const cur = this.current();
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      const n = Math.min(this.flat.length - 1, Math.max(0, idx + (e.key === 'ArrowDown' ? 1 : -1)));
      this.select(this.flat[n]?.id ?? null);
      e.preventDefault();
    } else if (e.key === 'PageDown' || e.key === 'PageUp') {
      const n = Math.min(this.flat.length - 1, Math.max(0, idx + (e.key === 'PageDown' ? 8 : -8)));
      this.select(this.flat[n]?.id ?? null);
      e.preventDefault();
    } else if (e.key === 'Enter') {
      if (cur) void this.act(this.mode === 'panel' ? 'paste' : 'copy');
      e.preventDefault();
    } else if (ctrl && e.key.toLowerCase() === 'c') {
      const s = target as HTMLInputElement;
      const hasSel = inSearch && s.selectionStart !== s.selectionEnd;
      if (!hasSel && !(window.getSelection()?.toString())) { if (cur) void this.act('copy'); e.preventDefault(); }
    } else if (ctrl && e.key.toLowerCase() === 'p') {
      if (cur) void this.act('pin');
      e.preventDefault();
    } else if (ctrl && e.key.toLowerCase() === 'f') {
      this.focusSearch();
      e.preventDefault();
    } else if (ctrl && /^[1-9]$/.test(e.key)) {
      const it = this.flat[Number(e.key) - 1];
      if (it) void this.act(this.mode === 'panel' ? 'paste' : 'copy', it.id);
      e.preventDefault();
    } else if (e.key === 'Delete' && (!inSearch || !this.q)) {
      if (cur) void this.act('delete');
      e.preventDefault();
    } else if (e.key === ' ' && (!inSearch || !this.q) && cur?.kind === 'image') {
      this.openViewer(cur.id);
      e.preventDefault();
    } else if (e.key === 'Tab') {
      const i = TYPES.indexOf(this.type);
      this.type = TYPES[(i + (e.shiftKey ? TYPES.length - 1 : 1)) % TYPES.length] ?? 'all';
      this.sel = null;
      void this.refresh();
      e.preventDefault();
    } else if (e.key === 'Escape') {
      if (this.menuEl) this.closeMenu();
      else if (this.q) { this.q = ''; (this.$('input.q') as HTMLInputElement).value = ''; void this.refresh(); }
      else if (this.mode === 'panel') void this.api.invoke('hide');
      e.preventDefault();
    } else if (!inSearch && e.key.length === 1 && !ctrl && !e.altKey) {
      this.focusSearch();
    }
  }

  private onDragStart(e: DragEvent) {
    const row = (e.target as HTMLElement).closest('.row') as HTMLElement | null;
    if (!row?.dataset.id || !e.dataTransfer) return;
    e.dataTransfer.setData('application/x-clipvault-id', row.dataset.id);
    e.dataTransfer.effectAllowed = 'move';
  }
  private onDragOver(e: DragEvent) {
    const d = (e.target as HTMLElement).closest('[data-drop]') as HTMLElement | null;
    if (!d || !e.dataTransfer?.types.includes('application/x-clipvault-id')) return;
    e.preventDefault();
    d.classList.add('drop');
  }
  private onDrop(e: DragEvent) {
    const d = (e.target as HTMLElement).closest('[data-drop]') as HTMLElement | null;
    const id = e.dataTransfer?.getData('application/x-clipvault-id');
    d?.classList.remove('drop');
    if (!d || !id) return;
    e.preventDefault();
    void this.api.invoke('setCollection', id, d.dataset.drop || null);
  }
}

function CSS_escape(s: string) {
  return s.replace(/["\\]/g, '\\$&');
}

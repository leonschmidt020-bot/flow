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
  /** Hub only: the Flow ⇄ ClipVault switch in the sidebar (Mac: same toggle next to the logo) */
  onSwitch?: () => void;
}

type Nav = 'history' | 'pinned' | 'images' | 'links' | 'files';
const ILLU = '../../assets/illustrations/';
const lsGet = (k: string) => { try { return localStorage.getItem(k) === '1'; } catch { return false; } };
const lsSet = (k: string, v: boolean) => { try { localStorage.setItem(k, v ? '1' : '0'); } catch { /* storage off */ } };
const AV_COLORS = ['#8c5ccc', '#4e8c88', '#c0602a', '#2f63b8', '#b8467f', '#6b8e23', '#a06c12'];
const avColor = (name: string) => { let h = 0; for (const c of name.toLowerCase()) h = (h * 31 + c.charCodeAt(0)) >>> 0; return AV_COLORS[h % AV_COLORS.length]; };

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
  private secretInput = '';
  private nav: Nav = 'history';
  /** shared view: null = everyone, '' = me, else a member name */
  private person: string | null = null;
  private members: string[] = [];
  private pinCollapsed = lsGet('cv.pinCollapsed');
  private hiddenPins = 0;
  private pinnedCount = 0;
  private todayCount = 0;
  private counts: Record<TypeFilter, number> = { all: 0, text: 0, links: 0, images: 0, files: 0 };
  private heroOff = lsGet('cv.heroOff');
  private showAdvanced = false;

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
  private me() { return this.settings?.sync.name || ''; }
  private keycaps(hk: string) {
    const de = this.api.locale === 'de';
    return hk.split('+').map((k) => k.trim()).filter(Boolean).map((k) => {
      const l = k.toLowerCase();
      const n = l === 'control' || l === 'ctrl' || l === 'commandorcontrol' ? (de ? 'Strg' : 'Ctrl') : l === 'shift' ? (de ? 'Umschalt' : 'Shift') : l === 'alt' ? 'Alt' : l === 'super' || l === 'meta' ? 'Win' : k.toUpperCase();
      return `<kbd>${esc(n)}</kbd>`;
    }).join('');
  }
  private $(sel: string) { return this.el.querySelector(sel) as HTMLElement | null; }

  private async boot() {
    if (this.mode === 'hub') {
      // render check only (offscreen PNGs): start on a given view
      const q = new URLSearchParams(location.search);
      if (q.get('render') === '1') {
        const v = q.get('cv');
        if (v === 'shared') this.col = SHARED;
        else if (v === 'settings') this.page = 'settings';
        else if (v === 'pinfold') this.pinCollapsed = true;
        if (q.get('cvperson')) this.person = q.get('cvperson');
        if (q.get('cvadv')) this.showAdvanced = true;
        this.heroOff = false;
      }
    }
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
    let sections = data.sections;
    if (this.col === null && !this.q) {
      this.counts = data.counts;
      if (this.type === 'all') {
        this.pinnedCount = sections.find((x) => x.key === 'pinned')?.items.length ?? 0;
        this.todayCount = sections.find((x) => x.key === 'today')?.items.length ?? 0;
      }
    }
    if (this.col === null && this.nav === 'pinned') sections = sections.filter((x) => x.key === 'pinned');
    if (this.col === SHARED) {
      const me = this.me().toLowerCase();
      const all = sections.flatMap((x) => x.items);
      this.members = [...new Set(all.map((i) => i.source ?? '').filter((n) => n && n.toLowerCase() !== me))].sort((a, b) => a.localeCompare(b));
      if (this.person !== null && this.person !== '' && !this.members.includes(this.person)) this.person = null;
      if (this.person !== null) {
        const want = (this.person || me).toLowerCase();
        sections = sections.map((x) => ({ ...x, items: x.items.filter((i) => (i.source ?? '').toLowerCase() === want) }));
      }
    }
    this.hiddenPins = 0;
    if (this.pinCollapsed && !this.q && this.col === null && this.nav !== 'pinned') {
      sections = sections.map((x) => { if (x.key !== 'pinned') return x; this.hiddenPins = x.items.length; return { ...x, items: [] }; });
    }
    this.data = { ...data, sections };
    this.flat = sections.flatMap((x) => x.items);
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
        <section class="frame">
          <section class="main">
            <div class="mhead"></div>
            <div class="hero"></div>
            <div class="top"><label class="search">${icon('search', 16)}<input class="q" type="text" spellcheck="false" autocomplete="off" placeholder="${esc(this.t('searchPlaceholder'))}"><kbd>${this.api.locale === 'de' ? 'Strg' : 'Ctrl'} F</kbd></label></div>
            <div class="filters"></div>
            <div class="banners"></div>
            <div class="connect-slot"></div>
            <div class="body"><div class="list" tabindex="-1"></div></div>
            <div class="settings" hidden></div>
          </section>
          <aside class="prev"></aside>
        </section>`;
    }
  }

  private render() {
    if (this.mode === 'panel') this.renderChips(); else this.renderSide();
    const inSettings = this.page === 'settings';
    for (const sel of ['.filters', '.body', '.top', '.banners', '.mhead', '.hero', '.connect-slot', '.prev']) { const n = this.$(sel); if (n && this.mode === 'hub') n.hidden = inSettings; }
    this.$('.frame')?.classList.toggle('insettings', inSettings);
    const st = this.$('.settings');
    if (st) st.hidden = !inSettings;
    if (inSettings) { this.renderSettings(); return; }
    if (this.mode === 'hub') { this.renderHead(); this.renderHero(); this.renderConnect(); }
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
    const st = this.settings;
    const sy = this.sync;
    const list = this.page === 'list';
    const navOn = (n: Nav) => (list && this.col === null && this.nav === n ? 'on' : '');
    const colOn = (c: CollectionId) => (list && this.col === c ? 'on' : '');
    const n = (v: number) => (v ? `<span class="n">${v}</span>` : '');
    const live = st?.sync.enabled && sy?.state === 'connected';
    s.innerHTML = `
      <div class="brand">
        <span class="bic">${icon('vault', 22)}</span><span class="bw">ClipVault</span>
        ${this.api.onSwitch ? `<div class="modes"><button data-act="toFlow" title="${esc(this.t('toFlow'))}">${icon('bars', 15)}</button><button class="on" tabindex="-1">${icon('vault', 15)}</button></div>` : ''}
      </div>
      <button class="nav ${navOn('history')}" data-nav="history" data-drop="">${icon('clock', 18)}${esc(this.t('history'))}${n(d?.historyCount ?? 0)}</button>
      <button class="nav ${navOn('pinned')}" data-nav="pinned">${icon('pin', 18)}${esc(this.t('navPinned'))}${n(this.pinnedCount)}</button>
      <button class="nav ${navOn('images')}" data-nav="images">${icon('image', 18)}${esc(this.t('images'))}${n(this.counts.images)}</button>
      <button class="nav ${navOn('links')}" data-nav="links">${icon('link', 18)}${esc(this.t('links'))}${n(this.counts.links)}</button>
      <button class="nav ${navOn('files')}" data-nav="files">${icon('file', 18)}${esc(this.t('files'))}${n(this.counts.files)}</button>
      <button class="nav ${colOn(SHARED)}" data-col="${SHARED}">${icon('users', 18)}${esc(this.t('shared'))}${live ? '<i class="live"></i>' : ''}</button>
      <div class="lbl">${esc(this.api.locale === 'de' ? 'Bereiche' : 'Collections')}</div>
      ${(d?.collections ?? []).map((k) => `<button class="nav sm ${colOn(k.id)}" data-col="${esc(k.id)}" data-drop="${esc(k.id)}" data-colmenu="${esc(k.id)}">${this.colIcon(k.symbol, k.secret)}${esc(k.name)}${n(k.count)}</button>`).join('')}
      <button class="nav sm dim" data-act="newCollection">${icon('plus', 16)}${esc(this.t('newCollection'))}</button>
      <div class="grow"></div>
      <div class="scard">
        <div class="st"><i class="dot ${st?.paused ? 'warn' : 'ok'}"></i>${esc(st?.paused ? this.t('pausedState') : this.t('running'))}</div>
        <div class="big"><b>${this.todayCount}</b>${esc(this.t('copiesToday'))}</div>
        <div class="keys">${this.keycaps(st?.hotkey ?? 'Control+Shift+V')}<span>${esc(this.t('opensAnywhere'))}</span></div>
      </div>
      <div class="sep"></div>
      <button class="nav ${this.page === 'settings' ? 'on' : ''}" data-act="settingsPage">${icon('settings', 18)}${esc(this.t('settings'))}</button>`;
  }

  private headTitle(): string {
    if (this.col === SHARED) return this.t('shared');
    if (this.col) return this.data?.collections.find((c) => c.id === this.col)?.name ?? '';
    return this.nav === 'pinned' ? this.t('navPinned') : this.nav === 'images' ? this.t('images') : this.nav === 'links' ? this.t('links') : this.nav === 'files' ? this.t('files') : this.t('history');
  }

  private renderHead() {
    const h = this.$('.mhead');
    if (!h) return;
    const sy = this.sync ?? { state: 'off' };
    const on = !!this.settings?.sync.enabled;
    const st = on ? sy.state : 'off';
    const dot = st === 'connected' ? 'ok' : st === 'offline' ? 'bad' : st === 'off' ? '' : 'warn';
    const pill = this.col === SHARED ? `<span class="spill"><i class="dot ${dot}"></i>${esc(this.t(('st_' + st) as StringKey))}</span>` : '';
    h.innerHTML = `<h1>${esc(this.headTitle())}</h1><span class="hc">${this.flat.length + this.hiddenPins}</span>${pill}`;
  }

  private renderHero() {
    const h = this.$('.hero');
    if (!h) return;
    const shared = this.col === SHARED;
    const show = !this.q && (shared || (this.col === null && this.nav === 'history' && !this.heroOff));
    if (!show) { h.innerHTML = ''; return; }
    if (shared) {
      const me = this.me();
      const people = this.sync?.paired ? [...(me ? [me] : []), ...this.members] : [];
      const av = people.slice(0, 6).map((p) => `<span class="av" style="background:${avColor(p)}" title="${esc(p)}">${esc([...p][0]?.toUpperCase() ?? '?')}</span>`).join('');
      h.innerHTML = `<div class="banner b-shared"><div class="b-t">
          <div class="b-big">${esc(this.t('sharedA'))}<em>${esc(this.t('sharedEm'))}</em>${esc(this.t('sharedB'))}</div>
          <div class="b-sub">${esc(this.t('sharedSub'))}</div>
          ${people.length ? `<div class="b-act"><span class="avs">${av}</span><span class="b-note">${esc(this.t('inTeam', people.length))}</span></div>` : ''}
        </div><img class="b-img" src="${ILLU}illu_geteilt.png" alt=""></div>`;
      return;
    }
    const s = this.settings;
    h.innerHTML = `<div class="banner"><button class="b-close" data-act="heroOff" title="${esc(this.t('close'))}">${icon('x', 12)}</button><div class="b-t">
        <div class="b-big">${esc(this.t('heroA'))}<em>${esc(this.t('heroEm'))}</em>${esc(this.t('heroB'))}</div>
        <div class="b-sub">${esc(this.t('heroSub', s?.maxAgeDays ?? 2, this.data?.historyCount ?? 0, this.pinnedCount))}</div>
        <div class="b-act"><button class="btn light" data-act="newCollection">${icon('layers', 15)}${esc(this.t('newCollection'))}</button><span class="keys">${this.keycaps(s?.hotkey ?? 'Control+Shift+V')}<span>${esc(this.t('anywhere'))}</span></span></div>
      </div><img class="b-img" src="${ILLU}illu_bilder_sammeln.png" alt=""></div>`;
  }

  private renderConnect() {
    const c = this.$('.connect-slot');
    if (!c) return;
    const sy = this.sync;
    const need = this.col === SHARED && (!this.settings?.sync.enabled || !sy?.paired);
    for (const sel of ['.top', '.filters', '.body']) { const n = this.$(sel); if (n) n.hidden = need; }
    if (!need) { c.innerHTML = ''; return; }
    c.innerHTML = `<div class="connect"><div class="ct">
        <h2>${esc(this.t('connectTitle'))}</h2><p class="lead">${esc(this.t('connectLead'))}</p>
        <ol><li><span>1</span>${esc(this.t('connectStep1'))}</li><li><span>2</span>${esc(this.t('connectStep2'))}</li><li><span>3</span>${esc(this.t('connectStep3'))}</li></ol>
        <div class="joinrow"><input class="field" data-field="pairCode" value="${esc(this.pairInput)}" placeholder="${esc(this.t('syncCodePh'))}" spellcheck="false" autocomplete="off"><button class="btn primary" data-act="syncPairJoin">${icon('key', 15)}${esc(this.t('pairBtn'))}</button></div>
        <div class="fine">${icon('lock', 13)}${esc(this.t('e2e'))}${sy?.reason ? ' · ' + esc(sy.reason) : ''}</div>
      </div></div>`;
  }

  private renderFilters() {
    const f = this.$('.filters');
    if (!f || !this.data) return;
    const n = this.data.counts;
    const shared = this.col === SHARED;
    const people = shared && this.members.length
      ? [['*', this.t('everyone')], ...this.members.map((m) => [m, m]), ['', this.t('fromMe')]].map(([v, l]) => {
        const on = (v === '*' ? this.person === null : this.person === v);
        const dot = v && v !== '*' ? `<i class="pdot" style="background:${avColor(v!)}"></i>` : '';
        return `<button class="seg person ${on ? 'on' : ''}" data-person="${esc(v)}">${dot}${esc(l)}</button>`;
      }).join('')
      : '';
    const hide = this.mode === 'hub' && (this.col === null && this.nav !== 'history' && this.nav !== 'pinned');
    f.innerHTML = (shared ? people : hide ? '' : TYPES.map((ty) => `<button class="seg ${this.type === ty ? 'on' : ''}" data-type="${ty}">${esc(this.t(ty as StringKey))}${ty !== 'all' && n[ty] ? `<span class="n">${n[ty]}</span>` : ''}</button>`).join(''))
      + (this.mode === 'panel' ? `<span class="count">${esc(this.flat.length === 1 ? this.t('entry') : this.t('entries', this.flat.length))}</span>` : '');
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

  private hhmm(ts: number) { return new Date(ts * 1000).toLocaleTimeString(this.api.locale === 'de' ? 'de-DE' : 'en-US', { hour: '2-digit', minute: '2-digit' }); }
  /** time column: HH:MM today, else the short date (shared list has no day sections) */
  private rowTime(it: ItemView) {
    const d = new Date(it.ts * 1000);
    if (it.collection !== SHARED || d.toDateString() === new Date().toDateString()) return this.hhmm(it.ts);
    return d.toLocaleDateString(this.api.locale === 'de' ? 'de-DE' : 'en-US', { day: 'numeric', month: 'short' });
  }

  private hubRowHTML(it: ItemView): string {
    const inShared = it.collection === SHARED;
    const me = this.me().toLowerCase();
    const who = it.source ?? '';
    const mine = inShared && who.toLowerCase() === me;
    const tile = inShared && !(it.kind === 'image' && it.thumbUrl)
      ? `<div class="av lg" style="background:${avColor(who || '?')}">${esc([...who][0]?.toUpperCase() ?? '?')}</div>`
      : this.tileFor(it);
    const tags: string[] = [];
    if (it.masked) tags.push(`<span class="tag secret">${esc(this.t('hidden'))}</span>`);
    else for (const b of it.badges.slice(0, 2)) if (!(b === 'link' && it.isLink)) tags.push(`<span class="tag ${esc(b)}">${esc(b === 'code' ? 'Code' : b === 'email' ? 'E-Mail' : b === 'phone' ? (this.api.locale === 'de' ? 'Telefon' : 'Phone') : b === 'color' ? (this.api.locale === 'de' ? 'Farbe' : 'Color') : b === 'link' ? 'Link' : b)}</span>`);
    if (it.shared && !inShared) tags.push(`<span class="tag shared">${esc(this.t('shared'))}</span>`);
    const report = inShared && it.title.startsWith('# Flow-Fehlerbericht');
    if (report) tags.push(`<span class="tag code">${esc(this.api.locale === 'de' ? 'Fehlerbericht' : 'Error report')}</span>`);
    const subText = inShared
      ? [mine ? this.t('youShared') : this.t('theyShared', who), ...it.subtitle.split(' · ').slice(1)].filter(Boolean).join(' · ')
      : it.subtitle;
    return `<div class="row hrow ${it.id === this.sel ? 'sel' : ''}" data-id="${esc(it.id)}" draggable="${inShared ? 'false' : 'true'}">
      <div class="tm">${esc(this.rowTime(it))}</div>
      ${tile}
      <div class="meta"><div class="title">${esc(it.masked ? '••••••••••••' : report ? it.title.replace(/^#\s*/, '') : it.title)}</div><div class="sub">${tags.join('')}<span>${esc(subText)}</span></div></div>
      ${it.pinned ? `<span class="pinmark">${icon('pinFill', 15)}</span>` : ''}
      <div class="rowacts">
        <button class="iconbtn" data-act="copy" data-id="${esc(it.id)}" title="${esc(this.t('copy'))}">${icon('copy', 15)}</button>
        <button class="iconbtn ${it.pinned ? 'on' : ''}" data-act="pin" data-id="${esc(it.id)}" title="${esc(it.pinned ? this.t('unpin') : this.t('pin'))}">${icon(it.pinned ? 'pinFill' : 'pin', 15)}</button>
        <button class="iconbtn danger" data-act="delete" data-id="${esc(it.id)}" title="${esc(this.t('delete'))}">${icon('trash', 15)}</button>
      </div>
    </div>`;
  }

  private rowHTML(it: ItemView, quick: number | null): string {
    if (this.mode === 'hub') return this.hubRowHTML(it);
    const tags: string[] = [];
    if (it.masked || it.expiresInH !== null && it.expiresInH !== undefined) {
      tags.push(`<span class="tag secret">${esc(it.masked ? this.t('hidden') : this.t('reveal'))}</span>`);
      if (it.expiresInH !== null && it.expiresInH !== undefined) tags.push(`<span>${esc(this.t('expiresIn', it.expiresInH))} ·</span>`);
    } else {
      for (const b of it.badges.slice(0, 2)) if (!(b === 'link' && it.isLink)) tags.push(`<span class="tag ${esc(b)}">${esc(b === 'link' ? 'Link' : b === 'code' ? 'Code' : b === 'email' ? 'E-Mail' : b === 'phone' ? (this.api.locale === 'de' ? 'Telefon' : 'Phone') : b === 'color' ? (this.api.locale === 'de' ? 'Farbe' : 'Color') : b)}</span>`);
      if (it.shared && it.collection !== SHARED) tags.push(`<span class="tag shared">${esc(this.t('shared'))}</span>`);
    }
    const sub = [it.subtitle, this.fmtTime(it.ts)].filter(Boolean).join(' · ');
    const acts = '';
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
    (this.$('.frame') ?? this.$('.body'))?.classList.toggle('noprev', !this.flat.length);
    if (!this.flat.length && !this.hiddenPins) {
      const searching = !!this.q.trim() || this.type !== 'all';
      l.innerHTML = `<div class="empty"><div><div class="ring">${icon(searching ? 'search' : 'copy', 22)}</div><h3>${esc(searching ? this.t('noResults') : this.t('empty'))}</h3><p>${esc(searching ? this.t('noResultsHint') : this.t('emptyHint'))}</p></div></div>`;
      return;
    }
    let n = 0;
    const secTitle = (k: string) => (k === 'pinned' ? this.t('pinned') : k === 'today' ? this.t('today') : k === 'yesterday' ? this.t('yesterday') : k === 'collection' || k === 'shared' ? '' : new Date(k + 'T12:00:00').toLocaleDateString(this.api.locale === 'de' ? 'de-DE' : 'en-US', { weekday: 'long', day: 'numeric', month: 'long' }));
    const hub = this.mode === 'hub';
    l.innerHTML = this.data.sections.map((s) => {
      const title = secTitle(s.key);
      const pinned = s.key === 'pinned';
      if (pinned && !s.items.length && !this.hiddenPins) return '';
      const cnt = pinned ? (s.items.length || this.hiddenPins) : s.items.length;
      const canFold = pinned && this.col === null && this.nav !== 'pinned' && !this.q;
      const head = !title ? '' : canFold
        ? `<button class="sec pinned fold ${this.pinCollapsed ? 'closed' : ''}" data-act="togglePins" title="${esc(this.pinCollapsed ? this.t('reveal') : this.t('pinsHidden'))}">${icon(this.pinCollapsed ? 'right' : 'down', 12)}${icon('pinFill', 11)}<span>${esc(title)}</span><span class="sn">${cnt}</span></button>`
        : `<div class="sec ${pinned ? 'pinned' : ''}">${pinned ? icon('pinFill', 11) : ''}<span>${esc(title)}</span>${hub ? `<span class="sn">${cnt}</span>` : ''}</div>`;
      const rows = s.items.map((it) => { n++; return this.rowHTML(it, n <= 9 ? n : null); }).join('');
      return head + (hub ? (rows ? `<div class="grp">${rows}</div>` : '') : rows);
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

  private relTime(ts: number) {
    const s = Date.now() / 1000 - ts;
    if (s < 90) return this.t('justNow');
    if (s < 3600) return this.t('minAgo', Math.round(s / 60));
    if (s < 6 * 3600) return this.t('hAgo', Math.round(s / 3600));
    return this.fmtTime(ts);
  }

  private renderHubPreview(p: HTMLElement, it: ItemView) {
    const inShared = it.collection === SHARED;
    const de = this.api.locale === 'de';
    const loc = de ? 'de-DE' : 'en-US';
    const d = new Date(it.ts * 1000);
    const date = d.toLocaleDateString(loc, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }) + ' · ' + this.hhmm(it.ts);
    const kind = it.kind === 'image' ? ['image', this.t('kImage')] : it.kind === 'file' ? ['file', this.t('kFile')] : it.isLink ? ['link', this.t('kLink')] : ['text', this.t('kText')];
    const cols = this.data?.collections ?? [];
    const colName = it.collection && !inShared ? cols.find((c) => c.id === it.collection)?.name : null;
    let body: string;
    let stats = '';
    if (it.masked && !this.revealed.has(it.id)) {
      body = `<div class="pmask">${icon('lock', 26)}<div>${esc(this.t('hidden'))}</div><button class="btn" data-act="reveal">${icon('eye', 15)}${esc(this.t('reveal'))}</button></div>`;
    } else if (it.kind === 'image') {
      const src = it.imageUrl ?? it.thumbUrl ?? '';
      body = `<div class="pimg" data-act="viewer"><img data-fallback="${esc(it.id)}" src="${esc(src)}" alt=""></div>${it.text ? `<div class="ocr">${esc(it.text)}</div>` : ''}`;
      if (it.w) stats = `${it.w} × ${it.h}`;
    } else if (it.kind === 'file') {
      body = `<div class="pfiles">${(it.fileNames ?? []).map((f) => `<div class="frow">${icon('file', 18)}<span>${esc(f)}</span></div>`).join('')}</div>`;
    } else {
      const txt = it.text ?? '';
      const code = it.badges.includes('code');
      body = `${it.color ? `<div class="swatch" style="background:${esc(it.color)}"></div>` : ''}${code ? `<pre class="ptext code">${esc(txt)}</pre>` : `<div class="ptext">${esc(txt)}</div>`}`;
      const words = txt.trim() ? txt.trim().split(/\s+/).length : 0;
      const lines = txt ? txt.split(/\r?\n/).length : 0;
      stats = [this.t('nChars', [...txt].length), words === 1 ? this.t('oneWord') : this.t('nWords', words), lines === 1 ? this.t('oneLine') : this.t('nLines', lines)].join(' · ');
    }
    const det: [string, string][] = inShared
      ? [[this.t('lblFrom'), it.source ?? '–'], [this.t('lblShared'), this.relTime(it.ts)]]
      : [[this.t('lblCopied'), this.relTime(it.ts)], [this.t('lblSource'), it.subtitle.split(' · ')[0] || '–'], [this.t('lblColl'), colName ?? '–']];
    const syncOn = !!this.settings?.sync.enabled;
    const g = (act: string, ic: string, label: string, cls = '') => `<button class="gbtn ${cls}" data-act="${act}">${icon(ic, 17)}<span>${esc(label)}</span></button>`;
    p.innerHTML = `
      <div class="pscroll">
        <div class="pk"><span class="kchip">${icon(kind[0]!, 13)}${esc(kind[1]!)}</span>${it.pinned ? `<span class="kchip pin">${icon('pinFill', 12)}${esc(this.t('navPinned'))}</span>` : ''}</div>
        <div class="pdate">${esc(date)}</div>
        ${body}
        ${stats ? `<div class="pstats">${esc(stats)}</div>` : ''}
        <div class="plbl">${esc(this.t('lblDetails'))}</div>
        <dl class="pdl">${det.map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl>
      </div>
      <div class="pfoot">
        <button class="btn primary big" data-act="copy">${icon('copy', 17)}<span>${esc(this.t('copy'))}</span><span class="k">↵</span></button>
        <div class="pgrid">
          ${g('pin', it.pinned ? 'pinFill' : 'pin', it.pinned ? this.t('unpin') : this.t('pin'), it.pinned ? 'on' : '')}
          ${!inShared ? g('more', 'layers', this.t('lblColl')) : g('more', 'more', this.t('more'))}
          ${syncOn && !inShared ? g(it.shared ? 'unshare' : 'share', 'users', it.shared ? this.t('unshare') : this.t('share')) : ''}
          ${it.kind === 'image' ? g('viewer', 'fit', this.t('openViewer')) : it.isLink && !it.masked ? g('openLink', 'external', this.t('openLink')) : ''}
          ${g('delete', 'trash', this.t('delete'), 'danger')}
        </div>
      </div>`;
    for (const img of p.querySelectorAll('img[data-fallback]')) img.addEventListener('error', () => void this.fallbackImage(img as HTMLImageElement), { once: true });
  }

  private renderPreview() {
    const p = this.$('.prev');
    if (!p) return;
    const it = this.detail;
    if (!it || !this.flat.length) { p.innerHTML = ''; return; }
    if (this.mode === 'hub') { this.renderHubPreview(p, it); return; }
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
    const opt = (title: string, hint: string, ctl: string, cls = '') => `<div class="opt ${cls}"><div class="ot"><div>${esc(title)}</div>${hint ? `<div>${esc(hint)}</div>` : ''}</div>${ctl ? `<div class="oc">${ctl}</div>` : ''}</div>`;
    const sy = this.sync ?? { state: 'off' };
    const st = s.sync.enabled ? sy.state : 'off';
    const dotCls = st === 'connected' ? 'ok' : st === 'offline' ? 'bad' : st === 'off' ? '' : 'warn';
    const statusHint = !s.sync.enabled ? this.t('statusHintOff')
      : [sy.paired && sy.host ? sy.host : '', sy.reason ?? '', sy.queue ? this.t('queue', sy.queue) : ''].filter(Boolean).join(' · ');
    const codeBox = sy.pairingCode
      ? `<div class="opt col"><div class="ot"><div>${esc(this.t('syncPairCreate'))}</div><div>${esc(this.t('syncCodeHint'))}</div></div>
          <div class="paircode">${esc(sy.pairingCode)}</div>
          <div class="brow"><button class="btn primary" data-act="copyCode">${icon('copy', 15)}${esc(this.t('copyCode'))}</button><button class="btn" data-act="syncPairCancel">${esc(this.t('syncCancel'))}</button></div></div>`
      : '';
    let syncBody = '';
    if (s.sync.enabled) {
      syncBody += opt(this.t('syncName'), this.t('nameHint'), `<input class="field" data-field="sync.name" value="${esc(s.sync.name)}" placeholder="${esc(this.api.locale === 'de' ? 'z. B. Lena' : 'e.g. Lena')}">`);
      if (!sy.paired) {
        syncBody += `<div class="opt col"><div class="ot"><div>${esc(this.t('syncPairJoin'))}</div><div>${esc(this.t('syncJoinHint'))}</div></div>
          <div class="joinrow"><input class="field" data-field="pairCode" value="${esc(this.pairInput)}" placeholder="${esc(this.t('syncCodePh'))}" spellcheck="false" autocomplete="off"><button class="btn primary" data-act="syncPairJoin">${icon('key', 15)}${esc(this.t('pairBtn'))}</button></div></div>`;
        syncBody += codeBox;
        syncBody += `<button class="adv ${this.showAdvanced ? 'open' : ''}" data-act="toggleAdv">${icon(this.showAdvanced ? 'down' : 'right', 13)}${esc(this.t('advanced'))}</button>`;
        if (this.showAdvanced) {
          syncBody += `<div class="opt col"><div class="ot"><div>${esc(this.t('syncNewVault'))}</div><div>${esc(this.t('syncInitHint'))}</div></div>
            <div class="joinrow"><input class="field" data-field="syncUrl" value="${esc(this.urlInput || sy.url || '')}" placeholder="${esc(this.t('syncUrlPh'))}"><input class="field sm" type="password" data-field="initSecret" value="${esc(this.secretInput)}" placeholder="${esc(this.t('syncInitPh'))}"><button class="btn" data-act="syncSetup">${esc(this.t('syncSave'))}</button></div>
            ${sy.state === 'unpaired' ? `<div class="brow"><button class="btn" data-act="syncPairCreate">${esc(this.t('syncPairCreate'))}</button></div>` : ''}</div>`;
        }
      } else {
        syncBody += sy.pairingCode ? codeBox : opt(this.t('invite'), this.t('inviteHint'), `<button class="btn" data-act="syncPairCreate">${icon('plus', 15)}${esc(this.t('inviteBtn'))}</button>`);
        syncBody += opt(this.t('leave'), this.t('leaveHint'), `<button class="btn danger" data-act="syncUnpair">${icon('logout', 15)}${esc(this.t('syncUnpair'))}</button>`);
      }
    }
    const syncCard = `<div class="card">
        <div class="opt"><div class="ot"><div class="status big"><i class="dot ${dotCls}"></i>${esc(this.t(('st_' + st) as StringKey))}</div>${statusHint ? `<div>${esc(statusHint)}</div>` : ''}</div><div class="oc">${sw('sync.enabled', s.sync.enabled)}</div></div>
        ${syncBody}
      </div>`;
    const num = (f: string, v: number, min: number, max: number, unit: string) => `<label class="unit"><input class="field num" type="number" min="${min}" max="${max}" data-field="${f}" value="${v}"><span>${esc(unit)}</span></label>`;
    el.innerHTML = `
      <h1 class="sh">${esc(this.t('settings'))}</h1>
      <div class="slbl">${esc(this.t('sync'))}</div>
      ${syncCard}
      <div class="slbl">${esc(this.t('secHistory'))}</div>
      <div class="card">
        ${opt(this.t('sRetention'), this.t('retentionHint', s.maxAgeDays, s.maxItems, s.quotaMB), '', 'col')}
        <div class="opt units">${num('maxAgeDays', s.maxAgeDays, 1, 30, this.t('sDays'))}${num('maxItems', s.maxItems, 20, 2000, this.t('sMax'))}${num('quotaMB', s.quotaMB, 50, 20000, this.t('sQuota'))}</div>
        ${opt(this.t('sClear'), this.t('sClearConfirm').replace(/^[^?]*\?\s*/, ''), `<button class="btn danger" data-act="clearHistory">${icon('trash', 15)}${esc(this.t('sClear'))}</button>`)}
      </div>
      <div class="slbl">${esc(this.t('secOpen'))}</div>
      <div class="card">
        ${opt(this.t('sHotkey'), this.t('hotkeyHint'), `<span class="keys">${this.keycaps(s.hotkey)}</span><input class="field" data-field="hotkey" value="${esc(s.hotkey)}" style="width:170px">`)}
        ${opt(this.t('sPaste'), this.t('sPasteHint'), sw('pasteOnEnter', s.pasteOnEnter))}
      </div>
      <div class="slbl">${esc(this.t('secPrivacy'))}</div>
      <div class="card">
        ${opt(this.t('sPause'), '', sw('paused', s.paused))}
        ${opt(this.t('sPasswords'), this.t('sPasswordsHint'), sw('skipPasswordLike', s.skipPasswordLike))}
        ${opt(this.t('sEncrypt'), s.dpapiAvailable ? this.t('sEncryptHint') : this.t('sEncryptNA'), sw('encryptAtRest', s.encryptAtRest && s.dpapiAvailable, !s.dpapiAvailable))}
        <div class="opt col"><div class="ot"><div>${esc(this.t('sIgnored'))}</div></div><textarea class="field" data-field="ignoredApps" spellcheck="false">${esc(s.ignoredApps.join('\n'))}</textarea></div>
      </div>`;
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
      case 'syncSetup': await this.syncCall('syncSetup', this.urlInput, this.secretInput); this.secretInput = ''; break;
      case 'syncPairCreate': await this.syncCall('syncPairCreate'); break;
      case 'syncPairJoin': {
        const code = this.pairInput.trim();
        if (!code) { (this.$('input[data-field="pairCode"]') as HTMLInputElement | null)?.focus(); break; }
        if (this.settings && !this.settings.sync.enabled) await this.setSetting({ sync: { enabled: true } });
        await this.syncCall('syncPairJoin', code); this.pairInput = ''; break;
      }
      case 'toFlow': this.api.onSwitch?.(); break;
      case 'heroOff': this.heroOff = true; lsSet('cv.heroOff', true); this.renderHero(); break;
      case 'togglePins': this.pinCollapsed = !this.pinCollapsed; lsSet('cv.pinCollapsed', this.pinCollapsed); this.sel = null; await this.refresh(); break;
      case 'toggleAdv': this.showAdvanced = !this.showAdvanced; this.render(); break;
      case 'syncPairCancel': await this.syncCall('syncPairCancel'); break;
      case 'syncUnpair': if (confirm(this.t('leaveConfirm'))) await this.syncCall('syncUnpair'); break;
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
    const navEl = t.closest('[data-nav]') as HTMLElement | null;
    if (navEl) {
      this.nav = navEl.dataset.nav as Nav;
      this.col = null;
      this.page = 'list';
      this.type = this.nav === 'images' ? 'images' : this.nav === 'links' ? 'links' : this.nav === 'files' ? 'files' : 'all';
      this.sel = null;
      void this.refresh();
      return;
    }
    const perEl = t.closest('[data-person]') as HTMLElement | null;
    if (perEl) { const v = perEl.dataset.person ?? ''; this.person = v === '*' ? null : v; this.sel = null; void this.refresh(); return; }
    const colEl = t.closest('[data-col]') as HTMLElement | null;
    if (colEl) {
      this.col = colEl.dataset.col || null;
      this.nav = 'history';
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
    else if (t.dataset.field === 'initSecret') this.secretInput = t.value;
  }

  private onChange(e: Event) {
    const t = e.target as HTMLInputElement;
    const f = t.dataset.field;
    if (!f || f === 'pairCode' || f === 'syncUrl' || f === 'initSecret') return;
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

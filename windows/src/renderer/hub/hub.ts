// Hub window: Verlauf · Wörterbuch · ClipVault · Einstellungen. Vanilla TS, no framework.
import { t as tr, hotkeyName, hotkeyShort, type I18nKey } from '../../shared/i18n';
import type { HubState, HistoryItem } from '../../shared/hubState';
import { HOTKEYS, type Settings } from '../../shared/settings';
import { mount as mountClipVault } from '../../clipvault/ui';
import { demoState } from './demo';

interface FlowApi {
  getState(): Promise<HubState>;
  setSettings(p: Partial<Settings>): Promise<HubState>;
  deleteHistory(id: string): Promise<void>;
  clearHistory(): Promise<void>;
  copy(text: string): Promise<void>;
  downloadModel(model: string): Promise<void>;
  micDevices(): Promise<{ deviceId: string; label: string }[]>;
  micMonitor(on: boolean): Promise<void>;
  open(what: 'micSettings' | 'dataFolder' | 'homepage'): Promise<void>;
  checkUpdates(): Promise<void>;
  onState(cb: (s: HubState) => void): () => void;
  onLevel(cb: (lv: number) => void): () => void;
  onNavigate(cb: (p: string) => void): () => void;
  clipvault: { invoke(name: string, ...a: unknown[]): Promise<unknown>; on(name: string, cb: (p: unknown) => void): () => void };
}
const q = new URLSearchParams(location.search);
const RENDER = q.has('render');
const api: FlowApi = (window as unknown as { flow?: FlowApi }).flow ?? mockApi();

let S: HubState;
type Page = 'history' | 'dictionary' | 'clipvault' | 'settings';
let page: Page = (q.get('page') as Page) || 'history';
const L = () => S.settings.locale;
const t = (k: I18nKey, v?: Record<string, string | number>) => tr(L(), k, v);

// ── tiny DOM helper ──
type Attrs = Record<string, unknown> & { class?: string; on?: Record<string, (e: Event) => void> };
function h<K extends keyof HTMLElementTagNameMap>(tag: K, a: Attrs | null = null, ...kids: (Node | string | null | undefined | false)[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (a) for (const [k, v] of Object.entries(a)) {
    if (k === 'on') for (const [ev, fn] of Object.entries(v as Record<string, (e: Event) => void>)) el.addEventListener(ev, fn);
    else if (k === 'class') el.className = String(v);
    else if (k === 'html') el.innerHTML = String(v);
    else if (v === true) el.setAttribute(k, '');
    else if (v !== false && v !== undefined && v !== null) {
      if (k in el) (el as unknown as Record<string, unknown>)[k] = v;
      else el.setAttribute(k, String(v));
    }
  }
  for (const c of kids) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}
const svg = (d: string) => { const s = document.createElement('span'); s.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`; return s.firstChild as SVGElement; };
const I = {
  history: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  dictionary: '<path d="M5 4.5h10.5a3 3 0 0 1 3 3v12H8a3 3 0 0 1-3-3z"/><path d="M5 16.5a3 3 0 0 1 3-3h10.5"/><path d="M9 8.5h6"/>',
  clipvault: '<rect x="5" y="4.5" width="14" height="16" rx="2.5"/><path d="M9 4.5V3.8A1.3 1.3 0 0 1 10.3 2.5h3.4A1.3 1.3 0 0 1 15 3.8v.7"/><path d="M9 10h6M9 13.5h6M9 17h3.5"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.6 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.6-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
  copy: '<rect x="8.5" y="8.5" width="11" height="11" rx="2.2"/><path d="M15.5 8.5V6.2a1.7 1.7 0 0 0-1.7-1.7H6.2a1.7 1.7 0 0 0-1.7 1.7v7.6a1.7 1.7 0 0 0 1.7 1.7h2.3"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  trash: '<path d="M4.5 7h15M10 11v6M14 11v6M6.5 7l.8 11.2A2 2 0 0 0 9.3 20h5.4a2 2 0 0 0 2-1.8L17.5 7M9.5 7V5.2A1.2 1.2 0 0 1 10.7 4h2.6a1.2 1.2 0 0 1 1.2 1.2V7"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
};

// ── sidebar ──
function renderNav() {
  const nav = document.getElementById('nav')!;
  nav.replaceChildren(...(['history', 'dictionary', 'clipvault', 'settings'] as Page[]).map((p) =>
    h('button', { class: 'nav-item' + (p === page ? ' active' : ''), on: { click: () => go(p) } }, svg(I[p]),
      t(p === 'history' ? 'navHistory' : p === 'dictionary' ? 'navDictionary' : p === 'clipvault' ? 'navClipVault' : 'navSettings'))));
}

function asrLine(): { text: string; sub: string; dot: string; progress: number | null } {
  const a = S.asr;
  const pct = Math.round(a.progress * 100);
  switch (a.status) {
    case 'ready': return { text: S.paused ? t('toastPaused') : t('statusReady', { hotkey: hotkeyShort(L(), S.settings.hotkey) }), sub: `${a.model === 'whisper-turbo' ? 'Whisper turbo' : 'Parakeet v3'} · ${t('statusLocal')}`, dot: S.paused ? 'off' : '', progress: null };
    case 'downloading': return { text: t('modelDownloading', { pct }), sub: a.bytesPerSec ? `${(a.bytesPerSec / 1e6).toFixed(1)} MB/s` : '', dot: 'warn', progress: a.progress };
    case 'verifying': return { text: t('modelVerifying'), sub: '', dot: 'warn', progress: 1 };
    case 'extracting': return { text: t('modelExtracting'), sub: '', dot: 'warn', progress: 1 };
    case 'loading': return { text: t('modelLoading'), sub: '', dot: 'warn', progress: null };
    case 'error': return { text: t('modelError', { msg: a.error.slice(0, 60) }), sub: '', dot: 'off', progress: null };
    default: return { text: t('modelMissing'), sub: '', dot: 'off', progress: null };
  }
}
function renderStatus() {
  const s = asrLine();
  document.getElementById('status')!.replaceChildren(...[
    h('div', { class: 'st-row' }, h('i', { class: 'dot ' + s.dot }), h('span', null, s.text)),
    s.sub ? h('div', { class: 'sub' }, s.sub) : null,
    s.progress !== null ? h('div', { class: 'bar' }, h('i', { style: `width:${Math.round(s.progress * 100)}%` })) : null,
  ].filter((x): x is HTMLDivElement => !!x));
}

// ── pages ──
interface PageView { el: HTMLElement; update(): void; dispose?(): void }
let view: PageView | null = null;

function header(title: string, lead: string, right?: Node) {
  return h('div', { class: 'head' }, h('div', null, h('h1', { html: title }), h('p', { class: 'lead' }, lead)), right ?? null);
}

function onboardingHero(): HTMLElement | null {
  const a = S.asr;
  if (a.status === 'ready' || a.status === 'loading') return null;
  const busy = a.status === 'downloading' || a.status === 'verifying' || a.status === 'extracting';
  const line = asrLine();
  return h('div', { class: 'card hero' },
    h('div', { class: 't' },
      h('div', { class: 'big' }, t('onbTitle')),
      h('div', { class: 'muted' }, a.status === 'error' ? line.text : t('onbText')),
      busy ? h('div', { class: 'progress' }, h('i', { style: `width:${Math.round(a.progress * 100)}%` })) : null,
      busy ? h('div', { class: 'muted', style: 'margin-top:8px;font-size:12px' }, line.text + (line.sub ? ' · ' + line.sub : '')) : null),
    busy ? null : h('button', { class: 'btn primary', on: { click: () => api.downloadModel(S.settings.engine) } }, t('onbStart')));
}

function micNotice(): HTMLElement | null {
  if (!S.micError) return null;
  return h('div', { class: 'card notice' }, h('div', { class: 't' }, t('micDenied')),
    h('button', { class: 'btn', on: { click: () => api.open('micSettings') } }, t('micOpenSettings')));
}

function dayLabel(d: Date): string {
  const today = new Date(); const y = new Date(); y.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return t('today');
  if (d.toDateString() === y.toDateString()) return t('yesterday');
  return d.toLocaleDateString(L() === 'de' ? 'de-DE' : 'en-GB', { weekday: 'long', day: 'numeric', month: 'long' });
}

function historyPage(): PageView {
  let query = '';
  const listBox = h('div');
  const statsBox = h('div', { class: 'stats' });
  const heroBox = h('div');
  const search = h('input', { class: 'input', placeholder: t('historySearch'), on: { input: (e) => { query = (e.target as HTMLInputElement).value.toLowerCase(); update(); } } });
  const el = h('div', null,
    header(L() === 'de' ? 'Dein <em>Verlauf</em>' : 'Your <em>history</em>', t('historySub')),
    heroBox, statsBox,
    h('div', { class: 'toolbar' }, h('div', { class: 'search' }, svg(I.search), search), h('div', { class: 'grow' }),
      h('button', { class: 'btn ghost danger', on: { click: () => { if (confirm(t('historyClearConfirm'))) void api.clearHistory(); } } }, t('historyClear'))),
    listBox);
  function row(r: HistoryItem) {
    const d = new Date(r.date);
    const copyBtn = h('button', { class: 'icon-btn', title: t('copy') }, svg(I.copy));
    copyBtn.addEventListener('click', async () => { await api.copy(r.text); copyBtn.replaceChildren(svg(I.check)); setTimeout(() => copyBtn.replaceChildren(svg(I.copy)), 1200); });
    return h('div', { class: 'item' },
      h('div', { class: 'time' }, d.toLocaleTimeString(L() === 'de' ? 'de-DE' : 'en-GB', { hour: '2-digit', minute: '2-digit' })),
      h('div', null, h('div', { class: 'text' }, r.text), h('div', { class: 'meta' }, [`${r.words} ${t('words')}`, r.app.replace(/\.exe$/i, '')].filter(Boolean).join(' · '))),
      h('div', { class: 'actions' }, copyBtn, h('button', { class: 'icon-btn', title: t('delete'), on: { click: () => api.deleteHistory(r.id) } }, svg(I.trash))));
  }
  function update() {
    heroBox.replaceChildren(...[onboardingHero(), micNotice()].filter((x): x is HTMLElement => !!x));
    statsBox.replaceChildren(
      h('div', { class: 'card stat' }, h('div', { class: 'n' }, String(S.wordsToday)), h('div', { class: 'l' }, L() === 'de' ? 'Wörter heute' : 'words today')),
      h('div', { class: 'card stat' }, h('div', { class: 'n' }, S.wordsTotal.toLocaleString(L())), h('div', { class: 'l' }, L() === 'de' ? 'Wörter insgesamt' : 'words in total')),
      h('div', { class: 'card stat' }, h('div', { class: 'n' }, String(S.totalDictations)), h('div', { class: 'l' }, L() === 'de' ? 'Diktate' : 'dictations')));
    const items = S.history.filter((r) => !query || r.text.toLowerCase().includes(query));
    if (items.length === 0) {
      listBox.replaceChildren(h('div', { class: 'card empty' }, h('div', { class: 'big' }, L() === 'de' ? 'Noch still hier.' : 'Quiet so far.'),
        h('div', { html: esc(t('historyEmpty', { hotkey: '§' })).replace('§', `<kbd>${esc(hotkeyShort(L(), S.settings.hotkey))}</kbd>`) })));
      return;
    }
    const groups = new Map<string, HistoryItem[]>();
    for (const r of items) { const k = dayLabel(new Date(r.date)); groups.set(k, [...(groups.get(k) ?? []), r]); }
    listBox.replaceChildren(...[...groups].flatMap(([day, rs]) => [h('div', { class: 'day' }, day), h('div', { class: 'card list' }, ...rs.map(row))]));
  }
  update();
  return { el, update };
}

function dictionaryPage(): PageView {
  const heard = h('input', { class: 'input', placeholder: L() === 'de' ? 'z. B. clip vault' : 'e.g. clip vault' });
  const write = h('input', { class: 'input', placeholder: L() === 'de' ? 'z. B. ClipVault' : 'e.g. ClipVault' });
  const listBox = h('div');
  const add = async () => {
    const a = heard.value.trim(), b = write.value.trim();
    if (!a || !b) { (a ? write : heard).focus(); return; }
    const rest = S.settings.dictionary.filter((e) => e.heard.toLowerCase() !== a.toLowerCase());
    S = await api.setSettings({ dictionary: [{ heard: a, write: b }, ...rest] });
    heard.value = ''; write.value = ''; heard.focus(); update();
  };
  for (const i of [heard, write]) i.addEventListener('keydown', (e) => { if ((e as KeyboardEvent).key === 'Enter') void add(); });
  const el = h('div', null,
    header(L() === 'de' ? 'Dein <em>Wörterbuch</em>' : 'Your <em>dictionary</em>', t('dictSub')),
    h('div', { class: 'card dict-form' }, heard, h('div', { class: 'arrow' }, '→'), write, h('button', { class: 'btn primary', on: { click: () => void add() } }, svg(I.plus), t('dictSave'))),
    listBox);
  function update() {
    const d = S.settings.dictionary;
    if (d.length === 0) { listBox.replaceChildren(h('div', { class: 'card empty' }, h('div', { class: 'big' }, L() === 'de' ? 'Noch leer.' : 'Empty so far.'), t('dictEmpty'))); return; }
    listBox.replaceChildren(h('div', { class: 'card list' }, ...d.map((e) => h('div', { class: 'entry' },
      h('div', { class: 'heard' }, e.heard), h('div', { class: 'arrow' }, '→'), h('div', { class: 'write' }, e.write),
      h('div', { class: 'actions' }, h('button', { class: 'icon-btn', title: t('delete'), on: { click: async () => { S = await api.setSettings({ dictionary: S.settings.dictionary.filter((x) => x !== e && x.heard !== e.heard) }); update(); } } }, svg(I.trash)))))));
  }
  update();
  return { el, update };
}

function toggle(key: keyof Settings) {
  const input = h('input', { type: 'checkbox' }) as HTMLInputElement;
  input.checked = !!S.settings[key];
  input.addEventListener('change', () => void set({ [key]: input.checked } as Partial<Settings>));
  const w = h('label', { class: 'switch' }, input, h('span'));
  return { el: w, sync: () => { input.checked = !!S.settings[key]; } };
}
async function set(p: Partial<Settings>) { S = await api.setSettings(p); refresh(); }
const row = (title: string, desc: string | null, ...ctl: (Node | null)[]) =>
  h('div', { class: 'row' }, h('div', null, h('div', { class: 't' }, title), desc ? h('div', { class: 'd' }, desc) : null), h('div', { class: 'ctl' }, ...ctl));

function settingsPage(): PageView {
  const syncers: (() => void)[] = [];
  const sw = (k: keyof Settings) => { const x = toggle(k); syncers.push(x.sync); return x.el; };
  const select = (opts: [string, string][], value: () => string, onChange: (v: string) => void) => {
    const s = h('select', { class: 'input' }, ...opts.map(([v, l]) => h('option', { value: v }, l))) as HTMLSelectElement;
    s.value = value();
    s.addEventListener('change', () => onChange(s.value));
    syncers.push(() => { if (document.activeElement !== s) s.value = value(); });
    return s;
  };
  const seg = (opts: [string, string][], value: () => string, onChange: (v: string) => void) => {
    const box = h('div', { class: 'seg' });
    const draw = () => box.replaceChildren(...opts.map(([v, l]) => h('button', { class: value() === v ? 'on' : '', on: { click: () => onChange(v) } }, l)));
    draw(); syncers.push(draw);
    return box;
  };
  // mic
  const meter = h('div', { class: 'meter' }, h('i'));
  let testing = false;
  const testBtn = h('button', { class: 'btn' }, t('micTest'));
  testBtn.addEventListener('click', async () => { testing = !testing; testBtn.textContent = testing ? t('micStopTest') : t('micTest'); await api.micMonitor(testing); if (!testing) (meter.firstChild as HTMLElement).style.width = '0'; });
  const micSel = h('select', { class: 'input', style: 'max-width:260px' }, h('option', { value: '' }, t('micDefault'))) as HTMLSelectElement;
  micSel.addEventListener('change', () => void set({ micDeviceId: micSel.value }));
  void api.micDevices().then((ds) => { micSel.append(...ds.map((d) => h('option', { value: d.deviceId }, d.label))); micSel.value = S.settings.micDeviceId; });
  const offLevel = api.onLevel((lv) => { (meter.firstChild as HTMLElement).style.width = `${Math.min(100, Math.round((lv as number) * 900))}%`; });
  // model
  const modelBadge = h('span', { class: 'badge' });
  const modelBtn = h('button', { class: 'btn', on: { click: () => api.downloadModel(S.settings.engine) } }, t('modelDownload'));
  syncers.push(() => {
    const inst = S.asr.installed[S.settings.engine];
    const active = S.asr.model === S.settings.engine;
    const st = active ? S.asr.status : inst ? 'ready' : 'missing';
    modelBadge.className = 'badge' + (st === 'ready' ? ' ok' : '');
    modelBadge.textContent = st === 'ready' ? t('modelReady') : st === 'downloading' ? t('modelDownloading', { pct: Math.round(S.asr.progress * 100) })
      : st === 'verifying' ? t('modelVerifying') : st === 'extracting' ? t('modelExtracting') : st === 'loading' ? t('modelLoading') : st === 'error' ? t('modelError', { msg: S.asr.error.slice(0, 40) }) : t('modelMissing');
    modelBtn.style.display = st === 'missing' || st === 'error' ? '' : 'none';
  });
  const hkOpts: [string, string][] = HOTKEYS.map((k) => [k, hotkeyName(L(), k)]);
  const el = h('div', null,
    header(L() === 'de' ? '<em>Einstellungen</em>' : '<em>Settings</em>', t('tagline')),
    micNotice() ?? h('span'),
    h('div', { class: 'section' }, h('h2', null, t('secHotkey')), h('div', { class: 'card' },
      row(t('hotkeyLabel'), t('hotkeyDesc'), select(hkOpts, () => S.settings.hotkey, (v) => void set({ hotkey: v as Settings['hotkey'] }))),
      row(t('doubleTap'), t('doubleTapDesc'), sw('doubleTapHandsFree')))),
    h('div', { class: 'section' }, h('h2', null, t('secLanguage')), h('div', { class: 'card' },
      row(t('dictLang'), t('dictLangDesc'), seg([['auto', t('lang_auto')], ['de', t('lang_de')], ['en', t('lang_en')]], () => S.settings.language, (v) => void set({ language: v as Settings['language'] }))),
      row(t('uiLang'), null, seg([['de', 'Deutsch'], ['en', 'English']], () => S.settings.locale, (v) => void set({ locale: v as Settings['locale'] }).then(() => go(page)))))),
    h('div', { class: 'section' }, h('h2', null, t('secEngine')), h('div', { class: 'card' },
      row(t('engineLabel'), t('engineDesc'), modelBadge, modelBtn, select([['parakeet-v3', t('eng_parakeet')], ['whisper-turbo', t('eng_whisper')]], () => S.settings.engine, (v) => void set({ engine: v as Settings['engine'] }))))),
    h('div', { class: 'section' }, h('h2', null, t('secMic')), h('div', { class: 'card' },
      row(t('micLabel'), null, meter, testBtn, micSel))),
    h('div', { class: 'section' }, h('h2', null, t('secText')), h('div', { class: 'card' },
      row(t('fillers'), t('fillersDesc'), sw('removeFillers')),
      row(t('commands'), t('commandsDesc'), sw('voiceCommands')),
      row(t('polish'), t('polishDesc'), sw('polish')),
      row(t('keepClip'), t('keepClipDesc'), sw('keepInClipboard')))),
    h('div', { class: 'section' }, h('h2', null, t('secSystem')), h('div', { class: 'card' },
      row(t('autostart'), null, sw('startWithWindows')),
      row(t('pillVisible'), t('pillVisibleDesc'), sw('pillAlwaysVisible')),
      row(t('historyKeep'), t('historyKeepDesc', { days: S.settings.historyRetentionDays }), sw('historyEnabled')),
      row(t('autoUpdate'), t('autoUpdateDesc'), sw('autoUpdate')))),
    h('div', { class: 'section' }, h('h2', null, t('secAbout')), h('div', { class: 'card' },
      row(t('version', { v: S.version }), t('aboutText'),
        h('button', { class: 'btn ghost', on: { click: () => api.open('dataFolder') } }, t('openData')),
        h('button', { class: 'btn', on: { click: () => api.checkUpdates() } }, t('checkUpdates'))))),
    h('div', { class: 'foot' }, 'Flow · MIT · ' + (L() === 'de' ? 'frei, quelloffen, lokal' : 'free, open source, local')));
  const update = () => syncers.forEach((f) => f());
  update();
  return { el, update, dispose: () => { offLevel(); if (testing) void api.micMonitor(false); } };
}

function clipVaultPage(): PageView {
  const host = h('div', { class: 'cv-host' });
  const root = host.attachShadow({ mode: 'open' });
  let unmount: (() => void) | null = null;
  try {
    unmount = mountClipVault(root, { invoke: (n, ...a) => api.clipvault.invoke(n, ...a) as Promise<never>, on: (n, cb) => api.clipvault.on(n, cb), locale: L() });
  } catch (e) {
    root.append(h('div', { style: 'padding:40px;color:var(--text-dim)' }, 'ClipVault: ' + String(e)));
  }
  return { el: host, update() {}, dispose: () => unmount?.() };
}

function go(p: Page) {
  view?.dispose?.();
  page = p;
  view = p === 'history' ? historyPage() : p === 'dictionary' ? dictionaryPage() : p === 'clipvault' ? clipVaultPage() : settingsPage();
  const box = document.getElementById('page')!;
  box.replaceChildren(view.el);
  box.scrollTop = 0;
  document.documentElement.lang = L();
  renderNav();
  renderStatus();
}
function refresh() { renderStatus(); renderNav(); view?.update(); }
function esc(s: string) { return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!); }

function mockApi(): FlowApi {
  const st = demoState(q.get('state') ?? 'ready', q.get('lang') === 'en' ? 'en' : 'de');
  return {
    getState: async () => st, setSettings: async (p) => { st.settings = { ...st.settings, ...p }; return st; }, deleteHistory: async () => {}, clearHistory: async () => {},
    copy: async () => {}, downloadModel: async () => {}, micDevices: async () => [{ deviceId: 'a', label: 'Mikrofon (Shure MV7)' }, { deviceId: 'b', label: 'Headset (Jabra Evolve2)' }],
    micMonitor: async () => {}, open: async () => {}, checkUpdates: async () => {}, onState: () => () => {}, onLevel: (cb) => { if (RENDER) setTimeout(() => cb(0.045), 50); return () => {}; },
    onNavigate: () => () => {}, clipvault: { invoke: async () => null, on: () => () => {} },
  };
}

(async () => {
  S = await api.getState();
  api.onState((s) => { const localeChanged = s.settings.locale !== S?.settings.locale; S = s; if (localeChanged) go(page); else refresh(); });
  api.onNavigate((p) => go(p as Page));
  go(page);
  if (q.get('scroll')) document.getElementById('page')!.scrollTop = Number(q.get('scroll'));
  document.body.dataset.ready = '1';
})();

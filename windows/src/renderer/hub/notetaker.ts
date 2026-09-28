// Hub page „Notetaker“: meetings list + detail (transcript with speaker colours, search, rename, delete, „Behalten“,
// retention, optional summary), recording controls, audio-file drop, notetaker settings. Vanilla TS like hub.ts.
import { duration as fmtDuration, speakerName, stamp } from '../../meeting/format';
import { mt, noteText, type MKey, type MLoc } from '../../meeting/i18n';
import { RETENTION_CHOICES, type MeetingSettings } from '../../meeting/settings';
import type { Meeting, MeetingHubState, MeetingListItem } from '../../meeting/types';

export interface MeetingApi {
  state(): Promise<MeetingHubState>;
  get(id: string): Promise<Meeting | null>;
  start(): Promise<void>;
  stop(): Promise<void>;
  pickFile(): Promise<void>;
  dropFiles(files: File[]): Promise<void>;
  rename(id: string, title: string): Promise<void>;
  renameSpeaker(id: string, key: string, name: string): Promise<void>;
  setKeep(id: string, keep: boolean): Promise<void>;
  delete(id: string): Promise<void>;
  reprocess(id: string): Promise<void>;
  summarize(id: string): Promise<void>;
  copyPrompt(id: string): Promise<{ ok: boolean }>;
  copyTranscript(id: string): Promise<boolean>;
  openFolder(id: string): Promise<void>;
  setSettings(p: Partial<MeetingSettings>): Promise<MeetingSettings>;
  onState(cb: (s: MeetingHubState) => void): () => void;
}

type Attrs = Record<string, unknown> & { class?: string; on?: Record<string, (e: Event) => void> };
function h<K extends keyof HTMLElementTagNameMap>(tag: K, a: Attrs | null = null, ...kids: (Node | string | null | undefined | false)[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (a) for (const [k, v] of Object.entries(a)) {
    if (k === 'on') for (const [ev, fn] of Object.entries(v as Record<string, (e: Event) => void>)) el.addEventListener(ev, fn);
    else if (k === 'class') el.className = String(v);
    else if (k === 'html') el.innerHTML = String(v);
    else if (v === true) el.setAttribute(k, '');
    else if (v !== false && v !== undefined && v !== null) { if (k in el) (el as unknown as Record<string, unknown>)[k] = v; else el.setAttribute(k, String(v)); }
  }
  for (const c of kids) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}
const svg = (d: string) => { const s = document.createElement('span'); s.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`; return s.firstChild as SVGElement; };
export const NOTETAKER_ICON = '<rect x="4" y="3.5" width="16" height="17" rx="3"/><path d="M8 8.5h8M8 12h8M8 15.5h4.5"/><circle cx="17" cy="16.5" r="2.2" fill="currentColor" stroke="none"/>';
const I = {
  mic: '<rect x="9" y="3.5" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
  stop: '<rect x="6.5" y="6.5" width="11" height="11" rx="2"/>',
  upload: '<path d="M12 15.5V4.5M7.5 9L12 4.5 16.5 9M5 15.5v2.5A2 2 0 0 0 7 20h10a2 2 0 0 0 2-2v-2.5"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2"/>',
  pin: '<path d="M9.5 3.5h5l-.7 5.2 3.2 3.3H7l3.2-3.3zM12 12v8.5"/>',
  agent: '<path d="M5 6.5h14v9H9.5L6 19v-3.5H5z"/><path d="M9 10.5h6M9 13h3.5"/>',
  copy: '<rect x="8.5" y="8.5" width="11" height="11" rx="2.2"/><path d="M15.5 8.5V6.2a1.7 1.7 0 0 0-1.7-1.7H6.2a1.7 1.7 0 0 0-1.7 1.7v7.6a1.7 1.7 0 0 0 1.7 1.7h2.3"/>',
  folder: '<path d="M3.5 7.5A2 2 0 0 1 5.5 5.5h4l2 2h7a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/>',
  redo: '<path d="M19 12a7 7 0 1 1-2.1-5"/><path d="M19 4.5V9h-4.5"/>',
  trash: '<path d="M4.5 7h15M10 11v6M14 11v6M6.5 7l.8 11.2A2 2 0 0 0 9.3 20h5.4a2 2 0 0 0 2-1.8L17.5 7M9.5 7V5.2A1.2 1.2 0 0 1 10.7 4h2.6a1.2 1.2 0 0 1 1.2 1.2V7"/>',
  spark: '<path d="M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1L5 10.5l5.1-1.9zM18.5 16l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
};
/** speaker colours (dark UI); "me" gets the accent */
const COLORS = ['#7cc4ff', '#f5a97f', '#8bd5a8', '#f0c86c', '#e59ad8', '#9fb1ff', '#6fd6d0', '#ff8f8f'];
export function speakerColor(key: string, order: string[]): string {
  if (key === 'me') return '#b3a6ff';
  const i = order.filter((k) => k !== 'me').indexOf(key);
  return COLORS[(i < 0 ? 0 : i) % COLORS.length]!;
}

export function notetakerPage(o: { api: MeetingApi; loc: () => MLoc; hotkeysDisabled: boolean; toast: (text: string) => void; initialSelect?: string | null; render?: boolean }) {
  const { api } = o;
  const L = o.loc;
  const t = (k: MKey, v?: Record<string, string | number>) => mt(L(), k, v);
  let S: MeetingHubState | null = null;
  let selected: string | null = o.initialSelect ?? null;
  let detail: Meeting | null = null;
  let query = '';

  const headRight = h('div', { class: 'nt-head-actions' });
  const banner = h('div');
  const listBox = h('div', { class: 'nt-list' });
  const detailBox = h('div', { class: 'nt-detail card' });
  const settingsBox = h('div', { class: 'section' });
  const search = h('input', { class: 'input', placeholder: t('search'), on: { input: (e) => { query = (e.target as HTMLInputElement).value.trim().toLowerCase(); renderList(); renderDetail(); } } });
  const drop = h('div', { class: 'nt-drop' }, h('div', { class: 'nt-drop-inner' }, svg(I.upload), h('div', { class: 'big' }, t('dropHere')), h('div', { class: 'muted' }, t('dropSub'))));
  const el = h('div', { class: 'nt' },
    h('div', { class: 'head' }, h('div', null, h('h1', { html: t('title') }), h('p', { class: 'lead' }, t('lead'))), headRight),
    banner,
    h('div', { class: 'nt-grid' },
      h('div', { class: 'nt-left' }, h('div', { class: 'search nt-search' }, svg(I.search), search), listBox),
      detailBox),
    settingsBox,
    drop);

  // ── drag & drop (whole page) ──
  let dragDepth = 0;
  el.addEventListener('dragenter', (e) => { e.preventDefault(); dragDepth++; el.classList.add('dragging'); });
  el.addEventListener('dragover', (e) => { e.preventDefault(); if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy'; });
  el.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; el.classList.remove('dragging'); } });
  el.addEventListener('drop', (e) => {
    e.preventDefault(); dragDepth = 0; el.classList.remove('dragging');
    const files = Array.from(e.dataTransfer?.files ?? []);
    if (files.length) void api.dropFiles(files);
  });

  const loc = () => (L() === 'de' ? 'de-DE' : 'en-GB');
  const time = (iso: string) => new Date(iso).toLocaleTimeString(loc(), { hour: '2-digit', minute: '2-digit' });
  const dayLabel = (iso: string) => {
    const d = new Date(iso), today = new Date(), y = new Date(); y.setDate(today.getDate() - 1);
    if (d.toDateString() === today.toDateString()) return t('today');
    if (d.toDateString() === y.toDateString()) return t('yesterday');
    return d.toLocaleDateString(loc(), { weekday: 'long', day: 'numeric', month: 'long' });
  };
  const deletesText = (iso: string | null) => {
    if (!iso) return '';
    const days = Math.ceil((Date.parse(iso) - Date.now()) / 86400_000);
    return t('deletesIn', { when: days <= 0 ? t('deletesToday') : days === 1 ? t('deletesTomorrow') : t('deletesDays', { n: days }) });
  };
  const elapsed = (iso: string) => stamp((Date.now() - Date.parse(iso)) / 1000);
  const filtered = () => (S?.meetings ?? []).filter((m) => !query || m.haystack.includes(query));

  function renderHead() {
    if (!S) return;
    const rec = S.recording;
    headRight.replaceChildren(
      h('button', { class: 'btn', on: { click: () => void api.pickFile() } }, svg(I.upload), t('import')),
      rec ? h('button', { class: 'btn nt-rec on', on: { click: () => void api.stop() } }, h('i', { class: 'nt-dot' }), svg(I.stop), t('stop'))
        : h('button', { class: 'btn primary', on: { click: () => void api.start() } }, svg(I.mic), t('start')));
    const parts: HTMLElement[] = [];
    if (rec) {
      parts.push(h('div', { class: 'card nt-banner rec' }, h('i', { class: 'nt-dot' }),
        h('div', { class: 't' }, h('div', { class: 'nt-clock' }, t('running', { t: elapsed(rec.startedAt) })),
          h('div', { class: 'muted' }, rec.system ? (L() === 'de' ? 'Mikrofon + Systemton · Mitschrift läuft live' : 'Microphone + system audio · live transcript') : (L() === 'de' ? 'Nur Mikrofon · Mitschrift läuft live' : 'Microphone only · live transcript'))),
        h('button', { class: 'btn', on: { click: () => void api.stop() } }, svg(I.stop), t('stop'))));
    }
    if (S.importing) {
      parts.push(h('div', { class: 'card nt-banner' }, svg(I.upload),
        h('div', { class: 't' }, h('div', null, S.importing.file), h('div', { class: 'muted' }, noteText(L(), S.importing.note)),
          h('div', { class: 'progress' }, h('i', { style: `width:${Math.round(S.importing.progress * 100)}%` }))),
        h('span', { class: 'badge' }, `${Math.round(S.importing.progress * 100)} %`)));
    }
    banner.replaceChildren(...parts);
  }

  function statusBadge(m: MeetingListItem): HTMLElement | null {
    if (m.status === 'recording') return h('span', { class: 'nt-badge rec' }, h('i', { class: 'nt-dot' }), 'REC');
    if (m.status === 'processing' || m.progressNote === 'summarizing') return h('span', { class: 'nt-badge' }, m.progress !== undefined ? `${Math.round(m.progress * 100)} %` : '…');
    if (m.status === 'failed') return h('span', { class: 'nt-badge err' }, '!');
    if (m.keep) return h('span', { class: 'nt-badge keep', title: t('kept') }, svg(I.pin));
    return null;
  }

  function renderList() {
    if (!S) return;
    const items = filtered();
    if (S.meetings.length === 0) {
      listBox.replaceChildren(h('div', { class: 'card empty nt-empty' }, h('div', { class: 'big' }, t('emptyBig')),
        h('div', { html: esc(t('emptyText', { hotkey: '§' })).replace('§', '<kbd>Strg + Alt + M</kbd>') })));
      return;
    }
    if (items.length === 0) { listBox.replaceChildren(h('div', { class: 'muted nt-none' }, t('nothingFound'))); return; }
    if (!selected || !items.some((m) => m.id === selected)) selected = items[0]!.id;
    const groups = new Map<string, MeetingListItem[]>();
    for (const m of items) { const k = dayLabel(m.date); groups.set(k, [...(groups.get(k) ?? []), m]); }
    listBox.replaceChildren(...[...groups].flatMap(([day, ms]) => [h('div', { class: 'day' }, day),
      ...ms.map((m) => h('button', { class: 'nt-item' + (m.id === selected ? ' active' : ''), on: { click: () => { selected = m.id; renderList(); void loadDetail(); } } },
        h('div', { class: 'nt-item-top' }, h('span', { class: 'nt-item-title' }, m.title), statusBadge(m)),
        h('div', { class: 'nt-item-meta' }, [time(m.date), m.duration > 0 ? fmtDuration(m.duration, L()) : '', m.source === 'import' ? t('fileMeeting') : (m.app ?? '').replace(/ \(.*\)$/, '')].filter(Boolean).join(' · '))))]));
  }

  async function loadDetail() {
    detail = selected ? await api.get(selected) : null;
    renderDetail();
  }

  function highlight(text: string): Node[] {
    if (!query) return [document.createTextNode(text)];
    const out: Node[] = [];
    const low = text.toLowerCase();
    let i = 0;
    for (;;) {
      const j = low.indexOf(query, i);
      if (j < 0) { out.push(document.createTextNode(text.slice(i))); break; }
      out.push(document.createTextNode(text.slice(i, j)), h('mark', null, text.slice(j, j + query.length)));
      i = j + query.length;
    }
    return out;
  }

  function editable(text: string, cls: string, onSave: (v: string) => void, title: string) {
    const span = h('span', { class: cls + ' editable', title });
    span.textContent = text;
    span.addEventListener('click', () => {
      const input = h('input', { class: 'input ' + cls + '-input', value: text }) as HTMLInputElement;
      const done = (save: boolean) => { if (save && input.value.trim() && input.value.trim() !== text) onSave(input.value.trim()); input.replaceWith(span); };
      input.addEventListener('keydown', (e) => { if ((e as KeyboardEvent).key === 'Enter') done(true); if ((e as KeyboardEvent).key === 'Escape') done(false); });
      input.addEventListener('blur', () => done(true));
      span.replaceWith(input); input.focus(); input.select();
    });
    return span;
  }

  function renderDetail() {
    if (!S) return;
    const item = S.meetings.find((m) => m.id === selected);
    const m = detail && detail.id === selected ? detail : null;
    if (!item || !m) { detailBox.replaceChildren(h('div', { class: 'empty' }, h('div', { class: 'big' }, S.meetings.length ? t('selectOne') : ''))); return; }
    const myName = S.settings.myName;
    const order: string[] = [];
    for (const s of m.segments) if (!order.includes(s.speaker)) order.push(s.speaker);
    const busy = m.status === 'processing' || m.status === 'recording';
    const promptBtn = h('button', { class: 'btn primary', disabled: m.segments.length === 0 && m.status !== 'done' }, svg(I.agent), t('promptAgent'));
    promptBtn.addEventListener('click', async () => { const r = await api.copyPrompt(m.id); if (r.ok) { o.toast(t('promptCopied')); promptBtn.replaceChildren(svg(I.check), t('promptCopied')); setTimeout(() => promptBtn.replaceChildren(svg(I.agent), t('promptAgent')), 1600); } });
    const copyBtn = h('button', { class: 'btn', disabled: m.segments.length === 0 }, svg(I.copy), t('copyTranscript'));
    copyBtn.addEventListener('click', async () => { if (await api.copyTranscript(m.id)) { copyBtn.replaceChildren(svg(I.check), t('copied')); setTimeout(() => copyBtn.replaceChildren(svg(I.copy), t('copyTranscript')), 1300); } });
    const keepBtn = h('button', { class: 'btn' + (item.keep ? ' on' : ''), title: item.keep ? t('unkeep') : t('keep'), on: { click: () => void api.setKeep(m.id, !item.keep) } }, svg(I.pin), item.keep ? t('kept') : t('keep'));
    const actions = h('div', { class: 'nt-actions' }, promptBtn, copyBtn, keepBtn,
      S.claude && m.segments.length && !busy ? h('button', { class: 'btn', title: t('summarizeHint'), disabled: item.progressNote === 'summarizing', on: { click: () => void api.summarize(m.id) } }, svg(I.spark), m.summary ? t('summarizeAgain') : t('summarize')) : null,
      h('div', { class: 'grow' }),
      h('button', { class: 'icon-btn', title: t('openFolder'), on: { click: () => void api.openFolder(m.id) } }, svg(I.folder)),
      (m.status === 'failed' || m.status === 'done') ? h('button', { class: 'icon-btn', title: t('reprocess'), on: { click: () => void api.reprocess(m.id) } }, svg(I.redo)) : null,
      m.status !== 'recording' ? h('button', { class: 'icon-btn danger', title: t('delete'), on: { click: () => { if (confirm(t('deleteConfirm', { title: m.title }))) void api.delete(m.id); } } }, svg(I.trash)) : null);
    const meta = [new Date(m.date).toLocaleDateString(loc(), { weekday: 'short', day: 'numeric', month: 'long' }) + ', ' + time(m.date),
      m.duration > 0 ? fmtDuration(item.duration, L()) : '', m.source === 'import' ? t('fileMeeting') : (m.app ?? ''),
      order.length ? t('speakers', { n: order.length }) : '', item.words ? t('words', { n: item.words }) : ''].filter(Boolean).join(' · ');
    const status: (HTMLElement | null)[] = [];
    if (m.status === 'processing' || item.progressNote === 'summarizing') {
      status.push(h('div', { class: 'nt-status' }, h('div', null, noteText(L(), item.progressNote) || t('processing')),
        item.progress !== undefined ? h('div', { class: 'progress' }, h('i', { style: `width:${Math.round(item.progress * 100)}%` })) : null));
    } else if (m.status === 'failed') {
      status.push(h('div', { class: 'nt-status err' }, h('b', null, t('failed')), ' · ', noteText(L(), item.progressNote)));
    }
    const chips = h('div', { class: 'nt-speakers' }, ...order.map((k) => h('span', { class: 'nt-chip' },
      h('i', { style: `background:${speakerColor(k, order)}` }),
      editable(speakerName(m, k, myName, L()), 'nt-chip-name', (v) => void api.renameSpeaker(m.id, k, v), t('renameSpeaker')))));
    const rows = m.segments.filter((s) => !query || s.text.toLowerCase().includes(query) || m.title.toLowerCase().includes(query) || (m.summary ?? '').toLowerCase().includes(query));
    const transcript = m.segments.length === 0
      ? h('div', { class: 'nt-empty-tr muted' }, m.status === 'recording' ? t('live') : m.status === 'processing' ? t('processing') : t('noText'))
      : h('div', { class: 'nt-transcript' }, ...rows.map((s) => h('div', { class: 'nt-seg' },
        h('div', { class: 'nt-time' }, stamp(s.start)),
        h('div', null, h('div', { class: 'nt-who', style: `color:${speakerColor(s.speaker, order)}` }, speakerName(m, s.speaker, myName, L())),
          h('div', { class: 'nt-text' }, ...highlight(s.text))))));
    detailBox.replaceChildren(...[
      h('div', { class: 'nt-title-row' }, editable(m.title, 'nt-title', (v) => void api.rename(m.id, v), t('rename')),
        item.keep ? h('span', { class: 'badge ok' }, t('kept')) : item.deletesAt && !busy ? h('span', { class: 'badge' }, deletesText(item.deletesAt)) : null),
      h('div', { class: 'nt-meta' }, meta),
      actions, ...status,
      order.length ? chips : null,
      m.summary ? h('div', { class: 'nt-summary' }, h('div', { class: 'nt-sec' }, '✦ ' + t('summary')), h('div', { class: 'nt-summary-text', html: miniMarkdown(m.summary) })) : null,
      h('div', { class: 'nt-sec' }, t('transcript')),
      transcript].filter((x): x is HTMLElement => !!x));
  }

  function renderSettings() {
    if (!S) return;
    const st = S.settings;
    const set = async (p: Partial<MeetingSettings>) => { if (S) S.settings = await api.setSettings(p); renderSettings(); };
    const sw = (k: keyof MeetingSettings) => {
      const input = h('input', { type: 'checkbox' }) as HTMLInputElement;
      input.checked = !!st[k];
      input.addEventListener('change', () => void set({ [k]: input.checked } as Partial<MeetingSettings>));
      return h('label', { class: 'switch' }, input, h('span'));
    };
    const row = (title: string, desc: string | null, ...ctl: (Node | null)[]) =>
      h('div', { class: 'row' }, h('div', null, h('div', { class: 't' }, title), desc ? h('div', { class: 'd' }, desc) : null), h('div', { class: 'ctl' }, ...ctl));
    const seg = h('div', { class: 'seg' }, ...(['off', 'ask', 'auto'] as const).map((v) => h('button', { class: st.detection === v ? 'on' : '', on: { click: () => void set({ detection: v }) } }, t(`det_${v}` as MKey))));
    const ret = h('select', { class: 'input' }, ...RETENTION_CHOICES.map((n) => h('option', { value: String(n) }, n === 0 ? t('ret_never') : n === 1 ? t('ret_day') : t('ret_days', { n })))) as HTMLSelectElement;
    ret.value = String(st.retentionDays);
    ret.addEventListener('change', () => void set({ retentionDays: Number(ret.value) }));
    const name = h('input', { class: 'input', placeholder: t('myNamePh'), value: st.myName, style: 'width:180px' }) as HTMLInputElement;
    name.addEventListener('change', () => void set({ myName: name.value }));
    const ff = h('input', { class: 'input', placeholder: t('ffmpegPh'), value: st.ffmpegPath, style: 'width:240px' }) as HTMLInputElement;
    ff.addEventListener('change', () => void set({ ffmpegPath: ff.value }));
    const d = S.diarization;
    const diarBadge = h('span', { class: 'badge' + (d.status === 'ready' ? ' ok' : '') }, d.status === 'ready' ? t('diarReady') : d.status === 'downloading' ? t('diarDownloading', { pct: Math.round(d.progress * 100) }) : d.status === 'error' ? t('diarError', { msg: d.error.slice(0, 40) }) : t('diarMissing'));
    settingsBox.replaceChildren(h('h2', null, t('secSettings')), h('div', { class: 'card' },
      row(t('detection'), t('detectionDesc'), seg),
      row(t('systemAudio'), t('systemAudioDesc'), sw('systemAudio')),
      row(t('keepAudio'), t('keepAudioDesc'), sw('keepAudio')),
      row(t('retention'), t('retentionDesc'), ret),
      row(t('myName'), null, name),
      o.hotkeysDisabled ? null : row(t('hotkey'), t('hotkeyDesc'), sw('hotkey')),
      S.claude ? row(t('autoSummary'), t('autoSummaryDesc'), sw('autoSummary')) : null,
      row(t('decoder'), S.ffmpeg ? t('decoderFfmpeg', { path: S.ffmpeg }) : t('decoderBuiltin'), ff),
      row(t('diarization'), t('diarizationDesc'), diarBadge)));
  }

  function renderAll() { renderHead(); renderList(); renderDetail(); renderSettings(); }

  let lastSig = '';
  const onState = (s: MeetingHubState) => {
    S = s;
    renderHead(); renderList();
    const it = s.meetings.find((m) => m.id === selected);
    const sig = it ? `${it.id}|${it.status}|${it.words}|${it.title}|${it.hasSummary}|${it.keep}|${it.progressNote}|${Math.round((it.progress ?? 0) * 50)}` : '';
    if (sig !== lastSig) { lastSig = sig; void loadDetail(); }
    renderSettings();
  };
  const off = api.onState(onState);
  void api.state().then(async (s) => { S = s; renderAll(); await loadDetail(); lastSig = ''; el.dataset.ready = '1'; });
  // recording clock
  const clockTimer = window.setInterval(() => { if (S?.recording) renderHead(); }, 1000);

  return { el, update() { if (S) renderAll(); }, dispose() { off(); window.clearInterval(clockTimer); } };
}

function esc(s: string) { return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!); }

/** **bold**, bullet lines, paragraphs – enough for the Claude summary */
export function miniMarkdown(md: string): string {
  const lines = esc(md).split('\n');
  let html = '', inList = false;
  for (const raw of lines) {
    const line = raw.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
    const li = /^\s*[-*•–]\s+(.*)$/.exec(line);
    if (li) { if (!inList) { html += '<ul>'; inList = true; } html += `<li>${li[1]}</li>`; continue; }
    if (inList) { html += '</ul>'; inList = false; }
    if (line.trim()) html += `<p>${line}</p>`;
  }
  if (inList) html += '</ul>';
  return html;
}

// Hub page „Agent-Prompts“ (port of APPromptsPane, Mac): list of the last 50 + detail with Prompt | Original, copy, delete.
// Settings rows for the Einstellungen page live here too. Vanilla TS like hub.ts.
import { apt, type APLoc } from '../../agentPrompt/i18n';
import type { APMode, APRecordView } from '../../shared/agentPrompt';
import { promptLines, sourceLabel } from '../pill/apCard';
import { SAMPLE_ORIGINAL_DE, SAMPLE_PROMPT_DE, SAMPLE_PROMPT_EN, FALLBACK_DE } from '../../agentPrompt/testSet';

export interface PromptsApi {
  list(): Promise<APRecordView[]>;
  delete(id: string): Promise<void>;
  copy(id: string, which: 'prompt' | 'original'): Promise<boolean>;
  onChanged(cb: () => void): () => void;
}

export const PROMPTS_ICON = '<path d="M12 3.5l1.6 4.4 4.4 1.6-4.4 1.6L12 15.5l-1.6-4.4L6 9.5l4.4-1.6z"/><path d="M18.5 14.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/><path d="M4.5 19.5h7"/>';
const I = {
  copy: '<rect x="8.5" y="8.5" width="11" height="11" rx="2.2"/><path d="M15.5 8.5V6.2a1.7 1.7 0 0 0-1.7-1.7H6.2a1.7 1.7 0 0 0-1.7 1.7v7.6a1.7 1.7 0 0 0 1.7 1.7h2.3"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  trash: '<path d="M4.5 7h15M10 11v6M14 11v6M6.5 7l.8 11.2A2 2 0 0 0 9.3 20h5.4a2 2 0 0 0 2-1.8L17.5 7M9.5 7V5.2A1.2 1.2 0 0 1 10.7 4h2.6a1.2 1.2 0 0 1 1.2 1.2V7"/>',
  app: '<rect x="4" y="5" width="16" height="14" rx="2.5"/><path d="M4 9h16"/>',
  spark: '<path d="M12 3.5l1.6 4.4 4.4 1.6-4.4 1.6L12 15.5l-1.6-4.4L6 9.5l4.4-1.6z"/>',
  list: '<path d="M9 6.5h11M12 12h8M12 17.5h8"/><circle cx="4.8" cy="6.5" r="1"/>',
};

type Attrs = Record<string, unknown> & { class?: string; on?: Record<string, (e: Event) => void> };
function h<K extends keyof HTMLElementTagNameMap>(tag: K, a: Attrs | null = null, ...kids: (Node | string | null | undefined | false)[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (a) for (const [k, v] of Object.entries(a)) {
    if (k === 'on') for (const [ev, fn] of Object.entries(v as Record<string, (e: Event) => void>)) el.addEventListener(ev, fn);
    else if (k === 'class') el.className = String(v);
    else if (k === 'html') el.innerHTML = String(v);
    else if (v !== false && v !== undefined && v !== null) el.setAttribute(k, String(v));
  }
  for (const c of kids) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}
const svg = (d: string) => { const s = document.createElement('span'); s.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`; return s.firstChild as SVGElement; };

function relative(loc: APLoc, iso: string, now = Date.now()): string {
  const s = Math.round((Date.parse(iso) - now) / 1000);
  const rtf = new Intl.RelativeTimeFormat(loc === 'de' ? 'de-DE' : 'en-GB', { numeric: 'auto' });
  const a = Math.abs(s);
  if (a < 60) return rtf.format(s, 'second');
  if (a < 3600) return rtf.format(Math.round(s / 60), 'minute');
  if (a < 86400) return rtf.format(Math.round(s / 3600), 'hour');
  return rtf.format(Math.round(s / 86400), 'day');
}

/** prompt text in the detail: headings lilac, „**Ziel:**“ bold, items monospace – like the card, larger */
function promptView(text: string): HTMLElement {
  const box = h('div', { class: 'pr-prompt' });
  for (const l of promptLines(text)) {
    const clean = (s: string) => s.split('`').join('');
    if (l.t === 'heading') box.append(h('div', { class: 'pr-h' }, l.s.toUpperCase()));
    else if (l.t === 'goal') box.append(h('div', { class: 'pr-goal' }, h('b', null, l.k + ': '), clean(l.v)));
    else if (l.t === 'item') box.append(h('div', { class: 'pr-item' }, clean(l.s.trim())));
    else if (l.t === 'text') box.append(h('div', { class: 'pr-text' }, clean(l.s)));
    else box.append(h('div', { class: 'pr-blank' }));
  }
  return box;
}

export interface PromptsPageOpts {
  api: PromptsApi;
  loc: () => APLoc;
  initialSelect?: string | null;
  /** render check: fixed „now“, Original tab */
  render?: boolean;
  showOriginal?: boolean;
}

export function promptsPage(o: PromptsPageOpts): { el: HTMLElement; update(): void; dispose(): void } {
  const L = o.loc;
  const t = (k: Parameters<typeof apt>[1], v?: Record<string, string | number>) => apt(L(), k, v);
  let records: APRecordView[] = [];
  let selected: string | null = o.initialSelect ?? null;
  let showOriginal = !!o.showOriginal;
  const listBox = h('div', { class: 'pr-list' });
  const detailBox = h('div', { class: 'card pr-detail' });
  const countEl = h('span', { class: 'badge' });
  const el = h('div', { class: 'pr' },
    h('div', { class: 'head' }, h('div', null, h('h1', { html: t('title') }), h('p', { class: 'lead' }, t('lead'))), countEl),
    h('div', { class: 'pr-grid' }, listBox, detailBox));

  function renderList() {
    countEl.textContent = t('count', { n: records.length });
    if (!records.length) { listBox.replaceChildren(); return; }
    listBox.replaceChildren(...records.map((r) => h('button', { class: 'pr-item-btn' + (r.id === selected ? ' active' : ''), on: { click: () => { selected = r.id; showOriginal = false; render(); } } },
      h('div', { class: 'pr-item-title' }, r.title),
      h('div', { class: 'pr-item-meta' }, relative(L(), r.created),
        r.tasks > 0 ? ` · ${r.tasks === 1 ? t('tasks1') : t('tasksN', { n: r.tasks })}` : '',
        r.byRules ? h('span', { class: 'pr-rules' }, ` · ${t('rulesTag')}`) : null))));
  }

  function renderDetail() {
    const r = records.find((x) => x.id === selected);
    if (!r) {
      detailBox.className = 'card pr-detail pr-empty';
      detailBox.replaceChildren(
        h('img', { src: '../../assets/illustrations/illu_prompt_fertig.png', alt: '', class: 'pr-empty-img' }),
        h('div', { class: 'big' }, t('emptyBig')),
        h('div', { class: 'muted' }, t('emptyText')));
      return;
    }
    detailBox.className = 'card pr-detail';
    const date = new Date(r.created).toLocaleString(L() === 'de' ? 'de-DE' : 'en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
    const tag = (label: string, icon: string, cls = '') => h('span', { class: 'pr-tag ' + cls }, svg(icon), label);
    const seg = h('div', { class: 'seg' },
      h('button', { class: showOriginal ? '' : 'on', on: { click: () => { showOriginal = false; renderDetail(); } } }, t('segPrompt')),
      h('button', { class: showOriginal ? 'on' : '', on: { click: () => { showOriginal = true; renderDetail(); } } }, t('segOriginal')));
    const copyBtn = h('button', { class: 'icon-btn', title: showOriginal ? t('copyOriginal') : t('copyPrompt') }, svg(I.copy));
    copyBtn.addEventListener('click', async () => {
      await o.api.copy(r.id, showOriginal ? 'original' : 'prompt');
      copyBtn.replaceChildren(svg(I.check));
      setTimeout(() => copyBtn.replaceChildren(svg(I.copy)), 1200);
    });
    const del = h('button', { class: 'icon-btn danger', title: t('deletePrompt'), on: { click: async () => { await o.api.delete(r.id); await load(); } } }, svg(I.trash));
    detailBox.replaceChildren(
      h('div', { class: 'pr-bar' }, seg, h('div', { class: 'grow' }), copyBtn, del),
      h('div', { class: 'pr-meta' },
        h('span', { class: 'pr-date' }, date),
        r.appName ? tag(r.appName, I.app) : null,
        r.byRules ? tag(t('byRules'), I.list, 'amber') : tag(sourceLabel(r.source), I.spark, 'lilac')),
      h('div', { class: 'pr-body' }, showOriginal ? h('div', { class: 'pr-original' }, r.original) : promptView(r.prompt)));
  }

  function render() { renderList(); renderDetail(); }

  async function load() {
    records = await o.api.list();
    if (!selected || !records.some((r) => r.id === selected)) selected = records[0]?.id ?? null;
    render();
  }
  const off = o.api.onChanged(() => void load());
  void load();
  return { el, update() {}, dispose: off };
}

/** Einstellungen › Agent-Prompts */
export function promptSettingsRows(o: { loc: APLoc; mode: APMode; claude: boolean; set: (m: APMode) => void; row: (title: string, desc: string | null, ...ctl: (Node | null)[]) => HTMLElement }) {
  const L = o.loc;
  const seg = h('div', { class: 'seg' }, ...(['on', 'explicitOnly', 'off'] as APMode[]).map((m) =>
    h('button', { class: o.mode === m ? 'on' : '', on: { click: () => o.set(m) } }, apt(L, `mode_${m}`))));
  const how = apt(L, 'howStart') + apt(L, o.claude ? 'howClaude' : 'howRules') + apt(L, 'howEnd');
  const badge = h('span', { class: 'badge' + (o.claude ? ' ok' : '') }, apt(L, o.claude ? 'cliFound' : 'cliMissing'));
  return [o.row(apt(L, 'mode'), apt(L, `modeDesc_${o.mode}`), seg), o.row(apt(L, 'howTo'), how, badge)];
}

/** demo data for the offscreen render check (no personal data) */
export function demoPromptsApi(kind: string): PromptsApi {
  const now = Date.now();
  const recs: APRecordView[] = kind === 'empty' ? [] : [
    { id: 'p1', created: new Date(now - 6_000).toISOString(), prompt: SAMPLE_PROMPT_DE, original: SAMPLE_ORIGINAL_DE, appName: 'Visual Studio Code', source: 'claude/sonnet/low', note: '', trigger: 'zuruf', buildMs: 11_400, byRules: false, title: 'Die Settings Page im Dashboard schneller machen, indem statt aller User nur die ersten 50 geladen und per Infinite Scroll nachgeladen werden.', tasks: 5 },
    { id: 'p2', created: new Date(now - 26 * 60_000).toISOString(), prompt: SAMPLE_PROMPT_EN, original: 'Agent prompt: add retry logic to the upload client, three attempts with backoff, keep the API the same and make sure tests pass.', appName: 'Terminal', source: 'claude/sonnet/low', note: '', trigger: 'zuruf', buildMs: 7_900, byRules: false, title: 'Add retry logic to the upload client.', tasks: 2 },
    { id: 'p3', created: new Date(now - 3 * 3600_000).toISOString(), prompt: '**Ziel:** Bau das bitte so um, dass nur die ersten 50 User geladen werden – korrigiert: die …\n\n## Aufgabe\n1. Bau das bitte so um, dass nur die ersten 50 User geladen werden – korrigiert: die ersten 100.\n2. Prüf, ob der Endpoint /api/users in users.controller.ts einen limit Parameter hat.', original: FALLBACK_DE, appName: 'Cursor', source: 'regeln', note: 'Claude-CLI fehlt', trigger: 'zuruf', buildMs: 40, byRules: true, title: 'Bau das bitte so um, dass nur die ersten 50 User geladen werden – korrigiert: die …', tasks: 2 },
  ];
  return {
    list: async () => recs,
    delete: async (id) => { const i = recs.findIndex((r) => r.id === id); if (i >= 0) recs.splice(i, 1); },
    copy: async () => true,
    onChanged: () => () => {},
  };
}

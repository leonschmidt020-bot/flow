// Agent-Prompt card in the pill window – port of APCard.swift (Mac). It grows out of the pill to its right (left when there
// is no room), bottom-aligned with the capsule, like the Mac's VFNotify cards.
//
// States: offer („Daraus einen Agent-Prompt machen?“) → building (live text) → done (preview, Kopieren/Einfügen/Ansehen,
// Prompt | Original) · or cancelled/failed (Original einfügen/kopieren, Nochmal). A state change only changes the height
// (springy) – the card stays the same. Mouse on it = stays open, the done preview grows; the wheel scrolls the preview.
// ✕ closes (while building: cancels). Plain DOM – the window is click-through except over the card.
import type { APAction, APCardMessage, APCardView, APFlash, APGistView } from '../../shared/agentPrompt';
import { apt, reasonText, type APKey, type APLoc } from '../../agentPrompt/i18n';

export const CARD_W = 476;
const TILE_OVERLAP = 14, GAP = 12, INSET = 10;
const H = { offer: 158, building: 272, done: 338, doneExpanded: 500, stopped: 272 } as const;
const TIMEOUT: Record<APCardView['kind'], number | null> = { offer: 12_000, building: null, done: 30_000, stopped: 45_000 };
const ILLU = '../../assets/illustrations/';
const DONE_VARIANTS = ['illu_prompt_fertig', 'illu_prompt_fertig_2', 'illu_prompt_fertig_3', 'illu_prompt_fertig_4'];

// SF Symbols of the Mac card as small stroke icons
const ICONS: Record<string, string> = {
  sparkles: '<path d="M12 3.5l1.6 4.4 4.4 1.6-4.4 1.6L12 15.5l-1.6-4.4L6 9.5l4.4-1.6z"/><path d="M18.5 14.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/>',
  wand: '<path d="M4 20L15 9"/><path d="M13.5 7.5l3 3"/><path d="M18 3.5v3M16.5 5h3M20 10.5v2M19 11.5h2M10 3.5v2M9 4.5h2"/>',
  list: '<path d="M9 6.5h11M12 12h8M12 17.5h8"/><circle cx="4.8" cy="6.5" r="1.1"/><path d="M7.5 12l-2 0M7.5 17.5h-2"/>',
  stop: '<circle cx="12" cy="12" r="8.5"/><rect x="9" y="9" width="6" height="6" rx="1"/>',
  warn: '<path d="M12 4l9 15.5H3z"/><path d="M12 10v4.5M12 17.2v.3"/>',
  copy: '<rect x="8.5" y="8.5" width="11" height="11" rx="2.2"/><path d="M15.5 8.5V6.2a1.7 1.7 0 0 0-1.7-1.7H6.2a1.7 1.7 0 0 0-1.7 1.7v7.6a1.7 1.7 0 0 0 1.7 1.7h2.3"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  insert: '<path d="M12 4v11"/><path d="M7.5 10.5L12 15l4.5-4.5"/><path d="M5 19.5h14"/>',
  retry: '<path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3"/><path d="M19.5 4.5v4h-4"/>',
  x: '<path d="M7 7l10 10M17 7L7 17"/>',
};
const icon = (name: string, cls = 'ap-i') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${ICONS[name] ?? ''}</svg>`;

const esc = (s: string) => s.replace(/[&<>"]/gu, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const wordsOf = (s: string) => s.split(/\s+/u).filter(Boolean).length;

// MARK: - prompt text, lightly typeset (headings lilac in capitals, „**Ziel:**“ bold, the rest monospace)

type Line = { t: 'heading'; s: string } | { t: 'goal'; k: string; v: string } | { t: 'item'; s: string } | { t: 'text'; s: string } | { t: 'blank' };

export function promptLines(s: string): Line[] {
  const out: Line[] = [];
  for (const raw of s.split('\n')) {
    const t = raw.trim();
    if (!t) { if (out[out.length - 1]?.t !== 'blank') out.push({ t: 'blank' }); continue; }
    if (t.startsWith('#')) { out.push({ t: 'heading', s: t.replace(/^[#\s]+|[#\s]+$/gu, '') }); continue; }
    const g = /^\*\*([^*]{1,20}):\*\*\s*(.*)$/u.exec(t);
    if (g) { out.push({ t: 'goal', k: g[1]!, v: g[2]! }); continue; }
    if (/^(\d+[.)]|[-*•])\s+/u.test(t)) { out.push({ t: 'item', s: raw.split('**').join('') }); continue; }
    out.push({ t: 'text', s: t.split('**').join('') });
  }
  while (out[out.length - 1]?.t === 'blank') out.pop();
  return out;
}

function promptHtml(s: string): string {
  const tick = (x: string) => esc(x.split('`').join(''));
  return promptLines(s).map((l) => {
    switch (l.t) {
      case 'heading': return `<div class="ap-h">${esc(l.s.toUpperCase())}</div>`;
      case 'goal': return `<div class="ap-goal"><b>${esc(l.k)}:</b> ${tick(l.v)}</div>`;
      case 'item': return `<div class="ap-item">${tick(l.s.trim())}</div>`;
      case 'text': return `<div class="ap-text">${tick(l.s)}</div>`;
      default: return '<div class="ap-blank"></div>';
    }
  }).join('');
}

export function countsLine(loc: APLoc, g: APGistView): string {
  const t = (one: APKey, many: APKey, n: number) => (n === 1 ? apt(loc, one) : apt(loc, many, { n }));
  const parts = [t('tasks1', 'tasksN', g.tasks)];
  if (g.criteria > 0) parts.push(t('crit1', 'critN', g.criteria));
  if (g.rules > 0) parts.push(t('rules1', 'rulesN', g.rules));
  if (g.open > 0) parts.push(t('open1', 'openN', g.open));
  return parts.join(' · ');
}

/** „claude/sonnet/low“ → „Sonnet · low“ */
export function sourceLabel(s: string): string {
  const p = s.split('/');
  if (p[0] !== 'claude' || p.length < 2) return s;
  const m = p[1]!;
  return m.charAt(0).toUpperCase() + m.slice(1) + (p.length > 2 ? ` · ${p[2]}` : '');
}

export function rulesLabel(loc: APLoc, note: string): string {
  if (!note || note === 'Claude-CLI fehlt') return apt(loc, 'rulesNoCli');
  return apt(loc, 'rulesWhy', { why: reasonText(loc, note) });
}

// MARK: - the card

export interface CardApi {
  action(a: APAction): void;
  /** mouse over the card (for Esc while building) */
  hover?(on: boolean): void;
}

export interface CardOptions {
  /** render check: fixed hover/original state, fixed illustration, frozen timers */
  still?: { hovering?: boolean; showOriginal?: boolean; illustration?: string; elapsed?: number };
}

export class AgentCard {
  readonly el: HTMLDivElement;
  private msg: APCardMessage | null = null;
  private seq = -1;
  private kind: APCardView['kind'] | null = null;
  private hovering = false;
  private showOriginal = false;
  private copied = false;
  private copiedOriginal = false;
  private inserted = false;
  private illus = new Map<string, string>();
  private hidden = false;
  private closing = false;
  private left = 0; // ms until the automatic close
  private tick = 0;
  private timer: number | null = null;
  private leaveTimer: number | null = null;
  private secTimer: number | null = null;
  private foldRaf = 0;
  private placeSide: 'right' | 'left' | 'above' = 'right';

  constructor(parent: HTMLElement, private api: CardApi, private opts: CardOptions = {}) {
    this.el = document.createElement('div');
    this.el.className = 'ap-card';
    this.el.hidden = true;
    parent.append(this.el);
    this.el.addEventListener('click', (e) => this.onClick(e));
    if (opts.still) {
      this.hovering = !!opts.still.hovering;
      this.showOriginal = !!opts.still.showOriginal;
    }
  }

  get side(): 'right' | 'left' | 'above' { return this.placeSide; }
  /** card rectangle in window coordinates (only meaningful while visible) */
  rect(): DOMRect { return this.el.getBoundingClientRect(); }
  get visible(): boolean { return !!this.msg && !this.hidden && !this.el.hidden; }
  get loc(): APLoc { return this.msg?.locale ?? 'de'; }

  /** new message from main (null = close) */
  set(m: APCardMessage | null): void {
    if (!m) { this.close(); return; }
    const fresh = !this.msg || this.closing || m.seq !== this.seq;
    const sameKind = !fresh && this.kind === m.view.kind;
    this.msg = m;
    this.seq = m.seq;
    this.closing = false;
    if (fresh) {
      this.illus.clear();
      if (!this.opts.still) { this.hovering = false; this.showOriginal = false; }
      this.copied = false; this.copiedOriginal = false; this.inserted = false;
    }
    if (m.view.kind === 'done' && !sameKind) {
      this.copied = true;    // the prompt was copied automatically
      if (!this.opts.still) this.showOriginal = false;
    }
    if (sameKind && m.view.kind === 'building') { this.updateLive(); return; }
    this.kind = m.view.kind;
    this.render();
    if (fresh) this.appear();
    this.restartTimer();
  }

  flash(f: APFlash): void {
    if (f === 'copied') this.copied = true;
    if (f === 'copiedOriginal') {
      this.copiedOriginal = true;
      window.setTimeout(() => { this.copiedOriginal = false; if (this.kind === 'done' || this.kind === 'stopped') this.renderButtons(); }, 1600);
    }
    if (f === 'inserted') this.inserted = true;
    this.renderButtons();
    this.restartTimer();
  }

  /** meeting card has priority: the card steps aside and comes back */
  setHidden(h: boolean): void {
    if (h === this.hidden) return;
    this.hidden = h;
    this.el.classList.toggle('ap-away', h);
  }

  private close() {
    if (!this.msg || this.closing) return;
    this.closing = true;
    this.stopTimers();
    this.el.classList.add('ap-out');
    this.el.classList.remove('ap-in');
    window.setTimeout(() => {
      if (!this.closing) return;
      this.el.hidden = true;
      this.el.replaceChildren();
      this.el.classList.remove('ap-out');
      this.msg = null; this.kind = null; this.closing = false;
      this.api.hover?.(false);
    }, 320);
  }

  private appear() {
    this.el.hidden = false;
    this.el.classList.remove('ap-out', 'ap-in');
    if (this.opts.still) { this.el.classList.add('ap-in', 'ap-still'); return; }
    void this.el.offsetWidth; // restart the animation
    this.el.classList.add('ap-in');
  }

  // MARK: geometry

  height(): number {
    switch (this.kind) {
      case 'offer': return H.offer;
      case 'building': return H.building;
      case 'done': return this.hovering ? H.doneExpanded : H.done;
      case 'stopped': return H.stopped;
      default: return 0;
    }
  }

  /** place next to the capsule (window coordinates): right if there is room, else left, else above it */
  layout(W: number, winH: number, capsule: { x: number; y: number; w: number; h: number }) {
    if (!this.msg) return;
    const roomRight = W - (capsule.x + capsule.w) - GAP - INSET >= CARD_W;
    const roomLeft = capsule.x - GAP - INSET >= CARD_W;
    let x: number, bottom: number;
    let side: 'right' | 'left' | 'above';
    if (roomRight) { side = 'right'; x = capsule.x + capsule.w + GAP; bottom = winH - (capsule.y + capsule.h) - 2; }
    else if (roomLeft) { side = 'left'; x = capsule.x - GAP - CARD_W; bottom = winH - (capsule.y + capsule.h) - 2; }
    else { side = 'above'; x = Math.max(INSET, Math.min(W - INSET - CARD_W, capsule.x + capsule.w / 2 - CARD_W / 2)); bottom = winH - capsule.y + GAP; }
    const maxH = winH - bottom - TILE_OVERLAP - 4;
    this.el.style.setProperty('--ap-max', `${Math.max(140, maxH)}px`);
    if (side !== this.placeSide) { this.placeSide = side; this.el.dataset.side = side; }
    const l = `${Math.round(x)}px`, b = `${Math.round(bottom)}px`;
    if (this.el.style.left !== l) this.el.style.left = l;
    if (this.el.style.bottom !== b) this.el.style.bottom = b;
  }

  /** card + the illustration sticking out above it */
  hit(x: number, y: number): boolean {
    if (!this.visible || this.closing) return false;
    const r = this.el.getBoundingClientRect();
    const tile = this.el.querySelector('.ap-tile')?.getBoundingClientRect();
    const inR = (q: DOMRect | undefined) => !!q && x >= q.left - 3 && x <= q.right + 3 && y >= q.top - 3 && y <= q.bottom + 3;
    return inR(r) || inR(tile);
  }

  /** mouse moved (window coordinates) */
  pointer(over: boolean): void {
    if (this.opts.still) return;
    if (over) {
      if (this.leaveTimer !== null) { clearTimeout(this.leaveTimer); this.leaveTimer = null; }
      if (!this.hovering) { this.hovering = true; this.api.hover?.(true); this.applyHeight(); this.el.classList.add('ap-hover'); }
    } else if (this.hovering && this.leaveTimer === null) {
      // leaving: shrink only after a short pause (no flicker at the edge)
      this.leaveTimer = window.setTimeout(() => {
        this.leaveTimer = null;
        this.hovering = false; this.api.hover?.(false); this.applyHeight(); this.el.classList.remove('ap-hover');
      }, 250);
    }
  }

  private applyHeight() { this.el.style.height = `min(${this.height()}px, var(--ap-max, 520px))`; }

  // MARK: timers

  private stopTimers() {
    if (this.timer !== null) { clearInterval(this.timer); this.timer = null; }
    if (this.secTimer !== null) { clearInterval(this.secTimer); this.secTimer = null; }
    if (this.foldRaf) { cancelAnimationFrame(this.foldRaf); this.foldRaf = 0; }
  }

  private restartTimer() {
    if (this.timer !== null) { clearInterval(this.timer); this.timer = null; }
    const k = this.kind;
    const t = k ? TIMEOUT[k] : null;
    if (!t || this.opts.still) return;
    this.left = t;
    this.tick = performance.now();
    this.timer = window.setInterval(() => {
      const now = performance.now();
      if (this.visible) this.left -= now - this.tick;   // runs only while visible
      this.tick = now;
      if (this.left > 0) return;
      if (this.hovering) { this.left = 2000; return; }
      if (this.timer !== null) { clearInterval(this.timer); this.timer = null; }
      this.api.action(this.kind === 'offer' ? 'dismissOffer' : 'close');
    }, 200);
  }

  // MARK: rendering

  private illustration(kind: APCardView['kind']): string {
    let name = this.illus.get(kind);
    if (!name) {
      if (this.opts.still?.illustration && kind === 'done') name = this.opts.still.illustration;
      else if (kind === 'done') name = this.opts.still ? DONE_VARIANTS[0]! : DONE_VARIANTS[Math.floor(Math.random() * DONE_VARIANTS.length)]!;
      else name = kind === 'building' ? 'illu_prompt_baut' : 'illu_prompt_vorschlag';
      this.illus.set(kind, name);
    }
    return name;
  }

  private render() {
    const m = this.msg;
    if (!m) return;
    this.stopTimers();
    const v = m.view;
    const L = this.loc;
    this.el.dataset.kind = v.kind;
    this.applyHeight();
    const chip = (label: string, ic: string, tint: string) => `<span class="ap-chip ap-${tint}">${icon(ic, 'ap-ci')}${esc(label.toUpperCase())}</span>`;
    let chips = '';
    let title = '';
    let sub = '';
    let body = '';
    switch (v.kind) {
      case 'offer':
        chips = chip(apt(L, 'chipOffer'), 'wand', 'lilac');
        title = apt(L, 'titleOffer');
        sub = esc(this.offerLine(v));
        break;
      case 'building':
        chips = chip(apt(L, 'chipPrompt'), 'sparkles', 'lilac') + `<span class="ap-secs">${this.secs(v.startedAt)} s</span>`;
        title = apt(L, 'titleBuilding');
        sub = `<span class="ap-live-sub">${esc(this.buildingLine(v))}</span>`;
        body = `<div class="ap-preview ap-building"><canvas class="ap-fold"></canvas><div class="ap-live"><div class="ap-live-in"></div><i class="ap-caret"></i></div><div class="ap-sweep"><i></i></div></div>`;
        break;
      case 'done':
        chips = (v.byRules ? chip(apt(L, 'chipRules'), 'list', 'amber') : chip(apt(L, 'chipPrompt'), 'sparkles', 'lilac'))
          + `<span class="ap-spacer"></span><span class="ap-seg"><button data-seg="0" class="${this.showOriginal ? '' : 'on'}">${esc(apt(L, 'segPrompt'))}</button><button data-seg="1" class="${this.showOriginal ? 'on' : ''}">${esc(apt(L, 'segOriginal'))}</button></span>`;
        title = apt(L, 'titleDone');
        sub = this.showOriginal
          ? esc(apt(L, 'doneOriginalSub', { n: wordsOf(v.original) }))
          : `<span class="ap-goalline">${esc(v.gist.goal)}</span><span class="ap-counts">${esc(countsLine(L, v.gist))}</span>`;
        body = `<div class="ap-preview ap-scroll"><div class="ap-scroll-in">${this.showOriginal ? `<div class="ap-orig">${esc(v.original)}</div>` : promptHtml(v.prompt)}</div><div class="ap-fade"></div></div>`;
        break;
      case 'stopped':
        chips = chip(apt(L, v.stop === 'cancelled' ? 'chipCancelled' : 'chipFailed'), v.stop === 'cancelled' ? 'stop' : 'warn', 'amber');
        title = apt(L, v.stop === 'cancelled' ? 'titleCancelled' : 'titleFailed');
        sub = esc(apt(L, 'stoppedSub') + (!v.reason || v.reason === 'Abgebrochen' ? '' : ` (${reasonText(L, v.reason)})`));
        body = `<div class="ap-preview ap-scroll"><div class="ap-scroll-in"><div class="ap-orig">${esc(v.original)}</div></div><div class="ap-fade"></div></div>`;
        break;
    }
    const subCls = v.kind === 'done' && !this.showOriginal ? 'ap-sub ap-sub-done' : 'ap-sub';
    const name = this.illustration(v.kind);
    this.el.innerHTML = `
      <div class="ap-bg"></div>
      <div class="ap-content">
        <div class="ap-head ap-head-${v.kind}${v.kind === 'done' && this.showOriginal ? ' ap-head-orig' : ''}">
          <div class="ap-chips">${chips}</div>
          <div class="ap-title">${esc(title)}</div>
          <div class="${subCls}">${sub}</div>
        </div>
        ${body || '<div class="ap-flex"></div>'}
        <div class="ap-buttons"></div>
      </div>
      <div class="ap-tile"><img src="${ILLU}${name}.png" alt="" draggable="false"><button class="ap-x" data-act="close" title="${esc(apt(L, v.kind === 'building' ? 'btnCancel' : 'close'))}">${icon('x', 'ap-xi')}</button></div>`;
    this.renderButtons();
    if (v.kind === 'building') {
      this.updateLive();
      if (!this.opts.still) this.secTimer = window.setInterval(() => this.updateSecs(), 1000);
    }
  }

  private offerLine(v: Extract<APCardView, { kind: 'offer' }>): string {
    const L = this.loc;
    const parts = [apt(L, 'offerWords', { n: v.words })];
    if (v.agentApp) parts.push(apt(L, 'offerAgent'));
    else if (v.technical.length) parts.push(apt(L, 'offerTech', { tech: v.technical.slice(0, 2).join(', ') }));
    else parts.push(apt(L, 'offerTask'));
    return parts.join(' · ');
  }

  private buildingLine(v: Extract<APCardView, { kind: 'building' }>): string {
    const L = this.loc;
    if (!v.claude) return apt(L, 'buildingRules', { n: v.words });
    if (!v.partial) return apt(L, 'buildingWait', { n: v.words });
    const a = wordsOf(v.partial);
    return apt(L, 'buildingLive', { a, b: Math.max(v.words, a) });
  }

  private secs(startedAt: number): number {
    if (this.opts.still?.elapsed !== undefined) return this.opts.still.elapsed;
    return Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
  }

  private updateSecs() {
    const v = this.msg?.view;
    const el = this.el.querySelector('.ap-secs');
    if (v?.kind === 'building' && el) el.textContent = `${this.secs(v.startedAt)} s`;
  }

  /** live text: follows to the bottom by itself, the caret blinks at the end */
  private updateLive() {
    const v = this.msg?.view;
    if (v?.kind !== 'building') return;
    const sub = this.el.querySelector('.ap-live-sub');
    if (sub) sub.textContent = this.buildingLine(v);
    const pre = this.el.querySelector('.ap-building') as HTMLElement | null;
    const live = this.el.querySelector('.ap-live') as HTMLElement | null;
    const inner = this.el.querySelector('.ap-live-in') as HTMLElement | null;
    if (!pre || !live || !inner) return;
    pre.classList.toggle('ap-has-text', !!v.partial);
    if (v.partial) {
      if (this.foldRaf) { cancelAnimationFrame(this.foldRaf); this.foldRaf = 0; }
      inner.innerHTML = promptHtml(v.partial);
      live.scrollTop = live.scrollHeight;
    } else if (!this.foldRaf) {
      this.startFolding(pre.querySelector('.ap-fold') as HTMLCanvasElement);
    }
  }

  /** waiting picture before the first word: the pill's level bars fold into lines of text, row by row */
  private startFolding(c: HTMLCanvasElement | null) {
    if (!c) return;
    const g = c.getContext('2d');
    if (!g) return;
    const draw = (now: number) => {
      const t = this.opts.still ? 1.3 : now / 1000;
      const dpr = window.devicePixelRatio || 1;
      const w = c.clientWidth, h = c.clientHeight;
      if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) { c.width = Math.round(w * dpr); c.height = Math.round(h * dpr); }
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, w, h);
      const widths = [0.55, 0.92, 0.78, 0.86, 0.64, 0.4];
      const rowH = 20, seg = 5, gapW = 3;
      for (let r = 0; r < 6; r++) {
        const y = r * rowH + 8;
        if (y >= h - 6) break;
        const lineW = w * widths[r % widths.length]!;
        const n = Math.floor(lineW / (seg + gapW));
        const cycle = 2.4;
        const phase = ((t + r * 0.32) % cycle) / cycle;
        for (let k = 0; k < n; k++) {
          const x = k * (seg + gapW);
          const front = phase * lineW * 1.25;
          const folded = Math.min(1, Math.max(0, (front - x) / 60));
          const wobble = Math.abs(Math.sin(t * 7.3 + k * 1.7) * Math.cos(t * 3.1 + k * 0.9));
          const barH = 3 + (1 - folded) * (4 + 9 * wobble);
          const bh = folded >= 1 ? 5 : barH;
          const a = 0.14 + 0.5 * folded * (0.6 + 0.4 * Math.sin(t * 2 + r));
          const rw = folded > 0.5 ? seg + gapW + 0.5 : seg * 0.6;
          g.fillStyle = folded > 0.5 ? `rgba(255,255,255,${a})` : `rgba(189,161,255,${0.35 + 0.4 * wobble})`;
          g.beginPath();
          g.roundRect(x, y + (12 - bh) / 2, rw, bh, Math.min(rw, bh) / 2);
          g.fill();
        }
      }
      if (!this.opts.still) this.foldRaf = requestAnimationFrame(draw);
    };
    this.foldRaf = requestAnimationFrame(draw);
    if (this.opts.still) draw(0);
  }

  private renderButtons() {
    const box = this.el.querySelector('.ap-buttons');
    const v = this.msg?.view;
    if (!box || !v) return;
    const L = this.loc;
    const b = (act: string, label: string, kind: 'primary' | 'secondary' | 'ghost', ic?: string, done = false) =>
      `<button class="ap-btn ap-${kind}${done ? ' ap-done' : ''}" data-act="${act}">${ic ? icon(ic) : ''}<span>${esc(label)}</span></button>`;
    let html = '';
    switch (v.kind) {
      case 'offer':
        html = b('build', apt(L, 'btnBuild'), 'primary', 'sparkles') + b('dismissOffer', apt(L, 'btnNo'), 'ghost') + '<span class="ap-spacer"></span>';
        break;
      case 'building':
        html = b('cancel', apt(L, 'btnCancel'), 'secondary') + '<span class="ap-spacer"></span>' + `<span class="ap-foot">${esc(apt(L, 'originalReady'))}</span>`;
        break;
      case 'done': {
        if (this.showOriginal) {
          html = b('copyOriginal', apt(L, this.copiedOriginal ? 'btnCopied' : 'btnCopyOriginal'), 'primary', this.copiedOriginal ? 'check' : 'copy')
            + b('insertOriginal', apt(L, 'btnInsertOriginal'), 'secondary', 'insert');
        } else {
          html = b('copy', apt(L, this.copied ? 'btnCopied' : 'btnCopy'), 'primary', this.copied ? 'check' : 'copy', this.copied)
            + b('insert', apt(L, this.inserted ? 'btnInserted' : 'btnInsert'), 'secondary', 'insert')
            + b('open', apt(L, 'btnOpen'), 'ghost');
        }
        const secs = (v.buildMs / 1000).toFixed(1);
        const foot = v.byRules ? rulesLabel(L, v.note) : `${sourceLabel(v.source)} · ${L === 'de' ? secs.replace('.', ',') : secs} s`;
        html += `<span class="ap-spacer"></span><span class="ap-foot ap-foot-src">${esc(foot)}</span>`;
        break;
      }
      case 'stopped':
        html = b('insertOriginal', apt(L, 'btnInsertOriginal'), 'primary', 'insert')
          + b('copyOriginal', apt(L, this.copiedOriginal ? 'btnCopied' : 'btnCopyOriginal'), 'secondary', this.copiedOriginal ? 'check' : 'copy')
          + '<span class="ap-spacer"></span>' + b('retry', apt(L, 'btnRetry'), 'ghost', 'retry');
        break;
    }
    box.innerHTML = html;
  }

  private onClick(e: MouseEvent) {
    const t = e.target as HTMLElement;
    const seg = t.closest('[data-seg]') as HTMLElement | null;
    if (seg) {
      const on = seg.dataset.seg === '1';
      if (on !== this.showOriginal) { this.showOriginal = on; this.render(); }
      this.restartTimer();
      return;
    }
    const btn = t.closest('[data-act]') as HTMLElement | null;
    if (!btn) return;
    const a = btn.dataset.act as APAction;
    this.api.action(a);
  }
}

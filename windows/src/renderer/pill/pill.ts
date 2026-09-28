// The pill: a small capsule at the bottom of the screen. Drawn on a canvas, closely following the Mac pill
// (Sources/Murmur/Pill.swift): idle strip 44×9, listening 66×24 with 9 bars, hands-free 112×26 with ✕/■, transcribing dots.
// Cards: meeting card (canvas) > Agent-Prompt card (DOM, apCard.ts, right of the capsule) > learner card (DOM, above).
import { AgentCard } from './apCard';
import type { APAction, APCardMessage, APCardView, APFlash } from '../../shared/agentPrompt';
type Mode = 'idle' | 'recording' | 'handsfree' | 'transcribing' | 'loading' | 'hidden';
/** notetaker card (canvas) – has priority over the learner card (DOM, below) */
interface MeetingCard { kind: string; title: string; sub: string; yes: string; no: string }
interface PillState {
  mode: Mode; progress?: number; label?: string; alwaysVisible?: boolean;
  meeting?: { startedAt: number; label: string } | null;
  task?: { label: string; progress: number } | null;
  meetingCard?: MeetingCard | null;
  /** an Agent-Prompt is being built (pill shows lilac dots while it rests) */
  apBusy?: boolean;
}
interface Toast { text: string; kind?: 'info' | 'success' | 'error'; ms?: number }
interface Card { id: number; title: string; text: string; options: string[]; save: string; no: string; timeoutMs: number }
interface CardAnswer { id: number; save: boolean; choice?: string; timeout?: boolean }
interface PillApi {
  onState(cb: (s: PillState) => void): void;
  onLevel(cb: (lv: number) => void): void;
  onToast(cb: (t: Toast) => void): void;
  setInteractive(on: boolean): void;
  click(what: string): void;
  drop?(files: File[]): void;
  onCard?(cb: (c: Card | null) => void): void;
  answerCard?(a: CardAnswer): void;
  onAgent?(cb: (m: APCardMessage | null) => void): void;
  onAgentFlash?(cb: (f: APFlash) => void): void;
  agentAction?(a: APAction): void;
  agentHover?(on: boolean): void;
  ready(): void;
}
const api = (window as unknown as { flowPill?: PillApi }).flowPill;

const canvas = document.getElementById('c') as HTMLCanvasElement;
const g = canvas.getContext('2d')!;
const FONT = '"Segoe UI Variable Text", "Segoe UI", system-ui, -apple-system, sans-serif';

let state: PillState = { mode: 'idle', alwaysVisible: true };
let level = 0, smooth = 0;
let w = 44, h = 9, alpha = 0;
let bars = new Array(9).fill(2.2);
const t0 = performance.now();
let toast: { text: string; kind: string; until: number; born: number } | null = null;
let hot: { cancel: DOMRect | null; stop: DOMRect | null } = { cancel: null, stop: null };
// notetaker hit areas (meeting stop / open, card buttons)
let mhot: { id: string; r: DOMRect }[] = [];
let dragging = false;
let cardAlpha = 0;
const pad2 = (n: number) => String(n).padStart(2, '0');
function elapsed(startedAt: number): string {
  const s = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
  return s >= 3600 ? `${Math.floor(s / 3600)}:${pad2(Math.floor(s / 60) % 60)}:${pad2(s % 60)}` : `${pad2(Math.floor(s / 60))}:${pad2(s % 60)}`;
}
const meetingText = () => (state.meeting ? `${state.meeting.label} · ${elapsed(state.meeting.startedAt)}` : '');
let interactive = false;

function targetSize(): [number, number] {
  if (state.mode === 'idle' && dragging) return [150, 28];
  if (state.mode === 'idle' && state.task) return [Math.max(176, textW(state.task.label, 11.5, 600) + 44), 28];
  if (state.mode === 'idle' && state.meeting) return [Math.ceil(textW(state.meeting.label + ' · 00:00', 11.5, 600)) + 62, 26];
  if (state.mode === 'idle' && state.apBusy) return [66, 24];
  switch (state.mode) {
    case 'idle': return [44, 9];
    case 'recording': case 'transcribing': return [66, 24];
    case 'handsfree': return [112, 26];
    case 'loading': return [Math.max(176, textW(state.label ?? '', 11.5, 600) + 44), 28];
    default: return [44, 9];
  }
}
function targetAlpha() {
  if (state.mode === 'hidden') return 0;
  if (state.mode === 'idle' && !state.alwaysVisible && !state.meeting && !state.task && !state.apBusy && !dragging) return 0;
  return 1;
}
function textW(s: string, size: number, weight: number) {
  g.font = `${weight} ${size}px ${FONT}`;
  return g.measureText(s).width;
}

function resize() {
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(innerWidth * dpr);
  canvas.height = Math.round(innerHeight * dpr);
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
}
addEventListener('resize', resize);
resize();

function capsule(x: number, y: number, cw: number, ch: number) {
  // stadium shape; radius = half of the shorter side (bars are vertical, the pill is horizontal)
  const r = Math.max(0, Math.min(cw, ch) / 2);
  g.beginPath();
  g.roundRect(x, y, Math.max(0, cw), Math.max(0, ch), r);
}

function drawBars(cx: number, cy: number, count: number, maxH: number, t: number, lvl: number, barW = 2.2, gap = 2.3) {
  if (bars.length !== count) bars = new Array(count).fill(barW);
  const total = count * barW + (count - 1) * gap;
  let x = cx - total / 2;
  const lv = Math.min(1, Math.max(0, (lvl - 0.04) / 0.8));
  const mid = (count - 1) / 2;
  for (let i = 0; i < count; i++) {
    const env = 1 - Math.pow(Math.abs(i - mid) / (mid + 1), 1.6) * 0.75;
    const wobble = 0.55 + 0.45 * Math.abs(Math.sin(t * 7.3 + i * 1.7) * Math.cos(t * 3.1 + i * 0.9));
    const target = barW + (maxH - barW) * lv * env * wobble;
    bars[i] += (target - bars[i]) * 0.35;
    const bh = Math.max(barW, bars[i]);
    g.fillStyle = `rgba(255,255,255,${alpha})`;
    capsule(x, cy - bh / 2, barW, bh);
    g.fill();
    x += barW + gap;
  }
}

function drawDots(cx: number, cy: number, t: number, rgb = '255,255,255') {
  const count = 5, spacing = 6, radius = 1.6;
  const total = (count - 1) * spacing;
  for (let i = 0; i < count; i++) {
    const x = cx - total / 2 + i * spacing;
    const ph = t * 6.5 - i * 0.75;
    const dy = Math.sin(ph) * 3;
    const a = 0.45 + 0.55 * (0.5 + 0.5 * Math.sin(ph));
    g.fillStyle = `rgba(${rgb},${alpha * a})`;
    g.beginPath(); g.arc(x, cy + dy, radius, 0, Math.PI * 2); g.fill();
  }
}

function drawProgress(label: string, progress: number, x: number, y: number, cx: number, cy: number) {
  const p = Math.max(0.03, Math.min(1, progress));
  g.font = `600 11.5px ${FONT}`; g.textAlign = 'center'; g.textBaseline = 'middle';
  g.fillStyle = `rgba(255,255,255,${0.92 * alpha})`;
  g.fillText(label, cx, cy - 2);
  const tx = x + 16, tw2 = w - 32, ty = y + h - 6;
  g.fillStyle = `rgba(255,255,255,${0.2 * alpha})`; g.fillRect(tx, ty, tw2, 2);
  g.fillStyle = `rgba(255,255,255,${alpha})`; g.fillRect(tx, ty, tw2 * p, 2);
}

function drawMeetingCard(c: MeetingCard, W: number, H: number, a: number) {
  g.font = `600 11.5px ${FONT}`;
  const bw1 = Math.max(70, g.measureText(c.yes).width + 22), bw2 = Math.max(64, g.measureText(c.no).width + 20);
  g.font = `600 12.5px ${FONT}`;
  const tw = Math.max(g.measureText(c.title).width, (g.font = `500 11.5px ${FONT}`, g.measureText(c.sub).width));
  const cw = Math.min(W - 16, Math.max(300, 32 + tw + 14 + bw1 + 6 + bw2 + 12)), ch = 58, x0 = (W - cw) / 2, y0 = H - 26 - 20 - ch + (1 - a) * 6;
  g.save();
  g.shadowColor = `rgba(0,0,0,${0.35 * a})`; g.shadowBlur = 14; g.shadowOffsetY = 3;
  g.beginPath(); g.roundRect(x0, y0, cw, ch, 16);
  g.fillStyle = `rgba(12,12,14,${0.94 * a})`; g.fill();
  g.restore();
  g.beginPath(); g.roundRect(x0 + 0.5, y0 + 0.5, cw - 1, ch - 1, 15.5);
  g.strokeStyle = `rgba(255,255,255,${0.22 * a})`; g.lineWidth = 1; g.stroke();
  const by = y0 + (ch - 26) / 2;
  const bx2 = x0 + cw - 12 - bw2, bx1 = bx2 - 6 - bw1;
  const maxText = Math.max(40, bx1 - (x0 + 32) - 10);
  // red dot + two lines of text (ellipsis instead of squeezing)
  const fit = (s: string) => { if (g.measureText(s).width <= maxText) return s; let t = s; while (t.length > 1 && g.measureText(t + '…').width > maxText) t = t.slice(0, -1); return t + '…'; };
  g.fillStyle = `rgba(255,69,58,${a})`;
  g.beginPath(); g.arc(x0 + 20, y0 + 20, 4, 0, Math.PI * 2); g.fill();
  g.textAlign = 'left'; g.textBaseline = 'middle';
  g.font = `600 12.5px ${FONT}`; g.fillStyle = `rgba(255,255,255,${a})`;
  g.fillText(fit(c.title), x0 + 32, y0 + 20);
  g.font = `500 11.5px ${FONT}`; g.fillStyle = `rgba(255,255,255,${0.66 * a})`;
  g.fillText(fit(c.sub), x0 + 32, y0 + 39);
  // buttons: [yes] (light) [no] (ghost)
  g.font = `600 11.5px ${FONT}`;
  g.beginPath(); g.roundRect(bx1, by, bw1, 26, 13); g.fillStyle = `rgba(242,242,244,${a})`; g.fill();
  g.fillStyle = `rgba(11,12,15,${a})`; g.textAlign = 'center'; g.fillText(c.yes, bx1 + bw1 / 2, by + 13.5);
  g.beginPath(); g.roundRect(bx2, by, bw2, 26, 13); g.fillStyle = `rgba(255,255,255,${0.12 * a})`; g.fill();
  g.fillStyle = `rgba(255,255,255,${0.9 * a})`; g.fillText(c.no, bx2 + bw2 / 2, by + 13.5);
  mhot.push({ id: 'cardYes', r: new DOMRect(bx1, by, bw1, 26) }, { id: 'cardNo', r: new DOMRect(bx2, by, bw2, 26) });
}

function frame() {
  const t = (performance.now() - t0) / 1000;
  const [tw, th] = targetSize();
  const k = 0.28;
  w += (tw - w) * k; h += (th - h) * k;
  alpha += (targetAlpha() - alpha) * 0.22;
  smooth += (level - smooth) * 0.3;
  const W = innerWidth, H = innerHeight;
  g.clearRect(0, 0, W, H);
  const cx = W / 2, cy = H - 26;
  const x = cx - w / 2, y = cy - h / 2;
  hot = { cancel: null, stop: null };
  mhot = [];

  if (alpha > 0.005) {
    const idleStrip = state.mode === 'idle' && !state.meeting && !state.task && !state.apBusy && !dragging;
    // shadow + fill
    g.save();
    g.shadowColor = `rgba(0,0,0,${0.35 * alpha})`;
    g.shadowBlur = 10; g.shadowOffsetY = 2;
    capsule(x, y, w, h);
    g.fillStyle = idleStrip ? `rgba(41,41,41,${0.92 * alpha})` : `rgba(0,0,0,${0.92 * alpha})`;
    g.fill();
    g.restore();
    // hairline border
    capsule(x + 0.5, y + 0.5, w - 1, h - 1);
    g.lineWidth = 1;
    g.strokeStyle = `rgba(255,255,255,${(h > 12 ? 0.32 : 0.42) * alpha})`;
    g.stroke();

    if (state.mode === 'idle' && dragging) {
      g.font = `600 11.5px ${FONT}`; g.textAlign = 'center'; g.textBaseline = 'middle';
      g.fillStyle = `rgba(179,166,255,${alpha})`;
      g.fillText('↓', x + 16, cy + 0.5);
      g.fillStyle = `rgba(255,255,255,${0.95 * alpha})`;
      g.fillText(document.documentElement.lang === 'en' ? 'Drop to transcribe' : 'Ablegen → Transkript', cx + 7, cy + 0.5, w - 34);
    } else if (state.mode === 'idle' && state.task) {
      drawProgress(state.task.label, state.task.progress, x, y, cx, cy);
    } else if (state.mode === 'idle' && state.meeting) {
      // ● Meeting läuft · 12:03   ■
      const pulse = 0.55 + 0.45 * (0.5 + 0.5 * Math.sin(t * 3.2));
      const dx = x + 15;
      g.fillStyle = `rgba(255,69,58,${alpha * (0.35 + 0.65 * pulse)})`;
      g.beginPath(); g.arc(dx, cy, 3.6 + smooth * 2.2, 0, Math.PI * 2); g.fill();
      g.font = `600 11.5px ${FONT}`; g.textAlign = 'left'; g.textBaseline = 'middle';
      g.fillStyle = `rgba(255,255,255,${0.95 * alpha})`;
      g.fillText(meetingText(), x + 27, cy + 0.5);
      const sx = x + w - 15;
      g.fillStyle = `rgba(255,255,255,${0.16 * alpha})`;
      g.beginPath(); g.arc(sx, cy, 8.5, 0, Math.PI * 2); g.fill();
      g.fillStyle = `rgba(255,255,255,${0.95 * alpha})`;
      g.beginPath(); g.roundRect(sx - 3, cy - 3, 6, 6, 1.3); g.fill();
      mhot.push({ id: 'meetingStop', r: new DOMRect(sx - 11, cy - 11, 22, 22) }, { id: 'meetingOpen', r: new DOMRect(x, y, w - 26, h) });
    } else if (state.mode === 'idle' && state.apBusy) {
      drawDots(cx, cy, t, '189,161,255');
    } else if (state.mode === 'recording') drawBars(cx, cy, 9, h - 9, t, smooth);
    else if (state.mode === 'handsfree') {
      // ✕ left, ■ (red) right, bars in the middle
      const lx = x + 15, rx = x + w - 15;
      g.fillStyle = `rgba(255,255,255,${0.16 * alpha})`;
      g.beginPath(); g.arc(lx, cy, 8.5, 0, Math.PI * 2); g.fill();
      g.strokeStyle = `rgba(255,255,255,${0.9 * alpha})`; g.lineWidth = 1.4; g.lineCap = 'round';
      g.beginPath(); g.moveTo(lx - 3, cy - 3); g.lineTo(lx + 3, cy + 3); g.moveTo(lx + 3, cy - 3); g.lineTo(lx - 3, cy + 3); g.stroke();
      g.fillStyle = `rgba(255,69,58,${alpha})`;
      g.beginPath(); g.arc(rx, cy, 8.5, 0, Math.PI * 2); g.fill();
      g.fillStyle = `rgba(255,255,255,${alpha})`;
      g.beginPath(); g.roundRect(rx - 3, cy - 3, 6, 6, 1.3); g.fill();
      drawBars(cx, cy, 9, h - 10, t, smooth);
      hot = { cancel: new DOMRect(lx - 11, cy - 11, 22, 22), stop: new DOMRect(rx - 11, cy - 11, 22, 22) };
    } else if (state.mode === 'transcribing') {
      drawDots(cx, cy, t);
      // subtle shimmer sweeping along the capsule
      const sweep = ((t * 0.9) % 1.6) - 0.3;
      const sx = x + w * sweep;
      const grad = g.createLinearGradient(sx - 30, 0, sx + 30, 0);
      grad.addColorStop(0, 'rgba(255,255,255,0)');
      grad.addColorStop(0.5, `rgba(255,255,255,${0.22 * alpha})`);
      grad.addColorStop(1, 'rgba(255,255,255,0)');
      capsule(x + 0.5, y + 0.5, w - 1, h - 1);
      g.strokeStyle = grad; g.lineWidth = 1.2; g.stroke();
    } else if (state.mode === 'loading') {
      drawProgress(state.label ?? '', state.progress ?? 0, x, y, cx, cy);
    }
  }

  // notetaker card („Teams erkannt · Meeting aufnehmen?“) at the top of the pill window
  cardAlpha += ((state.meetingCard ? 1 : 0) - cardAlpha) * 0.25;
  if (state.meetingCard && cardAlpha > 0.02) drawMeetingCard(state.meetingCard, W, H, cardAlpha);

  // Agent-Prompt card: next to the capsule; steps aside for the meeting card, pushes the learner card away
  ap.setHidden(!!state.meetingCard);
  ap.layout(W, H, { x, y, w, h });
  const apShown = ap.visible;
  if (apShown !== apWasShown) { apWasShown = apShown; syncLearnerAway(); }

  // toast above the pill
  if (toast) {
    const now = performance.now();
    const life = Math.min(1, (now - toast.born) / 160, Math.max(0, (toast.until - now) / 220));
    if (now > toast.until) toast = null;
    else {
      g.font = `500 12px ${FONT}`;
      const hasDot = toast.kind === 'error' || toast.kind === 'success';
      const tw3 = Math.min(W - 24, g.measureText(toast.text).width + 28 + (hasDot ? 12 : 0));
      const ty = cy - 13 - 10 - 24 + (1 - life) * 4 - cardLift();
      let txx = cx - tw3 / 2;
      // Agent-Prompt card to the right/left of the capsule: the toast moves aside instead of hiding under it
      if (ap.visible && ap.side === 'right') txx = Math.max(12, Math.min(txx, ap.rect().left - 10 - tw3));
      if (ap.visible && ap.side === 'left') txx = Math.min(W - 12 - tw3, Math.max(txx, ap.rect().right + 10));
      g.save();
      g.shadowColor = `rgba(0,0,0,${0.3 * life})`; g.shadowBlur = 12; g.shadowOffsetY = 3;
      capsule(txx, ty, tw3, 24);
      g.fillStyle = `rgba(0,0,0,${0.86 * life})`; g.fill();
      g.restore();
      capsule(txx + 0.5, ty + 0.5, tw3 - 1, 23);
      g.strokeStyle = `rgba(255,255,255,${0.25 * life})`; g.lineWidth = 1; g.stroke();
      const dot = toast.kind === 'error' ? '255,99,90' : toast.kind === 'success' ? '120,220,150' : '';
      let textX = txx + tw3 / 2;
      if (dot) {
        g.fillStyle = `rgba(${dot},${life})`;
        g.beginPath(); g.arc(txx + 13, ty + 12, 3, 0, Math.PI * 2); g.fill();
        textX += 7;
      }
      g.textAlign = 'center'; g.textBaseline = 'middle';
      g.fillStyle = `rgba(255,255,255,${life})`;
      g.fillText(toast.text, textX, ty + 12.5, W - 40);
    }
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// click-through except over the hands-free buttons and the cards
addEventListener('mousemove', (e) => {
  const onAp = ap.hit(e.clientX, e.clientY);
  ap.pointer(onAp);
  const over = [hot.cancel, hot.stop, ...mhot.map((m) => m.r)].some((r) => r && e.clientX >= r.x && e.clientX <= r.right && e.clientY >= r.y && e.clientY <= r.bottom) || overCard(e.clientX, e.clientY) || onAp;
  if (over !== interactive) { interactive = over; api?.setInteractive(over); }
  document.body.style.cursor = over ? 'pointer' : 'default';
});
document.addEventListener('mouseleave', () => {
  ap.pointer(false);
  if (interactive) { interactive = false; api?.setInteractive(false); }
});
addEventListener('mousedown', (e) => {
  const inside = (r: DOMRect | null) => !!r && e.clientX >= r.x && e.clientX <= r.right && e.clientY >= r.y && e.clientY <= r.bottom;
  if (inside(hot.cancel)) api?.click('cancel');
  else if (inside(hot.stop)) api?.click('stop');
  else { const m = mhot.find((x) => inside(x.r)); if (m) api?.click(m.id); }
});

// drop audio/video files onto the pill → notetaker import
addEventListener('dragover', (e) => { e.preventDefault(); if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy'; dragging = true; });
addEventListener('dragleave', () => { dragging = false; });
addEventListener('drop', (e) => {
  e.preventDefault();
  dragging = false;
  const files = Array.from(e.dataTransfer?.files ?? []);
  if (files.length) api?.drop?.(files);
});

// ── question card („Wort gelernt?“) ──
const cardEl = document.getElementById('card') as HTMLDivElement;

// ── Agent-Prompt card ──
const q0 = new URLSearchParams(location.search);
const apStill = q0.has('ap') ? { hovering: q0.get('aphover') === '1', showOriginal: q0.get('aporig') === '1', illustration: q0.get('apillu') ?? undefined, elapsed: Number(q0.get('apsecs') ?? 6) } : undefined;
const ap = new AgentCard(document.body, {
  action: (a) => api?.agentAction?.(a),
  hover: (on) => api?.agentHover?.(on),
}, { still: apStill });
let apWasShown = false;
let card: Card | null = null;
let choice = '';
let cardLeft = 0;      // ms of the timeout still to go
let cardTick = 0;      // performance.now() of the last update
let cardTimer: number | null = null;
const ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M5 4.5h10.5a3 3 0 0 1 3 3v12H8a3 3 0 0 1-3-3z"/><path d="M5 16.5a3 3 0 0 1 3-3h10.5"/><path d="M9 8.5h6"/></svg>';

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls: string, text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
function cardVisible() { return !!card && !cardEl.hidden && !cardEl.classList.contains('away'); }
/** toasts sit above whichever card is shown */
function cardLift() {
  if (state.meetingCard) return 58 + 8;
  if (ap.visible && ap.side === 'above') return ap.rect().height + 22;
  return cardVisible() ? cardEl.getBoundingClientRect().height + 8 : 0;
}
function overCard(x: number, y: number) {
  if (!cardVisible()) return false;
  const r = cardEl.getBoundingClientRect();
  return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
}
function answer(save: boolean, timeout = false) {
  if (!card) return;
  const a: CardAnswer = { id: card.id, save, choice: save ? choice : undefined, timeout };
  showCard(null);
  if (interactive) { interactive = false; api?.setInteractive(false); }
  api?.answerCard?.(a);
}
function drawCard() {
  if (!card) return;
  const kids: HTMLElement[] = [];
  const head = el('div', 'c-head');
  const icon = el('div', 'c-icon'); icon.innerHTML = ICON;
  head.append(icon, el('div', 'c-title', card.title));
  kids.push(head, el('div', 'c-text', card.text));
  if (card.options.length > 1) {
    const chips = el('div', 'c-chips');
    for (const o of card.options) {
      const b = el('button', 'chip' + (o === choice ? ' on' : ''), o);
      b.addEventListener('click', () => { choice = o; drawCard(); });
      chips.append(b);
    }
    kids.push(chips);
  }
  const acts = el('div', 'c-actions');
  const no = el('button', 'btn no', card.no); no.addEventListener('click', () => answer(false));
  const save = el('button', 'btn save', card.save); save.addEventListener('click', () => answer(true));
  acts.append(no, save);
  const bar = el('div', 'c-bar'); const fill = el('i', ''); bar.append(fill);
  kids.push(acts, bar);
  cardEl.replaceChildren(...kids);
  updateBar();
}
function updateBar() {
  const fill = cardEl.querySelector('.c-bar i') as HTMLElement | null;
  if (fill && card) fill.style.transform = `scaleX(${Math.max(0, Math.min(1, cardLeft / Math.max(1, card.timeoutMs)))})`;
}
function showCard(c: Card | null) {
  if (cardTimer !== null) { clearInterval(cardTimer); cardTimer = null; }
  card = c;
  if (!c) { cardEl.hidden = true; cardEl.replaceChildren(); return; }
  choice = c.options[0] ?? '';
  cardLeft = c.timeoutMs;
  cardTick = performance.now();
  cardEl.hidden = false;
  drawCard();
  if (c.timeoutMs > 0) {
    cardTimer = window.setInterval(() => {
      const now = performance.now();
      // the timeout only runs while the card is visible (hidden while dictating) and the mouse is not over it
      if (cardVisible() && !interactive) cardLeft -= now - cardTick;
      cardTick = now;
      updateBar();
      if (cardLeft <= 0) answer(false, true);
    }, 100);
  }
}

function syncLearnerAway() {
  // while dictating the card steps aside (the pill needs the attention), afterwards it comes back
  // …and it never shows while a meeting is recorded, a meeting card is up or the Agent-Prompt card is shown (priority)
  cardEl.classList.toggle('away', (state.mode !== 'idle' && state.mode !== 'hidden') || !!state.meeting || !!state.meetingCard || ap.visible);
}
function setState(s: PillState) {
  state = { ...state, ...s };
  syncLearnerAway();
}
function showToast(tt: Toast) { const now = performance.now(); toast = { text: tt.text, kind: tt.kind ?? 'info', born: now, until: now + (tt.ms ?? 2200) }; }
function setLevel(lv: number) { level = Math.min(1, lv * 9); }

api?.onState(setState);
api?.onLevel(setLevel);
api?.onToast(showToast);
api?.onCard?.(showCard);
api?.onAgent?.((m) => {
  ap.set(m);
  syncLearnerAway();
  // card gone → click-through again (the next mousemove turns it back on over anything else that is clickable)
  if (!m) setTimeout(() => { if (interactive && !ap.visible) { interactive = false; api?.setInteractive(false); document.body.style.cursor = 'default'; } }, 340);
});
api?.onAgentFlash?.((f) => ap.flash(f));
api?.ready();

// render-check hooks (offscreen screenshots)
const q = new URLSearchParams(location.search);
if (q.has('render')) {
  document.body.classList.add('render');
  if (q.get('bg') === 'light') document.body.classList.add('light');
  const mode = (q.get('mode') ?? 'idle') as Mode;
  state = { mode, alwaysVisible: true, progress: Number(q.get('p') ?? 0.42), label: q.get('label') ?? 'Sprachmodell · 42 %' };
  if (q.get('meeting')) state.meeting = { startedAt: Date.now() - Number(q.get('meeting')) * 1000, label: q.get('mlabel') ?? 'Meeting läuft' };
  if (q.get('task')) state.task = { label: q.get('task')!, progress: Number(q.get('p') ?? 0.42) };
  if (q.get('mcard')) { const [title, sub, yes, no] = q.get('mcard')!.split('|'); state.meetingCard = { kind: 'detected', title: title!, sub: sub!, yes: yes!, no: no! }; cardAlpha = 1; }
  if (q.get('drag')) dragging = true;
  if (q.get('lang')) document.documentElement.lang = q.get('lang')!;
  [w, h] = targetSize(); alpha = 1;
  if (mode === 'recording' || mode === 'handsfree') { level = 0.6; smooth = 0.6; setInterval(() => { level = 0.35 + Math.random() * 0.5; }, 60); }
  if (q.get('toast')) showToast({ text: q.get('toast')!, kind: (q.get('kind') as Toast['kind']) ?? 'info', ms: 60000 });
  if (q.get('card')) { try { showCard(JSON.parse(q.get('card')!) as Card); } catch { /* bad fixture */ } }
  if (q.get('ap')) { try { ap.set({ seq: 1, view: JSON.parse(q.get('ap')!) as APCardView, locale: q.get('lang') === 'en' ? 'en' : 'de' }); } catch { /* bad fixture */ } }
  if (q.get('apbusy')) state.apBusy = true;
  setState({ mode });
}
(window as unknown as { __pill: unknown }).__pill = { setState, showToast, setLevel, showCard, ap };

export {};

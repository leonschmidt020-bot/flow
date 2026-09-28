// Pill (transparent, click-through, always on top, never focused) + Hub window.
import { BrowserWindow, ipcMain, screen, shell } from 'electron';
import { paths } from './paths';
import { AP_ACTIONS, type APAction, type APCardMessage, type APFlash } from '../shared/agentPrompt';

export type PillMode = 'idle' | 'recording' | 'handsfree' | 'transcribing' | 'loading' | 'hidden';
export interface PillState {
  mode: PillMode; progress?: number; label?: string; alwaysVisible?: boolean;
  /** notetaker (src/meeting): shown while the dictation pill rests (mode idle) */
  meeting?: { startedAt: number; label: string } | null;
  task?: { label: string; progress: number } | null;
  /** notetaker card („Teams erkannt · Meeting aufnehmen?“ / „Meeting vorbei?“) – has priority over the learner card */
  meetingCard?: { kind: string; title: string; sub: string; yes: string; no: string } | null;
  /** an Agent-Prompt is being built (lilac dots while the pill rests) */
  apBusy?: boolean;
}
export type PillClick = 'cancel' | 'stop' | 'meetingStop' | 'meetingOpen' | 'cardYes' | 'cardNo';
/** a question card above the pill („Wort gelernt?“) – strings are already localised */
export interface PillCard { id: number; title: string; text: string; options: string[]; save: string; no: string; timeoutMs: number }
export interface PillCardAnswer { id: number; save: boolean; choice?: string; timeout?: boolean }

/** tall enough for the learner card above the capsule; the window is click-through except over buttons */
export const PILL_W = 460, PILL_H = 230;
/** while the Agent-Prompt card is up: room for the 476 px card right of the capsule (up to 500 px tall + illustration) */
export const PILL_AP_W = 1100, PILL_AP_H = 580;

export class Pill {
  win: BrowserWindow | null = null;
  private last: PillState = { mode: 'idle', alwaysVisible: true };
  private ready = false;
  private queue: [string, unknown][] = [];
  onClick: (what: PillClick) => void = () => {};
  onCardAnswer: (a: PillCardAnswer) => void = () => {};
  /** files dropped onto the pill (audio import) */
  onDrop: (files: string[]) => void = () => {};
  /** one mouse model: the window is click-through unless the renderer is over a button/card or the cursor is on the drop zone */
  private rendererInteractive = false;
  private dropZone = false;
  private hoverTimer: NodeJS.Timeout | null = null;
  /** false in self-tests: never put anything on the screen */
  visible = true;
  /** Agent-Prompt card: button clicks / mouse over the card (Esc while building cancels only then) */
  onAgentAction: (a: APAction) => void = () => {};
  agentHover = false;
  private agentShown = false;
  private agentShrink: NodeJS.Timeout | null = null;

  create() {
    const win = new BrowserWindow({
      width: PILL_W, height: PILL_H, show: false, frame: false, transparent: true, resizable: false, movable: false,
      minimizable: false, maximizable: false, fullscreenable: false, skipTaskbar: true, focusable: false, hasShadow: false,
      alwaysOnTop: true, backgroundColor: '#00000000', type: process.platform === 'win32' ? 'toolbar' : undefined,
      webPreferences: { preload: paths.preload('pill'), contextIsolation: true, sandbox: false, backgroundThrottling: false },
    });
    win.setAlwaysOnTop(true, 'screen-saver');
    win.setIgnoreMouseEvents(true, { forward: true });
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    void win.loadFile(paths.renderer('pill', 'pill.html'));
    ipcMain.on('pill:ready', (e) => {
      if (e.sender !== win.webContents) return;
      this.ready = true;
      win.webContents.send('pill:state', this.last);
      for (const [ch, p] of this.queue) win.webContents.send(ch, p);
      this.queue = [];
    });
    ipcMain.on('pill:interactive', (e, on: boolean) => { if (e.sender === win.webContents) { this.rendererInteractive = on; this.applyMouse(); } });
    ipcMain.on('pill:click', (e, what: PillClick) => { if (e.sender === win.webContents) this.onClick(what); });
    ipcMain.on('pill:drop', (e, files: string[]) => { if (e.sender === win.webContents && Array.isArray(files)) this.onDrop(files.map(String)); });
    ipcMain.on('pill:apAction', (e, a: unknown) => {
      if (e.sender !== win.webContents || typeof a !== 'string' || !(AP_ACTIONS as readonly string[]).includes(a)) return;
      this.onAgentAction(a as APAction);
    });
    ipcMain.on('pill:apHover', (e, on: unknown) => { if (e.sender === win.webContents) this.agentHover = on === true; });
    ipcMain.on('pill:cardAnswer', (e, a: PillCardAnswer) => {
      if (e.sender !== win.webContents || !a || typeof a.id !== 'number') return;
      // the card is gone → click-through again (through the shared mouse model, the drop zone may still hold it)
      this.rendererInteractive = false;
      this.applyMouse();
      this.onCardAnswer({ id: a.id, save: a.save === true, choice: typeof a.choice === 'string' ? a.choice : undefined, timeout: a.timeout === true });
    });
    this.win = win;
    this.place();
    if (this.visible) win.showInactive();
    screen.on('display-metrics-changed', this.onDisplay);
    // drop target: a click-through window never receives a drag, so while the cursor is over the pill capsule the
    // window stops being click-through (a small zone at the bottom centre) – lets audio files be dropped onto it
    if (process.platform === 'win32' && this.visible) {
      this.hoverTimer = setInterval(() => this.pollHover(), 120);
      this.hoverTimer.unref?.();
    }
  }

  private pollHover() {
    if (!this.win || this.win.isDestroyed() || !this.win.isVisible()) return;
    const b = this.win.getBounds();
    const p = screen.getCursorScreenPoint();
    const cx = b.x + b.width / 2, cy = b.y + b.height - 26;
    const w = this.last.meeting || this.last.task ? 190 : 70;
    const inside = Math.abs(p.x - cx) <= w / 2 && Math.abs(p.y - cy) <= 18;
    if (inside !== this.dropZone) { this.dropZone = inside; this.applyMouse(); }
  }

  private applyMouse() {
    if (!this.win || this.win.isDestroyed()) return;
    const on = this.rendererInteractive || this.dropZone;
    this.win.setIgnoreMouseEvents(!on, { forward: true });
  }

  /** bottom centre of the display that has the mouse cursor (bigger while the Agent-Prompt card is up – the capsule
   *  stays at the same spot: the window is centred and bottom-aligned either way) */
  place() {
    // display-metrics-changed kann nach dem Schließen der Pille noch feuern (Aufwachen, Monitorwechsel)
    if (!this.win || this.win.isDestroyed()) return;
    const d = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    const wa = d.workArea;
    const W = this.agentShown ? Math.min(PILL_AP_W, wa.width) : PILL_W;
    const Hh = this.agentShown ? Math.min(PILL_AP_H, wa.height - 6) : PILL_H;
    const x = Math.round(wa.x + (wa.width - W) / 2);
    const y = Math.round(wa.y + wa.height - Hh - 6);
    const b = this.win.getBounds();
    if (b.x !== x || b.y !== y || b.width !== W || b.height !== Hh) this.win.setBounds({ x, y, width: W, height: Hh });
  }

  private send(ch: string, p: unknown) {
    if (!this.win || this.win.isDestroyed()) return;
    if (!this.ready) { this.queue.push([ch, p]); return; }
    this.win.webContents.send(ch, p);
  }
  state(s: Partial<PillState>) {
    this.last = { ...this.last, ...s };
    const extra = !!(s.meeting || s.task || s.meetingCard);
    if (((s.mode && s.mode !== 'idle') || extra) && this.visible) { this.place(); this.win?.showInactive(); this.win?.setAlwaysOnTop(true, 'screen-saver'); }
    this.send('pill:state', this.last);
  }
  level(lv: number) { this.send('pill:level', lv); }
  /** show (or with null: remove) the question card */
  card(c: PillCard | null) {
    if (c && this.visible) { this.place(); this.win?.showInactive(); this.win?.setAlwaysOnTop(true, 'screen-saver'); }
    this.send('pill:card', c);
  }
  /** show / update (or with null: close) the Agent-Prompt card */
  agentCard(m: APCardMessage | null) {
    if (this.agentShrink) { clearTimeout(this.agentShrink); this.agentShrink = null; }
    if (m) {
      if (!this.agentShown) { this.agentShown = true; if (this.visible) { this.place(); this.win?.showInactive(); this.win?.setAlwaysOnTop(true, 'screen-saver'); } }
      this.send('pill:ap', m);
      return;
    }
    this.send('pill:ap', null);
    this.agentHover = false;
    // back to the small window after the closing animation (the card no longer needs the room)
    this.agentShrink = setTimeout(() => { this.agentShrink = null; this.agentShown = false; this.place(); }, 420);
  }
  agentFlash(f: APFlash) { this.send('pill:apFlash', f); }
  toast(text: string, kind: 'info' | 'success' | 'error' = 'info', ms = 2200) { if (this.visible) { this.place(); this.win?.showInactive(); } this.send('pill:toast', { text, kind, ms }); }
  private onDisplay = () => this.place();
  destroy() { if (this.hoverTimer) clearInterval(this.hoverTimer); screen.removeListener('display-metrics-changed', this.onDisplay); this.win?.destroy(); this.win = null; }
}

export function createHub(opts: { show: boolean; offscreen?: boolean }): BrowserWindow {
  const win = new BrowserWindow({
    width: 1080, height: 740, minWidth: 820, minHeight: 560, show: false, title: 'Flow', backgroundColor: '#0b0c0f',
    icon: paths.asset(process.platform === 'win32' ? 'icon.ico' : 'icon.png'),
    titleBarStyle: 'hidden',
    titleBarOverlay: process.platform === 'win32' ? { color: '#0c0d11', symbolColor: '#cfd2d8', height: 38 } : undefined,
    autoHideMenuBar: true,
    webPreferences: { preload: paths.preload('hub'), contextIsolation: true, sandbox: false, spellcheck: false, offscreen: opts.offscreen ?? false },
  });
  win.removeMenu();
  void win.loadFile(paths.renderer('hub', 'hub.html'));
  win.once('ready-to-show', () => { if (opts.show) win.show(); });
  // external links → default browser; never navigate the hub away
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https:\/\//.test(url)) void shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  return win;
}

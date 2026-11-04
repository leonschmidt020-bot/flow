// Pill (transparent, click-through outside the capsule, always on top, never focused) + Hub window.
// 0.4.0: like the Mac pill – hover shows the dictation language (+ ClipVault button), click = menu, right click = full
// menu, drag it anywhere (snaps to 8 spots, stored per screen, upright at the left/right edge).
import { BrowserWindow, ipcMain, screen, shell, type Display, type Menu } from 'electron';
import { paths } from './paths';
import { AP_ACTIONS, type APAction, type APCardMessage, type APFlash } from '../shared/agentPrompt';
import { displayKey, isVertical, placementCenter, placementForDrop, windowAround, type PillPlacement, type Point } from '../shared/pillPlacement';

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
  /** recording, but the mic delivers no audio yet (cold start) – dimmed bars, don't speak yet */
  micWait?: boolean;
  /** dictation language, shown on hover („Auto“ / „DE“ / „EN“) */
  lang?: string;
  /** ClipVault is on → small button next to the pill on hover */
  clipVault?: boolean;
}
export type PillClick = 'cancel' | 'stop' | 'meetingStop' | 'meetingOpen' | 'cardYes' | 'cardNo' | 'langMenu' | 'menu' | 'clipvault' | 'stopRecording';
/** where the capsule sits inside the pill window (sent to the renderer) */
export interface PillAnchor { x: number; y: number; vertical: boolean; below: boolean }
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
  /** placements per screen (settings) and how a new one is stored */
  placements: () => Record<string, PillPlacement> = () => ({});
  onPlacement: (key: string, pl: PillPlacement | null) => void = () => {};
  /** left mouse button physically down (Windows: GetAsyncKeyState) – ends a drag whose mouseup got lost */
  mouseDown: (() => boolean) | null = null;
  private center: Point = { x: 0, y: 0 };
  private anchorSent = '';
  private anchor: PillAnchor = { x: PILL_W / 2, y: PILL_H - 26, vertical: false, below: false };
  private drag: { cursor: Point; center: Point; timer: NodeJS.Timeout } | null = null;
  private menuOpen = false;

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
      win.webContents.send('pill:anchor', this.anchor);
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
    ipcMain.on('pill:dragStart', (e) => { if (e.sender === win.webContents) this.startDrag(); });
    ipcMain.on('pill:dragEnd', (e) => { if (e.sender === win.webContents) this.endDrag(); });
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
    if (this.drag) return;
    const b = this.win.getBounds();
    const p = screen.getCursorScreenPoint();
    const cx = b.x + this.anchor.x, cy = b.y + this.anchor.y;
    const restingHidden = this.last.mode === 'idle' && this.last.alwaysVisible === false && !this.last.meeting && !this.last.task && !this.last.apBusy;
    // just the capsule (a drop target needs the window to take the mouse; the renderer widens it for the hover look
    // itself – forwarded mouse moves – so clicks next to the resting pill still reach the app below)
    let w = this.last.meeting || this.last.task ? 200 : 70, hh = 36;
    if (this.anchor.vertical && !this.last.meeting && !this.last.task) [w, hh] = [hh, w];
    const inside = !restingHidden && Math.abs(p.x - cx) <= w / 2 && Math.abs(p.y - cy) <= hh / 2;
    if (inside !== this.dropZone) { this.dropZone = inside; this.applyMouse(); }
  }

  /** dragging: the window follows the cursor (main process – the renderer would lose the mouse at the window edge) */
  private startDrag() {
    if (this.drag || !this.win || this.win.isDestroyed()) return;
    const cursor = screen.getCursorScreenPoint();
    const timer = setInterval(() => this.dragTick(), 16);
    this.drag = { cursor, center: { ...this.center }, timer };
    this.rendererInteractive = true;
    this.applyMouse();
  }
  private dragTick() {
    const d = this.drag;
    if (!d || !this.win || this.win.isDestroyed()) return;
    if (this.mouseDown && !this.mouseDown()) { this.endDrag(); return; }
    const p = screen.getCursorScreenPoint();
    const c = { x: d.center.x + (p.x - d.cursor.x), y: d.center.y + (p.y - d.cursor.y) };
    const disp = screen.getDisplayNearestPoint(p);
    this.layoutAt(c, disp.workArea);
  }
  private endDrag() {
    const d = this.drag;
    if (!d) return;
    clearInterval(d.timer);
    this.drag = null;
    const disp = screen.getDisplayNearestPoint(this.center);
    this.onPlacement(displayKey(disp), placementForDrop(this.center, disp.workArea));
    this.rendererInteractive = false;
    this.applyMouse();
    this.place();
  }
  get dragging() { return !!this.drag; }

  /** show a native menu at the capsule; the window stays interactive while it is open */
  popup(menu: Menu) {
    if (!this.win || this.win.isDestroyed()) return;
    this.menuOpen = true;
    this.applyMouse();
    const x = Math.max(0, Math.round(this.anchor.x - 40)), y = Math.round(this.anchor.below ? this.anchor.y + 18 : this.anchor.y - 14);
    menu.popup({
      window: this.win, x, y,
      callback: () => { this.menuOpen = false; this.rendererInteractive = false; this.applyMouse(); this.send('pill:menuClosed', null); },
    });
  }

  private applyMouse() {
    if (!this.win || this.win.isDestroyed()) return;
    const on = this.rendererInteractive || this.dropZone || this.menuOpen || !!this.drag;
    this.win.setIgnoreMouseEvents(!on, { forward: true });
  }

  /** the display that has the mouse cursor, at the pill's spot stored for that display (default: bottom centre).
   *  Bigger while the Agent-Prompt card is up – the capsule stays at the same spot. */
  place() {
    // display-metrics-changed kann nach dem Schließen der Pille noch feuern (Aufwachen, Monitorwechsel)
    if (!this.win || this.win.isDestroyed() || this.drag) return;
    const d: Display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    const wa = d.workArea;
    this.layoutAt(placementCenter(this.placements()[displayKey(d)], wa), wa);
  }

  private layoutAt(c: Point, wa: { x: number; y: number; width: number; height: number }) {
    if (!this.win || this.win.isDestroyed()) return;
    const W = this.agentShown ? Math.min(PILL_AP_W, wa.width) : PILL_W;
    const Hh = this.agentShown ? Math.min(PILL_AP_H, wa.height - 6) : PILL_H;
    const g = windowAround(c, W, Hh, wa);
    this.center = c;
    this.anchor = { x: g.ax, y: g.ay, vertical: isVertical(c, wa), below: g.below };
    const b = this.win.getBounds();
    if (b.x !== g.x || b.y !== g.y || b.width !== W || b.height !== Hh) this.win.setBounds({ x: g.x, y: g.y, width: W, height: Hh });
    const key = JSON.stringify(this.anchor);
    if (key !== this.anchorSent) { this.anchorSent = key; this.send('pill:anchor', this.anchor); }
  }

  /** placement reset (tray / hub): back to the bottom centre on every screen */
  resetPlacement() { this.onPlacement('*', null); this.place(); }

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
  destroy() { if (this.drag) clearInterval(this.drag.timer); this.drag = null; if (this.hoverTimer) clearInterval(this.hoverTimer); screen.removeListener('display-metrics-changed', this.onDisplay); this.win?.destroy(); this.win = null; }
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

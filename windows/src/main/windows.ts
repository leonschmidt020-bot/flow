// Pill (transparent, click-through, always on top, never focused) + Hub window.
import { BrowserWindow, ipcMain, screen, shell } from 'electron';
import { paths } from './paths';

export type PillMode = 'idle' | 'recording' | 'handsfree' | 'transcribing' | 'loading' | 'hidden';
export interface PillState {
  mode: PillMode; progress?: number; label?: string; alwaysVisible?: boolean;
  /** notetaker (src/meeting): shown while the dictation pill rests (mode idle) */
  meeting?: { startedAt: number; label: string } | null;
  task?: { label: string; progress: number } | null;
  card?: { kind: string; title: string; sub: string; yes: string; no: string } | null;
}
export type PillClick = 'cancel' | 'stop' | 'meetingStop' | 'meetingOpen' | 'cardYes' | 'cardNo';

const PILL_W = 460, PILL_H = 150;

export class Pill {
  win: BrowserWindow | null = null;
  private last: PillState = { mode: 'idle', alwaysVisible: true };
  private ready = false;
  private queue: [string, unknown][] = [];
  onClick: (what: PillClick) => void = () => {};
  /** files dropped onto the pill (audio import) */
  onDrop: (files: string[]) => void = () => {};
  private rendererInteractive = false;
  private dropZone = false;
  private hoverTimer: NodeJS.Timeout | null = null;
  /** false in self-tests: never put anything on the screen */
  visible = true;

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

  /** bottom centre of the display that has the mouse cursor */
  place() {
    // display-metrics-changed kann nach dem Schließen der Pille noch feuern (Aufwachen, Monitorwechsel)
    if (!this.win || this.win.isDestroyed()) return;
    const d = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    const wa = d.workArea;
    const x = Math.round(wa.x + (wa.width - PILL_W) / 2);
    const y = Math.round(wa.y + wa.height - PILL_H - 6);
    this.win.setBounds({ x, y, width: PILL_W, height: PILL_H });
  }

  private send(ch: string, p: unknown) {
    if (!this.win || this.win.isDestroyed()) return;
    if (!this.ready) { this.queue.push([ch, p]); return; }
    this.win.webContents.send(ch, p);
  }
  state(s: Partial<PillState>) {
    this.last = { ...this.last, ...s };
    const extra = !!(s.meeting || s.task || s.card);
    if (((s.mode && s.mode !== 'idle') || extra) && this.visible) { this.place(); this.win?.showInactive(); this.win?.setAlwaysOnTop(true, 'screen-saver'); }
    this.send('pill:state', this.last);
  }
  level(lv: number) { this.send('pill:level', lv); }
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

// The quick panel: a compact dark-glass window next to the cursor (Ctrl+Shift+V).
import { BrowserWindow, screen } from 'electron';
import * as path from 'node:path';
import type { Platform, WindowRef } from '../platform/types';

export const PANEL_W = 780;
export const PANEL_H = 520;

export interface PanelOptions {
  platform: Platform;
  preload: string;
  html: string;
  locale: 'de' | 'en';
  log: (...a: unknown[]) => void;
}

export class PanelWindow {
  win: BrowserWindow | null = null;
  private prevForeground: WindowRef | null = null;
  private normalBounds: Electron.Rectangle | null = null;
  /** a native dialog (Save as …) is open – don't hide on blur */
  modal = false;

  constructor(private o: PanelOptions) {}

  private material(): 'acrylic' | 'none' {
    if (process.platform !== 'win32') return 'none';
    const [maj, , build] = (process.getSystemVersion?.() ?? '0.0.0').split('.').map(Number);
    return (maj ?? 0) >= 10 && (build ?? 0) >= 22621 ? 'acrylic' : 'none'; // Windows 11 22H2+
  }

  private create(): BrowserWindow {
    const material = this.material();
    const win = new BrowserWindow({
      width: PANEL_W, height: PANEL_H, show: false, frame: false, resizable: false, maximizable: false, minimizable: false,
      fullscreenable: false, skipTaskbar: true, alwaysOnTop: true, hasShadow: true,
      ...(process.platform === 'win32'
        ? { backgroundMaterial: material, backgroundColor: material === 'acrylic' ? '#00000000' : '#16171b', roundedCorners: true }
        : { transparent: true, backgroundColor: '#00000000', vibrancy: 'hud' as const, visualEffectState: 'active' as const }),
      webPreferences: { preload: this.o.preload, contextIsolation: true, sandbox: false, nodeIntegration: false, spellcheck: false, backgroundThrottling: false },
    });
    win.setAlwaysOnTop(true, 'pop-up-menu');
    win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    win.webContents.on('will-navigate', (e) => e.preventDefault());
    win.on('blur', () => { if (!this.modal && !win.webContents.isDevToolsOpened()) this.hide(false); });
    win.on('closed', () => { this.win = null; });
    void win.loadFile(this.o.html, { query: { locale: this.o.locale, material: material === 'acrylic' ? 'acrylic' : process.platform === 'darwin' ? 'vibrancy' : 'solid' } });
    return win;
  }

  get visible() { return !!this.win && this.win.isVisible(); }

  show(view?: string) {
    this.prevForeground = this.o.platform.foregroundWindow();
    if (!this.win) this.win = this.create();
    const win = this.win;
    this.normalBounds = null;
    const cur = screen.getCursorScreenPoint();
    const wa = screen.getDisplayNearestPoint(cur).workArea;
    let x = cur.x - 48, y = cur.y + 18;
    if (y + PANEL_H > wa.y + wa.height) y = cur.y - PANEL_H - 12;
    x = Math.min(Math.max(wa.x + 8, x), wa.x + wa.width - PANEL_W - 8);
    y = Math.min(Math.max(wa.y + 8, y), wa.y + wa.height - PANEL_H - 8);
    win.setBounds({ x: Math.round(x), y: Math.round(y), width: PANEL_W, height: PANEL_H });
    const reveal = () => {
      win.show();
      win.focus();
      win.webContents.send('clipvault:event', 'panel:shown', { view: view ?? null });
    };
    if (win.webContents.isLoading()) win.webContents.once('did-finish-load', reveal); else reveal();
  }

  toggle() { if (this.visible) this.hide(true); else this.show(); }

  /** hide; `restoreFocus` gives the focus back to the window that had it before */
  hide(restoreFocus: boolean) {
    if (!this.win || !this.win.isVisible()) return;
    this.setViewer(false);
    this.win.hide();
    if (restoreFocus && this.prevForeground) this.o.platform.restoreForeground(this.prevForeground);
  }

  /** hide, give focus back, then Ctrl+V. Returns false where auto-paste isn't available. */
  async pasteIntoPrevious(): Promise<boolean> {
    const prev = this.prevForeground;
    if (!this.win) return false;
    this.setViewer(false);
    this.win.hide();
    if (!prev || !this.o.platform.restoreForeground(prev)) return false;
    await new Promise((r) => setTimeout(r, 70)); // let the target window take focus
    return this.o.platform.sendPaste();
  }

  /** big image viewer: grow the panel to ~80 % of the screen, and back */
  setViewer(on: boolean) {
    const win = this.win;
    if (!win) return;
    if (on && !this.normalBounds) {
      this.normalBounds = win.getBounds();
      const wa = screen.getDisplayMatching(this.normalBounds).workArea;
      const w = Math.round(wa.width * 0.82), h = Math.round(wa.height * 0.84);
      win.setBounds({ x: wa.x + Math.round((wa.width - w) / 2), y: wa.y + Math.round((wa.height - h) / 2), width: w, height: h }, true);
    } else if (!on && this.normalBounds) {
      win.setBounds(this.normalBounds, true);
      this.normalBounds = null;
    }
  }

  nativeHandle(): WindowRef | null {
    if (!this.win) return null;
    const b = this.win.getNativeWindowHandle();
    return b.length >= 8 ? b.readBigInt64LE(0) : b.readInt32LE(0);
  }

  destroy() {
    if (this.win && !this.win.isDestroyed()) this.win.destroy();
    this.win = null;
  }

  static htmlPath(baseDir: string) { return path.join(baseDir, 'clipvault', 'ui', 'panel.html'); }
  static preloadPath(baseDir: string) { return path.join(baseDir, 'clipvault', 'preload.js'); }
}

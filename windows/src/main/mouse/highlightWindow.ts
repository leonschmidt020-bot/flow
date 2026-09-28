// The blue frame „Text kommt hierher“: a transparent, click-through, topmost, frameless window laid over the target
// window while the user speaks. Never focusable, never in the taskbar, invisible to the target search (own pid).
import { BrowserWindow } from 'electron';
import { paths } from '../paths';
import type { Rect } from '../../core/mouseTarget';
import type { HighlightPort } from './mouseTarget';

/** the frame is drawn 2 DIP outside the window so it does not cover the window's own border */
export const FRAME_OUTSET = 2;

export class HighlightWindow implements HighlightPort {
  private win: BrowserWindow | null = null;
  private label = '';
  private visible = false;

  private ensure(label: string): BrowserWindow {
    if (this.win && !this.win.isDestroyed()) {
      if (label !== this.label) { this.label = label; void this.win.loadFile(paths.renderer('highlight', 'highlight.html'), { query: { label } }); }
      return this.win;
    }
    const win = new BrowserWindow({
      width: 400, height: 300, show: false, frame: false, transparent: true, resizable: false, movable: false, minimizable: false,
      maximizable: false, fullscreenable: false, skipTaskbar: true, focusable: false, hasShadow: false, alwaysOnTop: true,
      backgroundColor: '#00000000', type: process.platform === 'win32' ? 'toolbar' : undefined,
      webPreferences: { contextIsolation: true, sandbox: true, backgroundThrottling: false },
    });
    win.setIgnoreMouseEvents(true);
    win.setAlwaysOnTop(true, 'floating');
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    this.label = label;
    void win.loadFile(paths.renderer('highlight', 'highlight.html'), { query: { label } });
    this.win = win;
    return win;
  }

  show(r: Rect, label: string): void {
    const win = this.ensure(label);
    win.setBounds({ x: Math.round(r.x - FRAME_OUTSET), y: Math.round(r.y - FRAME_OUTSET), width: Math.round(r.width + 2 * FRAME_OUTSET), height: Math.round(r.height + 2 * FRAME_OUTSET) });
    if (!this.visible) { win.showInactive(); this.visible = true; }
  }

  hide(): void {
    if (!this.visible || !this.win || this.win.isDestroyed()) { this.visible = false; return; }
    this.win.hide();
    this.visible = false;
  }

  destroy(): void { this.win?.destroy(); this.win = null; this.visible = false; }
}

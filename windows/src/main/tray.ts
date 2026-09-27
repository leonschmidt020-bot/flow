import { Menu, Tray, nativeImage } from 'electron';
import { paths } from './paths';
import { t, hotkeyShort, type Locale } from '../shared/i18n';

export interface TrayActions { openHub(): void; openClipVault(): void; togglePause(): void; checkUpdates(): void; quit(): void }

export class FlowTray {
  private tray: Tray | null = null;
  constructor(private a: TrayActions) {}
  create() {
    if (process.platform === 'win32') {
      // multi-size .ico: Windows picks the right size for the taskbar DPI
      this.tray = new Tray(paths.asset('icon.ico'));
    } else {
      const img = nativeImage.createFromPath(paths.asset('tray.png'));
      this.tray = new Tray(img.isEmpty() ? nativeImage.createEmpty() : img.resize({ width: 16, height: 16 }));
    }
    this.tray.setToolTip('Flow');
    this.tray.on('click', () => this.a.openHub());
  }
  update(locale: Locale, hotkey: string, paused: boolean) {
    if (!this.tray) return;
    this.tray.setContextMenu(Menu.buildFromTemplate([
      { label: t(locale, 'trayOpen'), click: () => this.a.openHub() },
      { label: t(locale, 'trayClipVault'), click: () => this.a.openClipVault() },
      { type: 'separator' },
      { label: t(locale, 'trayHotkey', { hotkey: hotkeyShort(locale, hotkey) }), enabled: false },
      { label: paused ? t(locale, 'resume') : t(locale, 'pause'), click: () => this.a.togglePause() },
      { label: t(locale, 'checkUpdates'), click: () => this.a.checkUpdates() },
      { type: 'separator' },
      { label: t(locale, 'trayQuit'), click: () => this.a.quit() },
    ]));
    this.tray.setToolTip(paused ? `Flow – ${t(locale, 'toastPaused')}` : `Flow – ${t(locale, 'trayHotkey', { hotkey: hotkeyShort(locale, hotkey) })}`);
  }
  destroy() { this.tray?.destroy(); this.tray = null; }
}

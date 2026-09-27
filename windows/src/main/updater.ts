// Updates from GitHub Releases (electron-updater). Source configured once in release.config.json.
import { app } from 'electron';
import { RELEASE } from './config';
import { log } from './log';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let updater: any = null;

export function initUpdater(onDownloaded: () => void) {
  if (!app.isPackaged) return;
  try {

    updater = require('electron-updater').autoUpdater;
    updater.setFeedURL({ provider: 'github', owner: RELEASE.owner, repo: RELEASE.repo });
    updater.autoDownload = true;
    updater.autoInstallOnAppQuit = true;
    updater.logger = { info: (m: unknown) => log('update', m), warn: (m: unknown) => log('update warn', m), error: (m: unknown) => log('update error', m), debug: () => {} };
    updater.on('update-downloaded', () => onDownloaded());
    updater.on('error', (e: Error) => log('update error', e.message));
  } catch (e) {
    log('updater unavailable', e);
  }
}

export async function checkForUpdates(): Promise<void> {
  if (!updater) return;
  try { await updater.checkForUpdates(); } catch (e) { log('update check failed', e); }
}

export function scheduleUpdates(enabled: () => boolean) {
  if (!updater) return;
  const tick = () => { if (enabled()) void checkForUpdates(); };
  setTimeout(tick, 20_000);
  setInterval(tick, 6 * 3600_000).unref();
}

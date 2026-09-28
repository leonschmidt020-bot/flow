import { app } from 'electron';
import path from 'node:path';

export const paths = {
  get userData() { return app.getPath('userData'); },
  get settings() { return path.join(app.getPath('userData'), 'settings.json'); },
  get history() { return path.join(app.getPath('userData'), 'history.json'); },
  get models() { return process.env.FLOW_MODEL_DIR ?? path.join(app.getPath('userData'), 'models'); },
  get logs() { return path.join(app.getPath('userData'), 'logs'); },
  /** dist/ (bundled main lives in dist/main.js) */
  get dist() { return __dirname; },
  asset(name: string) { return path.join(__dirname, 'assets', name); },
  renderer(...p: string[]) { return path.join(__dirname, 'renderer', ...p); },
  preload(name: string) { return path.join(__dirname, 'preload', name + '.js'); },
  /** files that external programs read (powershell.exe) – outside the asar in packaged builds */
  helper(name: string) { return path.join(__dirname.replace(/app\.asar(?=[\\/]|$)/u, 'app.asar.unpacked'), 'helpers', name); },
};

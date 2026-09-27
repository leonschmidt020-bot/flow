// settings.json in <userData>/clipvault/ – small, plain (no secrets in here).
import * as path from 'node:path';
import { readFileOrNull, writeFileAtomic } from './atomic';

export interface Settings {
  /** DPAPI for index.json + shared.json (Windows only) */
  encryptAtRest: boolean;
  skipPasswordLike: boolean;
  /** executable names whose copies are never stored */
  ignoredApps: string[];
  maxAgeDays: number;
  maxItems: number;
  quotaMB: number;
  hotkey: string;
  /** Enter pastes into the previous window (false = Enter only copies) */
  pasteOnEnter: boolean;
  paused: boolean;
  sync: { enabled: boolean; name: string };
}

export const DEFAULT_SETTINGS: Settings = {
  encryptAtRest: false,
  skipPasswordLike: true,
  ignoredApps: [],
  maxAgeDays: 2,
  maxItems: 200,
  quotaMB: 1024,
  hotkey: 'Control+Shift+V',
  pasteOnEnter: true,
  paused: false,
  sync: { enabled: false, name: '' },
};

const clamp = (n: unknown, lo: number, hi: number, d: number) => (typeof n === 'number' && Number.isFinite(n) ? Math.min(hi, Math.max(lo, Math.round(n))) : d);

export function sanitizeSettings(raw: unknown): Settings {
  const o = (raw && typeof raw === 'object' ? raw : {}) as Partial<Settings>;
  const d = DEFAULT_SETTINGS;
  return {
    encryptAtRest: typeof o.encryptAtRest === 'boolean' ? o.encryptAtRest : d.encryptAtRest,
    skipPasswordLike: typeof o.skipPasswordLike === 'boolean' ? o.skipPasswordLike : d.skipPasswordLike,
    ignoredApps: Array.isArray(o.ignoredApps) ? o.ignoredApps.filter((x): x is string => typeof x === 'string').slice(0, 50) : [],
    maxAgeDays: clamp(o.maxAgeDays, 1, 30, d.maxAgeDays),
    maxItems: clamp(o.maxItems, 20, 2000, d.maxItems),
    quotaMB: clamp(o.quotaMB, 50, 20_000, d.quotaMB),
    hotkey: typeof o.hotkey === 'string' && o.hotkey.length < 40 ? o.hotkey : d.hotkey,
    pasteOnEnter: typeof o.pasteOnEnter === 'boolean' ? o.pasteOnEnter : d.pasteOnEnter,
    paused: typeof o.paused === 'boolean' ? o.paused : d.paused,
    sync: {
      enabled: typeof o.sync?.enabled === 'boolean' ? o.sync.enabled : false,
      name: typeof o.sync?.name === 'string' ? o.sync.name.slice(0, 40) : '',
    },
  };
}

export function loadSettings(dir: string): Settings {
  const raw = readFileOrNull(path.join(dir, 'settings.json'));
  try { return sanitizeSettings(raw ? JSON.parse(raw.toString('utf8')) : {}); } catch { return sanitizeSettings({}); }
}

export function saveSettings(dir: string, s: Settings): void {
  writeFileAtomic(path.join(dir, 'settings.json'), JSON.stringify(s, null, 1));
}

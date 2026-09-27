// Demo data for offscreen render checks (no personal data).
import type { HubState } from '../../shared/hubState';
import { DEFAULTS } from '../../shared/settings';

export function demoState(kind: string, lang: 'de' | 'en' = 'de'): HubState {
  const now = Date.now();
  const at = (minAgo: number) => new Date(now - minAgo * 60_000).toISOString();
  const history = kind === 'empty' || kind === 'missing' ? [] : [
    { id: '1', date: at(3), text: 'Hallo zusammen, das Meeting ist morgen um zehn Uhr im großen Besprechungsraum. Bitte bringt eure Zahlen fürs dritte Quartal mit.', app: 'OUTLOOK.EXE', words: 24, durationSec: 7.1 },
    { id: '2', date: at(18), text: 'Einkaufen:\n- Milch\n- Brot\n- Eier\n- Butter', app: 'Obsidian.exe', words: 5, durationSec: 3.4 },
    { id: '3', date: at(46), text: 'Can you send me the latest version of the report before the end of the day?', app: 'slack.exe', words: 15, durationSec: 4.2 },
    { id: '4', date: at(60 * 26), text: 'Wir treffen uns am Freitag im Park und bringen Kuchen, Kaffee und ein paar Decken mit.', app: 'WhatsApp.exe', words: 16, durationSec: 5.0 },
    { id: '5', date: at(60 * 27), text: 'Neuer Absatz: Die Website ist fast fertig. Nächste Woche testen wir alles auf Handys und Tablets.', app: 'WINWORD.EXE', words: 16, durationSec: 6.3 },
  ];
  const status = kind === 'download' ? 'downloading' : kind === 'missing' ? 'missing' : 'ready';
  return {
    settings: {
      ...DEFAULTS, onboardingDone: true, locale: lang,
      dictionary: kind === 'empty' ? [] : [{ heard: 'clip vault', write: 'ClipVault' }, { heard: 'para keet', write: 'Parakeet' }, { heard: 'github', write: 'GitHub' }, { heard: 'k i', write: 'KI' }],
    },
    history,
    totalDictations: history.length ? 128 : 0,
    wordsToday: history.length ? 60 : 0,
    wordsTotal: history.length ? 18432 : 0,
    asr: { model: 'parakeet-v3', status, progress: status === 'downloading' ? 0.42 : 1, bytesPerSec: 23.4e6, error: '', installed: { 'parakeet-v3': status === 'ready', 'whisper-turbo': false } },
    micError: kind === 'micerror' ? 'NotAllowedError' : '',
    version: '0.1.0', platform: 'win32', paused: false, hotkeysDisabled: false,
  };
}

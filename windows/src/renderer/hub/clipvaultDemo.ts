// Render check only: a few fake ClipVault items so the Hub page has something to show (never used in the app).
import type { ItemView } from '../../clipvault/core/types';
import type { ListResult } from '../../clipvault/core/view';

export function demoClipVault(loc: 'de' | 'en'): (name: string, ...a: unknown[]) => Promise<unknown> {
  const now = Date.now() / 1000;
  const de = loc === 'de';
  const mk = (id: string, title: string, sub: string, ago: number, o: Partial<ItemView> = {}): ItemView => ({
    id, kind: 'text', isLink: false, title, subtitle: sub, badges: [], ts: now - ago, pinned: false, collection: null, masked: false, shared: false, source: null, text: title, ...o,
  });
  const items: ItemView[] = [
    mk('p1', de ? 'Lieferadresse: Lindenstraße 4, 32756 Detmold' : 'Delivery address: 4 Linden Street', 'Notepad', 86400 * 3, { pinned: true }),
    mk('a', 'https://github.com/leonschmidt020-bot/flow/releases', 'Edge', 120, { isLink: true, badges: ['link'], source: 'msedge.exe' }),
    mk('b', de ? 'Treffen am Freitag um 18 Uhr im Park – Kuchen und Decken mitbringen.' : 'Friday 6 pm in the park – bring cake and blankets.', 'WhatsApp', 600),
    mk('c', 'npm run build && npm test', 'Windows Terminal', 1500, { badges: ['code'] }),
    mk('d', de ? 'Hallo zusammen, das Meeting ist morgen um zehn Uhr im großen Besprechungsraum.' : 'Hi all, the meeting is tomorrow at ten in the big room.', 'Outlook', 3600, { shared: true }),
    mk('e', '#8C5CCC', 'Figma', 5400, { badges: ['color'], color: '#8C5CCC' }),
    mk('f', de ? 'Rechnung_November.pdf' : 'Invoice_November.pdf', de ? 'Datei · 214 KB' : 'File · 214 KB', 86400 + 300, { kind: 'file', fileNames: ['Rechnung_November.pdf'] }),
  ];
  const list: ListResult = {
    sections: [{ key: 'pinned', items: items.slice(0, 1) }, { key: 'today', items: items.slice(1, 6) }, { key: 'yesterday', items: items.slice(6) }],
    counts: { all: 7, text: 5, links: 1, images: 0, files: 1 },
    collections: [{ id: 'c1', name: de ? 'Arbeit' : 'Work', symbol: 'briefcase', count: 3, secret: false }, { id: 'c2', name: de ? 'Passwörter' : 'Passwords', symbol: 'lock', count: 2, secret: true }],
    historyCount: 7, total: 7,
  };
  const q = new URLSearchParams(location.search);
  const sync = q.get('sync') ?? 'connected';
  const sh = (id: string, by: string, text: string, ago: number, o: Partial<ItemView> = {}): ItemView =>
    mk(id, text, by, ago, { collection: '__shared__', shared: true, source: by, ...o });
  const sharedItems: ItemView[] = [
    sh('s1', 'Lena', de ? 'Kannst du mir bis Freitag die Busangebote schicken? Dann entscheiden wir am Wochenende.' : 'Can you send me the bus quotes by Friday? Then we decide on the weekend.', 300),
    sh('s2', 'Nico', '# Flow-Fehlerbericht · Flow 0.6.0 · 0 Probleme', 1900),
    sh('s3', 'Sam', 'https://github.com/leonschmidt020-bot/flow', 4000, { isLink: true, badges: ['link'] }),
    sh('s4', 'Lena', de ? 'Treffpunkt Samstag 9:30 am Gemeindehaus' : 'Meeting point Saturday 9:30 at the hall', 7200),
    sh('s5', 'Nico', de ? 'Präsentation_final.pdf' : 'Presentation_final.pdf', 86400 + 600, { kind: 'file', fileNames: ['Präsentation_final.pdf'], subtitle: 'Nico · 2.4 MB' }),
  ];
  const settings = {
    encryptAtRest: false, skipPasswordLike: true, ignoredApps: ['KeePass.exe'], maxAgeDays: 2, maxItems: 200, quotaMB: 1024,
    hotkey: 'Control+Shift+V', pasteOnEnter: true, paused: false, sync: { enabled: sync !== 'off', name: 'Sam' },
    dpapiAvailable: true, platform: 'win32', readOnly: false, recovery: '',
  };
  const syncView = sync === 'connected' ? { state: 'connected', paired: true, queue: 0, host: 'clipvault-sync.workers.dev' }
    : sync === 'code' ? { state: 'connected', paired: true, queue: 0, host: 'clipvault-sync.workers.dev', pairingCode: 'cvpair1.' + 'DEMO-nur-zum-Ansehen-'.repeat(5) + 'kein-echter-Code' }
    : sync === 'off' ? { state: 'off' } : { state: 'unconfigured', paired: false };
  return async (name, ...a) => {
    if (name === 'list') {
      const arg = (a[0] ?? {}) as { collection?: string | null; type?: string };
      if (arg.collection === '__shared__') return { ...list, sections: [{ key: 'shared', items: sync === 'connected' || sync === 'code' ? sharedItems : [] }] };
      if (arg.type && arg.type !== 'all') {
        const f = (i: ItemView) => arg.type === 'links' ? i.isLink : arg.type === 'files' ? i.kind === 'file' : arg.type === 'images' ? i.kind === 'image' : i.kind === 'text' && !i.isLink;
        return { ...list, sections: list.sections.map((x) => ({ ...x, items: x.items.filter(f) })).filter((x) => x.items.length) };
      }
      return list;
    }
    if (name === 'item') return [...items, ...sharedItems].find((x) => x.id === a[0]) ?? null;
    if (name === 'syncStatus') return syncView;
    if (name === 'settings') return settings;
    return null;
  };
}

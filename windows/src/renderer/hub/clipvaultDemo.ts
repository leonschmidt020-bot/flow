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
  return async (name, ...a) => {
    if (name === 'list') return list;
    if (name === 'item') return items.find((x) => x.id === a[0]) ?? null;
    if (name === 'syncStatus') return { state: 'connected', paired: true, queue: 0 };
    return null;
  };
}

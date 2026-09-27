// Electron clipboard → ClipboardPort. Electron ≥ 40 has the async W3C-style API (ClipboardItem):
// every MIME type the platform exposes (text, HTML, RTF, PNG, …) is saved and written back.
import { clipboard, ClipboardItem } from 'electron';
import type { ClipboardPort, ClipSnapshot } from './insert/inserter';

type Saved = { type: string; data: Blob | string }[];

export const electronClipboard: ClipboardPort = {
  async snapshot(): Promise<ClipSnapshot> {
    const saved: Saved = [];
    let text = '';
    try {
      const items = await clipboard.read();
      for (const item of items) {
        for (const type of item.types) {
          try {
            const v = await item.getType(type);
            if (v instanceof Blob) saved.push({ type, data: v });
          } catch { /* format vanished */ }
        }
      }
      text = await clipboard.readText();
    } catch { /* empty clipboard */ }
    return { text, formats: { saved } };
  },
  async restore(s) {
    const saved = (s.formats.saved as Saved | undefined) ?? [];
    if (saved.length === 0) { clipboard.clear(); return; }
    const rec: Record<string, Blob | string> = {};
    for (const x of saved) rec[x.type] = x.data;
    try {
      await clipboard.write([new ClipboardItem(rec)]);
    } catch {
      // some raw formats cannot be written back → at least restore the text
      if (s.text) await clipboard.writeText(s.text); else clipboard.clear();
    }
  },
  async writeText(t) { await clipboard.writeText(t); },
  async readText() { return clipboard.readText(); },
};

/** in-memory clipboard for non-Windows dev runs – Flow never touches the real clipboard there */
export function memoryClipboard(): ClipboardPort {
  let text = '';
  return { snapshot: () => ({ text, formats: {} }), restore: (s) => { text = s.text; }, writeText: (t) => { text = t; }, readText: () => text };
}

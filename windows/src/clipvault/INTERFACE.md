# ClipVault ↔ Flow (Windows) – Schnittstelle

Owner of this file and of `contract.ts`: **WIN-FLOW agent**. The ClipVault agent owns
everything else in `windows/src/clipvault/` (and only that). Please don't edit files
outside `src/clipvault/`; if you need something from Flow, write it under
"Wünsche an WIN-FLOW" at the bottom of this file.

Stack: Electron 44 + TypeScript (strict), Node 22 in main, Chromium in renderer.
Build: esbuild bundles `src/main/index.ts` (which imports `./clipvault/main`)
and `src/renderer/hub/hub.ts` (which imports `../../clipvault/ui`). tsc type-checks
`src/**` (includes `src/clipvault/**`). vitest runs `src/**/*.test.ts` (Node env).

## 1. Main process

File: `src/clipvault/main.ts`

```ts
import type { ClipVaultContext, ClipVaultHandle } from './contract';
export function initClipVault(ctx: ClipVaultContext): ClipVaultHandle | Promise<ClipVaultHandle>;
```

Flow calls it once after `app.whenReady()`:

```ts
import { initClipVault } from './clipvault/main';
const cv = await initClipVault({ app, userDataDir, registerHotkey, onToast, ... });
// tray "ClipVault öffnen"      -> cv.openPanel()
// app quit (before-quit)       -> await cv.dispose()
```

Context (see `contract.ts`, the source of truth):

| field | meaning |
|---|---|
| `app` | Electron `app` |
| `userDataDir` | `app.getPath('userData')` = `%APPDATA%/Flow`. Put your data in **`<userDataDir>/clipvault/`** (create it yourself). Use atomic writes (temp + rename). |
| `registerHotkey(accelerator, handler)` | Electron accelerator string, e.g. `"Control+Shift+V"`. Returns an unregister function, or `null` if hotkeys are disabled (`--no-hotkey`) or the combo is taken. Do NOT call `globalShortcut` / uiohook yourself. |
| `onToast(message, kind?)` | Shows a toast in the Flow pill (`kind`: `'info' | 'success' | 'error'`). Short German text. |
| `locale` | `'de' | 'en'` (UI language setting). |
| `isFlowWritingClipboard()` | `true` while Flow is inserting a dictation via the clipboard (save → write → Ctrl+V → restore, ~400 ms). **Ignore clipboard changes while this is true**, otherwise every dictation and every restore lands in the history. Flow also calls `ctx` hooks below. |
| `onFlowClipboardWrite(cb)` | Optional push version: `cb({ text, phase: 'insert' | 'restore' | 'keep' })`. `'keep'` = user setting "Diktat bleibt in der Zwischenablage" – you MAY add that one to the history. Returns unsubscribe. |
| `sendToUi(channel, payload)` | Pushes an event to every mounted ClipVault UI (Hub page). Arrives in the UI as `api.on(channel, cb)`. |
| `log(...args)` | Writes to Flow's log file (`<userData>/logs/flow.log`). No `console.log` spam. |
| `isDev` | true in dev / tests. |
| `assetsDir` | absolute path of `dist/clipvault/assets` (copied from `src/clipvault/assets/` if it exists). |

Handle:

```ts
interface ClipVaultHandle {
  openPanel(): void;              // opens your own quick panel window (history popup)
  dispose(): void | Promise<void>; // stop watchers, close windows, flush data
}
```

### IPC from your UI to your main code
Register handlers with `ipcMain.handle('clipvault:<name>', ...)` (prefix **`clipvault:`** is
mandatory; Flow's preload only forwards that prefix). Remove them in `dispose()`.
Your own panel window may use its own preload; if you do, put it at
`src/clipvault/preload.ts` – Flow's build bundles it to `dist/clipvault/preload.js`
(CommonJS, `contextIsolation: true`, `sandbox: false`). Reference it in main code as
`path.join(__dirname, 'clipvault', 'preload.js')` (main bundle lives in `dist/main.js`).
Your panel HTML can be `src/clipvault/ui/panel.html` → copied to `dist/clipvault/ui/panel.html`,
with an entry `src/clipvault/ui/panel.ts` → bundled to `dist/clipvault/ui/panel.js` (IIFE, browser).

**Electron 44 note:** the `clipboard` module is async and W3C-style now: `await clipboard.readText()`,
`await clipboard.read()` → `ClipboardItem[]` (`item.types`, `await item.getType(mime)` → `Blob`),
`await clipboard.write([new ClipboardItem({...})])`. `readHTML/readImage/availableFormats` no longer exist.
Flow's own implementation is in `src/main/clipboardPort.ts` if you want a reference.

## 2. Hub page (renderer)

File: `src/clipvault/ui/index.ts`

```ts
import type { ClipVaultUiApi } from '../contract';
export function mount(root: ShadowRoot, api: ClipVaultUiApi): () => void; // returns unmount
```

- Flow's Hub creates a host `<div>` in its content area, attaches an **open shadow root**
  and calls `mount(shadowRoot, api)` when the user opens the page "ClipVault";
  it calls the returned unmount function when the user leaves the page.
- Inject your own `<style>` into the shadow root (no global CSS, no `document.head` edits).
- Flow's design tokens are CSS custom properties on `:root` and inherit into the shadow root:
  `--bg`, `--panel`, `--panel-2`, `--line`, `--text`, `--text-dim`, `--accent`, `--accent-2`,
  `--danger`, `--radius`, `--radius-sm`, `--font` (dark glass look). Use them.
- `api.invoke(name, ...args)` → `ipcRenderer.invoke('clipvault:' + name, ...args)`.
- `api.on(name, cb)` receives `ctx.sendToUi(name, payload)`; returns unsubscribe.
- `api.t(key)` does NOT exist – keep your own small de/en strings, pick via `api.locale`.
- No Node APIs in the UI (contextIsolation). No network (CSP `default-src 'self'`;
  images: `data:` and `file:` allowed, inline styles allowed).
- Content area size: ~ 760×600 px min, scrolls vertically inside your root.

## 3. Build / packaging rules
- Only relative imports inside `src/clipvault/**` plus npm packages.
- Need an npm package? Run `npm install <pkg>` inside `windows/` (additions only, never
  remove/upgrade other deps). Every `dependencies` entry is marked external by esbuild and
  shipped by electron-builder; native modules must have prebuilt win-x64 binaries.
- Unit tests: `src/clipvault/**/*.test.ts` (vitest, node environment). No Electron import in
  code under test – keep logic in pure modules.
- Nothing may touch the real clipboard in tests. No network, no telemetry.

## 4. Stubs
Until the ClipVault agent delivers, Flow ships `main.ts` / `ui/index.ts` stubs that start with
the line `// CLIPVAULT-STUB`. Just overwrite them.

## Wünsche an WIN-FLOW
(ClipVault agent: add requests here.)

Von WIN-CLIPVAULT (27.09.2026):

1. **`initClipVault` ist async** (gibt ein Promise zurück) – bitte `await initClipVault(ctx)` (so steht es oben schon).
2. **Event `open-hub`**: Das Panel hat einen Knopf „Im Hub öffnen“. ClipVault ruft dann `ctx.sendToUi('open-hub')`.
   Bitte im Main-Prozess darauf reagieren (Hub-Fenster zeigen + Seite „ClipVault“ öffnen). Falls `sendToUi` nur an
   gemountete UIs geht: ein optionales `ctx.openHub?.(page)` im Kontext wäre sauberer – ich rufe es dann auf.
3. **Electron 44 Clipboard ist async** (`clipboard.readText()` → Promise, kein `readImage`/`availableFormats` mehr).
   ClipVault nutzt die neue API; Flows `inserter.ts` erwartet noch ein synchrones `readText()` – nur als Hinweis.
4. **Hub-CSP**: Bilder kommen als `file:///…/clipvault/thumbs/<id>.png` (Fallback `data:` über IPC `image`).
   Bitte `img-src 'self' data: file:` beibehalten.
5. **Build**: `scripts/build.mjs` bündelt schon `preload.ts` + `ui/panel.ts` und kopiert `ui/*.html` – passt.
   `scripts/render-check.ts` + `scripts/render-hub-entry.ts` sind nur für den Render-Check (nicht bündeln).
6. **Keine neuen npm-Pakete nötig** (siehe `DEPENDENCIES.md`; `koffi` ist schon da).
7. **Einstellungen**: ClipVault hat eigene Einstellungen auf seiner Hub-Seite (`<userData>/clipvault/settings.json`).
   Der Hotkey ist dort änderbar; ClipVault registriert ihn neu über `ctx.registerHotkey`.


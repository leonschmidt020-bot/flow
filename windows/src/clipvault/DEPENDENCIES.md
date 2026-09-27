# ClipVault – npm dependencies

ClipVault does **not** need any package that isn't already in `windows/package.json`.

| package | where | why | status |
|---|---|---|---|
| `koffi` (dependency) | `platform/win32.ts` | user32/kernel32/shell32/crypt32: `GetClipboardSequenceNumber`, exclusion formats, CF_HDROP read/write, clipboard owner process, `SendInput` (Ctrl+V), focus restore, DPAPI `CryptProtectData` | already present (`^3.3.2`) |
| `electron` (dev) | `main.ts`, `electron/*`, `preload.ts` | BrowserWindow, async clipboard (Electron ≥ 44 API), nativeImage, net.fetch, powerMonitor | already present |
| `vitest`, `typescript`, `esbuild` (dev) | tests, build | – | already present |

Not needed: `ws` (Node 22's global `WebSocket` is used, auth via `Sec-WebSocket-Protocol: cvsync.v1, auth.<token>`,
which the worker accepts), no crypto library (node:crypto AES-256-GCM / HKDF / HMAC).

koffi is loaded lazily (`createRequire(__filename)('koffi')`) and only on Windows. If it is missing or a DLL call
fails, ClipVault falls back to the generic platform: capture still works (fingerprint polling), copy works,
but no auto-paste, no CF_HDROP and no DPAPI.

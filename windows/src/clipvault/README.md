# ClipVault für Flow (Windows)

Zwischenablage-Verlauf als Modul der Windows-App „Flow“ – nachgebaut nach ClipVault für den Mac
(`mac-apple-tools/clipvault`). Schnittstelle zu Flow: `INTERFACE.md` / `contract.ts`.

## Aufbau

| Datei | Inhalt |
|---|---|
| `main.ts` | `initClipVault(ctx)` → `{ openPanel, dispose }`: Speicher, Watcher, IPC (`clipvault:*`), Panel, Sync |
| `core/store.ts` | Verlauf in `<userData>/clipvault/` (atomar, Sicherheitskopie, Aufbewahrung, Kontingent, optional DPAPI) |
| `core/watcher.ts` | Zwischenablage-Wächter (250 ms), plattformneutral, Adapter injiziert |
| `core/sensitive.ts` | was NICHT gespeichert wird (Formate wie Win+V, Passwortmanager, Heuristiken) |
| `core/dedupe.ts` | Bild-Doppel wie `imagededupe.swift` (16×16-Abdruck + 256-px-Feinprüfung, 3 min) |
| `core/search.ts`, `core/view.ts`, `core/badges.ts` | Filter/Suche/Gruppen, Anzeige-Modell, Link/E-Mail/Code/Farbe |
| `platform/win32.ts` | koffi-Bindungen (Sequenznummer, Formate, CF_HDROP, Besitzer-Prozess, SendInput, Fokus, DPAPI) |
| `electron/clipboardAdapter.ts` | die EINZIGE Stelle, die die echte Zwischenablage liest/schreibt (Electron ≥ 44, async API) |
| `electron/panelWindow.ts` | Schnell-Panel am Mauszeiger (Acrylic unter Windows 11), Einfügen ins vorige Fenster |
| `ui/app.ts` | eine Oberfläche für Panel **und** Hub-Seite (Vanilla DOM, Shadow Root) |
| `sync/wire.ts`, `sync/engine.ts`, `sync/vault.ts` | Sync-Client, kompatibel mit `sync.swift` + `sync-worker` |

## Daten (`<userData>/clipvault/`)

`index.json` (Mac-kompatible Felder, neueste zuerst) · `index.bak.json` (letzte heile Fassung, höchstens alle 60 s) ·
`index.kaputt.json` (nach einer Wiederherstellung) · `collections.json` (Bereiche) · `settings.json` ·
`<id>.png` + `thumbs/<id>.png` · `files/<id>/<name>` (Kopien ≤ 200 MB).
Sync (nur wenn eingeschaltet): `sync.json` (nicht geheim), `sync-secrets.bin` (Schlüssel + Token, DPAPI),
`sync-queue.json`, `shared.json`, `shared/…`, `vocab.json`.

Aufbewahrung: Verlauf 2 Tage, max. 200 Einträge, Kontingent 1 GB (alles einstellbar) · angeheftet oder in einem
Bereich = für immer · Geheim-Bereich („Passwörter“): verborgen, nach 24 h gelöscht, außer angeheftet.

## Verschlüsselung im Ruhezustand (optional, Windows DPAPI)

Einstellung „Verlauf verschlüsseln“ (aus per Standard). Dann werden `index.json`, `index.bak.json` und
`shared.json` als `CVDP1\n` + DPAPI-Blob geschrieben (`CryptProtectData`, Benutzerbereich *CurrentUser*,
`CRYPTPROTECT_UI_FORBIDDEN`, fester Zusatz-Entropie-Wert `ClipVault-Flow-Windows|v1`).

- Lesbar nur für dasselbe Windows-Konto auf demselben PC (bzw. mit Roaming-Profil). Kein eigenes Passwort.
- Bilder und kopierte Dateien bleiben unverschlüsselt (Dateisystem-Rechte des Profils); der Index – also alle
  Texte – ist verschlüsselt.
- Ist die Datei verschlüsselt, aber DPAPI nicht verfügbar (anderes Konto, anderer PC), öffnet ClipVault den
  Verlauf **nur lesend** und überschreibt nichts.
- Beim Start macht die DPAPI-Bindung einen Selbsttest; schlägt er fehl, ist die Option ausgegraut.
- Die Sync-Schlüssel (`sync-secrets.bin`) liegen IMMER per DPAPI geschützt (Fallback: Electron `safeStorage`).

## Nicht gespeichert wird

1. Formate, die auch Windows' eigener Verlauf (Win+V) respektiert: `ExcludeClipboardContentFromMonitorProcessing`,
   `CanIncludeInClipboardHistory = 0`, dazu `Clipboard Viewer Ignore` (KeePass u. a.).
2. Kopien aus Passwortmanagern (Besitzer-Prozess: 1Password, KeePass(XC), Bitwarden, Dashlane, LastPass, Keeper,
   Enpass, NordPass, RoboForm, Proton Pass …) und aus selbst eingetragenen Apps.
3. Inhalte: private Schlüssel (PEM/OpenSSH), bekannte API-Token (OpenAI/Anthropic, GitHub, Slack, AWS, Google,
   Stripe, GitLab, JWT, ClipVault-Kopplungscodes), Kreditkartennummern (Luhn), optional „passwortartige“
   Zeichenketten (8–64 Zeichen, ≥ 3 Zeichenklassen, hohe Entropie, keine URL/Pfad/UUID/Hash).
4. Flows eigene Diktat-Schreibvorgänge (`isFlowWritingClipboard`), außer Phase `keep` (landet als „Diktat“).

Protokolliert wird nur der Grund, nie der Inhalt.

## Bedienung

Strg+Umschalt+V (über `ctx.registerHotkey`) öffnet das Panel am Mauszeiger. ↑↓ / Bild↑↓ Auswahl · ↵ einfügen ins
vorige Fenster (Panel weg, Fokus zurück, SendInput Strg+V) · Strg+C nur kopieren · Strg+1…9 direkt einfügen ·
Strg+P anheften · Entf löschen · Tab Filter wechseln · Leertaste Bild groß (Zoom mit Rad/+/−/0, ←→ blättern,
ziehen verschiebt, Doppelklick 100 %/Einpassen, Esc) · Rechtsklick/„Mehr“: in Bereich legen, Im Explorer zeigen,
Speichern unter …, Teilen · Zeilen per Drag & Drop auf einen Bereich ziehen · Esc schließt.
Hub-Seite: dieselben Funktionen, Bereiche in der Seitenleiste (Rechtsklick: umbenennen/Symbol/löschen),
Einstellungen, Teilen & Sync.

## Tests

```
cd windows && npx vitest run src/clipvault
```
Ohne `windows/node_modules`: `CV_TOOL_NODE_MODULES=<pfad>/node_modules npx vitest run --config src/clipvault/vitest.config.ts`.
Kein Test fasst die echte Zwischenablage an (Fake-Adapter), kein Test nutzt das Netz (In-Memory-Worker).

## Render-Check (Screenshots der Oberfläche, offscreen)

Nutzt den echten Preload, `panel.html/panel.js`, Store und die Listen-/Anzeige-Logik mit Beispieldaten; nur die
IPC-Handler sind eine Attrappe (keine Zwischenablage, keine Hotkeys, kein Netz):
```
O=/tmp/cv-render; mkdir -p $O/ui; E=node_modules/.bin/esbuild
$E src/clipvault/scripts/render-check.ts --bundle --platform=node --format=cjs --external:electron --outfile=$O/render-check.js
$E src/clipvault/preload.ts --bundle --platform=node --format=cjs --external:electron --outfile=$O/preload.js
$E src/clipvault/ui/panel.ts --bundle --platform=browser --format=iife --outfile=$O/ui/panel.js
$E src/clipvault/scripts/render-hub-entry.ts --bundle --platform=browser --format=iife --outfile=$O/hub.js
cp src/clipvault/ui/panel.html $O/ui/ && npx electron $O/render-check.js $O     # -> $O/01-…12-*.png
```

## Sync (optional, aus per Standard)

Kompatibel mit dem Mac (`sync.swift`, `sync-worker/`): gleicher Worker, gleiches Wire-Format, gleiche Kopplungscodes.
Die Worker-URL trägt der Nutzer selbst ein (keine Standard-URL). Geprüft gegen Testvektoren, die der Swift-Code
selbst erzeugt (`scripts/gen-sync-vectors.swift` → `test-fixtures/swift-sync-vectors.json`), in beide Richtungen.

Umgesetzt: AES-256-GCM (CryptoKit-„combined“), AAD für Einträge und Teile, `CVS1`-Rahmen, Kopplungscode
`cvpair1.`, `init/invite/join/info/since/items`, große Einträge v2 (begin/parts/commit, 1-MiB-Teile,
fortsetzbar, Manipulation eines Teils bricht das Laden ab, bis 20 MB automatisch laden), Grabsteine,
letzter Schreiber gewinnt, WebSocket mit Ping 30 s (+Jitter), 10 s ohne Pong = neu verbinden, Backoff 1 → 30 s
(+Jitter), Nachholen beim Verbinden / alle 60 s / nach Aufwachen / Netz wieder da, Warteschlange auf Platte,
gemeinsame Namen (vocab) werden empfangen, geprüft (id passt zum Wort) und in `vocab.json` abgelegt.

Noch nicht: Ordner teilen (Mac zippt sie), „Neu vom Partner“ (`shared-seen.json`, grüner Punkt), Speicher-
aufräumen (`evict`/`cleanupBig`), `vocab` senden (Flow-Diktat hat noch keinen Namens-Lerner), Anzeige laufender
Übertragungen als Ring. Nie gegen den echten Worker getestet (bewusst: kein Netz in diesem Lauf).

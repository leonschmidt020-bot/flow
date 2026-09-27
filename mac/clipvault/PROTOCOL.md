# ClipVault — Daten & Befehlsprotokoll

Für Programme, die ClipVault von außen anzeigen oder steuern (z. B. eine Hub-Oberfläche).
Grundregel: **lesen aus den Dateien, ändern nur über Befehle.** ClipVault hält den Verlauf im
Speicher und überschreibt `index.json` bei jeder Änderung — direkt hineingeschriebene Änderungen
gehen verloren (Ausnahme: danach sofort den Befehl `reload` schicken).

Alle Pfade liegen in `~/.config/flow-clipvault/` (im Folgenden `$CV`).

## 1. Dateien

| Datei | Inhalt |
|---|---|
| `index.json` | Verlauf (Array, siehe 2). Wird **atomar** ersetzt (temp + rename) → immer komplett neu lesen. |
| `index.bak.json` | Sicherheitskopie der vorigen Fassung (höchstens alle 60 s) |
| `collections.json` | Bereiche (siehe 3) |
| `shared.json` | Geteilter Tresor (siehe 4) |
| `shared-seen.json` | Gesehen-Stand „Neu vom Partner" (siehe 4.1), `0600`, atomar ersetzt. **Andere Programme dürfen hier schreiben** |
| `<UUID>.png` | Bild eines Bild-Eintrags (Name steht in `image`) |
| `files/<eintrag-id>/<name>` | Gesicherte Kopie einer kopierten Datei (≤ 200 MB) |
| `shared/<id>.png`, `shared/files/<id>/<dateiname>` | Bild/Datei geteilter Einträge (Ordner `0700`, Dateien `0600`; ältere Fassung: `shared/<id>/<dateiname>` — beim Lesen beide prüfen). Fehlt die Datei, ist ein großer Eintrag noch nicht geladen |
| `linkprev/<sha256-16hex>.png` / `.txt` | Website-Vorschau + Seitentitel zu Link-Einträgen (Schlüssel = SHA-256 der URL, erste 16 Hex-Zeichen) |
| `token` | Schlüssel für Befehle: 64 Hex-Zeichen + `\n`, Rechte `0600` |
| `status.txt` | `schluessel=wert` je Zeile (pid, hotkey, eintraege, bereiche, befehle, ocr, geteilt, shared_new, sync, sync_state, sync_queue, sync_partner, sync_reason, sync_latenz_ms, sync_used, sync_quota, sync_transfers, vocab_inbox, seit) — alle 30 s, bei jedem Sync-Zustandswechsel und wenn sich Geteiltes/Gesehenes ändert. `shared_new=<n>` = Anzahl neuer Einträge vom Partner (4.1) · `vocab_inbox=<n>` = abzuholende Namen (4.2, fehlt bei 0) |
| `sync.json` | Sync-Einstellungen, `0600`, **nicht geheim**: `url` (Worker), `vaultId`, `deviceId`, `cursor` (Serverzeit ms), `partnerJoined` |
| `sync-queue.json` | Warteschlange noch nicht hochgeladener geteilter Eintraege (nur ids), `0600` |
| `sync-pairing.json` | nur waehrend ein Kopplungscode angezeigt wird: `{code, payload, expiresAt}`, `0600`. **Der Code ist geheim** (enthaelt den Tresor-Schluessel), verschwindet nach Beitritt/Ablauf/Abbruch |
| `vocab.json` | Gemeinsame Namen (siehe 4.2), `0600`, atomar ersetzt. **Nur lesen** — ändern über `vocabAck` |
| `sync-notify.txt` | optional `1`: Toast „<Partner> hat etwas geteilt" bei neuen Eintraegen vom Partner (Standard aus) |

Es werden **keine Thumbnails** gespeichert. Für Listen selbst verkleinern
(ImageIO `CGImageSourceCreateThumbnailAtIndex`, nie das Vollbild im RAM halten).

## 2. `index.json` — Verlauf

Array von Einträgen, **neueste zuerst** (Reihenfolge = Anzeige-Reihenfolge; Angeheftete werden
beim Anzeigen nach oben gezogen, stehen in der Datei aber an ihrer Zeitposition).

| Feld | Typ | Bedeutung |
|---|---|---|
| `id` | String (UUID) | eindeutig, bleibt stabil |
| `kind` | `"text"` \| `"image"` \| `"file"` | Art |
| `text` | String? | Inhalt bei `text` (Original, kann Private-Use-Zeichen enthalten) |
| `image` | String? | Dateiname des PNG relativ zu `$CV` (nur `image`) |
| `files` | `[{name, stored, orig}]`? | nur `file`: `name` Dateiname · `stored` Pfad der gesicherten Kopie relativ zu `$CV` oder `null` (Ordner/zu groß) · `orig` absoluter Originalpfad (kann inzwischen fehlen) |
| `ts` | Double | **Unix-Sekunden** (seit 1970, UTC). Zuletzt benutzt: wird beim erneuten Kopieren auf „jetzt" gesetzt |
| `source` | String? | Herkunft: `null`, `"KI"`, `"iPhone"`, `"Diktat"`, `"Meeting"`, `"Command Mode"` oder frei (Befehl `addText`) |
| `pinned` | Bool? | angeheftet (fehlt = `false`) |
| `collection` | String? | Bereichs-`id` oder `null` (= normaler Verlauf) |
| `ocrText` | String? | nur `image`: erkannter Text (Deutsch+Englisch). `null` = noch nicht gelesen · `""` = gelesen, kein Text |
| `shared` | Bool? | mit dem Partner geteilt (fehlt = `false`) |
| `collectedAt` | Double? | Unix-Sekunden: seit wann im aktuellen Bereich |
| `edited` | Double? | Unix-Sekunden: zuletzt von Hand bearbeitet |
| `origin` | String? | nur `image`: absoluter Pfad der Originaldatei (Screenshot-Ordner/Finder), falls bekannt. Derselbe Screenshot über Datei **und** Zwischenablage wird zu **einem** Eintrag zusammengeführt (Pixel-Abgleich, 3 min Fenster); die Fassung mit `origin` gewinnt, `id`/`ocrText` bleiben |
| `badges` | [String]? | **nur Info** (wird neu berechnet): `"link"`, `"email"`, `"phone"`, `"color"`, `"code"` |

Ältere Einträge haben die optionalen Felder nicht — fehlend wie `null`/`false` behandeln.

**Anzeige-Regeln im Panel** (zum Nachbauen):
- „Verlauf" = Einträge mit `collection == null`; darin angeheftete oben unter „Angeheftet", Rest nach Tagen gruppiert.
- Bereich X = Einträge mit `collection == X.id`.
- Einträge in einem **Geheim-Bereich** (siehe 3) zeigen statt Text `••••` — Inhalt nur bei Hover/⌥.
- Typ-Filter: Text = `text` ohne reine URL · Bilder = `image` · Links = `text` mit Badge `link` · Dateien = `file`.
- Suche: `text`, `ocrText` und `files[].name`, Groß/Klein egal.

**Aufbewahrung:** Verlauf 2 Tage und max. 200 Einträge · angeheftet oder in einem Bereich = kein Ablauf ·
Geheim-Bereich: nach 24 h ab `collectedAt` gelöscht, außer `pinned`.

## 3. `collections.json` — Bereiche

```json
[{"id":"95898D06-…","name":"Arbeit","symbol":"briefcase.fill"},
 {"id":"F7C9973B-…","name":"Passwörter","symbol":"lock.fill","secret":true}]
```
- `symbol`: SF-Symbol-Name **oder** `"img:<datei>"` (Bild relativ zu `$CV`, farbig, nicht einfärben).
- `secret`: Bool? — Geheim-Bereich. Fehlt es, gilt der Name: enthält „passw", „kennw", „geheim" oder „secret" → geheim.
- Der eingebaute Bereich **„Geteilt"** steht NICHT in dieser Datei; seine Kennung im Befehl `show` ist `"__shared__"`.

## 4. `shared.json` — Geteilter Tresor

```json
{"version":1,
 "pending":["<id>", …],
 "items":[{"id":"…","kind":"text|link|image|file","text":"…","fileName":"…",
           "createdBy":"Lena","createdAt":1790438950.7,"updatedAt":1790438950.7,
           "pinned":false,"deleted":false,
           "size":30421636,"parts":30,"content":"<32 hex>","sourceId":"…",
           "serverGone":true,"expiresAt":1791056950.7,"uploadError":"…"}]}
```
- Zeiten in Unix-Sekunden. `deleted: true` = weich gelöscht (nicht anzeigen).
- `pending` = lokal geändert, von der Synchronisierung noch nicht bestätigt („wartet auf Sync").
- Bilddaten: `shared/<id>.png` · Dateien: `shared/files/<id>/<fileName>` · `text` bei Bildern = OCR-Text (optional).
- `id` = id des Verlaufs-Eintrags, aus dem geteilt wurde. Mehrere Dateien in einem Verlaufs-Eintrag = ein geteilter
  Eintrag je Datei (erste Datei: gleiche id, weitere: abgeleitete UUID) mit `sourceId` = Verlaufs-Eintrag.
- Dateien jeder Art bis **200 MB** je Datei, Ordner werden als `.zip` geteilt. `size` = Bytes.
- `parts` > 0 = **großer Eintrag** (> 4 MB): liegt auf dem Server in Teilen. Beim Empfänger wird er bis 20 MB sofort
  geladen, größere erst auf „Laden" (Befehl `download`). Solange die Datei fehlt: noch nicht geladen.
- `serverGone: true` = Teile auf dem Server abgelaufen/aufgeräumt (lokale Kopien bleiben). `expiresAt` = wann sie
  ablaufen (nur große, nicht angeheftete: 7 Tage). `uploadError` = Hochladen gescheitert (z. B. Speicher voll), nur lokal.
- Eigener Name / Partner: eigener Vorname aus `NSFullUserName()` (überschreibbar: `shared-me.txt`); der Partner-Name wird beim Koppeln eingegeben (`shared-partner.txt`, sonst „Partner").

### 4.1 `shared-seen.json` — „Neu vom Partner" (grüner Punkt)

```json
{"baseline": 1790450877.18, "seen": ["C823F321-…", "305fc245-…"]}
```
- `baseline`: Unix-Sekunden. `seen`: ids, die schon angesehen wurden — **höchstens 1000**, älteste vorn, neueste hinten
  (beim Kürzen bleiben die neuesten). ids vergleichen **ohne Groß/Klein**.
- Ein Eintrag aus `shared.json` ist **NEU**, wenn alles gilt: `createdBy` ≠ eigener Name (siehe oben) · `deleted` ist nicht
  `true` · `createdAt > baseline` · id steht nicht in `seen`.
- Fehlt die Datei, legt ClipVault sie mit `baseline = jetzt` und leerem `seen` an (alter Bestand zählt nicht als neu).
  Datei löschen = alles Bisherige gilt als gesehen.
- **Mitschreiben (z. B. eine andere App):** Datei lesen, ids hinten an `seen` anhängen, auf 1000 kürzen, **atomar**
  ersetzen (temp-Datei `0600` + `rename`), danach `app.flowdictation.clipvault.changed` senden. ClipVault liest die Datei beim
  Öffnen des Panels und bei jeder `changed`-Meldung neu — oder den Befehl `markSeen` benutzen (einfacher, kein Wettlauf).
- ClipVault markiert als gesehen: Kopieren (Klick, Enter, ⌘1–9, „Kopieren", Befehl `copy`), mehr als 1,5 s in der
  Vorschau, Rechtsklick „Als gesehen markieren", „Alle gesehen" in der Filterleiste von „Geteilt".
- Anzeige im Panel: grüne Zähler-Plakette (#34C759, weißer Ring) am Chip „Geteilt", grüner Punkt am Zeilenanfang +
  „NEU" im Untertitel, „● NEU" in der Vorschau-Kopfzeile.

### 4.2 `vocab.json` — Gemeinsame Namen (unsichtbar)

Lernt die Diktat-App (Flow) einen **Namen/Begriff**, schickt sie mit `sendVocab` NUR das Wort (Schreibweise + Art);
ClipVault ergänzt „gelernt von" (= eigener Name, siehe 4) und verschickt es über den geteilten Tresor wie einen Eintrag
(Ende-zu-Ende verschlüsselt, gleiche Warteschlange, gleicher Echtzeit-Weg). Solche Wörter erscheinen **nirgends**: nicht in
`shared.json`, nicht im Panel, nicht in „Geteilt", kein grüner Punkt, zählen nicht bei `shared_new`/`sharedNew`.

```json
{"version":1,
 "items":[{"id":"8AC62ADF-…","word":"Brenninkmeyer","type":"person","by":"Lena",
           "createdAt":1790456424.33,"updatedAt":1790456424.33,
           "dir":"in","inbox":true,"receivedAt":1790456424.34}]}
```
- `type`: `person` · `company` · `place` · `term`. `dir`: `out` = selbst gelernt · `in` = vom Partner.
- `inbox: true` = vom Partner, noch nicht abgeholt. Die Diktat-App liest die Datei (oder `vocabInbox`), fragt/übernimmt
  und bestätigt mit `vocabAck` (danach fehlt `inbox`). Kommt ein Wort an, sendet ClipVault **`app.flowdictation.clipvault.vocab`**
  (`object` = `nil`; Test-Instanzen hängen wie alle Meldungen `.<kennung>` an).
- **id = aus dem Wort abgeleitet** (HMAC-SHA256 mit einem Schlüssel aus dem Tresor-Schlüssel über das kleingeschriebene,
  Unicode-normalisierte Wort) → dasselbe Wort hat auf beiden Macs dieselbe id, der Server kann sie nicht zurückraten.
  Dadurch: kein Ping-Pong und keine Doppelten. `sendVocab` für ein schon bekanntes Wort (selbst geschickt ODER vom Partner
  bekommen) schickt nichts (`sent: false`, `known: "self"|"partner"`); lernen beide dasselbe Wort gleichzeitig, bekommt keiner
  einen Posteingangs-Eintrag. Ein Wort, dessen id nicht zum Wort passt, wird verworfen.
- Eigene Wörter von einem anderen eigenen Mac (gleicher Name in `by`) landen als `out`, nie im Posteingang.
- Nie geteilt werden Stimmprofile, Klang-Vorlagen, eigene Verhörer oder Aliasse — nur die Schreibweise. Was als „Name"
  zählt, entscheidet die Diktat-App (Allerweltswörter und Grammatik schickt sie nicht).
- Höchstens 2000 Wörter (älteste bestätigte fallen zuerst weg).

## 5. Befehle

**Senden:** `DistributedNotificationCenter`, Name **`app.flowdictation.clipvault.cmd`**,
`object` = **JSON-String** (kein userInfo), `deliverImmediately: true`.

```json
{"token":"<64 hex aus $CV/token>", "action":"pin", "id":"<eintrag-id>", "reqId":"optional"}
```

| Feld | Typ | |
|---|---|---|
| `token` | String | Pflicht. Falscher Schlüssel → Befehl wird still ignoriert (im Log vermerkt) |
| `action` | String | siehe Tabelle |
| `id` | String? | Eintrags-id |
| `collection` | String? / `null` | Bereichs-id |
| `text` | String? | Text für `edit` / `addText` |
| `name`, `symbol`, `secret`, `source` | optional | für `createCollection` / `addText` |
| `reqId` | String? | wenn gesetzt, kommt eine Antwort (siehe unten) |

| action | benötigt | Wirkung | Antwort-`id` |
|---|---|---|---|
| `ping` | – | nichts (Schlüssel testen) | – |
| `copy` | `id` | Eintrag in die Zwischenablage (wie Klick, rückt nach oben, Kopier-Pille). Auch für ids aus „Geteilt" — Dateien als **echte Datei-URL** (einfügbar in Finder, Mail, WhatsApp); noch nicht geladene werden erst geladen und landen danach in der Zwischenablage | id |
| `pin` / `unpin` | `id`, opt. `scope` = `shared` | anheften / lösen. Ohne `scope` gewinnt ein Verlaufs-Eintrag mit gleicher id; `scope=shared` meint den geteilten Eintrag (große Dateien laufen angeheftet nicht ab) | id |
| `delete` | `id` | löschen (inkl. Bild/Datei-Kopie) | id |
| `setCollection` | `id`, `collection` (id oder `null`) | in Bereich legen / herausnehmen | id |
| `createCollection` | `name`, opt. `symbol` (Standard `folder.fill`), `secret` | Bereich anlegen | **neue Bereichs-id** |
| `deleteCollection` | `collection` (oder `id`) | Bereich löschen, Einträge fallen in den Verlauf zurück | Bereichs-id |
| `edit` | `id`, `text` | Text eines Text-Eintrags ersetzen (setzt `edited`) | id |
| `addText` | `text`, opt. `collection`, `source` | neuen Text-Eintrag anlegen (gleicher Text → vorhandener rückt nach oben) | **Eintrags-id** |
| `ocr` | `id` (Bild) | Texterkennung neu starten; Ergebnis kommt später per `changed` | id |
| `share` | `id` | für den geteilten Tresor freigeben (Text/Link, Bild, Datei(en) jeder Art bis 200 MB je Datei, Ordner als .zip). Antwort zusätzlich `ids` (ein geteilter Eintrag je Datei) | id |
| `unshare` | `id` | Freigabe zurücknehmen (weich löschen) — geteilte id oder Verlaufs-id (dann alle ihre Dateien) | id |
| `addFile` | `path` (oder `paths` = Pfade, durch Zeilenumbruch getrennt) | Datei(en) in den Verlauf legen, ohne die Zwischenablage anzufassen | **Eintrags-id** |
| `download` | `id` (geteilt) | großen Eintrag laden („Laden"). Antwort `local: true`, wenn schon da | id |
| `cancelTransfer` | `id` | Laden/Hochladen stoppen (Hochladen abbrechen = am besten `unshare`) | id |
| `retryUpload` | `id` | nach `uploadError` erneut hochladen | id |
| `cleanupBig` | – | „Große Dateien aufräumen": Teile großer (> 20 MB), nicht angehefteter Einträge vom Server löschen. Antwort `ids`, `bytes` | – |
| `saveToDownloads` | `id` (geteilt) | Kopie in `~/Downloads` (freier Name). Antwort `path` | id |
| `transfers` | – | laufende Übertragungen: `transfers` = `{id: {dir: up|down, done, total}}` | – |
| `storage` | – | Speicherstand vom Server holen; Antwort wie `syncStatus` mit `used`, `quota`, `bigItems`, `bigBytes` | – |
| `renameCollection` | `collection` (oder `id`), `name` (oder `text`), opt. `symbol` | Bereich umbenennen / Icon ändern | Bereichs-id |
| `addImage` | `path` (Bilddatei), opt. `source` | Bild in den Verlauf legen, ohne die Zwischenablage anzufassen | **Eintrags-id** |
| `pairCreate` | opt. `name` | Sync: Tresor anlegen (falls keiner) + Kopplungscode (15 min). Antwort zusätzlich `code`, `payload`, `expiresAt`; Code liegt auch in `sync-pairing.json` | Code |
| `pairJoin` | `code` | Sync: mit dem Code des Partners beitreten | – |
| `pairCancel` | – | angezeigten Code zurückziehen | – |
| `unpair` | – | Kopplung trennen: Schlüssel aus dem Schlüsselbund löschen, Warteschlange leeren (lokale Einträge bleiben) | – |
| `syncStatus` | – | Antwort: `state`, `paired`, `partnerJoined`, `queue`, `url`, `vault`, `lastLatencyMs` … | – |
| `syncSetup` | `url`, opt. `initSecret` | Sync-Server (Worker-URL des eigenen Workers) eintragen, `https://` (http nur localhost); `initSecret` = INIT_SECRET des Workers (Schlüsselbund, nur zum Anlegen) | – |
| `setPartner` | opt. `name` | Namen des Freundes/Partners setzen (`shared-partner.txt`), leer = „Partner". `pairCreate`/`pairJoin` nehmen ebenfalls `name` | – |
| `sharedNew` | – | Neues vom Partner (4.1). Antwort zusätzlich `count`, `ids` (neueste zuerst), `baseline` | – |
| `markSeen` | `id` **oder** `all` (`1`/`true`) | als gesehen markieren (nur, was gerade neu ist; unbekannte id = Fehler). Antwort zusätzlich `marked` (ids), `count` + `ids` (was danach noch neu ist) | id |
| `sendVocab` | `word` (2–60 Zeichen, ≤ 4 Wörter), opt. `type` (`person`/`company`/`place`/`term`, sonst `term`) | gemeinsamen Namen verschicken (4.2), asynchron. Antwort `vocabId`, `sent` (Bool), bei `sent: false` zusätzlich `known` (`self`/`partner`). Fehler `nicht gekoppelt` | – |
| `vocabInbox` | opt. `all` (`1`) | Posteingang (4.2): `items` = `[{id, word, type, by, createdAt, dir, inbox}]` (neueste zuerst; mit `all` alle Wörter), `count` | – |
| `vocabAck` | `id`, `ids` (durch Komma getrennt) **oder** `all` | Posteingang bestätigt (abgeholt). Antwort `acked` (ids), `count` (was noch offen ist) | – |
| `reload` | – | `index.json`, `collections.json`, `shared.json`, `shared-seen.json` neu von Platte lesen | – |
| `show` | opt. `collection` (id oder `"__shared__"`) | Panel öffnen | – |

**Antwort** (nur mit `reqId`): Name **`app.flowdictation.clipvault.result`**, `object` = JSON-String
`{"reqId":"…","action":"…","ok":true,"id":"…"}` bzw. `{"ok":false,"error":"Eintrag nicht gefunden"}`.
Sync-Befehle (`pair…`, `unpair`, `sync…`) antworten asynchron (Netz) und können weitere Felder mitschicken.

**Änderungs-Meldung:** Name **`app.flowdictation.clipvault.changed`**, `object` = `nil`. Kommt nach JEDER
Änderung (Kopie, Befehl, OCR-Ergebnis, Ablauf, Geteilt) — höchstens alle 200 ms, die letzte Änderung
eines Schwalls wird immer noch gemeldet. Danach `index.json` / `collections.json` / `shared.json` neu lesen.

### Swift-Beispiel

```swift
let token = try String(contentsOfFile: NSHomeDirectory() + "/.config/flow-clipvault/token", encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
func send(_ cmd: [String: Any]) {
    var c = cmd; c["token"] = token
    let json = String(data: try! JSONSerialization.data(withJSONObject: c), encoding: .utf8)!
    DistributedNotificationCenter.default().postNotificationName(.init("app.flowdictation.clipvault.cmd"),
        object: json, userInfo: nil, deliverImmediately: true)
}
DistributedNotificationCenter.default().addObserver(forName: .init("app.flowdictation.clipvault.changed"),
    object: nil, queue: .main) { _ in /* index.json neu lesen */ }
send(["action": "pin", "id": itemId])
```

### Zum Testen auf der Kommandozeile
```
~/.config/flow-clipvault/clipvault send ping
~/.config/flow-clipvault/clipvault send addText text="Hallo"        # gibt die Antwort aus
~/.config/flow-clipvault/clipvault send setCollection id=<id> collection=null
~/.config/flow-clipvault/clipvault send sharedNew                   # {"count":1,"ids":["…"],…}
~/.config/flow-clipvault/clipvault send markSeen all=1
~/.config/flow-clipvault/clipvault send sendVocab word=Brenninkmeyer type=person
~/.config/flow-clipvault/clipvault send vocabInbox                  # {"count":1,"items":[…]}
~/.config/flow-clipvault/clipvault send vocabAck all=1
~/.config/flow-clipvault/clipvault listen 10                        # changed/result mitlesen
```

### Sicherheit
Der Schlüssel schützt vor versehentlichen oder blinden Befehlen anderer Programme. Verteilte
Meldungen sind aber für jedes Programm desselben Benutzers sichtbar — ein Programm, das gezielt
`app.flowdictation.clipvault.cmd` belauscht, sieht den Schlüssel. Das ist dieselbe Vertrauensgrenze wie der
Verlauf selbst (liegt lesbar in `$CV`). Neuer Schlüssel: `token` löschen und ClipVault neu starten.
Inhalte, die Passwortmanager als `org.nspasteboard.ConcealedType` / `TransientType` /
`AutoGeneratedType` markieren, landen gar nicht im Verlauf.

## 6. Synchronisierung (`sync.swift` + `sync-worker/`)

**Andocken:** In `shared.swift` definiert: `protocol SharedVaultBackend` (`backendName`, `start(vault:)`,
`push(_:)`, `stop()`), optional `SharedVaultCommandHandler` (eigene Befehle), `SharedVaultStatusProvider`
(Zeilen für `status.txt`), `SharedVaultPanelUI` (Koppeln-Knopf im Panel). Eine Klasse mit dem Objective-C-Namen
**`ClipVaultSyncBackend`** wird beim Start automatisch gefunden (`sync.swift`). Von außen Neues: `vault.applyRemote`,
lokale Änderungen kommen über `push(item)`, nach Erfolg `vault.markSynced([id])`.

**Server:** Cloudflare Worker `sync-worker/` (TypeScript), ein SQLite-Durable-Object pro Tresor. Dummer Speicher +
Verteiler: Tabelle `items(id, blob, updated_at, deleted, device, synced_at, size, chunks, parts, total, content, complete,
keep, gone, expires_at, began_at)`; Blobs > 1 MB in `chunks` (DO-Zeilen max. 2 MB). Endpunkte unter `/v/<tresor-uuid>/`:
`init`, `invite`, `join`, `info` (+ `used`, `quota`), `since?t=`, `items/<id>` (GET/PUT, Rohbytes, max. 8 MB), `wipe`,
`ws` (Hibernation-WebSocket, `ping`→`pong` automatisch, schickt jede neue/geänderte Zeile an die anderen Geräte;
Blobs ≤ 256 KB direkt, größere lädt der Mac nach).

**Große Einträge (v2, > 4 MB, bis 200 MB):** Tabelle `parts(id, idx, data)`.
`POST items/<id>/begin` (Body = verschlüsseltes Manifest, Header `X-CV-Parts`, `X-CV-Total`, `X-CV-Content`, `X-CV-Keep`)
→ `{have:[…]}` · `PUT items/<id>/parts/<n>` (Teil ≤ 1 MiB + 28 B) · `POST items/<id>/commit` (409 `{missing}`) ·
`GET items/<id>/parts/<n>` (410 = abgelaufen) · `POST items/<id>/evict`. Erst nach `commit` ist der Eintrag in
`since`/`ws` sichtbar. Gleiche Content-id beim nächsten `begin` = vorhandene Teile bleiben → Hochladen setzt nach
Abbruch/Neustart dort fort, wo es war; Anheften lädt nichts neu hoch. Parallel 3 Teile je Datei, höchstens 2 Dateien.
- **Kontingent** 3 GB pro Tresor (`QUOTA_BYTES`), 507 `vault full` → Eintrag zeigt „Geteilter Speicher voll".
- **Ablauf:** große (> 20 MB), nicht angeheftete Einträge verlieren ihre Teile nach 7 Tagen (`BIG_TTL_SECONDS`,
  DO-Alarm); nie beendete Uploads nach 3 Tagen. Der Eintrag bleibt (`gone`), geladene Kopien bleiben.
- **Gemeinsame Namen (proto 3, `vocab.swift`):** Nutzlast `kind: "vocab"`, `deleted: true`, `text`/`fileName` leer, das Wort im
Kopf-Feld `vocab: {word, type}`, Absender = `createdBy`. Beim Server **kein** Grabstein (`X-CV-Deleted: 0`), damit `/since`
das Wort auch Geräten liefert, die die id noch nicht kennen. Warum so und nicht nach Client-Version gefiltert: alle bisherigen
Fassungen machen aus einer unbekannten Art einen Text-Eintrag und zeigen geloeschte nie an (Panel, Geteilt, grüner Punkt,
Flows Geteilt-Liste) → eine ältere Fassung legt das Wort als leeren, unsichtbaren Grabstein ab, ohne den Namen zu
speichern. Kein Hinweis-Text, keine Versionsabfrage, kein Serverumbau. Nach dem Update holt der Client einmal alles neu
(`sync.json` `proto: 3`) und ersetzt diese Grabsteine durch die richtigen Wörter in `vocab.json`.

**Ältere Clients** (nur v1) sehen einen großen Eintrag als Text „Datei „x" (30 MB) — zum Öffnen ClipVault aktualisieren."
  Ihr v1-PUT darf ihn nur löschen, nicht überschreiben. Nach dem Update holt der neue Client einmal alles nach
  (`sync.json` `proto: 2`) und ersetzt den Hinweis durch die Datei.

Ratenbremse pro Tresor (Schreiben 120 sofort + 240/min, Teile 600 + 1200/min, Lesen 600/min, Beitritt 10 + 2/min,
Hochladen 200 MB sofort + 300 MB/min).

**Sicherheit:**
- Ende-zu-Ende: AES-GCM-256 (CryptoKit) über den ganzen Eintrag (Art, Text, Bild-/Dateibytes, Absender, Zeiten,
  angeheftet, gelöscht). AAD = `clipvault-item|v1|<tresor>|<id>` → der Server kann nichts vertauschen.
  Große Einträge: das Manifest (Name, Größe, Teilezahl, Content-id) wie oben; **jedes Teil** ein eigenes AES-GCM-Chiffrat
  mit eigener Zufalls-Nonce, AAD = `clipvault-part|v2|<tresor>|<id>|<content>|<idx>/<anzahl>` → Teile lassen sich nicht
  vertauschen, zwischen Dateien verschieben oder abschneiden; ein gekipptes Bit bricht das Laden ab (nichts wird geschrieben). Der Server
  sieht nur Chiffrat + id, Zeitstempel, Grabstein-Flag, Geräte-id, Größe.
- Zugang: pro Tresor zufälliges 256-bit-`vaultToken` (Bearer). Das DO speichert nur SHA-256(token). Keine Konten.
- Tresor-Schlüssel + Token nur im Schlüsselbund (Dienst `app.flowdictation.clipvault.sync`, Konten `vault-key`, `vault-token`).
  Zugriff über `/usr/bin/security` (Partition `apple-tool:`, `-A`) → nach Neubauten fragt macOS **nie** nach.
  Test-Instanzen: `CLIPVAULT_KEYCHAIN_SUFFIX`.
- Kopplung: `pairCreate` legt eine Einladung an (Beitritts-Geheimnis nur gehasht im DO, 15 min, einmalig; das Token
  liegt darin mit einem aus dem Geheimnis abgeleiteten Schlüssel verpackt). Code = `cvpair1.<base64url>` mit
  Worker-URL, Tresor-id, Geheimnis und Tresor-Schlüssel → **nur privat weitergeben** (z. B. iMessage).
- Konflikte: letzter Schreiber gewinnt (`updatedAt` des Geräts), Löschen = Grabstein.
- Es wird nie Inhalt oder Schlüssel protokolliert.

**Kopplung (einmal):**
```
Du:      clipvault sync setup <worker-url> <INIT_SECRET>   # einmal: eigener Worker, siehe sync-worker/README.md
Du:      clipvault pair create "Sam"    # Name des Freundes/Partners · oder Hub → Geteilt / Panel → Geteilt → „Koppeln …"
Freund:  clipvault pair join cvpair1.… "Alex"   # dein Name auf seiner Seite · oder Panel → Geteilt → Code einfügen
beide:   clipvault sync status · clipvault doctor · clipvault unpair · clipvault partner <name>
```
Der Mac des Freundes braucht vorher KEIN `sync setup` und kein INIT_SECRET — die URL steckt im Code.

**Echtzeit:** WebSocket + Nachholen über `/since` beim Verbinden, alle 60 s, nach Aufwachen/Netzwechsel und sobald
ein HTTP-Aufruf wieder klappt. Ping alle 30 s, 10 s ohne Pong = neu verbinden (Backoff 1 → 30 s).
Warteschlange (`sync-queue.json`) übersteht Neustarts; ohne Kopplung bleibt Geteiltes „wartet auf Sync".

**Test ohne zweiten Mac:** `CLIPVAULT_HOME=/tmp/devB CLIPVAULT_KEYCHAIN_SUFFIX=testB clipvault sync-agent`
startet ein kopfloses zweites Gerät (eigener Ordner, eigener Schlüsselbund-Dienst, eigene Meldungsnamen);
`CLIPVAULT_HOME=… clipvault send …` steuert es. Debug-Ausgaben: `CLIPVAULT_SYNC_DEBUG=1`.
Lokaler Server: `cd sync-worker && npm install && npm run dev` (http://127.0.0.1:8787).
Tests mit kleinem Kontingent/kurzem Ablauf: `npx wrangler dev --local --var QUOTA_BYTES:209715200 --var BIG_TTL_SECONDS:15`.
Hochladen künstlich bremsen (Abbruch-Test): `CLIPVAULT_TEST_PART_DELAY_MS=100`. Zwischenablage-Test ohne die echte:
`clipvault pasteboard-test <geteilte-id> <zielordner>` (eigene Zwischenablage, fügt wie der Finder ein).

**Deploy (Cloudflare, Free-Plan):**
```
cd clipvault/sync-worker
npm install
npx wrangler login                     # einmal, Browser
npx wrangler deploy                    # legt Worker „flow-clipvault-sync" + Durable Object (Migration v1, SQLite) an
npx wrangler secret put INIT_SECRET    # PFLICHT (Audit #16): ohne es legt der Worker keine Tresore an (503)
curl https://<worker>.<subdomain>.workers.dev/health
clipvault sync setup https://<worker>.<subdomain>.workers.dev <INIT_SECRET>   # auf dem Mac, der den Code erzeugt
```
Keine Geheimnisse im Repo. Das einzige Server-Geheimnis ist INIT_SECRET (nur zum Anlegen neuer Tresore; beim
Beitreten nicht nötig). Test-Tresor löschen:
`curl -X POST -H "Authorization: Bearer <token>" <url>/v/<tresor>/wipe`.
